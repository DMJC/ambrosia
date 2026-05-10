include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = VideoModule
BUNDLE_EXTENSION = .prefPane
VideoModule_PRINCIPAL_CLASS = VideoModule

# Use OBJCXX for Objective-C++
VideoModule_OBJCC_FILES = VideoModule.mm
VideoModule_CC_FILES = X11Backend.cpp WaylandBackend.cpp
VideoModule_RESOURCE_FILES = Video.tiff \
Resources/English.lproj

VideoModule_GUI_LIBS = -lX11 -lXrandr

# Flags
VideoModule_OBJCXXFLAGS += `gnustep-config --objc-flags` -std=gnu++17
VideoModule_LDFLAGS     += `gnustep-config --base-libs` `gnustep-config --gui-libs` -lX11 -lXrandr -lstdc++
include $(GNUSTEP_MAKEFILES)/bundle.make
-include GNUmakefile.preamble
-include GNUmakefile.postamble
