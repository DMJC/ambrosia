include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME     = AmbrosiaPrefs
BUNDLE_INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARY)/PreferencePanes

AmbrosiaPrefs_OBJC_FILES = \
	AmbrosiaPrefsModule.m

AmbrosiaPrefs_OBJCFLAGS  = -fobjc-arc
AmbrosiaPrefs_PRINCIPAL_CLASS = AmbrosiaPrefsModule

# Link against GNUstep PreferencePanes if available, otherwise AppKit only
AmbrosiaPrefs_LDFLAGS = -framework PreferencePanes

include $(GNUSTEP_MAKEFILES)/bundle.make
