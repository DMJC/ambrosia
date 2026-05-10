RPM_DISABLE_RELOCATABLE = YES

include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = NetworkModule
BUNDLE_EXTENSION = .prefPane

NetworkModule_HAS_RESOURCE_BUNDLE = yes

# Compiler flags for all files, including the unstable flag
ADDITIONAL_OBJCCFLAGS += -Wall -fobjc-runtime=gnustep-2.0 -DWLR_USE_UNSTABLE $(shell pkg-config --cflags wayland-client)

NetworkModule_OBJCC_FILES = NetworkModule.mm

NetworkModule_PRINCIPAL_CLASS = NetworkModule

NetworkModule_RESOURCE_FILES = Network.tiff \
  Ethernet.tiff \
  Bluetooth.tiff \
  Wifi.tiff \
  Resources/English.lproj

NetworkModule_LANGUAGES = \
Resources/English

ifeq ($(findstring darwin, $(GNUSTEP_TARGET_OS)), darwin)
  ADDITIONAL_GUI_LIBS += -lGSPreferencePanes -lwayland-client
#-lwlroots
else
  ADDITIONAL_GUI_LIBS += -lPreferencePanes -lwayland-client
#-lwlroots
endif

include $(GNUSTEP_MAKEFILES)/bundle.make

-include GNUmakefile.preamble
-include GNUmakefile.postamble
