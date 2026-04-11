/**
 * NSMenu (AmbrosiaMenus) — suppresses the main menu window on Wayland.
 *
 * GNUstep calls the private -_setGeometry method (and the public alias
 * -setGeometry) every time it needs to re-position the main menu window.
 * On Wayland / wlr-layer-shell this would create a competing layer surface
 * above AmbrosiaMenuServer's bar.  Our overrides detect the main menu and
 * immediately close its window instead of positioning it.
 *
 * Vertical drop-down menus (submenus opened via -popUpContextMenu:…) are
 * NOT the main menu and are left completely alone, so they continue to
 * appear and behave normally.
 */

#import <AppKit/NSMenu.h>

@interface NSMenu (AmbrosiaMenus)
/* Swizzle target; after exchange this IMP holds the original -display body. */
- (void)ambrosia_display;
@end
