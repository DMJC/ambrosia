/**
 * NSApplication (AmbrosiaMenus) — swizzles -setMainMenu: so that after
 * GNUstep sets up its internal menu state the menu window is suppressed.
 *
 * On Wayland, gnustep-back would create a wlr-layer-shell surface at
 * ZWLR_LAYER_SHELL_V1_LAYER_TOP for every NSMainMenuWindowLevel window.
 * AmbrosiaMenuServer already owns that surface; each app must not create
 * its own.  The swizzle is installed in +load before NSApplicationMain()
 * runs, so all subsequent -setMainMenu: calls (including the first one
 * from the app's nib or -applicationDidFinishLaunching:) go through it.
 *
 * The replacement also triggers re-registration with the MenuServer so the
 * bar is updated whenever the app replaces its main menu at runtime.
 */

#import <AppKit/NSApplication.h>

@interface NSApplication (AmbrosiaMenus)

/* Installed as the replacement IMP after swizzle; visible here so the
 * compiler knows about it when it is called recursively (as the original). */
- (void)ambrosia_setMainMenu:(NSMenu *)menu;

@end
