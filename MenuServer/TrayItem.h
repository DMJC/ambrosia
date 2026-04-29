/**
 * TrayItem.h
 *
 * Represents one StatusNotifierItem registered with the Ambrosia tray.
 *
 * Each item is identified by the D-Bus service name that called
 * RegisterStatusNotifierItem (e.g. ":1.42" or "org.kde.discord").
 * The canonical SNI object path is /StatusNotifierItem unless the caller
 * passed "service/objectPath" in the registration string.
 *
 * The item fetches its icon (IconPixmap preferred, IconName fallback) and
 * title asynchronously and notifies its delegate when ready.
 */

#import <AppKit/AppKit.h>

@protocol TrayItemDelegate;

@interface TrayItem : NSObject

/** D-Bus sender name (bus name, e.g. ":1.42"). */
@property (nonatomic, readonly, copy) NSString *busName;

/** D-Bus object path, typically "/StatusNotifierItem". */
@property (nonatomic, readonly, copy) NSString *objectPath;

/** Cached icon, updated after -fetchProperties completes.  May be nil. */
@property (nonatomic, readonly, strong) NSImage *icon;

/** Item title / tooltip text.  May be empty. */
@property (nonatomic, readonly, copy) NSString *title;

/**
 * D-Bus object path of the com.canonical.dbusmenu interface, or nil if the
 * item does not expose a dbusmenu (it uses the legacy ContextMenu(x,y) call).
 * Populated by -fetchPropertiesWithConnection:.
 */
@property (nonatomic, readonly, copy) NSString *menuPath;

/** Delegate notified when properties are updated. */
@property (nonatomic, weak) id<TrayItemDelegate> delegate;

/**
 * Designated initialiser.
 *
 * @param busName     The D-Bus bus name of the item's owner.
 * @param objectPath  The object path for the StatusNotifierItem interface.
 */
- (instancetype)initWithBusName:(NSString *)busName
                     objectPath:(NSString *)objectPath;

/**
 * Fetch (or re-fetch) IconPixmap, IconName, and Title from the item's
 * D-Bus interface.  Runs on a background queue; calls the delegate on the
 * main queue when done.
 *
 * @param connection  An open DBusConnection to the session bus.
 */
- (void)fetchPropertiesWithConnection:(void *)connection;

/**
 * Send an Activate(x, y) call to the item (left-click semantic).
 *
 * @param x          Screen x coordinate.
 * @param y          Screen y coordinate.
 * @param connection An open DBusConnection.
 */
- (void)activateAtX:(int)x y:(int)y connection:(void *)connection;

/**
 * Send a ContextMenu(x, y) call to the item (right-click semantic).
 * Used as a fallback when the item exposes no dbusmenu path.
 */
- (void)contextMenuAtX:(int)x y:(int)y connection:(void *)connection;

/**
 * Fetch the complete menu layout via com.canonical.dbusmenu GetLayout and
 * convert it to an array of MenuServer descriptor dictionaries.
 *
 * @param connection   The shared DBusConnection (used only to derive the bus
 *                     address; the actual blocking calls run on dbusQueue).
 * @param dbusQueue    The serial queue that owns the D-Bus connection.
 *                     Blocking calls are dispatched here so they cannot race
 *                     with the TrayManager's periodic dispatch handler.
 * @param completion   Called on the main queue with the parsed items, or an
 *                     empty array if the item has no dbusmenu.
 */
- (void)fetchMenuItemsWithConnection:(void *)connection
                           dbusQueue:(dispatch_queue_t)dbusQueue
                          completion:(void (^)(NSArray<NSDictionary *> *items))completion;

/**
 * Send Event(id, "clicked", 0, timestamp) to activate a dbusmenu item.
 * Dispatched to dbusQueue to avoid racing with the dispatch handler.
 */
- (void)triggerMenuItemId:(int32_t)itemId
               connection:(void *)connection
                dbusQueue:(dispatch_queue_t)dbusQueue;

@end


@protocol TrayItemDelegate <NSObject>
/** Called on the main queue after -fetchPropertiesWithConnection: updates the item. */
- (void)trayItemDidUpdate:(TrayItem *)item;
@end
