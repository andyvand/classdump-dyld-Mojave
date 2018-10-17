/*	
	classdump-dyld is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    any later version.

    classdump-dyld is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
*/

#define CDLog(...) if (inDebug)NSLog(@"libclassdump-dyld : %@", [NSString stringWithFormat:__VA_ARGS__] )


#define RESET   "\033[0m"
#define BOLDWHITE   "\033[1m\033[37m"  
#define CLEARSCREEN "\e[1;1H\e[2J"

#include <objc/objc.h>
#include <stdint.h>
#include <sys/types.h>
#include <stdio.h>
#include <dlfcn.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld_images.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>

#include "../base/logging.h"
#include "../snapshot/mac/process_reader_mac.h"
#include "../test/scoped_module_handle.h"
#include "../util/numeric/safe_assignment.h"

static NSString *classID=nil;
static BOOL addHeadersFolder=NO;
static BOOL shouldImportStructs=0;
static NSMutableArray *allStructsFound=nil;
static NSMutableArray *classesInStructs=nil;
static NSMutableArray *classesInClass=nil;
static NSMutableArray *processedImages=nil;
static BOOL inDebug=NO;

#ifdef LIBMAIN
NSString * libpropertyLineGenerator(NSString *attributes,NSString *name);
NSString * libcommonTypes(NSString *atype,NSString **inName,BOOL inIvarList);
const struct dyld_all_image_infos *libdyld_all_image_infos;
#else
const struct dyld_all_image_infos *dyld_all_image_infos;
NSString * propertyLineGenerator(NSString *attributes,NSString *name);
NSString * commonTypes(NSString *atype,NSString **inName,BOOL inIvarList);
#endif

static const dyld_all_image_infos* DyldGetAllImageInfos() {
#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_13
    // When building with the pre-10.13 SDK, the weak_import declaration above is
    // available and a symbol will be present in the SDK to link against. If the
    // old interface is also available at run time (running on pre-10.13), use it.
    if (_dyld_get_all_image_infos) {
        return _dyld_get_all_image_infos();
    }
#elif MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_13
    // When building with the 10.13 SDK or later, but able to run on pre-10.13,
    // look for _dyld_get_all_image_infos in the same module that provides
    // _dyld_image_count. There’s no symbol in the SDK to link against, so this is
    // a little more involved than the pre-10.13 SDK case above.
    Dl_info dli;
    if (!dladdr(reinterpret_cast<void*>(_dyld_image_count), &dli)) {
        LOG(WARNING) << "dladdr: failed";
    } else {
        ScopedModuleHandle module(
                                  dlopen(dli.dli_fname, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD));
        if (!module.valid()) {
            LOG(WARNING) << "dlopen: " << dlerror();
        } else {
            using DyldGetAllImageInfosType = const dyld_all_image_infos*(*)();
            const auto _dyld_get_all_image_infos =
            module.LookUpSymbol<DyldGetAllImageInfosType>(
                                                          "_dyld_get_all_image_infos");
            if (_dyld_get_all_image_infos) {
                return _dyld_get_all_image_infos();
            }
        }
    }
#endif
    
    // On 10.13 and later, do it the hard way.
    crashpad::ProcessReaderMac process_reader;
    if (!process_reader.Initialize(mach_task_self())) {
        return nullptr;
    }
    
    mach_vm_address_t all_image_info_addr_m =
    process_reader.DyldAllImageInfo(nullptr);
    if (!all_image_info_addr_m) {
        return nullptr;
    }
    
    uintptr_t all_image_info_addr_u;
    if (!crashpad::AssignIfInRange(&all_image_info_addr_u, all_image_info_addr_m)) {
        LOG(ERROR) << "all_image_info_addr_m " << all_image_info_addr_m
        << " out of range";
        return nullptr;
    }
    
    return reinterpret_cast<const dyld_all_image_infos*>(all_image_info_addr_u);
}

static NSString * parseImage(char *image,BOOL writeToDisk,NSString *outputDir,BOOL getSymbols,BOOL isRecursive,BOOL buildOriginalDirs,BOOL simpleHeader,BOOL skipAlreadyFound);

@interface NSArray (extras)
-(id)reversedArray;
@end


struct cache_header {
        char version[16];
        uint32_t baseaddroff;
        uint32_t unk2;
        uint32_t startaddr;
        uint32_t numlibs;
        uint64_t dyldaddr;
};

static BOOL arch64(){
	
	#ifdef __LP64__
	return YES;
	#endif
	return NO;

}

#ifdef LIBMAIN
BOOL libis64BitMachO(const char *image){
#else
BOOL is64BitMachO(const char *image){
#endif	
	return arch64();
	/*FILE *machoFile = fopen (image, "rb");
	if (machoFile == 0){
		fclose(machoFile);
	 	return NO;
	}
	mach_header_64 machHeader;
	int n = fread (&machHeader, sizeof (machHeader), 1, machoFile);
  	if (n != 1){
	  	fclose(machoFile);
  		return NO;
  	}
  	fclose(machoFile);
	return machHeader.magic==MH_MAGIC_64;
	*/
}

/****** Helper Functions ******/


static BOOL priorToiOS7(){
	
	return ![objc_getClass("NSProcessInfo") instancesRespondToSelector:@selector(endActivity:)];

}


static NSString * copyrightMessage(char *image){

	NSAutoreleasePool *pool =[[NSAutoreleasePool  alloc] init];
	NSString *version = [NSProcessInfo processInfo ].operatingSystemVersionString;
    NSLocale *loc=[NSLocale localeWithLocaleIdentifier: @"en-us"];
    NSString *date=[NSDate.date descriptionWithLocale: loc];

	NSString *message=[[NSString alloc] initWithFormat:@"/*\n\
* This header is generated by classdump-dyld 0.7\n\
* on %@\n\
* Operating System: %@\n\
* Image Source: %s\n\
* classdump-dyld is licensed under GPLv3, Copyright \u00A9 2013-2014 by Elias Limneos.\n\
*/\n\n",date,version,image];

	[pool drain];
	
	return message;

}

#ifdef LIBMAIN
void libprintHelp()
#else
void printHelp()
#endif
{

	printf("\nclassdump-dyld v0.7. Licensed under GPLv3, Copyright \u00A9 2013-2014 by Elias Limneos.\n\n");
	printf("Usage: classdump-dyld [<options>] <filename|framework>\n");
	printf("       or\n");
	printf("       classdump-dyld [<options>] -r <sourcePath>\n\n");

	printf("Options:\n\n");

	printf("    Structure:\n");
	printf("        -g   Do not generate symbol names\n"); 
	printf("        -b   Build original directory structure in output dir\n");
	printf("        -h   Add a \"Headers\" directory to place headers in\n");
	printf("        -u   Do not include framework when importing headers (\"Header.h\" instead of <frameworkName/Header.h>)\n\n");

	printf("    Output:\n");
	printf("        -o   <outputdir> Save generated headers to defined path\n\n");

	printf("    Mass dumping: (requires -o)\n");
	printf("        -c   Dump all images found in dyld_shared_cache\n");
	printf("        -r   <sourcepath> Recursively dump any compatible Mach-O file found in the given path\n");
	printf("        -s   In a recursive dump, skip header files already found in the same output directory\n\n");

	printf("    Miscellaneous\n");
	printf("        -D   Enable debug printing for troubleshooting errors\n");
	printf("        -e   dpopen 32Bit executables instead of injecting them (iOS 5+, use if defaults fail.This will skip any 64bit executable) \n"); 
	printf("        -a   In a recursive dump, include 'Applications' directories (skipped by default) \n\n"); 

	printf("    Examples:\n");
	printf("        Example 1: classdump-dyld -o outdir /System/Library/Frameworks/UIKit.framework\n");
	printf("        Example 2: classdump-dyld -o outdir /usr/libexec/backboardd\n");
	printf("        Example 3 (recursive): classdump-dyld -o outdir -c  (Dumps all files residing in dyld_shared_cache)\n");
	printf("        Example 4 (recursive): classdump-dyld -o outdir -r /System/Library/\n");
	printf("        Example 5 (recursive): classdump-dyld -o outdir -r / -c  (Mass-dumps almost everything on device)\n\n");

}


static NSString * print_free_memory () {
   
    mach_port_t host_port;
    mach_msg_type_number_t host_size;
    vm_size_t pagesize;
    
    host_port = mach_host_self();
    host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    host_page_size(host_port, &pagesize);        
 
    vm_statistics_data_t vm_stat;
              
    if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) != KERN_SUCCESS){
        //Failed to fetch vm stats
	}
    natural_t mem_free = vm_stat.free_count * pagesize;

	if (mem_free<10000000){ // break if less than 10MB of RAM
		printf("Error: Out of memory. You can repeat with -s option to continue from where left.\n\n");
		exit(0);
	}
	if (mem_free<20000000){ // warn if less than 20MB of RAM
		return [NSString stringWithFormat:@"Low Memory: %u MB free. Might exit to prevent system hang",(mem_free/1024/1024)] ;
	}
	else{
		return [NSString stringWithCString:"" encoding:NSASCIIStringEncoding];
		//return [NSString stringWithFormat:@"Memory: %u MB free",(mem_free/1024/1024)] ;
	}
	
}


// A nice loading bar. Credits: http://www.rosshemsley.co.uk/2011/02/creating-a-progress-bar-in-c-or-any-other-console-app/
static inline void loadBar(int x, int n, int r, int w,const char *className)
{
//	return;
    // Only update r times.
    if ((n/r)<1){
    	return;
    }
    if ( x % (n/r) != 0 ) return;
 
    // Calculuate the ratio of complete-to-incomplete.
    float ratio = x/(float)n;
    int   c     = ratio * w;
 
    // Show the percentage complete.
    printf("%3d%% [", (int)(ratio*100) );
 
    // Show the load bar.
    for (int x=0; x<c; x++)
       printf("=");
 
    for (int x=c; x<w; x++)
       printf(" ");
 
    // ANSI Control codes to go back to the
    // previous line and clear it.
    printf("] %s %d/%d <%s>\n\033[F\033[J",[print_free_memory() UTF8String],x,n,className);
}


/* Note: NSMethodSignature does not support unions or unknown structs on input.
// However, using NSMethodSignature to break ObjC types apart for parsing seemed to me very convenient.
// My implementation below encodes the unknown structs 
// and unions as a special, impossible to conflict struct that is accepted on input.
// They are then decoded back in the output of getArgumentTypeAtIndex:
// This actually adds support for unions and undefined structs. */


@implementation NSMethodSignature (classdump_dyld_helper)

+(id)cd_signatureWithObjCTypes:(const char *)types{
	
	__block NSString *text=[NSString stringWithCString:types encoding:NSUTF8StringEncoding]; 
	
	if ([text rangeOfString:@"{"].location!=NSNotFound){ 
	
		BOOL FOUND=1;
		NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?<!\\^)\\{([^\\{^\\}]+)\\}" options:0 error:nil];
		while (FOUND){
			NSRange range = [regex rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0, [text length])];
			if (range.location!=NSNotFound){
				FOUND=1;
				NSString *result = [text substringWithRange:range];
				text=[text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@",result] withString:[NSString stringWithFormat:@"^^^%@",result]];
			}
			else{
				FOUND=0;
			}
		}
	
		FOUND=1;
        regex = [NSRegularExpression regularExpressionWithPattern:@"(?<!\\^)\\{([^\\}]+)\\}" options:0 error:nil];
		while (FOUND){
			NSRange range = [regex rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0, [text length])];
			if (range.location!=NSNotFound){
				FOUND=1;
				NSString *result = [text substringWithRange:range];
				text=[text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@",result] withString:[NSString stringWithFormat:@"^^^%@",result]];
			}
			else{
				FOUND=0;
			}
		}
	}

	
	while ([text rangeOfString:@"("].location!=NSNotFound){
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\(([^\\(^\\)]+)\\)" options:0 error:nil];

		[regex enumerateMatchesInString:text options:0 
                                  range:NSMakeRange(0, [text length]) 
                             usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
        {
            for (int i = 1; i< [result numberOfRanges] ; i++) {
            	NSString *textFound=[text substringWithRange:[result rangeAtIndex:i]];
            	text=[text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"(%@)",textFound] withString:[NSString stringWithFormat:@"{union={%@}ficificifloc}",textFound]]; //add an impossible match of types
                *stop=YES;
            }
        }];
	}
	
	types=[text UTF8String];

	return [self signatureWithObjCTypes:types];
}

-(const char *)cd_getArgumentTypeAtIndex:(int)anIndex{
	
	const char *argument= [self getArgumentTypeAtIndex:anIndex];
	
	NSString *char_ns=[NSString stringWithCString:argument encoding:NSUTF8StringEncoding];
	__block NSString *text=char_ns;
	if ([text rangeOfString:@"^^^"].location!=NSNotFound){
		text=[text stringByReplacingOccurrencesOfString:@"^^^" withString:@""];
	}
	
	while ([text rangeOfString:@"{union"].location!=NSNotFound){
        
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\{union.+ficificifloc\\})" options:0 error:nil];
		[regex enumerateMatchesInString:text options:0 
                                  range:NSMakeRange(0, [text length]) 
                             usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
        {
            for (int i = 1; i< [result numberOfRanges] ; i++) {
            	NSString *textFound=[text substringWithRange:[result rangeAtIndex:i]];
            	
            	NSString *textToPut=[textFound substringFromIndex:8];
            	textToPut=[textToPut substringToIndex:textToPut.length-1-(@"ficificifloc".length+1)];
            	text=[text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%@",textFound] withString:[NSString stringWithFormat:@"(%@)",textToPut]];
        	    *stop=YES;
            }
        }];
	
	}
	
	char_ns=text;
	 
	return [char_ns UTF8String];

}
@end



/****** String Parsing Functions ******/


