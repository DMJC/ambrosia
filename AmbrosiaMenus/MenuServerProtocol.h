/**
 * MenuServerProtocol.h — Distributed Objects interface for AmbrosiaMenuServer.
 *
 * GNUstep applications that wish to integrate with the Ambrosia menu bar can
 * connect to the "AmbrosiaMenuServer" DO service and use these protocols to:
 *
 *   1. Register their main menu structure with the server when they become active.
 *   2. Receive action notifications when the user selects a menu item in the bar.
 *
 * MENU ITEM DESCRIPTOR
 * --------------------
 * A menu item is described by an NSDictionary with the following keys:
 *
 *   kMenuItemTitle      NSString  — Display title (localised)
 *   kMenuItemIdentifier NSString  — Stable identifier used in action callbacks
 *   kMenuItemEnabled    NSNumber  — BOOL; defaults to YES if absent
 *   kMenuItemSeparator  NSNumber  — BOOL; if YES the item is a separator rule
 *   kMenuItemKeyEquiv   NSString  — Key equivalent string (e.g. "s" for Cmd-S)
 *   kMenuItemChildren   NSArray   — Nested array of descriptors (submenu items)
 *
 * CONNECTING
 * ----------
 * An application connects with:
 *
 *   id<MenuServerProtocol> server =
 *       (id<MenuServerProtocol>)[NSConnection
 *           rootProxyForConnectionWithRegisteredName:kMenuServerConnectionName
 *                                              host:nil];
 *
 * Then, on NSApplicationDidBecomeActiveNotification:
 *
 *   [server applicationDidActivate:[[NSProcessInfo processInfo] processName]
 *                        menuItems:[self _buildMenuDescriptors]
 *                    clientObject:self];
 *
 * CLIENT CALLBACK
 * ---------------
 * The clientObject must implement MenuServerClientProtocol.  When the user
 * selects a menu item in the server, the server calls:
 *
 *   [client performMenuItemWithIdentifier:identifier];
 *
 * The identifier matches kMenuItemIdentifier in the descriptor sent earlier.
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

/* ------------------------------------------------------------------ */
#pragma mark - Client-side protocol (implemented by each GNUstep app)

/**
 * GNUstep applications implement this protocol and vend it via their own
 * NSConnection so the MenuServer can call them back on menu-item selection.
 */
@protocol MenuServerClientProtocol <NSObject>

/**
 * Called by the MenuServer when the user selects a menu item.
 *
 * @param identifier  The kMenuItemIdentifier value from the descriptor the
 *                    app sent when registering.  The app should perform the
 *                    appropriate action in response (e.g. open a file, quit).
 */
- (oneway void)performMenuItemWithIdentifier:(bycopy NSString *)identifier;

@end

/* ------------------------------------------------------------------ */
#pragma mark - Server-side protocol (vended by MenuServer)

/**
 * The protocol vended by the AmbrosiaMenuServer DO service.
 */
@protocol MenuServerProtocol <NSObject>

/**
 * Called when a GNUstep application becomes the frontmost application.
 *
 * @param appName     Human-readable name shown in the menu bar.
 * @param menuItems   NSArray<NSDictionary*> of top-level menu descriptors.
 *                    Each entry may contain a kMenuItemChildren array for the
 *                    drop-down items.  Pass nil to display the app name only.
 * @param client      A proxy to the app's MenuServerClientProtocol object.
 *                    Pass nil to suppress action callbacks.
 */
/**
 * Synchronous (no oneway): the bidirectional DO connection for the byref
 * client proxy is only established during a two-way call.  Making this
 * oneway prevents GNUstep from creating the reverse proxy channel.
 */
- (void)applicationDidActivate:(bycopy NSString *)appName
                    menuItems:(bycopy NSArray *)menuItems
                       client:(byref id<MenuServerClientProtocol>)client;

/**
 * Called when a GNUstep application is no longer the frontmost application.
 * The MenuServer will clear that app's menus from the bar.
 */
- (oneway void)applicationDidDeactivate:(bycopy NSString *)appName;

@end
