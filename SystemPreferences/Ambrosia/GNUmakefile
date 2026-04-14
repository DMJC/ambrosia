include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME     = AmbrosiaModule
BUNDLE_EXTENSION = .prefPane
BUNDLE_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles

AmbrosiaModule_OBJC_FILES = AmbrosiaModule.m

AmbrosiaModule_OBJCFLAGS  = -fobjc-arc
AmbrosiaModule_PRINCIPAL_CLASS = AmbrosiaModule
AmbrosiaModule_MAIN_MODEL_FILE = AmbrosiaModule

AmbrosiaModule_RESOURCE_FILES = Ambrosia.tiff \
  Resources/English.lproj


ADDITIONAL_FRAMEWORK_DIRS += $(GNUSTEP_LOCAL_DOMAIN_ROOT)
AmbrosiaModule_FRAMEWORKS  = PreferencePanes

include $(GNUSTEP_MAKEFILES)/bundle.make