/****** Properties Parser ******/

#ifdef LIBMAIN
NSString * libpropertyLineGenerator(NSString *attributes,NSString *name){
#else
NSString * propertyLineGenerator(NSString *attributes,NSString *name){
#endif	
	NSCharacterSet *parSet=[NSCharacterSet characterSetWithCharactersInString:@"()"];
	attributes=[attributes stringByTrimmingCharactersInSet:parSet];
	NSMutableArray *attrArr=(NSMutableArray *)[attributes componentsSeparatedByString:@","];
	NSString *type=[attrArr objectAtIndex:0] ;
	
	type=[type stringByReplacingCharactersInRange:NSMakeRange(0,1) withString:@""] ; 
	if ([type rangeOfString:@"@"].location==0 && [type rangeOfString:@"\""].location!=NSNotFound){ //E.G. @"NSTimer"
		type=[type stringByReplacingOccurrencesOfString:@"\"" withString:@""];
		type=[type stringByReplacingOccurrencesOfString:@"@" withString:@""];
		type=[type stringByAppendingString:@" *"] ;
		NSString *classFoundInProperties=[type stringByReplacingOccurrencesOfString:@" *" withString:@""];
		if (![classesInClass containsObject:classFoundInProperties] && [classFoundInProperties rangeOfString:@"<"].location==NSNotFound){
			[classesInClass addObject:classFoundInProperties];
		}
		if ([type rangeOfString:@"<"].location!=NSNotFound){
			type=[type stringByReplacingOccurrencesOfString:@"> *" withString:@">"];
			if ([type rangeOfString:@"<"].location==0){
				type=[@"id" stringByAppendingString:type];
			}
			else{
				type=[type stringByReplacingOccurrencesOfString:@"<" withString:@"*<"];			
			}
		}
	}
	else if ([type rangeOfString:@"@"].location==0 && [type rangeOfString:@"\""].location==NSNotFound){
		type=@"id";
	}
	else{
#ifdef LIBMAIN
		type=libcommonTypes(type,&name,NO);
#else
		type=commonTypes(type,&name,NO);
#endif
	}	
	if ([type rangeOfString:@"="].location!=NSNotFound){ 
		type=[type substringToIndex:[type rangeOfString:@"="].location];
		if ([type rangeOfString:@"_"].location==0){
			
			type=[type substringFromIndex:1];
		}
	}

	type=[type stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	attrArr=[NSMutableArray arrayWithArray:attrArr];
	[attrArr removeObjectAtIndex:0];
	NSMutableArray *newPropsArray=[NSMutableArray array];
	NSString *synthesize=@"";
	for (NSString *attr in attrArr){
		
		NSString *vToClear=nil;		
			
		if ([attr rangeOfString:@"V_"].location==0){
			vToClear=attr;
			attr=[attr stringByReplacingCharactersInRange:NSMakeRange(0,2) withString:@""] ;
			synthesize=[NSString stringWithFormat:@"\t\t\t\t//@synthesize %@=_%@ - In the implementation block",attr,attr];
		}
			
		if ([attr length]==1){
				
			 	NSString *translatedProperty = attr;
				if ([attr isEqual:@"R"]){ translatedProperty = @"readonly"; }
				if ([attr isEqual:@"C"]){ translatedProperty = @"copy"; }
				if ([attr isEqual:@"&"]){ translatedProperty = @"retain"; }
				if ([attr isEqual:@"N"]){ translatedProperty = @"nonatomic";}
				//if ([attr isEqual:@"D"]){ translatedProperty = @"@dynamic"; }
				if ([attr isEqual:@"D"]){ continue; }
				if ([attr isEqual:@"W"]){ translatedProperty = @"__weak"; }
				if ([attr isEqual:@"P"]){ translatedProperty = @"t<encoding>";}
				 
			 
			[newPropsArray addObject:translatedProperty];
		}
			
		if ([attr rangeOfString:@"G"].location==0){
			attr=[attr  stringByReplacingCharactersInRange:NSMakeRange(0,1) withString:@""] ;
			attr=[NSString stringWithFormat:@"getter=%@",attr];
			[newPropsArray addObject:attr];
		}
			
		if ([attr rangeOfString:@"S"].location==0){
			attr=[attr  stringByReplacingCharactersInRange:NSMakeRange(0,1) withString:@""] ;
			attr=[NSString stringWithFormat:@"setter=%@",attr];
			[newPropsArray addObject:attr];
		}
			
	}
		
	if ([newPropsArray containsObject:@"nonatomic"] && ![newPropsArray containsObject:@"assign"] && ![newPropsArray containsObject:@"readonly"] && ![newPropsArray containsObject:@"copy"] && ![newPropsArray containsObject:@"retain"]){
		[newPropsArray addObject:@"assign"];
	}
		
	newPropsArray=[newPropsArray reversedArray];
			
	NSString *rebuiltString=[newPropsArray componentsJoinedByString:@","];
	NSString *attrString=[newPropsArray count]>0 ? [NSString stringWithFormat:@"(%@)",rebuiltString] : @"(assign)";
	
	
	return [[NSString alloc] initWithFormat:@"\n%@%@ %@ %@; %@",@"@property ",attrString,type,name,synthesize];

}




/****** Properties Combined Array (for fixing non-matching types)   ******/

static NSMutableArray * propertiesArrayFromString(NSString *propertiesString){

	NSMutableArray *propertiesExploded=[[propertiesString componentsSeparatedByString:@"\n"] mutableCopy];
	NSMutableArray *typesAndNamesArray=[NSMutableArray array];

	for (NSString *string in propertiesExploded){		
	
		if (string.length<1){
			continue;
		}	 
		
		int startlocation=[string rangeOfString:@")"].location;
		int endlocation=[string rangeOfString:@";"].location;
		if ([string rangeOfString:@";"].location==NSNotFound || [string rangeOfString:@")"].location==NSNotFound){
			continue;
		}
		
		NSString *propertyTypeFound=[string substringWithRange:NSMakeRange(startlocation+1,endlocation-startlocation-1)];
		int firstSpaceLocationBackwards=[propertyTypeFound rangeOfString:@" " options:NSBackwardsSearch].location;
		if ([propertyTypeFound rangeOfString:@" " options:NSBackwardsSearch].location==NSNotFound){
			continue;
		}
		
		NSMutableDictionary *typesAndNames=[NSMutableDictionary dictionary];
		
		NSString *propertyNameFound=[propertyTypeFound substringFromIndex:firstSpaceLocationBackwards+1];
		propertyTypeFound=[propertyTypeFound substringToIndex:firstSpaceLocationBackwards];
		//propertyTypeFound=[propertyTypeFound stringByReplacingOccurrencesOfString:@" " withString:@""];
		if ([propertyTypeFound rangeOfString:@" "].location==0){
			propertyTypeFound=[propertyTypeFound substringFromIndex:1];
		}
		propertyNameFound=[propertyNameFound stringByReplacingOccurrencesOfString:@" " withString:@""];
		
		[typesAndNames setObject:propertyTypeFound forKey:@"type"];
		[typesAndNames setObject:propertyNameFound forKey:@"name"];
		[typesAndNamesArray addObject:typesAndNames];

	}
	[propertiesExploded release];
	return typesAndNamesArray;
}






/****** Protocol Parser ******/

#ifdef LIBMAIN
NSString * libbuildProtocolFile(Protocol *currentProtocol){
#else
NSString * buildProtocolFile(Protocol *currentProtocol){
#endif	
	NSString * protocolsMethodsString=@"";

	NSString *protocolName=[NSString stringWithCString:protocol_getName(currentProtocol) encoding:NSUTF8StringEncoding];
	protocolsMethodsString=[protocolsMethodsString stringByAppendingString:[NSString stringWithFormat:@"\n@protocol %@",protocolName]];
	NSMutableArray *classesInProtocol=[[NSMutableArray alloc] init];
	
	unsigned int outCount=0;
	Protocol ** protList=protocol_copyProtocolList(currentProtocol,&outCount);
	if (outCount>0){
		protocolsMethodsString=[protocolsMethodsString stringByAppendingString:@" <"];
	}
	for (int p=0; p<outCount; p++){
		NSString *end= p==outCount-1 ? @"" : @",";
		protocolsMethodsString=[protocolsMethodsString stringByAppendingString:[NSString stringWithFormat:@"%s%@",protocol_getName(protList[p]),end]];
	}
	if (outCount>0){
		protocolsMethodsString=[protocolsMethodsString stringByAppendingString:@">"];
	}
	free(protList);
	
	NSString *protPropertiesString=@"";
	unsigned int protPropertiesCount;
	objc_property_t * protPropertyList=protocol_copyPropertyList(currentProtocol,&protPropertiesCount);
	for (int xi=0; xi<protPropertiesCount; xi++){
		
		const char *propname=property_getName(protPropertyList[xi]);
		const char *attrs=property_getAttributes(protPropertyList[xi]);
		
		
		NSCharacterSet *parSet=[NSCharacterSet characterSetWithCharactersInString:@"()"];
		NSString *attributes=[[NSString stringWithCString:attrs encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:parSet];
		NSMutableArray *attrArr=(NSMutableArray *)[attributes componentsSeparatedByString:@","];
		NSString *type=[attrArr objectAtIndex:0] ;
	
		type=[type stringByReplacingCharactersInRange:NSMakeRange(0,1) withString:@""] ; 
		if ([type rangeOfString:@"@"].location==0 && [type rangeOfString:@"\""].location!=NSNotFound){ //E.G. @"NSTimer"
			type=[type stringByReplacingOccurrencesOfString:@"\"" withString:@""];
			type=[type stringByReplacingOccurrencesOfString:@"@" withString:@""];
			type=[type stringByAppendingString:@" *"] ;
			NSString *classFoundInProperties=[type stringByReplacingOccurrencesOfString:@" *" withString:@""];
			if (![classesInProtocol containsObject:classFoundInProperties] && [classFoundInProperties rangeOfString:@"<"].location==NSNotFound){
				[classesInProtocol addObject:classFoundInProperties];
			}
		}
		
#ifdef LIBMAIN
                NSString *newString=libpropertyLineGenerator([NSString stringWithCString:attrs encoding:NSUTF8StringEncoding],[NSString stringWithCString:propname encoding:NSUTF8StringEncoding]);
#else
		NSString *newString=propertyLineGenerator([NSString stringWithCString:attrs encoding:NSUTF8StringEncoding],[NSString stringWithCString:propname encoding:NSUTF8StringEncoding]);
#endif
		if ([protPropertiesString rangeOfString:newString].location==NSNotFound){
			protPropertiesString=[protPropertiesString stringByAppendingString:newString];
		}
		[newString release];

	}
	protocolsMethodsString=[protocolsMethodsString stringByAppendingString:protPropertiesString];
	free(protPropertyList);
	
	for (int acase=0; acase<4; acase++){
		
		unsigned int protocolMethodsCount=0;
		BOOL isRequiredMethod=acase<2 ? NO : YES;
		BOOL isInstanceMethod=(acase==0 || acase==2) ? NO : YES;
								
		objc_method_description *protMeths=protocol_copyMethodDescriptionList(currentProtocol, isRequiredMethod, isInstanceMethod, &protocolMethodsCount);
		for (unsigned gg=0; gg<protocolMethodsCount; gg++){
			if (acase<2 && [protocolsMethodsString rangeOfString:@"@optional"].location==NSNotFound){
				protocolsMethodsString=[protocolsMethodsString stringByAppendingString:@"\n@optional\n"];
			}
			if (acase>1 && [protocolsMethodsString rangeOfString:@"@required"].location==NSNotFound){
				protocolsMethodsString=[protocolsMethodsString stringByAppendingString:@"\n@required\n"];
			}
			NSString *startSign=isInstanceMethod==NO ? @"+" : @"-";
			objc_method_description selectorsAndTypes=protMeths[gg];
			SEL selector=selectorsAndTypes.name;
			char *types=selectorsAndTypes.types;
			NSString *protSelector=NSStringFromSelector(selector);
			NSString *finString=@"";
			NSMethodSignature *signature=[NSMethodSignature cd_signatureWithObjCTypes:types];

#ifdef LIBMAIN
                        NSString *returnType=libcommonTypes([NSString stringWithCString:[signature methodReturnType] encoding:NSUTF8StringEncoding],nil,NO);
#else
			NSString *returnType=commonTypes([NSString stringWithCString:[signature methodReturnType] encoding:NSUTF8StringEncoding],nil,NO);
#endif
			NSArray *selectorsArray=[protSelector componentsSeparatedByString:@":"];
			if (selectorsArray.count>1){
				int argCount=0;
				for (unsigned ad=2;ad<[signature numberOfArguments]; ad++){	
					argCount++;
					NSString *space=ad==[signature numberOfArguments]-1 ? @"" : @" ";
#ifdef LIBMAIN
                                        finString=[finString stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d%@" ,[selectorsArray objectAtIndex:ad-2],libcommonTypes([NSString stringWithCString:[signature cd_getArgumentTypeAtIndex:ad] encoding:NSUTF8StringEncoding],nil,NO),argCount,space]];
#else
					finString=[finString stringByAppendingString:[NSString stringWithFormat:@"%@:(%@)arg%d%@" ,[selectorsArray objectAtIndex:ad-2],commonTypes([NSString stringWithCString:[signature cd_getArgumentTypeAtIndex:ad] encoding:NSUTF8StringEncoding],nil,NO),argCount,space]];
#endif
				}				
			}
			else{
				finString=[finString stringByAppendingString:[NSString stringWithFormat:@"%@" ,[selectorsArray objectAtIndex:0]] ];	
			}
			finString=[finString stringByAppendingString:@";"];
			protocolsMethodsString=[protocolsMethodsString stringByAppendingString:[NSString stringWithFormat:@"%@(%@)%@\n",startSign,returnType,finString]];		
		}
		free(protMeths);
	}
	
	//FIX EQUAL TYPES OF PROPERTIES AND METHODS 
	NSArray *propertiesArray=propertiesArrayFromString(protPropertiesString);
	NSArray *lines=[protocolsMethodsString componentsSeparatedByString:@"\n"];
	NSString *finalString=@"";
	for (NSString *line in lines){
		if (line.length>0 && ([line rangeOfString:@"-"].location==0 || [line rangeOfString:@"+"].location==0)){
			NSString *methodInLine=[line substringFromIndex:[line rangeOfString:@")"].location+1];
			methodInLine=[methodInLine substringToIndex:[methodInLine rangeOfString:@";"].location];
			for (NSDictionary *dict in propertiesArray){
				NSString *propertyName=[dict objectForKey:@"name"];
				if ([methodInLine rangeOfString:@"set"].location!=NSNotFound){
					NSString *firstCapitalized=[[propertyName substringToIndex:1] capitalizedString];
					NSString *capitalizedFirst=[firstCapitalized stringByAppendingString:[propertyName substringFromIndex:1]];
					if ([methodInLine isEqual:[NSString stringWithFormat:@"set%@",capitalizedFirst] ]){
						// replace setter	
						NSString *newLine=[line substringToIndex:[line rangeOfString:@":("].location+2];
						newLine=[newLine stringByAppendingString:[dict objectForKey:@"type"]];
						newLine=[newLine stringByAppendingString:[line substringFromIndex:[line rangeOfString:@")" options:4].location]];
						line=newLine;
					}
				}
				if ([methodInLine isEqual:propertyName]){
					NSString *newLine=[line substringToIndex:[line rangeOfString:@"("].location+1];
					newLine=[newLine stringByAppendingString:[NSString stringWithFormat:@"%@)%@;",[dict objectForKey:@"type"],[dict objectForKey:@"name"]]];
					line=newLine;
				}
			}
			
		}
		finalString=[finalString stringByAppendingString:[line stringByAppendingString:@"\n"]];
	}
	
	
	if ([classesInProtocol count]>0){
		 
		NSMutableString *classesFoundToAdd=[[NSMutableString alloc] init];
		[classesFoundToAdd appendString:@"@class "];
		for (int f=0; f<classesInProtocol.count; f++){
			NSString *classFound=[classesInProtocol objectAtIndex:f];
			if (f<classesInProtocol.count-1){
				[classesFoundToAdd appendString:[NSString stringWithFormat:@"%@, ",classFound]];
			}
			else{
				[classesFoundToAdd appendString:[NSString stringWithFormat:@"%@;",classFound]];
			}
		}
		[classesFoundToAdd appendString:@"\n\n"];
		finalString=[classesFoundToAdd stringByAppendingString:finalString];	
		[classesFoundToAdd release];		
	}
	[classesInProtocol release];
	
	
	return [finalString stringByAppendingString:@"@end\n\n"];

}



static BOOL hasMalformedID(NSString *parts){
	
	if  ([parts rangeOfString:@"@\""].location!=NSNotFound && [parts rangeOfString:@"@\""].location+2<parts.length-1 &&  ([[parts substringFromIndex:[parts rangeOfString:@"@\""].location+2] rangeOfString:@"\""].location==[[parts substringFromIndex:[parts rangeOfString:@"@\""].location+2] rangeOfString:@"\"\""].location || [[parts substringFromIndex:[parts rangeOfString:@"@\""].location+2] rangeOfString:@"\""].location==[[parts substringFromIndex:[parts rangeOfString:@"@\""].location+2] rangeOfString:@"\"]"].location  || [[parts substringFromIndex:[parts rangeOfString:@"@\""].location+2] rangeOfString:@"\""].location==[parts substringFromIndex:[parts rangeOfString:@"@\""].location+2].length-1)){
		return YES;
	}
	
	return NO;

}

/****** Structs Parser ******/


static NSString *representedStructFromStruct(NSString *inStruct,NSString *inName, BOOL inIvarList,BOOL isFinal){


	if ([inStruct rangeOfString:@"\""].location==NSNotFound){ // not an ivar type struct, it has the names of types in quotes

		if ([inStruct rangeOfString:@"{?="].location==0){

			// UNKNOWN TYPE, WE WILL CONSTRUCT IT
			
			NSString *types=[inStruct substringFromIndex:3];
			types=[types substringToIndex:types.length-1];
			for (NSDictionary *dict in allStructsFound){

				if ([[dict objectForKey:@"types"] isEqual:types]){
				
					return [dict objectForKey:@"name"]; 
				}
			}
			
			__block NSMutableArray *strctArray=[NSMutableArray array];

			while ([types rangeOfString:@"{"].location!=NSNotFound){
			
				NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\{([^\\{^\\}]+)\\}" options:NSRegularExpressionCaseInsensitive error:nil];
				__block NSString *blParts;
				[regex enumerateMatchesInString:types options:0 
							   range:NSMakeRange(0, [types length]) 
							 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
				{
				
					for (int i = 1; i< [result numberOfRanges] ; i++) {
						NSString *stringToPut=representedStructFromStruct([NSString stringWithFormat:@"{%@}",[types substringWithRange:[result rangeAtIndex:i]]],nil,NO,0);
						blParts=[types stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}",[types substringWithRange:[result rangeAtIndex:i]]] withString:stringToPut];
						if ([blParts rangeOfString:@"{"].location==NSNotFound){
							[strctArray addObject:stringToPut];
						}
						break;
					}

				}];

				types=blParts;
			}
	
			NSMutableArray *alreadyFoundStructs=[NSMutableArray array];
			for (NSDictionary *dict in allStructsFound){

				if ([types rangeOfString:[dict objectForKey:@"name"]].location!=NSNotFound || [types rangeOfString:@"CFDictionary"].location!=NSNotFound ){
				
					BOOL isCFDictionaryHackException=0;
					NSString *str;
					
					if ([types rangeOfString:@"CFDictionary"].location!=NSNotFound){
						str=@"CFDictionary";
						isCFDictionaryHackException=1;
					}
					else{
						str=[dict objectForKey:@"name"];
					}
					
					while ([types rangeOfString:str].location!=NSNotFound){
						if ([str isEqual:@"CFDictionary"]){
							[alreadyFoundStructs addObject:@"void*"];
						}
						else{
							[alreadyFoundStructs addObject:str];
						}
						int replaceLocation=[types rangeOfString:str].location;
						int replaceLength=str.length;
						types=[types stringByReplacingCharactersInRange:NSMakeRange(replaceLocation,replaceLength) withString:@"+"];
					}
					
				}
			}
	

			__block NSMutableArray *arrArray=[NSMutableArray array];

			while ([types rangeOfString:@"["].location!=NSNotFound){

				NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\[^\\]]+)\\]" options:NSRegularExpressionCaseInsensitive error:nil];
				__block NSString *blParts2;

				[regex enumerateMatchesInString:types options:0 
							   range:NSMakeRange(0, [types length]) 
							 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
				{
					
					for (int i = 1; i< [result numberOfRanges] ; i++) {	
						NSString *stringToPut=[NSString stringWithFormat:@"[%@]",[types substringWithRange:[result rangeAtIndex:i]]];
						NSRange range=[types rangeOfString:stringToPut];
						
						blParts2=[types stringByReplacingCharactersInRange:NSMakeRange(range.location,range.length) withString:@"~"];
						
							[arrArray addObject:stringToPut];
						
						*stop=1;
						break;

					}

				}];

				types=blParts2;
			}

			__block NSMutableArray *bitArray=[NSMutableArray array];

			while ([types rangeOfString:@"b1"].location!=NSNotFound || [types rangeOfString:@"b2"].location!=NSNotFound || [types rangeOfString:@"b3"].location!=NSNotFound || [types rangeOfString:@"b4"].location!=NSNotFound || [types rangeOfString:@"b5"].location!=NSNotFound || [types rangeOfString:@"b6"].location!=NSNotFound || [types rangeOfString:@"b7"].location!=NSNotFound || [types rangeOfString:@"b8"].location!=NSNotFound || [types rangeOfString:@"b9"].location!=NSNotFound){

			NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(b[0-9]+)" options:0 error:nil];
				__block NSString *blParts3;
				[regex enumerateMatchesInString:types options:0 
							   range:NSMakeRange(0, [types length]) 
							 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
				{
					
					for (int i = 1; i< [result numberOfRanges] ; i++) {	
						NSString *stringToPut=[types substringWithRange:[result rangeAtIndex:i]];
						blParts3=[types stringByReplacingOccurrencesOfString:[types substringWithRange:[result rangeAtIndex:i]] withString:@"§"];
						[bitArray addObject:stringToPut];
						break;
					}

				}];

				types=blParts3;
			}

			for (NSString *string in strctArray){
				if ([types rangeOfString:string].location==NSNotFound){
					break;
				}
				int loc=[types rangeOfString:string].location;
				int length=string.length;
				types=[types stringByReplacingCharactersInRange:NSMakeRange(loc,length) withString:@"!"];
			}
			
			
			int fieldCount=0;
			
			for (int i=0; i<types.length; i++){
				
				NSString *string=[types substringWithRange:NSMakeRange(i,1)];
				if (![string isEqual:@"["] && ![string isEqual:@"]"] && ![string isEqual:@"{"] && ![string isEqual:@"}"] && ![string isEqual:@"\""] && ![string isEqual:@"b"] && ![string isEqual:@"("] && ![string isEqual:@")"]  ){
					fieldCount++;
#ifdef LIBMAIN
                                        NSString *newString=[NSString stringWithFormat:@"\"field%d\"%@",fieldCount,libcommonTypes(string,nil,NO)];
                                        types=[types stringByReplacingCharactersInRange:NSMakeRange(i,1) withString:[NSString stringWithFormat:@"\"field%d\"%@",fieldCount,libcommonTypes(string,nil,NO)]];
#else
					NSString *newString=[NSString stringWithFormat:@"\"field%d\"%@",fieldCount,commonTypes(string,nil,NO)];
                                        types=[types stringByReplacingCharactersInRange:NSMakeRange(i,1) withString:[NSString stringWithFormat:@"\"field%d\"%@",fieldCount,commonTypes(string,nil,NO)]];
#endif
					i+=newString.length-1;
				}
			
			}
			
			int fCounter=-1; // Separate counters used for debugging purposes
			
			while ([types rangeOfString:@"!"].location!=NSNotFound){
				fCounter++;
				int loc=[types rangeOfString:@"!"].location;
				types=[types stringByReplacingCharactersInRange:NSMakeRange(loc,1) withString:[strctArray objectAtIndex:fCounter]];
				
			}
			
			int fCounter2=-1;
			
			while ([types rangeOfString:@"~"].location!=NSNotFound){
				fCounter2++;
				int loc=[types rangeOfString:@"~"].location;
				types=[types stringByReplacingCharactersInRange:NSMakeRange(loc,1) withString:[arrArray objectAtIndex:fCounter2]];
				
			}
			
			int fCounter3=-1;
		
			while ([types rangeOfString:@"§"].location!=NSNotFound){
				fCounter3++;
				int loc=[types rangeOfString:@"§"].location;
				types=[types stringByReplacingCharactersInRange:NSMakeRange(loc,1) withString:[bitArray objectAtIndex:fCounter3]];
				
			}
			
			int fCounter4=-1;
		
			while ([types rangeOfString:@"+"].location!=NSNotFound){
				fCounter4++;
				int loc=[types rangeOfString:@"+"].location;
				types=[types stringByReplacingCharactersInRange:NSMakeRange(loc,1) withString:[alreadyFoundStructs objectAtIndex:fCounter4]];
				
			}
			
			NSString *whatIBuilt=[NSString stringWithFormat:@"{?=%@}",types];
			NSString *whatIReturn=representedStructFromStruct(whatIBuilt,nil,NO,YES);    		
			return whatIReturn;
		
		}
		
		else{
		
			if ([inStruct rangeOfString:@"="].location==NSNotFound){
				inStruct=[inStruct stringByReplacingOccurrencesOfString:@"{" withString:@""];
				inStruct=[inStruct stringByReplacingOccurrencesOfString:@"}" withString:@""];				
				return inStruct ;
			}
			int firstIson=[inStruct rangeOfString:@"="].location;
			inStruct=[inStruct substringToIndex:firstIson];
			
			inStruct=[inStruct substringFromIndex:1];
			return inStruct;
			
		}
		
	}
	
	int firstBrace=[inStruct rangeOfString:@"{"].location;
	int ison=[inStruct rangeOfString:@"="].location;
	NSString *structName=[inStruct substringWithRange:NSMakeRange(firstBrace+1,ison-1)];
	
	NSString *parts=[inStruct substringFromIndex:ison+1];
	parts=[parts substringToIndex:parts.length-1]; // remove last character "}" 
	
	if ([parts rangeOfString:@"{"].location==NSNotFound){ //does not contain other struct
	
		if  (hasMalformedID(parts)){

			while ([parts rangeOfString:@"@"].location!=NSNotFound && hasMalformedID(parts)){
				
				NSString *trialString=[parts substringFromIndex:[parts rangeOfString:@"@"].location+2];
				if ([trialString rangeOfString:@"\""].location!=[trialString rangeOfString:@"\"\""].location && [trialString rangeOfString:@"\""].location!=trialString.length-1 && [trialString rangeOfString:@"]"].location!=[trialString rangeOfString:@"\""].location+1){
					int location=[parts rangeOfString:@"@"].location;
					parts=[parts stringByReplacingCharactersInRange:NSMakeRange(location-1,3) withString:@"\"id\""];
				}

				int location=[parts rangeOfString:@"@"].location;
				
				if ([parts rangeOfString:@"@"].location!=NSNotFound){
					NSString *asubstring=[parts substringFromIndex:location+2];

					int nextlocation=[asubstring rangeOfString:@"\""].location;
					asubstring=[asubstring substringWithRange:NSMakeRange(0,nextlocation)];
					if ([classesInStructs indexOfObject:asubstring]==NSNotFound){
						[classesInStructs addObject:asubstring];
					}

					parts=[parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"@\"%@\"",asubstring] withString:[NSString stringWithFormat:@"^%@",asubstring]];
				}

			}
		}
	
		NSMutableArray *brokenParts=[[parts componentsSeparatedByString:@"\""] mutableCopy];
		[brokenParts removeObjectAtIndex:0];
		NSString *types=@"";
		
		BOOL reallyIsFlagInIvars=0;
		if (inIvarList && [inName rangeOfString:@"flags" options:NSCaseInsensitiveSearch].location!=NSNotFound){
			reallyIsFlagInIvars=1;
		}
		BOOL wasKnown=1;
		if ([structName isEqual:@"?"]){
			wasKnown=0;
			structName=[NSString stringWithFormat:@"SCD_Struct_%@%d",classID,(int)[allStructsFound count]];
		}
		
		if ([structName rangeOfString:@"_"].location==0){
			
			structName=[structName substringFromIndex:1];
		}
		
		NSString *representation=reallyIsFlagInIvars ? @"struct {\n" : (wasKnown ? [NSString stringWithFormat:@"typedef struct %@ {\n",structName] : @"typedef struct {\n");
		for (int i=0; i<[brokenParts count]-1; i+=2){ // always an even number
			NSString *nam=[brokenParts objectAtIndex:i];
			NSString *typ=[brokenParts objectAtIndex:i+1];
			types=[types stringByAppendingString:[brokenParts objectAtIndex:i+1]];
#ifdef LIBMAIN
                        representation=reallyIsFlagInIvars ? [representation stringByAppendingString:[NSString stringWithFormat:@"\t\t%@ %@;\n",libcommonTypes(typ,&nam,NO),nam]] : [representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n",libcommonTypes(typ,&nam,NO),nam]];
#else
			representation=reallyIsFlagInIvars ? [representation stringByAppendingString:[NSString stringWithFormat:@"\t\t%@ %@;\n",commonTypes(typ,&nam,NO),nam]] : [representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n",commonTypes(typ,&nam,NO),nam]];
#endif
		}
		
		representation=reallyIsFlagInIvars ? [representation stringByAppendingString:@"\t} "] : [representation stringByAppendingString: @"} "];
		if ([structName rangeOfString:@"_"].location==0){
			structName=[structName substringFromIndex:1];
		}
		if ([structName rangeOfString:@"_"].location==0){
			structName=[structName substringFromIndex:1];
		}
		representation=reallyIsFlagInIvars ? representation : [representation stringByAppendingString:[NSString stringWithFormat:@"%@;\n\n",structName]];


		if (isFinal && !reallyIsFlagInIvars){

			for (NSMutableDictionary *dict in allStructsFound){

				if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown && ![[dict objectForKey:@"name"] isEqual:[dict objectForKey:@"types"]]){
					NSString *repr=[dict objectForKey:@"representation"];
					
					if ([repr rangeOfString:@"field"].location!=NSNotFound && [representation rangeOfString:@"field"].location==NSNotFound && ![structName isEqual:types]){
						representation=[representation stringByReplacingOccurrencesOfString:structName withString:[dict objectForKey:@"name"]];
						[dict setObject:representation forKey:@"representation"];
						structName=[dict objectForKey:@"name"];
					
						break;
					}

				}

			}

		}
		
		
		BOOL found=NO;
		for (NSDictionary *dict in allStructsFound){
			if ([[dict objectForKey:@"name"] isEqual:structName]){
				
				found=YES;
				return structName;
				break;
		
			}
		}

		if (!found){
			for (NSMutableDictionary *dict in allStructsFound){
				if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown){
					found=YES;
					return [dict objectForKey:@"name"];
				}
			}
		}
		
		
		if (!found && !reallyIsFlagInIvars){
			[allStructsFound addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:representation,@"representation",structName,@"name",types,@"types",nil]];	
		}
		
		
		return reallyIsFlagInIvars ? representation : structName;
		
	}
	else{
		// contains other structs,attempt to break apart
	
		while ([parts rangeOfString:@"{"].location!=NSNotFound){
			
			NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\{([^\\{^\\}]+)\\}" options:NSRegularExpressionCaseInsensitive error:nil];
			__block NSString *blParts;
			[regex enumerateMatchesInString:parts options:0 
							  range:NSMakeRange(0, [parts length]) 
						 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
			{
				for (int i = 1; i< [result numberOfRanges] ; i++) {
					blParts=[parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}",[parts substringWithRange:[result rangeAtIndex:i]]] withString:representedStructFromStruct([NSString stringWithFormat:@"{%@}",[parts substringWithRange:[result rangeAtIndex:i]]],nil,NO,0)];
					break;
				}
			}];
			parts=blParts;
			
		}
		NSString *rebuiltStruct=[NSString stringWithFormat:@"{%@=%@}",structName,parts];
		NSString *final=representedStructFromStruct(rebuiltStruct,nil,NO,YES);
		return final;
	}

	return inStruct;
}



