# AmbrosiaMenus — AppKit bundle that bridges GNUstep apps to AmbrosiaMenuServer.
#
# Install as a bundle and add its path to the GSAppKitUserBundles user default
# (or -GSAppKitUserBundles launch argument) so that every GNUstep app on the
# Ambrosia desktop loads it automatically.
#
# Example (per-user install, added to NSGlobalDomain):
#   defaults write NSGlobalDomain GSAppKitUserBundles \
#     '("/usr/GNUstep/Local/Library/Bundles/AmbrosiaMenus.bundle")'
#
# Build:
#   source /usr/share/GNUstep/Makefiles/GNUstep.sh
#   make
#
# Install:
#   make install   (installs to GNUSTEP_LOCAL_ROOT/Library/Bundles/)

GNUSTEP_INSTALLATION_DOMAIN = LOCAL

include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = AmbrosiaMenus

AmbrosiaMenus_OBJC_FILES = \
    AmbrosiaMenusBundle.m         \
    NSApplication+AmbrosiaMenus.m \
    NSMenu+AmbrosiaMenus.m

AmbrosiaMenus_OBJCFLAGS       = -fobjc-arc
AmbrosiaMenus_PRINCIPAL_CLASS  = AmbrosiaMenusBundle

include $(GNUSTEP_MAKEFILES)/bundle.make
