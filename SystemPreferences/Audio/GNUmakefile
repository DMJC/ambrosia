RPM_DISABLE_RELOCATABLE=YES

include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = AudioModule
BUNDLE_EXTENSION = .prefPane

AudioModule_HAS_RESOURCE_BUNDLE = yes

OBJCCFLAGS += -Wall -fobjc-runtime=gnustep-2.0 libpulse

AudioModule_OBJCC_FILES = AudioModule.mm

AudioModule_PRINCIPAL_CLASS = AudioModule

AudioModule_RESOURCE_FILES = \
Audio.tiff \
Resources/English.lproj

AudioModule_FRAMEWORKS = PreferencePanes
AudioModule_LANGUAGES = \
Resources/English

ifeq ($(findstring darwin, $(GNUSTEP_TARGET_OS)), darwin)
  ADDITIONAL_GUI_LIBS += -lGSPreferencePanes -lpulse
else
  ADDITIONAL_FRAMEWORK_DIRS += $(GNUSTEP_LOCAL_DOMAIN_ROOT)
  ADDITIONAL_GUI_LIBS += -lPreferencePanes -lpulse
endif

include $(GNUSTEP_MAKEFILES)/bundle.make

-include GNUmakefile.preamble
-include GNUmakefile.postamble

