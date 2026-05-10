RPM_DISABLE_RELOCATABLE=YES

include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = PowerModule
BUNDLE_EXTENSION = .prefPane

PowerModule_HAS_RESOURCE_BUNDLE = yes

OBJCCFLAGS += -Wall -fobjc-runtime=gnustep-2.0 $(shell pkg-config --cflags glib-2.0)

PowerModule_OBJCC_FILES = PowerModule.mm

PowerModule_PRINCIPAL_CLASS = PowerModule

PowerModule_RESOURCE_FILES = \
Power.tiff \
Resources/English.lproj

PowerModule_LANGUAGES = \
Resources/English

ifeq ($(findstring darwin, $(GNUSTEP_TARGET_OS)), darwin)
  ADDITIONAL_GUI_LIBS += -lGSPreferencePanes $(shell pkg-config --libs glib-2.0)
else
  ADDITIONAL_GUI_LIBS += -lPreferencePanes $(shell pkg-config --libs glib-2.0)
endif

include $(GNUSTEP_MAKEFILES)/bundle.make

-include GNUmakefile.preamble
-include GNUmakefile.postamble

