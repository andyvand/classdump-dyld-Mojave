PRODUCT_DIR=`echo $PWD`
NAME=classdump-dyld
MAKEFILE_SOURCE=pb_makefiles
OS=MACOS
PLATFORM_OS=iPhoneSimulator
TARGET=iPhoneSimulator
SDKROOT=iPhoneSimulator8.1
MAKEFILEPATH=/Applications/Xcode.app/Contents/Developer/Makefiles
OTHER_CFLAGS=-Oz -Os -ObjC++
MAKEFILEDIR=$(MAKEFILEPATH)/$(MAKEFILE_SOURCE)
include $(MAKEFILEPATH)/$(MAKEFILE_SOURCE)/platform-variables.make
RANLIB=ranlib
AR=ar
ARCHS=-arch x86_64
MACVER=10.10
 CC=gcc
CXX=g++
LD=g++

LIBRARY_NAME = libclassdumpdyld

SIGNID = "Mac Developer: andyvandijck@hotmail.com (DE4YUA5AZQ)"

CODESIGN = codesign -s $(SIGNID)

all: $(LIBRARY_NAME).a $(LIBRARY_NAME).dylib $(LIBRARY_NAME).framework $(LIBRARY_NAME).bundle $(LIBRARY_NAME)

$(LIBRARY_NAME).bundle: classdumpdyldlib.o
	mkdir -p $@/Contents/MacOS
	mkdir -p $@/Contents/Resources
	cp -Rf InfoBundle.plist $@/Contents/Info.plist
	$(CXX) -bundle -dead_strip -interposable -bind_at_load -export_dynamic -dynamic $(ARCHS) $(OTHER_CFLAGS) -o $@/Contents/MacOS/$(LIBRARY_NAME) $^ -framework Foundation -u _libmain -e _libmain ../libtest.a ../libsnapshot.a ../libutil.a ../libbase.a
	$(CODESIGN) $(LIBRARY_NAME).bundle

$(LIBRARY_NAME).framework: classdumpdyldlib.o
	mkdir -p $@/Versions/A
	mkdir -p $@/Versions/A/Resources
	cd $@/Versions && ln -sf A Current && cd ../..
	ln -sf Versions/A/Resources Resources
	cp -Rf Version.plist Info.plist $@/Versions/A/Resources
	$(CXX) -dynamiclib -dead_strip -interposable -bind_at_load -export_dynamic -dynamic $(ARCHS) $(OTHER_CFLAGS) -o $@/Versions/A/$(LIBRARY_NAME) $^ -framework Foundation -u _libmain -e _libmain ../libtest.a ../libsnapshot.a ../libutil.a ../libbase.a
	cd $@ && ln -sf Versions/A/$(LIBRARY_NAME) $(LIBRARY_NAME) && cd ..
	$(CODESIGN) $@/Versions/A

$(LIBRARY_NAME).dylib: classdumpdyldlib.o
	$(CXX) -dynamiclib -dead_strip -export_dynamic -init _libmain -bind_at_load -dynamic $(ARCHS) $(OTHER_CFLAGS) -o $@ $^ -framework Foundation -u _libmain -e _libmain ../libtest.a ../libsnapshot.a ../libutil.a ../libbase.a
	$(CODESIGN) $(LIBRARY_NAME).dylib

$(LIBRARY_NAME): classdumpdyldlib.o
	$(CXX) -dead_strip $(ARCHS) $(OTHER_CFLAGS) -o $@ $^ -framework Foundation -u _libmain -e _libmain ../libtest.a ../libsnapshot.a ../libutil.a ../libbase.a
	$(CODESIGN) $(LIBRARY_NAME)

$(LIBRARY_NAME).a: classdumpdyldlib.o
	$(AR) cru $@ $^
	$(RANLIB) $@

classdumpdyldlib.o: classdumpdyldlib.mm
	$(CXX) $(ARCHS) $(OTHER_CFLAGS) -std=gnu++11 -DLIBMAIN -o $@ -c $<

%.mm: %.xm
	cp -f $^ $@

%.o: %.mm
	$(CXX) $(ARCHS) $(OTHER_CFLAGS) -std=gnu++11 -DLIBMAIN -o $@ -c $<

libclassdumpdyld_FILES = classdumpdyldlib.mm
libclassdumpdyld_LDFLAGS = -lsubstrate

include $(MAKEFILEDIR)/library.make
