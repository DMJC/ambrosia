#import <AppKit/AppKit.h>
#import "MenuServerProtocol.h"

@class MenuBarView;

/**
 * MenuBarController — owns the menu bar panel and co-ordinates between the
 * layer-shell window, the Distributed Objects service, and NSWorkspace
 * notifications.
 *
 * The controller also drives the Ambrosia system actions (logout, about, …)
 * that the MenuBarView triggers via direct calls.
 */
@interface MenuBarController : NSObject <MenuServerProtocol>

/** The full-width borderless panel displayed at NSMainMenuWindowLevel. */
@property (nonatomic, strong, readonly) NSPanel *menuPanel;

/** The custom view that fills the panel and draws all bar content. */
@property (nonatomic, strong, readonly) MenuBarView *menuBarView;

/** Show the menu bar.  Call once from -applicationDidFinishLaunching:. */
- (void)showMenuBar;

/* ---- Actions called by MenuBarView ---- */

/** Forward a menu-item action to the currently-active DO-registered app. */
- (void)performMenuItemWithIdentifier:(NSString *)identifier;

/** Show the "About Ambrosia" dialog. */
- (void)showAbout;

/** Open System Preferences if installed. */
- (void)openSystemPreferences;

/** Post the AmbrosiaLogoutRequest notification (with confirmation alert). */
- (void)logout;

@end
