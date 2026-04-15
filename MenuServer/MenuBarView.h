#import <AppKit/AppKit.h>
#import "AmbrosiaStatusItemPlugin.h"

@class MenuBarController;

/**
 * MenuBarView — full-width custom view that draws the Ambrosia menu bar.
 *
 * Layout (left-to-right):
 *
 *   [  Ambrosia ▾ ] | AppName | TopMenu1 ▾ | TopMenu2 ▾ | …  [BT▾]  HH:MM:SS  [ ⏻ ]
 *   ^               ^                                          ^       ^          ^
 *   System menu     Current app  Frontmost app's top-level    Status  Clock      Session
 *   (always shown)  name         menus (via DO registration)  items              menu
 *
 * The view is entirely drawn in -drawRect: for maximum control over appearance.
 * Mouse events are dispatched by checking pre-computed hit-test rectangles.
 */
@interface MenuBarView : NSView <AmbrosiaStatusItemPluginDelegate>

/** Back-pointer to the controller that handles actions. */
@property (nonatomic, weak) MenuBarController *controller;

/**
 * Ordered array of right-side status item plugins (drawn right-to-left,
 * inserted between the clock and session button).
 * Set by MenuBarController after construction.
 */
@property (nonatomic, copy) NSArray<id<AmbrosiaStatusItemPlugin>> *statusPlugins;

/**
 * Update the displayed application name and optional menu-item descriptors.
 *
 * @param appName   Name of the frontmost application, or nil to clear.
 * @param menuItems NSArray<NSDictionary*> of top-level menu descriptors as
 *                  defined in MenuServerProtocol.h, or nil for name-only display.
 */
- (void)setActiveAppName:(NSString *)appName menuItems:(NSArray *)menuItems;

@end
