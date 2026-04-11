/**
 * AmbrosiaMenusBundle — principal class of the AmbrosiaMenus AppKit bundle.
 *
 * Loaded automatically by every GNUstep app on the Ambrosia desktop via the
 * GSAppKitUserBundles user default.  On load the bundle:
 *
 *   1. Swizzles NSApplication -setMainMenu: so the menu window is suppressed
 *      (no competing layer-shell surface is created; AmbrosiaMenuServer owns
 *      the bar).
 *   2. Overrides NSMenu -_setGeometry / -setGeometry to keep the window hidden
 *      whenever GNUstep tries to re-position it.
 *   3. Connects to the AmbrosiaMenuServer via Distributed Objects and
 *      registers the app's menu structure when the app becomes active.
 *   4. Implements MenuServerClientProtocol so that MenuServer can call back
 *      when the user selects a menu item, dispatching the action to the
 *      NSMenuItem's target inside this process.
 */

#import <Foundation/Foundation.h>
#import "MenuServerProtocol.h"

@interface AmbrosiaMenusBundle : NSObject <MenuServerClientProtocol>

/** Returns the per-process singleton.  Created on first call. */
+ (instancetype)sharedBundle;

/**
 * Build menu descriptors from [NSApp mainMenu] and send them to MenuServer.
 * Safe to call at any time; silently no-ops if MenuServer is unreachable.
 */
- (void)registerMenuWithServer;

/**
 * Notify MenuServer that this app is shutting down / deactivating.
 * Called automatically on NSApplicationWillTerminateNotification.
 */
- (void)deregisterFromServer;

@end
