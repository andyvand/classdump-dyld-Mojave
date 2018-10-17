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
ARCHS=-arch x86_64

CC=gcc
CXX=g++
LD=g++

SIGNID = "Mac Developer: andyvandijck@hotmail.com (DE4YUA5AZQ)"

CODESIGN = codesign -s $(SIGNID)

all: classdumpdyldlibdir classdump-dyld

classdumpdyldlibdir: main.o
	make -C classdumpdyldlib -f Makefile libclassdumpdyld.a
	touch $@

classdump-dyld: main.o
	$(CXX) $(ARCHS) $(OTHER_CFLAGS) -o $@ $^ classdumpdyldlib/libclassdumpdyld.a libtest.a libsnapshot.a libutil.a libbase.a -framework Foundation -framework IOKit -framework CoreGraphics -framework QuartzCore -framework MediaToolbox -framework Cocoa -framework Security
	$(CODESIGN) $@ # --entitlements classdumpdyldlib/entitlements.plist $@

main.o: main.mm
	$(CXX) $(ARCHS) $(OTHER_CFLAGS) -std=gnu++11 -o $@ -c $^

%.mm: %.xm
	cp $^ $@

%.o: %.mm
	$(CXX) $(ARCHS) -std=gnu++11 -o $@ $(OTHER_CFLAGS) -c $^

aggregate: classdump-dyld
SUBPROJECTS+=classdumpdyldlib

include $(MAKEFILEDIR)/common.make

classdump-dyld_FILES=main.xm

include $(MAKEFILEDIR)/tool.make
include $(MAKEFILEDIR)/library.make
include $(MAKEFILEDIR)/aggregate.make
