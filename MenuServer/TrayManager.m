#import "TrayManager.h"
#import <dbus/dbus.h>

/* D-Bus service / interface / object-path constants */
static const char * const kWatcherService   = "org.kde.StatusNotifierWatcher";
static const char * const kWatcherPath      = "/StatusNotifierWatcher";
static const char * const kWatcherInterface = "org.kde.StatusNotifierWatcher";
static const char * const kHostService      = "org.kde.StatusNotifierHost";

/* SNI signal names */
static const char * const kSigItemRegistered = "StatusNotifierItemRegistered";
static const char * const kSigHostRegistered = "StatusNotifierHostRegistered";

/* NameOwnerChanged: watch for items that die without unregistering */
static const char * const kDBusInterface        = "org.freedesktop.DBus";
static const char * const kNameOwnerChanged     = "NameOwnerChanged";

/* SNI signals that indicate an item's icon or status changed */
static const char * const kSNIInterface = "org.kde.StatusNotifierItem";
static const char * const kSigNewIcon   = "NewIcon";
static const char * const kSigNewStatus = "NewStatus";

/* ---------------------------------------------------------------------- */
#pragma mark - D-Bus vtable callbacks (C)

static DBusHandlerResult watcherMessageHandler(DBusConnection *conn,
                                               DBusMessage    *msg,
                                               void           *userData);

static const DBusObjectPathVTable kWatcherVTable = {
    .unregister_function = NULL,
    .message_function    = watcherMessageHandler,
};

/* ---------------------------------------------------------------------- */

@implementation TrayManager {
    DBusConnection             *_conn;
    NSMutableArray<TrayItem *> *_items;
    dispatch_queue_t            _dbusQueue;
    dispatch_source_t           _dispatchSource; /* GCD timer drives D-Bus dispatch */
}

@synthesize dbusQueue = _dbusQueue;

@synthesize delegate = _delegate;

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _items     = [NSMutableArray array];
    _dbusQueue = dispatch_queue_create("ambrosia.tray.dbus",
                                       DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc
{
    if (_dispatchSource) {
        dispatch_source_cancel(_dispatchSource);
        _dispatchSource = nil;
    }
    if (_conn) {
        dbus_connection_close(_conn);
        dbus_connection_unref(_conn);
    }
}

- (NSArray<TrayItem *> *)trayItems { return [_items copy]; }
- (void *)dbusConnection           { return _conn; }

/* ---------------------------------------------------------------------- */
#pragma mark - Startup

- (void)start
{
    dispatch_async(_dbusQueue, ^{ [self _startOnQueue]; });
}

- (void)_startOnQueue
{
    /* Enable libdbus thread safety so internal data structures are locked.
     * Must be called before any other libdbus function.                    */
    dbus_threads_init_default();

    DBusError err;
    dbus_error_init(&err);

    _conn = dbus_bus_get(DBUS_BUS_SESSION, &err);
    if (!_conn || dbus_error_is_set(&err)) {
        NSLog(@"TrayManager: cannot connect to session bus: %s",
              dbus_error_is_set(&err) ? err.message : "(unknown)");
        dbus_error_free(&err);
        return;
    }

    /* Prevent libdbus from calling exit() on disconnect */
    dbus_connection_set_exit_on_disconnect(_conn, FALSE);

    /* Register StatusNotifierWatcher object path */
    if (!dbus_connection_register_object_path(_conn, kWatcherPath,
                                              &kWatcherVTable,
                                              (__bridge void *)self)) {
        NSLog(@"TrayManager: failed to register object path %s", kWatcherPath);
    }

    /* Request the well-known watcher service name */
    int result = dbus_bus_request_name(_conn, kWatcherService,
                                       DBUS_NAME_FLAG_REPLACE_EXISTING |
                                       DBUS_NAME_FLAG_DO_NOT_QUEUE,
                                       &err);
    if (dbus_error_is_set(&err)) {
        NSLog(@"TrayManager: request_name error: %s", err.message);
        dbus_error_free(&err);
    }
    if (result != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
        result != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        NSLog(@"TrayManager: could not acquire %s (result=%d). "
              @"Another watcher may be running.", kWatcherService, result);
    } else {
        NSLog(@"TrayManager: acquired %s", kWatcherService);
    }

    /* Register a StatusNotifierHost so clients know a host is present */
    dbus_bus_request_name(_conn, kHostService,
                          DBUS_NAME_FLAG_DO_NOT_QUEUE, &err);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);

    /* Emit StatusNotifierHostRegistered so already-running items wake up */
    [self _emitSignal:kSigHostRegistered];

    /* Watch for NameOwnerChanged to evict items whose process died */
    dbus_bus_add_match(_conn,
        "type='signal',"
        "sender='org.freedesktop.DBus',"
        "interface='org.freedesktop.DBus',"
        "member='NameOwnerChanged'",
        &err);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);

    /* Watch for SNI icon-change signals from any item */
    dbus_bus_add_match(_conn,
        "type='signal',"
        "interface='org.kde.StatusNotifierItem'",
        &err);
    if (dbus_error_is_set(&err)) dbus_error_free(&err);

    dbus_connection_add_filter(_conn, watcherMessageHandler,
                               (__bridge void *)self, NULL);
    dbus_connection_flush(_conn);

    /* Replace the old blocking while-loop with a GCD timer that fires on
     * _dbusQueue every 20 ms.  Because _dbusQueue is serial, the timer
     * handler and any blocking D-Bus calls dispatched to the same queue
     * cannot run concurrently — eliminating the reply-stealing race that
     * caused send_with_reply_and_block to time out.                        */
    [self _startDispatchTimer];
}

