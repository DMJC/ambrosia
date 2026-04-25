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
 *
 * @param x          Screen x coordinate.
 * @param y          Screen y coordinate.
 * @param connection An open DBusConnection.
 */
- (void)contextMenuAtX:(int)x y:(int)y connection:(void *)connection;

@end


@protocol TrayItemDelegate <NSObject>
/** Called on the main queue after -fetchPropertiesWithConnection: updates the item. */
- (void)trayItemDidUpdate:(TrayItem *)item;
@end