/****** Unions Parser ******/

#ifdef LIBMAIN
NSString *librepresentedUnionFromUnion(NSString *inUnion){
#else
NSString *representedUnionFromUnion(NSString *inUnion){
#endif
	if ([inUnion rangeOfString:@"\""].location==NSNotFound){


			if ([inUnion rangeOfString:@"{?="].location==0){
					
				NSString *types=[inUnion substringFromIndex:3];
				types=[types substringToIndex:types.length-1];
				for (NSDictionary *dict in allStructsFound){
					if ([[dict objectForKey:@"types"] isEqual:types]){
						return [dict objectForKey:@"name"]; 
					}
				}	
				return inUnion;
			}
			else{
				if ([inUnion rangeOfString:@"="].location==NSNotFound){
					inUnion=[inUnion stringByReplacingOccurrencesOfString:@"{" withString:@""];
					inUnion=[inUnion stringByReplacingOccurrencesOfString:@"}" withString:@""];					
					return inUnion ;
				}
				int firstIson=[inUnion rangeOfString:@"="].location;
				inUnion=[inUnion substringToIndex:firstIson];
				inUnion=[inUnion substringFromIndex:1];
				return inUnion;
			}
	}

	int firstParenthesis=[inUnion rangeOfString:@"("].location;
	int ison=[inUnion rangeOfString:@"="].location;
	NSString *unionName=[inUnion substringWithRange:NSMakeRange(firstParenthesis+1,ison-1)];
	
	NSString *parts=[inUnion substringFromIndex:ison+1];
	parts=[parts substringToIndex:parts.length-1]; // remove last character "}" 
	
	if ([parts rangeOfString:@"\"\"{"].location!=NSNotFound){
		parts=[parts stringByReplacingOccurrencesOfString:@"\"\"{" withString:@"\"field0\"{"];
	}
	
	if ([parts rangeOfString:@"("].location!=NSNotFound){
				
		while ([parts rangeOfString:@"("].location!=NSNotFound){

			NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\(([^\\(^\\)]+)\\)" options:NSRegularExpressionCaseInsensitive error:nil];
			__block NSString *unionParts;
			[regex enumerateMatchesInString:parts options:0 
							  range:NSMakeRange(0, [parts length]) 
						 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
			{
				for (int i = 1; i< [result numberOfRanges] ; i++) {
#ifdef LIBMAIN
                                        unionParts=[parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"(%@)",[parts substringWithRange:[result rangeAtIndex:i]]] withString:librepresentedUnionFromUnion([NSString stringWithFormat:@"(%@)",[parts substringWithRange:[result rangeAtIndex:i]]])];
#else
					unionParts=[parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"(%@)",[parts substringWithRange:[result rangeAtIndex:i]]] withString:representedUnionFromUnion([NSString stringWithFormat:@"(%@)",[parts substringWithRange:[result rangeAtIndex:i]]])];
#endif
					break;
				}
			}];
			parts=unionParts;
		}
			
	}


	if ([parts rangeOfString:@"{"].location!=NSNotFound){
				
		while ([parts rangeOfString:@"{"].location!=NSNotFound){
       			
			NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\{([^\\{^\\}]+)\\}" options:NSRegularExpressionCaseInsensitive error:nil];
			__block NSString *structParts;
			[regex enumerateMatchesInString:parts options:0 
							  range:NSMakeRange(0, [parts length]) 
						 usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
			{
				for (int i = 1; i< [result numberOfRanges] ; i++) {
					structParts=[parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}",[parts substringWithRange:[result rangeAtIndex:i]]] withString:representedStructFromStruct([NSString stringWithFormat:@"{%@}",[parts substringWithRange:[result rangeAtIndex:i]]],nil,NO,NO)];
					break;
				}
			}];
			parts=structParts;
        }
			
	}
			
		
	if  (hasMalformedID(parts)){

		while ([parts rangeOfString:@"@"].location!=NSNotFound && hasMalformedID(parts)){
			
			NSString *trialString=[parts substringFromIndex:[parts rangeOfString:@"@"].location+2];
		
			if ([trialString rangeOfString:@"\""].location!=[trialString rangeOfString:@"\"\""].location && [trialString rangeOfString:@"\""].location!=trialString.length-1 && [trialString rangeOfString:@"]"].location!=[trialString rangeOfString:@"\""].location+1){
				int location=[parts rangeOfString:@"@"].location;
				parts=[parts stringByReplacingCharactersInRange:NSMakeRange(location-1,3) withString:@"\"id\""];
			}

			int location=[parts rangeOfString:@"@"].location;

			if ([parts rangeOfString:@"@"].location!=NSNotFound){
				NSString *asubstring=[parts substringFromIndex:location+2];

				int nextlocation=[asubstring rangeOfString:@"\""].location;
				asubstring=[asubstring substringWithRange:NSMakeRange(0,nextlocation)];
				if ([classesInStructs indexOfObject:asubstring]==NSNotFound){
					[classesInStructs addObject:asubstring];
				}
			
				parts=[parts stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"@\"%@\"",asubstring] withString:[NSString stringWithFormat:@"^%@",asubstring]];
			}

		}
	}
		
		
	NSMutableArray *brokenParts=[[parts componentsSeparatedByString:@"\""] mutableCopy];
	[brokenParts removeObjectAtIndex:0];
	NSString *types=@"";
	
	BOOL wasKnown=1;
	
	if ([unionName isEqual:@"?"]){
		wasKnown=0;
		unionName=[NSString stringWithFormat:@"SCD_Union_%@%d",classID,(int)[allStructsFound count]];
	}
	
	if ([unionName rangeOfString:@"_"].location==0){
		
		unionName=[unionName substringFromIndex:1];
	}
	
	NSString *representation=wasKnown ? [NSString stringWithFormat:@"typedef union %@ {\n",unionName] : @"typedef union {\n" ;
	int upCount=0;
	
	for (int i=0; i<[brokenParts count]-1; i+=2){ // always an even number
		NSString *nam=[brokenParts objectAtIndex:i];
		upCount++;
		if ([nam rangeOfString:@"field0"].location!=NSNotFound){
			nam=[nam stringByReplacingOccurrencesOfString:@"field0" withString:[NSString stringWithFormat:@"field%d",upCount]];
		}
		NSString *typ=[brokenParts objectAtIndex:i+1];
		types=[types stringByAppendingString:[brokenParts objectAtIndex:i+1]];
#ifdef LIBMAIN
                representation=[representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n",libcommonTypes(typ,&nam,NO),nam]];
#else
		representation=[representation stringByAppendingString:[NSString stringWithFormat:@"\t%@ %@;\n",commonTypes(typ,&nam,NO),nam]];
#endif
	}
	
	representation=[representation stringByAppendingString:@"} "];
	representation=[representation stringByAppendingString:[NSString stringWithFormat:@"%@;\n\n",unionName]];
	BOOL found=NO;

	for (NSDictionary *dict in allStructsFound){
		if ([[dict objectForKey:@"name"] isEqual:unionName]){
			found=YES;
			return unionName;
			break;
		}
	}

	if (!found){
		for (NSDictionary *dict in allStructsFound){
			if ([[dict objectForKey:@"types"] isEqual:types] && !wasKnown){
				found=YES;
				return [dict objectForKey:@"name"];
				break;
			}
		}
	}
	
	[allStructsFound addObject:[NSDictionary dictionaryWithObjectsAndKeys:representation,@"representation",unionName,@"name",types,@"types",nil]];
	
	return unionName!=nil ? unionName : inUnion;
	
}


