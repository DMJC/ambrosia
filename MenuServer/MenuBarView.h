#import <AppKit/AppKit.h>

@class MenuBarController;

/**
 * MenuBarView — full-width custom view that draws the Ambrosia menu bar.
 *
 * Layout (left-to-right):
 *
 *   [  Ambrosia ▾ ] | AppName | TopMenu1 ▾ | TopMenu2 ▾ | …    HH:MM:SS  [ ⏻ ]
 *   ^               ^                                          ^            ^
 *   System menu     Current app  Frontmost app's top-level    Clock        Session
 *   (always shown)  name         menus (via DO registration)              menu
 *
 * The view is entirely drawn in -drawRect: for maximum control over appearance.
 * Mouse events are dispatched by checking pre-computed hit-test rectangles.
 */
@interface MenuBarView : NSView

/** Back-pointer to the controller that handles actions. */
@property (nonatomic, weak) MenuBarController *controller;

/**
 * Update the displayed application name and optional menu-item descriptors.
 *
 * @param appName   Name of the frontmost application, or nil to clear.
 * @param menuItems NSArray<NSDictionary*> of top-level menu descriptors as
 *                  defined in MenuServerProtocol.h, or nil for name-only display.
 */
- (void)setActiveAppName:(NSString *)appName menuItems:(NSArray *)menuItems;

@end
