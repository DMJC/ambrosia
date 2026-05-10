RPM_DISABLE_RELOCATABLE = YES

include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = BluetoothModule
BUNDLE_EXTENSION = .prefPane

BluetoothModule_HAS_RESOURCE_BUNDLE = yes

ADDITIONAL_OBJCCFLAGS += -Wall -fobjc-runtime=gnustep-2.0

BluetoothModule_OBJCC_FILES = BluetoothModule.mm

BluetoothModule_PRINCIPAL_CLASS = BluetoothModule

BluetoothModule_RESOURCE_FILES = Bluetooth.tiff \
  Resources/English.lproj

BluetoothModule_LANGUAGES = \
Resources/English

ifeq ($(findstring darwin, $(GNUSTEP_TARGET_OS)), darwin)
  ADDITIONAL_GUI_LIBS += -lGSPreferencePanes
else
  ADDITIONAL_GUI_LIBS += -lPreferencePanes
endif

include $(GNUSTEP_MAKEFILES)/bundle.make

-include GNUmakefile.preamble
-include GNUmakefile.postamble
