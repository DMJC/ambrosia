#import <AppKit/AppKit.h>
#import "MenuServerProtocol.h"
#import "BluetoothStatusItem.h"
#import "WiFiStatusItem.h"
#import "VolumeStatusItem.h"
#import "TrayManager.h"

@class MenuBarView;

/**
 * MenuBarController — owns the menu bar panel and co-ordinates between the
 * layer-shell window, the Distributed Objects service, and NSWorkspace
 * notifications.
 *
 * The controller also drives the Ambrosia system actions (logout, about, …)
 * that the MenuBarView triggers via direct calls.
 */
@interface MenuBarController : NSObject <MenuServerProtocol, TrayManagerDelegate>

/** The full-width borderless panel displayed at NSMainMenuWindowLevel. */
@property (nonatomic, strong, readonly) NSPanel *menuPanel;

/** The custom view that fills the panel and draws all bar content. */
@property (nonatomic, strong, readonly) MenuBarView *menuBarView;

/** The SNI tray manager; used by MenuBarView for Activate/ContextMenu calls. */
@property (nonatomic, strong, readonly) TrayManager *trayManager;

/** Show the menu bar.  Call once from -applicationDidFinishLaunching:. */
- (void)showMenuBar;

/* ---- Actions called by MenuBarView ---- */

/** Forward a menu-item action to the currently-active DO-registered app. */
- (void)performMenuItemWithIdentifier:(NSString *)identifier;

/** Show the "About Ambrosia" dialog. */
- (void)showAbout;

/** Open System Preferences if installed. */
- (void)openSystemPreferences;

/** Bring GFinder to focus if already running, otherwise launch it. */
- (void)openGFinder;

/** Launch a terminal emulator. */
- (void)openTerminal;

/** Post the AmbrosiaLogoutRequest notification (with confirmation alert). */
- (void)logout;

/** Shut the system down (with confirmation alert). */
- (void)shutdown;

/** Reboot the system (with confirmation alert). */
- (void)reboot;

/* ---- Panel geometry (called by MenuBarView for inline dropdowns) ---- */

/**
 * Expand the menu bar panel downward by dropH pixels so the inline dropdown
 * is visible within the same layer-shell surface.
 */
- (void)expandPanelByDropdownHeight:(CGFloat)dropH;

/**
 * Collapse the panel back to the standard 24-px bar height.
 */
- (void)contractPanelDropdown;

@end