- (void)_startDispatchTimer
{
    _dispatchSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _dbusQueue);

    dispatch_source_set_timer(_dispatchSource,
        DISPATCH_TIME_NOW,
        20 * NSEC_PER_MSEC,   /* 20 ms interval — low latency for signals  */
        5  * NSEC_PER_MSEC);  /* 5 ms leeway                               */

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_dispatchSource, ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_conn) return;
        if (!dbus_connection_get_is_connected(strongSelf->_conn)) {
            NSLog(@"TrayManager: D-Bus connection lost.");
            dispatch_source_cancel(strongSelf->_dispatchSource);
            return;
        }
        /* Non-blocking read from the socket, then dispatch pending messages */
        dbus_connection_read_write(strongSelf->_conn, 0);
        while (dbus_connection_dispatch(strongSelf->_conn) ==
               DBUS_DISPATCH_DATA_REMAINS) {}
    });

    dispatch_resume(_dispatchSource);
    NSLog(@"TrayManager: D-Bus dispatch timer started (20 ms interval).");
}

/* ---------------------------------------------------------------------- */
#pragma mark - Message handler (called from D-Bus dispatch thread)

/*
 * This function handles two kinds of messages:
 *
 * 1. Method calls on /StatusNotifierWatcher  (from SNI clients)
 * 2. Signals we subscribed to (NameOwnerChanged, SNI icon signals)
 *
 * It is a plain C function so libdbus can call it directly.
 * We bridge back to the ObjC TrayManager via the userData pointer.
 */
