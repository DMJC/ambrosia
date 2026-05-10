/**
 * TrayManager.h
 *
 * Implements the org.kde.StatusNotifierWatcher D-Bus service so that
 * StatusNotifierItem clients (Discord, nm-applet, etc.) can register
 * their tray icons with the Ambrosia menu bar.
 *
 * Also registers a StatusNotifierHost so clients know a host is present.
 *
 * Registered items are exposed via the -trayItems property; the delegate
 * is notified on the main queue whenever the set or state of items changes.
 */

#import <Foundation/Foundation.h>
#import "TrayItem.h"

@protocol TrayManagerDelegate;

@interface TrayManager : NSObject <TrayItemDelegate>

/** Currently registered tray items (ordered by registration time). */
@property (nonatomic, readonly, copy) NSArray<TrayItem *> *trayItems;

/** Delegate notified when items are added, removed, or updated. */
@property (nonatomic, weak) id<TrayManagerDelegate> delegate;

/**
 * Connect to the session D-Bus, register org.kde.StatusNotifierWatcher,
 * and start the D-Bus dispatch loop.  Call once from -applicationDidFinishLaunching:.
 */
- (void)start;

/** The raw DBusConnection pointer (void * to avoid importing dbus.h in headers). */
@property (nonatomic, readonly) void *dbusConnection;

/**
 * The serial GCD queue that owns the D-Bus connection.
 * All blocking D-Bus calls (send_with_reply_and_block) must be dispatched
 * to this queue so they do not race with the periodic dispatch handler.
 */
@property (nonatomic, readonly) dispatch_queue_t dbusQueue;

@end


@protocol TrayManagerDelegate <NSObject>
/** Called on the main queue when the tray item list or any item's icon changes. */
- (void)trayManagerDidUpdateItems:(TrayManager *)manager;
@end
