/**
 * MenuServerProtocol.h — Distributed Objects interface for AmbrosiaMenuServer.
 *
 * GNUstep applications integrate with the Ambrosia menu bar by:
 *
 *   1. Connecting to the "AmbrosiaMenuServer" DO service.
 *   2. Calling -applicationDidActivate:menuItems:pid: when they become active
 *      to register their menu structure.
 *   3. Observing kMenuItemSelectedNotification on NSDistributedNotificationCenter.
 *      When the user selects a menu item the server posts this notification;
 *      only the process whose PID matches kMenuItemSelectedPIDKey should act.
 *
 * MENU ITEM DESCRIPTOR
 * --------------------
 * A menu item is described by an NSDictionary with the following keys:
 *
 *   kMenuItemTitle      NSString  — Display title (localised)
 *   kMenuItemIdentifier NSString  — UUID used in the selection notification
 *   kMenuItemEnabled    NSNumber  — BOOL; defaults to YES if absent
 *   kMenuItemSeparator  NSNumber  — BOOL; if YES the item is a separator rule
 *   kMenuItemKeyEquiv   NSString  — Key equivalent string (e.g. "s" for Cmd-S)
 *   kMenuItemChildren   NSArray   — Nested array of descriptors (submenu items)
 */

#import <Foundation/Foundation.h>

/* ---- Service registration name ---- */
static NSString * const kMenuServerConnectionName = @"AmbrosiaMenuServer";

/* ---- Menu item descriptor keys ---- */
static NSString * const kMenuItemTitle      = @"title";
static NSString * const kMenuItemIdentifier = @"identifier";
static NSString * const kMenuItemEnabled    = @"enabled";
static NSString * const kMenuItemSeparator  = @"separator";
static NSString * const kMenuItemKeyEquiv   = @"keyEquiv";
static NSString * const kMenuItemChildren   = @"children";

/* ---- Menu-item selection notification (NSDistributedNotificationCenter) ----
 *
 * MenuServer posts this notification on NSDistributedNotificationCenter when
 * the user selects an item in the active app's menu.  The userInfo carries:
 *
 *   kMenuItemSelectedPIDKey        NSNumber (int32)  — PID of the target app
 *   kMenuItemSelectedIdentifierKey NSString          — the item's UUID
 *
 * Each GNUstep app that has registered via DO observes this notification and
 * ignores it when the PID does not match its own getpid() / processIdentifier.
 * This avoids any DO reverse-connection complexity: the server only needs to
 * know the target PID, not hold a proxy to the client.
 * ------------------------------------------------------------------ */
static NSString * const kMenuItemSelectedNotification  = @"AmbrosiaMenuItemSelected";
static NSString * const kMenuItemSelectedPIDKey        = @"clientPID";
static NSString * const kMenuItemSelectedIdentifierKey = @"identifier";

/* ------------------------------------------------------------------ */
#pragma mark - Server-side protocol (vended by MenuServer)

/**
 * The protocol vended by the AmbrosiaMenuServer DO service.
 * Applications connect with:
 *
 *   id<MenuServerProtocol> server =
 *       (id<MenuServerProtocol>)[NSConnection
 *           rootProxyForConnectionWithRegisteredName:kMenuServerConnectionName
 *                                              host:nil];
 *   [server setProtocolForProxy:@protocol(MenuServerProtocol)];
 */
@protocol MenuServerProtocol <NSObject>

/**
 * Called when a GNUstep application becomes the frontmost application.
 *
 * @param appName   Human-readable name shown in the menu bar.
 * @param menuItems NSArray<NSDictionary*> of top-level menu descriptors.
 *                  Each entry may contain a kMenuItemChildren array.
 *                  Pass nil to display the app name only.
 * @param pid       The calling process's PID (as NSNumber int32).
 *                  MenuServer stores this and uses it as the routing key
 *                  when posting kMenuItemSelectedNotification.
 */
- (void)applicationDidActivate:(bycopy NSString *)appName
                     menuItems:(bycopy NSArray *)menuItems
                           pid:(bycopy NSNumber *)pid;

/**
 * Called when a GNUstep application is no longer the frontmost application.
 * MenuServer will clear that app's menus from the bar.
 */
- (oneway void)applicationDidDeactivate:(bycopy NSString *)appName;

@end
