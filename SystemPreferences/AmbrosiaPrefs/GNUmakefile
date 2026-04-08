include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME     = AmbrosiaPrefs
BUNDLE_EXTENSION = .prefPane
BUNDLE_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/Bundles

AmbrosiaPrefs_OBJC_FILES = \
	AmbrosiaPrefsModule.m

AmbrosiaPrefs_OBJCFLAGS  = -fobjc-arc
AmbrosiaPrefs_PRINCIPAL_CLASS = AmbrosiaPrefsModule

ADDITIONAL_FRAMEWORK_DIRS += $(GNUSTEP_LOCAL_DOMAIN_ROOT)
AmbrosiaPrefs_FRAMEWORKS  = PreferencePanes

include $(GNUSTEP_MAKEFILES)/bundle.make