static DBusHandlerResult watcherMessageHandler(DBusConnection *conn,
                                               DBusMessage    *msg,
                                               void           *userData)
{
    TrayManager *self = (__bridge TrayManager *)userData;
    if (!self) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    const char *iface  = dbus_message_get_interface(msg);
    const char *member = dbus_message_get_member(msg);
    int         mtype  = dbus_message_get_type(msg);

    if (!iface || !member) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    /* ---- Method calls on the watcher interface ---- */
    if (mtype == DBUS_MESSAGE_TYPE_METHOD_CALL &&
        strcmp(iface, kWatcherInterface) == 0) {

        if (strcmp(member, "RegisterStatusNotifierItem") == 0) {
            const char *service = NULL;
            dbus_message_get_args(msg, NULL,
                DBUS_TYPE_STRING, &service,
                DBUS_TYPE_INVALID);
            if (service) {
                NSString *svcStr = @(service);
                const char *sender = dbus_message_get_sender(msg);
                NSString *senderStr = sender ? @(sender) : svcStr;
                [self _registerItemWithService:svcStr sender:senderStr];
            }
            /* Reply with empty success */
            DBusMessage *reply = dbus_message_new_method_return(msg);
            if (reply) {
                dbus_connection_send(conn, reply, NULL);
                dbus_message_unref(reply);
            }
            return DBUS_HANDLER_RESULT_HANDLED;
        }

        if (strcmp(member, "RegisterStatusNotifierHost") == 0) {
            DBusMessage *reply = dbus_message_new_method_return(msg);
            if (reply) {
                dbus_connection_send(conn, reply, NULL);
                dbus_message_unref(reply);
            }
            return DBUS_HANDLER_RESULT_HANDLED;
        }

        /* Properties.Get on the watcher */
        if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 &&
            strcmp(member, "Get") == 0) {
            [self _handlePropertyGet:msg connection:conn];
            return DBUS_HANDLER_RESULT_HANDLED;
        }
    }

    /* ---- Properties.Get on the watcher (separate iface check) ---- */
    if (mtype == DBUS_MESSAGE_TYPE_METHOD_CALL &&
        strcmp(iface, "org.freedesktop.DBus.Properties") == 0 &&
        strcmp(member, "Get") == 0) {
        [self _handlePropertyGet:msg connection:conn];
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    /* ---- NameOwnerChanged: evict dead item buses ---- */
    if (mtype == DBUS_MESSAGE_TYPE_SIGNAL &&
        strcmp(iface, kDBusInterface) == 0 &&
        strcmp(member, kNameOwnerChanged) == 0) {
        const char *name  = NULL;
        const char *oldO  = NULL;
        const char *newO  = NULL;
        dbus_message_get_args(msg, NULL,
            DBUS_TYPE_STRING, &name,
            DBUS_TYPE_STRING, &oldO,
            DBUS_TYPE_STRING, &newO,
            DBUS_TYPE_INVALID);
        /* Name lost (newOwner is empty) */
        if (name && newO && *newO == '\0') {
            [self _evictItemWithBusName:@(name)];
        }
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    /* ---- SNI icon/status change ---- */
    if (mtype == DBUS_MESSAGE_TYPE_SIGNAL &&
        strcmp(iface, kSNIInterface) == 0 &&
        (strcmp(member, kSigNewIcon)   == 0 ||
         strcmp(member, kSigNewStatus) == 0)) {
        const char *sender = dbus_message_get_sender(msg);
        if (sender) [self _refreshItemWithBusName:@(sender)];
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Item registration / eviction (called from D-Bus queue)

- (void)_registerItemWithService:(NSString *)service sender:(NSString *)sender
{
    /* service may be "/objectpath", "busname", or "busname/objectpath" */
    NSString *busName    = sender;
    NSString *objectPath = nil;

    if ([service hasPrefix:@"/"]) {
        /* Pure object path — bus name comes from the D-Bus sender */
        objectPath = service;
    } else {
        NSRange slash = [service rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            busName    = [service substringToIndex:slash.location];
            objectPath = [service substringFromIndex:slash.location];
        }
    }

    if (!busName.length) busName = sender;

    TrayItem *item = [[TrayItem alloc] initWithBusName:busName
                                            objectPath:objectPath];
    item.delegate = self;

    dispatch_async(dispatch_get_main_queue(), ^{
        /* Avoid duplicate registrations */
        for (TrayItem *existing in self->_items) {
            if ([existing.busName isEqualToString:busName]) return;
        }
        [self->_items addObject:item];
        [self->_delegate trayManagerDidUpdateItems:self];
    });

    /* Fetch icon/title async (will call back via delegate) */
    [item fetchPropertiesWithConnection:_conn];

    /* Emit ItemRegistered signal */
    [self _emitSignal:kSigItemRegistered withString:service.UTF8String];

    NSLog(@"TrayManager: registered item busName=%@ path=%@",
          busName, objectPath ?: @"/StatusNotifierItem");
}

- (void)_evictItemWithBusName:(NSString *)busName
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger idx = NSNotFound;
        for (NSUInteger i = 0; i < self->_items.count; i++) {
            if ([self->_items[i].busName isEqualToString:busName]) {
                idx = i;
                break;
            }
        }
        if (idx == NSNotFound) return;
        [self->_items removeObjectAtIndex:idx];
        [self->_delegate trayManagerDidUpdateItems:self];
        NSLog(@"TrayManager: evicted item busName=%@", busName);
    });
}