/****** Generic Types Parser ******/

#ifdef LIBMAIN
NSString * libcommonTypes(NSString *atype,NSString **inName,BOOL inIvarList){
#else
NSString * commonTypes(NSString *atype,NSString **inName,BOOL inIvarList){
#endif	
	BOOL isRef=NO;
	BOOL isPointer=NO;
	BOOL isCArray=NO;
	BOOL isConst=NO;
	BOOL isOut=NO;
	BOOL isByCopy=NO;
	BOOL isByRef=NO;
	BOOL isOneWay=NO;

	
	/* Stripping off any extra identifiers to leave only the actual type for parsing later on */

#ifdef LIBMAIN
        if ([atype rangeOfString:@"o"].location==0 && ![libcommonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#else
	if ([atype rangeOfString:@"o"].location==0 && ![commonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#endif
		isOut=YES;
		atype=[atype substringFromIndex:1];
	}

#ifdef LIBMAIN
        if ([atype rangeOfString:@"O"].location==0 && ![libcommonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#else
	if ([atype rangeOfString:@"O"].location==0 && ![commonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#endif
		isByCopy=YES;
		atype=[atype substringFromIndex:1];
	}
	
#ifdef LIBMAIN
        if ([atype rangeOfString:@"R"].location==0 && ![libcommonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#else
	if ([atype rangeOfString:@"R"].location==0 && ![commonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#endif
		isByRef=YES;
		atype=[atype substringFromIndex:1];
	}
	
#ifdef LIBMAIN
        if ([atype rangeOfString:@"V"].location==0 && ![libcommonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#else
	if ([atype rangeOfString:@"V"].location==0 && ![commonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
#endif
		isOneWay=YES;
		atype=[atype substringFromIndex:1];
	}
	
	if ([atype rangeOfString:@"r^{"].location==0){
		isConst=YES;
		atype=[atype substringFromIndex:2];
		isPointer=YES;
		shouldImportStructs=1;
	} 
	
	if ([atype rangeOfString:@"r"].location==0){
		isConst=YES;
		atype=[atype substringFromIndex:1];
	}
	
	if ([atype isEqual:@"^?"]){
		atype=@"/*function pointer*/void*";
	}
		
	
	if ([atype rangeOfString:@"^"].location!=NSNotFound){
		isPointer=YES;
		atype=[atype  stringByReplacingOccurrencesOfString:@"^" withString:@""] ;
	} 
	
	if ([atype rangeOfString:@"("].location==0){
#ifdef LIBMAIN
                atype=librepresentedUnionFromUnion(atype);
#else
		atype=representedUnionFromUnion(atype);
#endif
	}
	
	int arrayCount=0;
	if ([atype rangeOfString:@"["].location==0){
	
		isCArray=YES;
		
		if ([atype rangeOfString:@"{"].location!=NSNotFound){
			atype=[atype stringByReplacingOccurrencesOfString:@"[" withString:@""];
			atype=[atype stringByReplacingOccurrencesOfString:@"]" withString:@""];
			int firstBrace=[atype rangeOfString:@"{"].location;
			arrayCount=[[atype stringByReplacingCharactersInRange:NSMakeRange(firstBrace,atype.length-firstBrace) withString:@""] intValue];
			atype=[atype stringByReplacingCharactersInRange:NSMakeRange(0,firstBrace) withString:@""];
		}
				
		else{
			isCArray=NO;
					
			__block NSString *tempString=[atype mutableCopy];
			__block NSMutableArray *numberOfArray=[NSMutableArray array];
			while ([tempString rangeOfString:@"["].location!=NSNotFound){

				NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\[([^\\[^\\]]+)\\])" options:0 error:nil];

        		[regex enumerateMatchesInString:tempString options:0 
            	                      range:NSMakeRange(0, [tempString length]) 
                	             usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) 
	        	{
    	        	for (int i = 1; i< [result numberOfRanges] ; i++) {
    	        		NSString *foundString=[tempString substringWithRange:[result rangeAtIndex:i]];
	    	        	tempString=[tempString stringByReplacingOccurrencesOfString:foundString withString:@""];
    	    	        [numberOfArray addObject:foundString]; //e.g. [2] or [100c]
        	         	break;
            		}
	        	}];
	        }
	        

	        
	        
	        NSString *stringContainingType;
	        for (NSString *aString in numberOfArray){
	        
	        	NSCharacterSet * set =[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLKMNOPQRSTUVWXYZ@#$%^&*()!<>?:\"|}{"] invertedSet];

				if ([aString rangeOfCharacterFromSet:set].location != NSNotFound) {
  					stringContainingType=aString;
  					break;
  				}
			}
			
			[numberOfArray removeObject:stringContainingType];
	        NSCharacterSet * set =[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLKMNOPQRSTUVWXYZ@#$%^&*()!<>?:\"|}{"];
			int letterLocation=[stringContainingType rangeOfCharacterFromSet:set].location==NSNotFound ? -1 : [stringContainingType rangeOfCharacterFromSet:set].location;
			NSString *outtype=letterLocation==-1 ? stringContainingType : [stringContainingType substringFromIndex:letterLocation];
			outtype=[outtype stringByReplacingOccurrencesOfString:@"]" withString:@""];
			stringContainingType=[stringContainingType stringByReplacingOccurrencesOfString:outtype withString:@""];
			for (NSString *subarr in numberOfArray){
				stringContainingType=[subarr stringByAppendingString:stringContainingType];
			}
			atype=outtype;
			if ([atype isEqual:@"v"]){
				atype=@"void*";
			}
			if (inName!=nil){
				*inName=[*inName stringByAppendingString:stringContainingType];
			}
		}
	}
	
		
		
	if ([atype rangeOfString:@"=}"].location!=NSNotFound && [atype rangeOfString:@"{"].location==0 && [atype rangeOfString:@"?"].location==NSNotFound  && [atype rangeOfString:@"\""].location==NSNotFound){
		shouldImportStructs=1;
		NSString *writeString=[atype stringByReplacingOccurrencesOfString:@"{" withString:@""];
		writeString=[writeString stringByReplacingOccurrencesOfString:@"}" withString:@""];
		writeString=[writeString stringByReplacingOccurrencesOfString:@"=" withString:@""];
		NSString *constString=isConst ? @"const " : @"";
		writeString=[NSString stringWithFormat:@"typedef %@struct %@* ",constString,writeString];
		
		

		atype=[atype stringByReplacingOccurrencesOfString:@"{__" withString:@""] ;
		atype=[atype stringByReplacingOccurrencesOfString:@"{" withString:@""] ;
		atype=[atype stringByReplacingOccurrencesOfString:@"=}" withString:@""] ;
		
		if ([atype rangeOfString:@"_"].location==0){
		
			atype=[atype substringFromIndex:1];
		}
		
		BOOL found=NO;
		for (NSDictionary *dict in allStructsFound){
			if ([[dict objectForKey:@"name"] isEqual:atype] ){
				found=YES;
				break;
			}
		}

		if (!found){
			writeString=[writeString stringByAppendingString:[NSString stringWithFormat:@"%@Ref;\n\n",representedStructFromStruct(atype,nil,0,NO)]];
			[allStructsFound addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:@""],@"types",writeString,@"representation",atype,@"name",nil]];
		}

		isRef=YES;
		isPointer=NO; // -> Ref
	}
	
	
	
	if ([atype rangeOfString:@"{"].location==0){
	

		if (inName!=nil){
			atype=representedStructFromStruct(atype,*inName,inIvarList,YES);
		}
		else{
			atype=representedStructFromStruct(atype,nil,inIvarList,YES);
		}
		if ([atype rangeOfString:@"_"].location==0){
			atype=[atype substringFromIndex:1];
		}
		shouldImportStructs=1;
	}


	if ([atype rangeOfString:@"b"].location==0 && atype.length>1){
		
		NSCharacterSet *numberSet=[NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
		if ([atype rangeOfCharacterFromSet:numberSet].location==1){
			NSString *bitValue=[atype substringFromIndex:1];
			atype= @"unsigned";
			if (inName!=nil){
				*inName=[*inName stringByAppendingString:[NSString stringWithFormat:@" : %@",bitValue]];
			}
		}
	}

#ifdef LIBMAIN
        if ([atype rangeOfString:@"N"].location==0 && ![libcommonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
                atype = libcommonTypes([atype substringFromIndex:1],nil,NO);
#else
	if ([atype rangeOfString:@"N"].location==0 && ![commonTypes([atype substringFromIndex:1],nil,NO) isEqual:[atype substringFromIndex:1]]){
                atype = commonTypes([atype substringFromIndex:1],nil,NO);
#endif	
		atype=[NSString stringWithFormat:@"inout %@",atype]; 
	}
	
	if ([atype isEqual:  @"d"]){ atype = @"double"; }
	if ([atype isEqual:  @"i"]){ atype = @"int"; }
	if ([atype isEqual:  @"f"]){ atype = @"float"; }
	
	if ([atype isEqual:  @"c"]){ atype = @"char"; }
	if ([atype isEqual:  @"s"]){ atype = @"short"; }
	if ([atype isEqual:  @"I"]){ atype = @"unsigned"; }
	if ([atype isEqual:  @"l"]){ atype = @"long"; }
	if ([atype isEqual:  @"q"]){ atype = @"long long"; }
	if ([atype isEqual:  @"L"]){ atype = @"unsigned long"; }
	if ([atype isEqual:  @"C"]){ atype = @"unsigned char"; }
	if ([atype isEqual:  @"S"]){ atype = @"unsigned short"; }
	if ([atype isEqual:  @"Q"]){ atype = @"unsigned long long"; }
	//if ([atype isEqual:  @"Q"]){ atype = @"uint64_t"; }

	if ([atype isEqual:  @"B"]){ atype = @"BOOL"; }
	if ([atype isEqual:  @"v"]){ atype = @"void"; }
	if ([atype isEqual:  @"*"]){ atype = @"char*"; }
	if ([atype isEqual:  @":"]){ atype = @"SEL"; }
	if ([atype isEqual:  @"?"]){ atype = @"/*function pointer*/void*"; }
	if ([atype isEqual:  @"#"]){ atype = @"Class"; }
	if ([atype isEqual:  @"@"]){ atype = @"id"; }
	if ([atype isEqual:  @"@?"]){ atype = @"/*^block*/id"; }
	if ([atype isEqual:  @"Vv"]){ atype = @"void"; }
	if ([atype isEqual:  @"rv"]){ atype = @"const void*"; }


	
	
	if (isRef){
		if ([atype rangeOfString:@"_"].location==0){
			atype=[atype substringFromIndex:1];
		}
		atype=[atype isEqual:@"NSZone"] ? @"NSZone*" : [atype stringByAppendingString:@"Ref"];
	}

	if (isPointer){
		atype=[atype stringByAppendingString:@"*"];
	}
	
	if (isConst){
		atype=[@"const " stringByAppendingString:atype];
	}

	if (isCArray && inName!=nil){ //more checking to do, some framework were crashing if not nil, shouldn't be nil
		
		*inName=[*inName stringByAppendingString:[NSString stringWithFormat:@"[%d]",arrayCount]];
	}
	
	if (isOut){
		atype=[@"out " stringByAppendingString:atype];
	}

	if (isByCopy){
		atype=[@"bycopy " stringByAppendingString:atype];
	}
	
	if (isByRef){
		atype=[@"byref " stringByAppendingString:atype];
	}

	if (isOneWay){
		atype=[@"oneway " stringByAppendingString:atype];
	}


	return atype;

}

/****** Methods Parser ******/

#ifdef LIBMAIN
NSString * libgenerateMethodLines(Class someclass,BOOL isInstanceMethod,NSMutableArray *propertiesArray){
#else
NSString * generateMethodLines(Class someclass,BOOL isInstanceMethod,NSMutableArray *propertiesArray){
#endif
	unsigned int outCount;

	NSMutableString *returnString=[[NSMutableString alloc] init];
	Method * methodsArray=class_copyMethodList(someclass,&outCount);

	for (unsigned x=0; x<outCount; x++){

        Method currentMethod=methodsArray[x];
		SEL sele= method_getName(currentMethod);    
		unsigned methodArgs=method_getNumberOfArguments(currentMethod);
		char * returnType=method_copyReturnType(currentMethod);
		const char *selectorName=sel_getName(sele);
		NSString *returnTypeSameAsProperty=nil;
		NSString *SelectorNameNS=[NSString stringWithCString:selectorName encoding:NSUTF8StringEncoding] ;
		if ([SelectorNameNS rangeOfString:@"."].location==0){ //.cxx.destruct etc
			continue;
		}
		for (NSDictionary *dict in propertiesArray){
			NSString *propertyName=[dict objectForKey:@"name"];
			if ([propertyName isEqual:SelectorNameNS]){
				returnTypeSameAsProperty=[[dict objectForKey:@"type"] retain];
				break;
			}
		}
		NSString *startSign=isInstanceMethod ? @"-" : @"+";

#ifdef LIBMAIN
                NSString *startTypes=returnTypeSameAsProperty ? [NSString stringWithFormat:@"\n%@(%@)",startSign,returnTypeSameAsProperty] : [NSString stringWithFormat:@"\n%@(%@)",startSign,libcommonTypes([NSString stringWithCString:returnType encoding:NSUTF8StringEncoding],nil,NO)];
#else
		NSString *startTypes=returnTypeSameAsProperty ? [NSString stringWithFormat:@"\n%@(%@)",startSign,returnTypeSameAsProperty] : [NSString stringWithFormat:@"\n%@(%@)",startSign,commonTypes([NSString stringWithCString:returnType encoding:NSUTF8StringEncoding],nil,NO)];
#endif
		[returnTypeSameAsProperty release];
		free(returnType);

		[returnString appendString:startTypes];
                    
		if (methodArgs>2){
			NSArray *selValuesArray=[SelectorNameNS componentsSeparatedByString:@":"];        
			for (unsigned i=2; i<methodArgs; i++){ 
				char * methodType= method_copyArgumentType( currentMethod,i);
				NSString *methodTypeSameAsProperty=nil;
				if (methodArgs==3){
					for (NSDictionary *dict in propertiesArray){
						NSString *propertyName=[dict objectForKey:@"name"];
						NSString *firstCapitalized=[[propertyName substringToIndex:1] capitalizedString];
						NSString *capitalizedFirst=[firstCapitalized stringByAppendingString:[propertyName substringFromIndex:1]];
						if ([[selValuesArray objectAtIndex:0] isEqual:[NSString stringWithFormat:@"set%@",capitalizedFirst] ]){
							methodTypeSameAsProperty=[[dict objectForKey:@"type"] retain];
							break;
						}
					}
				}
				if (methodTypeSameAsProperty){
					[returnString appendString:[NSString stringWithFormat:@"%@:(%@)arg%d ",[selValuesArray objectAtIndex:i-2],methodTypeSameAsProperty,i-1]];
				}
				else{
#ifdef LIBMAIN
                                        [returnString appendString:[NSString stringWithFormat:@"%@:(%@)arg%d ",[selValuesArray objectAtIndex:i-2],libcommonTypes([NSString stringWithCString:methodType encoding:NSUTF8StringEncoding],nil,NO),i-1]];
#else
					[returnString appendString:[NSString stringWithFormat:@"%@:(%@)arg%d ",[selValuesArray objectAtIndex:i-2],commonTypes([NSString stringWithCString:methodType encoding:NSUTF8StringEncoding],nil,NO),i-1]];
#endif
				}
				[methodTypeSameAsProperty release];
				free(methodType);
			}   
		}
            
		else{
			[returnString appendString:[NSString stringWithFormat:@"%@",SelectorNameNS]];
		}

		[returnString appendString:@";"];
	}
    
	free(methodsArray);	

	return returnString;
}   











/****** The actual job ******/

static NSString *  parseImage(char *image,BOOL writeToDisk,NSString *outputDir,BOOL getSymbols,BOOL isRecursive,BOOL buildOriginalDirs,BOOL simpleHeader,BOOL skipAlreadyFound){

#ifdef LIBMAIN
        libdyld_all_image_infos = (const struct
      dyld_all_image_infos *)DyldGetAllImageInfos();
        for(int i=0; i<libdyld_all_image_infos->infoArrayCount; i++) {
                if (libdyld_all_image_infos->infoArray[i].imageLoadAddress!=NULL){
                        char *currentImage=(char *)libdyld_all_image_infos->infoArray[i].imageFilePath;
#else
	dyld_all_image_infos = (const struct
      dyld_all_image_infos *)DyldGetAllImageInfos();
	for(int i=0; i<dyld_all_image_infos->infoArrayCount; i++) {
		if (dyld_all_image_infos->infoArray[i].imageLoadAddress!=NULL){
			char *currentImage=(char *)dyld_all_image_infos->infoArray[i].imageFilePath;
#endif
			if (strlen(currentImage)>0 && strstr(currentImage,image)){
				image=currentImage;
				break;
			}
		}
	}


	NSMutableString *returnString=[[NSMutableString alloc] init];

	// PROCEED
	BOOL isFramework=NO;
	NSMutableString *dumpString=[[NSMutableString alloc] initWithString:@""];
	unsigned int count;	
	CDLog(@"Getting class count for %s",image);
	const char **names = objc_copyClassNamesForImage(image,&count);
	CDLog(@"Did return class count %d",count);
	if (count){
		printf("  Dumping " BOLDWHITE "%s" RESET "...(%d classes) %s (injected with libclassdumpdyld.dylib) \n",image ,count,[print_free_memory() UTF8String]);
	}	

	 
	
	BOOL hasWrittenCopyright=NO;
	allStructsFound=nil;
	allStructsFound=[NSMutableArray array];
	classesInStructs=nil;
	classesInStructs=[NSMutableArray array];
	
	
	NSMutableArray *protocolsAdded=[NSMutableArray array];
	
	NSString *imageName=[[NSString stringWithCString:image encoding:NSUTF8StringEncoding] lastPathComponent];
	NSString *fullImageNameInNS=[NSString stringWithCString:image encoding:NSUTF8StringEncoding];

	
	NSString *seeIfIsBundleType=[fullImageNameInNS stringByDeletingLastPathComponent]; 
	NSString *lastComponent=[seeIfIsBundleType lastPathComponent];
	NSString *targetDir=nil;
	if ([lastComponent rangeOfString:@"."].location==NSNotFound){
		targetDir=fullImageNameInNS;
		
	}
	else{
		targetDir=[fullImageNameInNS stringByDeletingLastPathComponent];
		isFramework=YES;		
	}
	NSString *headersFolder=addHeadersFolder ? @"/Headers" : @"";
	NSString *writeDir=buildOriginalDirs ? (isFramework ? [NSString stringWithFormat:@"%@/%@%@",outputDir,targetDir,headersFolder] : [NSString stringWithFormat:@"%@/%@",outputDir,targetDir])  : outputDir;
	writeDir=[writeDir stringByReplacingOccurrencesOfString:@"///" withString:@"/"];
	writeDir=[writeDir stringByReplacingOccurrencesOfString:@"//" withString:@"/"];

	[writeDir retain];
	
	[processedImages addObject:[NSString stringWithCString:image encoding:NSUTF8StringEncoding]];
	CDLog(@"Beginning class loop (%d classed) for %s",count,image);
	NSMutableString *classesToImport=[[NSMutableString alloc] init];
	
	
	for (unsigned i=0; i<count; i++){

		NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
		
		classesInClass=nil;
		classesInClass=[NSMutableArray array];
		NSMutableArray *inlineProtocols=[NSMutableArray array];
		shouldImportStructs=0;
		if (skipAlreadyFound && [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"%@/%s.h",writeDir,names[i]]]){
			continue;
		}

		BOOL canGetSuperclass=YES;
		
		// Some blacklisted classes 
		if (strcmp((char *)image,(char *)"/System/Library/PrivateFrameworks/iWorkImport.framework/iWorkImport")==0 || strcmp((char *)image,(char *)"/System/Library/PrivateFrameworks/OfficeImport.framework/OfficeImport")==0){
				if (strcmp(names[i],"KNSlideStyle")==0 || strcmp(names[i],"TSWPListStyle")==0 ||  strcmp(names[i],"TSWPColumnStyle")==0 ||  strcmp(names[i],"TSWPCharacterStyle")==0 || strcmp(names[i],"TSWPParagraphStyle")==0 || strcmp(names[i],"TSTTableStyle")==0 || strcmp(names[i],"TSTCellStyle")==0 ||  strcmp(names[i],"TSDMediaStyle")==0 ||   strcmp(names[i],"TSDShapeStyle")==0 ||  strcmp(names[i],"TSCHStylePasteboardData")==0 || strcmp(names[i],"OABShapeBaseManager")==0 || strcmp(names[i],"TSCH3DGLRenderProcessor")==0 || strcmp(names[i],"TSCH3DAnimationTimeSlice")==0 || strcmp(names[i],"TSCH3DBarChartDefaultAppearance")==0 || strcmp(names[i],"TSCH3DGenericAxisLabelPositioner")==0 ||  strcmp(names[i],"TSCHChartSeriesNonStyle")==0 || strcmp(names[i],"TSCHChartAxisNonStyle")==0 || strcmp(names[i],"TSCHLegendNonStyle")==0 || strcmp(names[i],"TSCHChartNonStyle")==0 || strcmp(names[i],"TSCHChartSeriesStyle")==0 || strcmp(names[i],"TSCHChartAxisStyle")==0 || strcmp(names[i],"TSCHLegendStyle")==0 || strcmp(names[i],"TSCHChartStyle")==0 || strcmp(names[i],"TSCHBaseStyle")==0){
				continue;
			}

		}
		
		// Some more blacklisted classes 
		if (!strcmp(names[i],"WAServerProperties") || !strcmp(names[i],"FBGroupPendingStream") || !strcmp(names[i],"FBConsoleGetTagStatuses_result") || !strcmp(names[i],"CLLocationProviderAdapter") || strcmp(names[i],"AXBackBoardGlue")==0 || strcmp(names[i],"TMBackgroundTaskAgent")==0){
			continue;
		}

		// Some more blacklisted classes for iOS before iOS 7		
		if (priorToiOS7() && (!strcmp(names[i],"VKRoadGroup") || !strcmp(names[i],"SBApplication") || !strcmp(names[i],"SBSMSApplication") || !strcmp(names[i],"SBFakeNewsstandApplication") || !strcmp(names[i],"SBWebApplication") || !strcmp(names[i],"SBNewsstandApplication"))){
			continue;
		}
		
		if (writeToDisk){
			loadBar(i, count, 100, 50,names[i]);   
		}
		
		
		NSString *classNameNS=[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding];
		while ([classNameNS rangeOfString:@"_"].location==0){

			classNameNS=[classNameNS substringFromIndex:1];
		}
		classID=[classNameNS substringToIndex:2];
		Class currentClass=nil;
		CDLog(@"Processing Class %s (%d/%d)\n",names[i],i,count);
		currentClass=objc_getClass(names[i]);
		
		if ( ! class_getClassMethod(currentClass,NSSelectorFromString(@"doesNotRecognizeSelector:") )){
			canGetSuperclass=NO;
		}
		
		if ( ! class_getClassMethod(currentClass,NSSelectorFromString(@"methodSignatureForSelector:") )){
			canGetSuperclass=NO;
		}
		

				
		if (strcmp((char *)image,(char *)"/System/Library/CoreServices/SpringBoard.app/SpringBoard")==0){
			
			[currentClass class]; //init a class instance to prevent crashes, specifically needed for some SpringBoard classes
		}
		
		NSString *superclassString=canGetSuperclass ? ([[currentClass superclass] description] !=nil ? [NSString stringWithFormat:@" : %@",[[currentClass superclass] description]] : @"") : @" : _UKNOWN_SUPERCLASS_";
		
		
		unsigned int protocolCount;
		Protocol ** protocolArray=class_copyProtocolList(currentClass, &protocolCount);
		NSMutableString *inlineProtocolsString=[[NSMutableString alloc] init];
		for (unsigned t=0; t<protocolCount; t++){
			if (t==0){
				[inlineProtocolsString appendString:@" <"];
			}
			const char *protocolName=protocol_getName(protocolArray[t]);
			
			NSMutableString *addedProtocol=[[NSMutableString alloc] initWithCString:protocolName encoding:NSUTF8StringEncoding];
			if (t<protocolCount-1){
				[addedProtocol appendString:@", "];
			}
			[inlineProtocolsString appendString:addedProtocol];
			[addedProtocol release];
			if (t==protocolCount-1){
				[inlineProtocolsString appendString:@">"];
			}		
		}
		
		
		
		if ( writeToDisk || (!writeToDisk && !hasWrittenCopyright )){
			NSString *copyrightString=copyrightMessage(image);
			[dumpString appendString:copyrightString];
			[copyrightString release];
			hasWrittenCopyright=YES;
		}
		
		
		if (writeToDisk && superclassString.length>0 && ![superclassString isEqual:@" : NSObject"]){
			NSString *fixedSuperclass=[superclassString stringByReplacingOccurrencesOfString:@" : " withString:@""];
			NSString *importSuper=@"";
			if (!simpleHeader){
				NSString *imagePrefix=[imageName substringToIndex:2];

				NSString *superclassPrefix=[superclassString rangeOfString:@"_"].location==0 ? [[superclassString substringFromIndex:1] substringToIndex:2] : [superclassString substringToIndex:2];
				const char *imageNameOfSuper=[imagePrefix isEqual:superclassPrefix] ? [imagePrefix UTF8String] : class_getImageName(objc_getClass([fixedSuperclass UTF8String]));
				if (imageNameOfSuper){
					NSString *imageOfSuper=[NSString stringWithCString:imageNameOfSuper encoding:NSUTF8StringEncoding];
					imageOfSuper=[imageOfSuper lastPathComponent];	
					importSuper=[NSString stringWithFormat:@"#import <%@/%@.h>\n",imageOfSuper,fixedSuperclass];
				}
				
			}
			else{
				importSuper=[NSString stringWithFormat:@"#import \"%@.h\"\n",fixedSuperclass];
			}
			[dumpString appendString:importSuper];
		}
		
		
		for (unsigned d=0; d<protocolCount; d++){
			
			Protocol *protocol=protocolArray[d];
			const char *protocolName=protocol_getName(protocol);
			
			NSString *protocolNSString=[NSString stringWithCString:protocolName encoding:NSUTF8StringEncoding];
			if (writeToDisk){
				if (simpleHeader){
					[dumpString appendString:[NSString stringWithFormat:@"#import \"%@.h\"\n",protocolNSString]];
				}
				else{
					NSString *imagePrefix=[imageName substringToIndex:2];
					NSString *protocolPrefix=nil;
					NSString *imageOfProtocol=nil;

					protocolPrefix=[protocolNSString rangeOfString:@"_"].location==0 ? [[protocolNSString substringFromIndex:1] substringToIndex:2] : [protocolNSString substringToIndex:2];
					imageOfProtocol=([imagePrefix isEqual:protocolPrefix] || !class_getImageName(protocol) ) ? imageName : [NSString stringWithCString:class_getImageName(protocol) encoding:NSUTF8StringEncoding];
					imageOfProtocol=[imageOfProtocol lastPathComponent];
					
					if ([protocolNSString rangeOfString:@"UI"].location==0){
						imageOfProtocol=@"UIKit";
					}
					[dumpString appendString:[NSString stringWithFormat:@"#import <%@/%@.h>\n",imageOfProtocol,protocolNSString]];
				}

			}
			if ([protocolsAdded containsObject:protocolNSString]){
				continue;
			}
			[protocolsAdded addObject:protocolNSString];
#ifdef LIBMAIN
                        NSString *protocolHeader=libbuildProtocolFile(protocol);
#else
			NSString *protocolHeader=buildProtocolFile(protocol);
#endif
			if (strcmp(names[i],protocolName)==0){
				[dumpString appendString:protocolHeader];

			}
			else{
				if (writeToDisk){
					NSString *copyrightString=copyrightMessage(image);
					protocolHeader=[copyrightString stringByAppendingString:protocolHeader] ;
					[copyrightString release];
					
					NSString *targetSaveString=[NSString stringWithFormat:@"@@@@@%@/%s.h&&&&&",writeDir,protocolName];
					[returnString appendString:targetSaveString];
					[returnString appendString:protocolHeader];
				}
				else{
					[dumpString appendString:protocolHeader];
					
				}
			}
			
		}			
		free(protocolArray);
		
		
		[dumpString appendString:[NSString stringWithFormat:@"\n@interface %s%@%@",names[i],superclassString,inlineProtocolsString]];
		[inlineProtocolsString release];
		// Get Ivars
		unsigned int ivarOutCount;
		Ivar * ivarArray=class_copyIvarList(currentClass, &ivarOutCount);
		if (ivarOutCount>0){	
			[dumpString appendString:@" {\n"];
			for (unsigned x=0;x<ivarOutCount;x++){
				Ivar currentIvar=ivarArray[x];
				const char * ivarName=ivar_getName(currentIvar);

				NSString *ivarNameNS=[NSString stringWithCString:ivarName encoding:NSUTF8StringEncoding];
				const char * ivarType=ivar_getTypeEncoding(currentIvar);

#ifdef LIBMAIN
                                NSString *ivarTypeString=libcommonTypes([NSString stringWithCString:ivarType encoding:NSUTF8StringEncoding],&ivarNameNS,YES);
#else
				NSString *ivarTypeString=commonTypes([NSString stringWithCString:ivarType encoding:NSUTF8StringEncoding],&ivarNameNS,YES);
#endif
			
				if ([ivarTypeString rangeOfString:@"@\""].location!=NSNotFound){
					ivarTypeString=[ivarTypeString stringByReplacingOccurrencesOfString:@"@\"" withString:@""];
					ivarTypeString=[ivarTypeString stringByReplacingOccurrencesOfString:@"\"" withString:@"*"];
					NSString *classFoundInIvars=[ivarTypeString stringByReplacingOccurrencesOfString:@"*" withString:@""];
					if (![classesInClass containsObject:classFoundInIvars]){
						

						if ([classFoundInIvars rangeOfString:@"<"].location!=NSNotFound ){

								int firstOpening=[classFoundInIvars rangeOfString:@"<"].location;
								if (firstOpening!=0){
									NSString *classToAdd=[classFoundInIvars substringToIndex:firstOpening];
									if (![classesInClass containsObject:classToAdd]){
										[classesInClass addObject:classToAdd];				
									}
								}

								NSString *protocolToAdd=[classFoundInIvars substringFromIndex:firstOpening];
								protocolToAdd=[protocolToAdd stringByReplacingOccurrencesOfString:@"<" withString:@""];
								protocolToAdd=[protocolToAdd stringByReplacingOccurrencesOfString:@">" withString:@""];
								protocolToAdd=[protocolToAdd stringByReplacingOccurrencesOfString:@"*" withString:@""];
								if (![inlineProtocols containsObject:protocolToAdd]){	
									[inlineProtocols addObject:protocolToAdd];
								}
							
						}
						else{
							[classesInClass addObject:classFoundInIvars];
						}
					}
					if ([ivarTypeString rangeOfString:@"<"].location!=NSNotFound){
						ivarTypeString=[ivarTypeString stringByReplacingOccurrencesOfString:@">*" withString:@">"];
						if ([ivarTypeString rangeOfString:@"<"].location==0){
							ivarTypeString=[@"id" stringByAppendingString:ivarTypeString];
						}
						else{
							ivarTypeString=[ivarTypeString stringByReplacingOccurrencesOfString:@"<" withString:@"*<"];			
						}
					}
				}

				NSString *formatted=[NSString stringWithFormat:@"\n\t%@ %@;",ivarTypeString,ivarNameNS];
				[dumpString appendString:formatted];
				
			}
			[dumpString appendString:@"\n\n}"];
			
		}
		free(ivarArray);
		
		if ([inlineProtocols count]>0){
			
			NSMutableString *inlineProtocolsString=[[NSMutableString alloc] init];
			[inlineProtocolsString appendString:@"@protocol "];
			for (int g=0; g<inlineProtocols.count; g++){
				if (g<inlineProtocols.count-1){
					[inlineProtocolsString appendString:[NSString stringWithFormat:@"%@, ",[inlineProtocols objectAtIndex:g]]];
				}
				else{
					[inlineProtocolsString appendString:[NSString stringWithFormat:@"%@;\n",[inlineProtocols objectAtIndex:g]]];
				}
			}
			int interfaceLocation=[dumpString rangeOfString:@"@interface"].location;
			[dumpString insertString:inlineProtocolsString atIndex:interfaceLocation];
			[inlineProtocolsString release];
		}
		
		
		// Get Properties

		unsigned int propertiesCount;
		NSMutableString *propertiesString=[[NSMutableString alloc] init];
		objc_property_t *propertyList=class_copyPropertyList(currentClass,&propertiesCount);
		
		for (unsigned int b=0; b<propertiesCount; b++){
	
			const char *propname=property_getName(propertyList[b]);
			const char *attrs=property_getAttributes(propertyList[b]);
#ifdef LIBMAIN
                        NSString *newString=libpropertyLineGenerator([NSString stringWithCString:attrs encoding:NSUTF8StringEncoding],[NSString stringWithCString:propname encoding:NSUTF8StringEncoding]);
#else
			NSString *newString=propertyLineGenerator([NSString stringWithCString:attrs encoding:NSUTF8StringEncoding],[NSString stringWithCString:propname encoding:NSUTF8StringEncoding]);
#endif
			if ([propertiesString rangeOfString:newString].location==NSNotFound){
				[propertiesString appendString:newString];
			}
			[newString release];
		}
		free(propertyList);
		
		
		
		// Fix synthesize locations
		int propLenght=[propertiesString length];
		NSMutableArray *synthesized=[[propertiesString componentsSeparatedByString:@"\n"] mutableCopy];
		int longestLocation=0;
		for (NSString *string in synthesized){
		
			string=[string stringByReplacingOccurrencesOfString:@"\t" withString:@""];
			string=[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			int location=[string rangeOfString:@";"].location;
			if ([string rangeOfString:@";"].location==NSNotFound){
				continue;
			}
			if (location>longestLocation){
				longestLocation=location;
			}
		
		}
		
		NSMutableArray *newStrings=[NSMutableArray array];
		for (NSString *string in synthesized){
			int synthesizeLocation=[string rangeOfString:@"//@synth"].location;
			if ([string rangeOfString:@"//@synth"].location==NSNotFound){
				[newStrings addObject:string];
				continue;
			}

			NSString *copyString=[string substringFromIndex:synthesizeLocation];
			int location=[string rangeOfString:@";"].location;
			string=[string substringToIndex:location+1];
			string=[string stringByPaddingToLength:longestLocation+15 withString:@" " startingAtIndex:0];
			string=[string stringByAppendingString:copyString];
			[newStrings addObject:string];
		}
		if (propLenght>0){
			propertiesString=[[[@"\n" stringByAppendingString:[newStrings componentsJoinedByString:@"\n"]] mutableCopy] retain];
		}
		
		// Gather All Strings
		[dumpString appendString:propertiesString];
#ifdef LIBMAIN
                NSString *finalClassMethodLines=libgenerateMethodLines(object_getClass(currentClass),NO,nil);
                [dumpString appendString:finalClassMethodLines];
                NSString *finalMethodLines=libgenerateMethodLines(currentClass,YES,propertiesArrayFromString(propertiesString));
#else
		NSString *finalClassMethodLines=generateMethodLines(object_getClass(currentClass),NO,nil);
		[dumpString appendString:finalClassMethodLines];
		NSString *finalMethodLines=generateMethodLines(currentClass,YES,propertiesArrayFromString(propertiesString));
#endif
		[propertiesString release];
		[dumpString appendString:finalMethodLines];
		[finalClassMethodLines release];
		[finalMethodLines release];
		[dumpString appendString:@"\n@end\n\n"];
		
		
		
		

		if (shouldImportStructs && writeToDisk){
			int firstImport=[dumpString rangeOfString:@"#import"].location!=NSNotFound ? [dumpString rangeOfString:@"#import"].location : [dumpString rangeOfString:@"@interface"].location;
			NSString *structImport=simpleHeader ? [NSString stringWithFormat:@"#import \"%@-Structs.h\"\n",imageName] : [NSString stringWithFormat:@"#import <%@/%@-Structs.h>\n",imageName,imageName];
			[dumpString insertString:structImport atIndex:firstImport];
			
		}
		
		if (writeToDisk && [classesInClass count]>0){
			
			[classesInClass removeObject:[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding]];
			if ([classesInClass count]>0){
				int firstInteface=[dumpString rangeOfString:@"@interface"].location;
				NSMutableString *classesFoundToAdd=[[NSMutableString alloc] init];
				[classesFoundToAdd appendString:@"@class "];
				for (int f=0; f<classesInClass.count; f++){
					NSString *classFound=[classesInClass objectAtIndex:f];
					if (f<classesInClass.count-1){
						[classesFoundToAdd appendString:[NSString stringWithFormat:@"%@, ",classFound]];
					}
					else{
						[classesFoundToAdd appendString:[NSString stringWithFormat:@"%@;",classFound]];
					}
				}
				[classesFoundToAdd appendString:@"\n\n"];
				[dumpString insertString:classesFoundToAdd atIndex:firstInteface];	
				[classesFoundToAdd release];		
			}
		}
		
		// Write strings to disk or print out

		if (writeToDisk){
			

			NSString *fileToWrite=[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding];

			if ([[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding] isEqual:[[NSString stringWithCString:image encoding:NSUTF8StringEncoding] lastPathComponent]]){
				fileToWrite=[[NSString stringWithCString:names[i] encoding:NSUTF8StringEncoding] stringByAppendingString:@"-Class"];
			}
			
			NSString *targetSaveString=[NSString stringWithFormat:@"@@@@@%@/%@.h&&&&&",writeDir,fileToWrite];
			[returnString appendString:targetSaveString];
			[returnString appendString:dumpString];

		}
		else{
			printf("%s\n\n",[dumpString UTF8String]);
			
		}
		if (writeToDisk){
			NSString *importStringFrmt=simpleHeader ? [NSString stringWithFormat:@"#import \"%s.h\"\n",names[i]] : [NSString stringWithFormat:@"#import <%@/%s.h>\n",imageName,names[i]];
			[classesToImport appendString:importStringFrmt];
		}

		objc_destructInstance(currentClass);

		[dumpString release];
		dumpString=[[NSMutableString alloc] init];
		[pool drain];

	} 
	// END OF PER-CLASS LOOP
		
	if (writeToDisk && classesToImport.length>2){
			
			NSString *targetSaveString=[NSString stringWithFormat:@"@@@@@%@/%@.h&&&&&",writeDir,imageName];
			[returnString appendString:targetSaveString];
			[returnString appendString:classesToImport];

	}
	[classesToImport release];

	
	CDLog(@"Finished class loop for %s",image);
	
	// Compose FrameworkName-Structs.h file
	

	
	if ([allStructsFound count]>0){
		CDLog(@"Found %lu structs, processing...",(unsigned long)[allStructsFound count]);
		NSMutableString *structsString=[[NSMutableString alloc] init];
		if (writeToDisk){
			NSString *copyrightString=copyrightMessage(image);
			[structsString appendString:copyrightString];
			[copyrightString release];
		}

		if ([classesInStructs count]>0){
			
			[structsString appendString:@"\n@class "];
			for (NSString *string in classesInStructs){
				[structsString appendString:[NSString stringWithFormat:@"%@, ",string]];
			}
			structsString=[[[structsString substringToIndex:structsString.length-2] mutableCopy] retain];
			[structsString appendString:@";\n\n"];
		}
		

		for (NSDictionary *dict in allStructsFound){
			[structsString appendString:[dict objectForKey:@"representation"]];
		}
		if (writeToDisk){

			NSString *targetSaveString=[NSString stringWithFormat:@"@@@@@%@/%@-Structs.h&&&&&",writeDir,imageName];
			[returnString appendString:targetSaveString];
			[returnString appendString:structsString];
		
		}
		else{
			printf("\n%s\n",[structsString UTF8String]);
		}
		CDLog(@"Finished processing structs...");
		[structsString release];
	}

 
	
	
	// Compose FrameworkName-Symbols.h file (more like nm command's output not an actual header anyway)
	if (getSymbols){

		CDLog(@"In Symbols -> Fetching symbols for %s",image);
		
		struct mach_header * mh=nil;
		struct mach_header_64 * mh64=nil;
		
		// Decide if image is 64 bit
#ifdef LIBMAIN
		BOOL is64BitImage=libis64BitMachO(image);
#else
		BOOL is64BitImage=is64BitMachO(image);
#endif

#ifdef LIBMAIN
                int vmaddrImage;
                libdyld_all_image_infos = (const struct
      dyld_all_image_infos *)DyldGetAllImageInfos();
                for(int i=0; i<libdyld_all_image_infos->infoArrayCount; i++) {
                        if (libdyld_all_image_infos->infoArray[i].imageLoadAddress!=NULL){
                                char *currentImage=(char *)libdyld_all_image_infos->infoArray[i].imageFilePath;
                                if (strlen(currentImage)>0 && !strcmp(currentImage,image)){

                                        if (is64BitImage){
                                                mh64 = (struct mach_header_64 *)libdyld_all_image_infos->infoArray[i].imageLoadAddress;
                                        }
                                        else{
                                                mh = (struct mach_header *)libdyld_all_image_infos->infoArray[i].imageLoadAddress;
#else
		int vmaddrImage;
		dyld_all_image_infos = (const struct
      dyld_all_image_infos *)DyldGetAllImageInfos();
		for(int i=0; i<dyld_all_image_infos->infoArrayCount; i++) {
			if (dyld_all_image_infos->infoArray[i].imageLoadAddress!=NULL){
				char *currentImage=(char *)dyld_all_image_infos->infoArray[i].imageFilePath;
				if (strlen(currentImage)>0 && !strcmp(currentImage,image)){
					
					if (is64BitImage){
						mh64 = (struct mach_header_64 *)dyld_all_image_infos->infoArray[i].imageLoadAddress;
					}
					else{
						mh = (struct mach_header *)dyld_all_image_infos->infoArray[i].imageLoadAddress;
#endif
					}
					vmaddrImage=i;
					break;
				}
			}
		}
	
		if ((is64BitImage && (mh64==nil)) | (!is64BitImage && (mh==nil))){
			CDLog(@"Currently dlopened image %s not found in _dyld_image_count (?)",image);
		}
		else{
			
			unsigned int file_slide;
			NSMutableString *symbolsString=nil;
			
			
			if (!is64BitImage){
				CDLog(@"In Symbols -> Got mach header OK , filetype %d",mh->filetype);
				
				// Thanks to FilippoBiga for the code snippet below 
				
				struct segment_command *seg_linkedit = NULL;
				struct segment_command *seg_text = NULL;
				struct symtab_command *symtab = NULL;			
				struct load_command *cmd =  (struct load_command*)((char*)mh + sizeof(struct mach_header));
				CDLog(@"In Symbols -> Iterating header commands for %s",image);
				for (uint32_t index = 0; index < mh->ncmds; index++, cmd = (struct load_command*)((char*)cmd + cmd->cmdsize))
				{
					//CDLog(@"I=%d",index);
					switch(cmd->cmd)
					{
						case LC_SEGMENT:
						{
							//CDLog(@"FOUND LC_SEGMENT");
							struct segment_command *segmentCommand = (struct segment_command*)(cmd);
							if (strncmp(segmentCommand->segname, "__TEXT", sizeof(segmentCommand->segname)) == 0)
							{	                
								seg_text = segmentCommand;
				
							} else if (strncmp(segmentCommand->segname, "__LINKEDIT", sizeof(segmentCommand->segname)) == 0)
							{	
								seg_linkedit = segmentCommand;
							}
							break;
						}
			
						case LC_SYMTAB:
						{	
							//CDLog(@"FOUND SYMTAB");
							symtab = (struct symtab_command*)(cmd);
							break;
						}
			
						default:
						{
							break;
						}
			
					}
				}
				
				
				if (mh->filetype==MH_DYLIB){
					file_slide = ((unsigned long)seg_linkedit->vmaddr - (unsigned long)seg_text->vmaddr) - seg_linkedit->fileoff;
				}
				else{
					file_slide = 0;
				}
				CDLog(@"In Symbols -> Got symtab for %s",image);
				struct nlist *symbase = (struct nlist*)((unsigned long)mh + (symtab->symoff + file_slide));
				char *strings = (char*)((unsigned long)mh + (symtab->stroff + file_slide));
				struct nlist *sym;
				sym = symbase;
		
				symbolsString=[[NSMutableString alloc] init];
				NSAutoreleasePool *pp = [[NSAutoreleasePool alloc] init];
	
				CDLog(@"In Symbols -> Iteraring symtab");
				for (uint32_t index = 0; index < symtab->nsyms; index += 1, sym += 1)
				{	
			
					if ((uint32_t)sym->n_un.n_strx > symtab->strsize)
					{   	
						break;
		
					} else {
				
						const char *strFound = (char*) (strings + sym->n_un.n_strx);
						char *str= strdup(strFound);
						if (strcmp(str,"<redacted>") && strlen(str)>0){
							if (!symbolsString){
								NSString *copyrightString=copyrightMessage(image);
								[symbolsString appendString:[copyrightString stringByReplacingOccurrencesOfString:@"This header" withString:@"This output"]];
								[copyrightString release];	
								
								[symbolsString appendString :[NSString stringWithFormat:@"\nSymbols found in %s:\n%@\n",image,[NSString stringWithCString:str encoding:NSUTF8StringEncoding]]] ;
							}
							else{
								[symbolsString appendString : [NSString stringWithFormat:@"%s\n",str]] ;
							}

						}
						free (str);
				
					}
			
				}
				[pp drain];
			}	
			
			else{
				
				CDLog(@"In Symbols -> Got mach header64 OK , filetype %d",mh64->filetype);

				struct segment_command_64 *seg_linkedit = NULL;
				struct segment_command_64 *seg_text = NULL;
				struct symtab_command *symtab = NULL;
				struct load_command *cmd = (struct load_command*)((char*)mh64 + sizeof(struct mach_header_64));
				CDLog(@"In Symbols -> Iterating header64 commands for %s",image);

				for (uint32_t index = 0; index < mh64->ncmds; index++, cmd = (struct load_command*)((char*)cmd + cmd->cmdsize))
				{
					//CDLog(@"I=%d",index);
					switch(cmd->cmd)
					{
						case LC_SEGMENT_64:
						{	
							//CDLog(@"FOUND LC_SEGMENT_64");
							struct segment_command_64 *segmentCommand = (struct segment_command_64*)(cmd);
							if (strncmp(segmentCommand->segname, "__TEXT", sizeof(segmentCommand->segname)) == 0)
							{	                
								seg_text = segmentCommand;
				
							} else if (strncmp(segmentCommand->segname, "__LINKEDIT", sizeof(segmentCommand->segname)) == 0)
							{	
								seg_linkedit = segmentCommand;
							}
							break;
						}
			
						case LC_SYMTAB:
						{	
							//CDLog(@"FOUND SYMTAB");
							symtab = (struct symtab_command*)(cmd);
							break;
						}
			
						default:
						{
							break;
						}
			
					}
				}
				
				if (mh64->filetype==MH_DYLIB){
					file_slide = ((unsigned long)seg_linkedit->vmaddr - (unsigned long)seg_text->vmaddr) - seg_linkedit->fileoff;
				}
				else{
					file_slide = 0;
				}
				CDLog(@"In Symbols -> Got symtab for %s",image);
				struct nlist_64 *symbase = (struct nlist_64*)((unsigned long)mh64 + (symtab->symoff + file_slide));
				char *strings = (char*)((unsigned long)mh64 + (symtab->stroff + file_slide));
				struct nlist_64 *sym;
				sym = symbase;
				[symbolsString release];
			 	symbolsString=[[NSMutableString alloc] init];
				NSAutoreleasePool *pp = [[NSAutoreleasePool alloc] init];
	
				CDLog(@"In Symbols -> Iteraring symtab");
				for (uint32_t index = 0; index < symtab->nsyms; index += 1, sym += 1)
				{	
			
					if ((uint32_t)sym->n_un.n_strx > symtab->strsize)
					{   	
						break;
		
					} else {
				
						const char *strFound = (char*) (strings + sym->n_un.n_strx);
						char *str= strdup(strFound);
						if (strcmp(str,"<redacted>") && strlen(str)>0){
							if (!symbolsString){
								NSString *copyrightString=copyrightMessage(image);
								[symbolsString appendString:[copyrightString stringByReplacingOccurrencesOfString:@"This header" withString:@"This output"]];
								[copyrightString release];						
								
								[symbolsString appendString :[NSString stringWithFormat:@"\nSymbols found in %s:\n%@\n",image,[NSString stringWithCString:str encoding:NSUTF8StringEncoding]]] ;
							}
							else{
								[symbolsString appendString : [NSString stringWithFormat:@"%s\n",str]] ;
							}

						}
						free (str);
				
					}
			
				}
				[pp drain];
			}
			
		

			CDLog(@"Finished fetching symbols for %s\n",image);
			if ([symbolsString length]>0){
				if (writeToDisk){
				
					NSString *targetSaveString=[NSString stringWithFormat:@"@@@@@%@/%@-Symbols.h&&&&&",writeDir,imageName];
					[returnString appendString:targetSaveString];
					[returnString appendString:symbolsString];

				}
				else{
					printf("\n%s\n",[symbolsString UTF8String]);
				}		
			}
			[symbolsString release];
		}
	}
	[writeDir release];

	
	free(names);

	return returnString;

	
}



/****** main ******/

extern "C" {

#ifndef LIBMAIN
int main(int argc, char **argv)
#else
int libmain(int argc, char **argv)
#endif
{	
	@autoreleasepool {

		char * image=nil;
		BOOL writeToDisk=NO;
		BOOL buildOriginalDirs=NO;
		BOOL skipAlreadyFound=NO;
		BOOL simpleHeader=NO;
		BOOL getSymbols=YES;


		
		NSString *outputDir=nil;
 
		
		// Check and apply arguments
		
		NSString *currentDir=[[[NSProcessInfo processInfo] environment] objectForKey:@"PWD"];
	

		NSArray *arguments=[[NSProcessInfo processInfo] arguments];
		
		NSMutableArray *argumentsToUse=[arguments mutableCopy];
		//[argumentsToUse removeObjectAtIndex:0];
		int argCount=[arguments count];

		if (argCount<1){
#ifdef LIBMAIN
			libprintHelp();
#else
			printHelp();
#endif
			exit(0);
		}
		
		for (NSString *arg in arguments){
			
			if ([arg isEqual:@"-o"]){

				int argIndex=[arguments indexOfObject:arg]; 

				if (argIndex==argCount-1){
#ifdef LIBMAIN
					libprintHelp();
#else
					printHelp();
#endif
					exit(0);
				}

				outputDir=[arguments objectAtIndex:argIndex+1];

				if ([outputDir rangeOfString:@"-"].location==0){
#ifdef LIBMAIN
					libprintHelp();
#else
					printHelp();
#endif
					exit(0);
				}
				writeToDisk=YES;
				[argumentsToUse removeObject:arg];
				[argumentsToUse removeObject:outputDir];

				
			}
			
			 
			
			if ([arg isEqual:@"-b"]){
				buildOriginalDirs=YES;
				[argumentsToUse removeObject:arg];
				
			}
			
			if ([arg isEqual:@"-g"]){
				getSymbols=NO;
				[argumentsToUse removeObject:arg];
				
			}
			
			if ([arg isEqual:@"-u"]){
				simpleHeader=YES;
				[argumentsToUse removeObject:arg];				
			}
			 
			if ([arg isEqual:@"-h"]){
				addHeadersFolder=YES;
				[argumentsToUse removeObject:arg];				
			}
			if ([arg isEqual:@"-s"]){
				skipAlreadyFound=YES;
				[argumentsToUse removeObject:arg];				
			}
			if ([arg isEqual:@"-D"]){
				inDebug=YES;
				[argumentsToUse removeObject:arg];				
			}


		}
		
		if (addHeadersFolder && !outputDir){
#ifdef LIBMAIN
			libprintHelp();
#else
			printHelp();
#endif
			exit(0);
		}
		

		if ([argumentsToUse count]>0){
			image=(char *)[[argumentsToUse objectAtIndex:0] UTF8String];			
		}
		else{
#ifdef LIBMAIN
			libprintHelp();
#else
			printHelp();
#endif
			exit(0);
		}
				
		// Begin
	
		
		if (image){
			
			NSError *error=nil;
			NSFileManager *fileman=[[NSFileManager alloc ] init];	
			NSString *imageString=nil;	
			if (outputDir){

				[fileman createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:&error];
				if (error){
					NSLog(@"Could not create directory %@. Check permissions.",outputDir);
					exit(EXIT_FAILURE);
				}
				[fileman changeCurrentDirectoryPath:currentDir];

				[fileman changeCurrentDirectoryPath:outputDir];

				outputDir=[fileman currentDirectoryPath]!=nil ? [fileman currentDirectoryPath] : outputDir;
				
				if (![fileman currentDirectoryPath]){
					printf("  Error: Injected application cannot write to %s, please change your output directory (you can use your user directory, e.g. /var/root/%s )",[outputDir UTF8String],[[outputDir lastPathComponent] UTF8String]);
					exit(0); // exit injected application without error
				}
				imageString=[NSString stringWithCString:image encoding:NSUTF8StringEncoding];
			
				if ([imageString rangeOfString:@"/"].location!=0){ // not an absolute path
						
					[fileman changeCurrentDirectoryPath:currentDir];
					NSString *append=[imageString lastPathComponent];
					NSString *source=[imageString stringByDeletingLastPathComponent];
					[fileman changeCurrentDirectoryPath:source];
					imageString=[[fileman currentDirectoryPath] stringByAppendingString:[NSString stringWithFormat:@"/%@",append]];
					image=(char *)[imageString UTF8String];
				
				}
			}

			NSString *result=parseImage(image,writeToDisk,outputDir,getSymbols,NO,buildOriginalDirs,simpleHeader,skipAlreadyFound);
			
			

			if (writeToDisk){
				

				NSArray *things=[[result componentsSeparatedByString:@"@@@@@"] retain];
				[result release];

				int total=[things count];
				
				if (total>2){ //1 is empty, 2 is structs

					printf("  Writing " BOLDWHITE "%s" RESET " headers to disk...\n", image);

				}
				
				for (unsigned i=0; i<[things count]; i++){
				
					@autoreleasepool{
					
						NSString *thing=[things objectAtIndex:i]; 

						if (thing.length>0){
							NSError *createError=nil;
						
							NSString *filePath=[thing substringToIndex:[thing rangeOfString:@"&&&&&"].location];
							thing=[thing substringFromIndex:[thing rangeOfString:@"&&&&&"].location+5];
							NSString *dirtosave=[filePath stringByDeletingLastPathComponent];

							loadBar(i,total, 100, 50,[[filePath lastPathComponent] UTF8String]);   
							[[NSFileManager defaultManager] createDirectoryAtPath:dirtosave withIntermediateDirectories:YES attributes:nil error:&createError];
							FILE * pFile;
							pFile = fopen ([filePath UTF8String],"w");
							
							if (pFile!=NULL){
								fputs ([thing UTF8String],pFile);
								fclose (pFile);
							}
							else{
							//perror([filePath UTF8String]);
							}
						}
						
					}
					
				}
			
				[things release];

			}
			printf("  All done for " BOLDWHITE "%s" RESET "\n", image);
		
			[fileman release];
		}


	}
	exit(0);
	
	 
	
}

}