- (void)_refreshItemWithBusName:(NSString *)busName
{
    dispatch_async(dispatch_get_main_queue(), ^{
        for (TrayItem *item in self->_items) {
            if ([item.busName isEqualToString:busName]) {
                [item fetchPropertiesWithConnection:self->_conn];
                return;
            }
        }
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Properties.Get on watcher (called from D-Bus queue)

- (void)_handlePropertyGet:(DBusMessage *)msg connection:(DBusConnection *)conn
{
    const char *reqIface = NULL;
    const char *propName = NULL;
    dbus_message_get_args(msg, NULL,
        DBUS_TYPE_STRING, &reqIface,
        DBUS_TYPE_STRING, &propName,
        DBUS_TYPE_INVALID);
    if (!propName) return;

    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return;

    DBusMessageIter replyIter, varIter;
    dbus_message_iter_init_append(reply, &replyIter);

    if (strcmp(propName, "IsStatusNotifierHostRegistered") == 0) {
        dbus_bool_t val = TRUE;
        dbus_message_iter_open_container(&replyIter, DBUS_TYPE_VARIANT,
                                         "b", &varIter);
        dbus_message_iter_append_basic(&varIter, DBUS_TYPE_BOOLEAN, &val);
        dbus_message_iter_close_container(&replyIter, &varIter);

    } else if (strcmp(propName, "ProtocolVersion") == 0) {
        dbus_int32_t val = 0;
        dbus_message_iter_open_container(&replyIter, DBUS_TYPE_VARIANT,
                                         "i", &varIter);
        dbus_message_iter_append_basic(&varIter, DBUS_TYPE_INT32, &val);
        dbus_message_iter_close_container(&replyIter, &varIter);

    } else if (strcmp(propName, "RegisteredStatusNotifierItems") == 0) {
        /* Return the list of registered bus names on the main queue snapshot.
         * We can't easily reach the ObjC _items array from this queue safely,
         * so return an empty array; clients use the signals for live tracking. */
        DBusMessageIter arrIter;
        dbus_message_iter_open_container(&replyIter, DBUS_TYPE_VARIANT,
                                         "as", &varIter);
        dbus_message_iter_open_container(&varIter, DBUS_TYPE_ARRAY,
                                         "s", &arrIter);
        dbus_message_iter_close_container(&varIter, &arrIter);
        dbus_message_iter_close_container(&replyIter, &varIter);
    } else {
        dbus_message_unref(reply);
        reply = dbus_message_new_error(msg, DBUS_ERROR_UNKNOWN_PROPERTY,
                                       "Unknown property");
    }

    dbus_connection_send(conn, reply, NULL);
    dbus_message_unref(reply);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Signal helpers

- (void)_emitSignal:(const char *)signalName
{
    if (!_conn) return;
    DBusMessage *sig = dbus_message_new_signal(kWatcherPath,
                                               kWatcherInterface,
                                               signalName);
    if (!sig) return;
    dbus_connection_send(_conn, sig, NULL);
    dbus_connection_flush(_conn);
    dbus_message_unref(sig);
}

- (void)_emitSignal:(const char *)signalName withString:(const char *)str
{
    if (!_conn || !str) return;
    DBusMessage *sig = dbus_message_new_signal(kWatcherPath,
                                               kWatcherInterface,
                                               signalName);
    if (!sig) return;
    dbus_message_append_args(sig, DBUS_TYPE_STRING, &str, DBUS_TYPE_INVALID);
    dbus_connection_send(_conn, sig, NULL);
    dbus_connection_flush(_conn);
    dbus_message_unref(sig);
}

/* ---------------------------------------------------------------------- */
#pragma mark - TrayItemDelegate

- (void)trayItemDidUpdate:(TrayItem *)item
{
    /* Already called on main queue by TrayItem */
    [_delegate trayManagerDidUpdateItems:self];
}

@end
