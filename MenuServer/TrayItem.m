#import "TrayItem.h"
#import <dbus/dbus.h>
#import "MenuServerProtocol.h"
#include <time.h>

/* SNI interface and object path */
static const char * const kSNIInterface  = "org.kde.StatusNotifierItem";
static const char * const kSNIObjectPath = "/StatusNotifierItem";

/* Properties we fetch from the SNI interface */
static const char * const kPropIconName   = "IconName";
static const char * const kPropIconPixmap = "IconPixmap";
static const char * const kPropTitle      = "Title";
static const char * const kPropMenu       = "Menu";

/* com.canonical.dbusmenu constants */
static const char * const kDBusMenuIface       = "com.canonical.dbusmenu";
static const char * const kDBusMenuGetLayout   = "GetLayout";
static const char * const kDBusMenuEvent       = "Event";
static const char * const kDBusMenuAboutToShow = "AboutToShow";

/* Private descriptor keys carrying routing info in each menu item dict */
static NSString * const kTrayMenuBusName = @"_trayBusName";
static NSString * const kTrayMenuPath    = @"_trayMenuPath";
static NSString * const kTrayMenuItemId  = @"_dbusMenuId";

/* XDG icon size preference order for bar icons */
static NSArray<NSString *> *IconSizes(void)
{
    return @[@"22x22", @"16x16", @"24x24", @"32x32", @"scalable"];
}

/* XDG subdirectory categories to search */
static NSArray<NSString *> *IconCategories(void)
{
    return @[@"apps", @"status", @"devices", @"mimetypes", @"places"];
}

/* Locate a PNG by icon name in the hicolor theme and /usr/share/pixmaps. */
static NSString *FindIconPath(NSString *iconName)
{
    if (!iconName.length) return nil;

    /* Absolute path given directly */
    if ([iconName hasPrefix:@"/"]) {
        return [[NSFileManager defaultManager] fileExistsAtPath:iconName]
               ? iconName : nil;
    }

    NSArray<NSString *> *bases = @[
        @"/usr/share/icons/hicolor",
        @"/usr/share/icons/Adwaita",
        @"/usr/share/icons/gnome",
        @"/usr/share/icons/oxygen",
    ];
    NSArray<NSString *> *sizes = IconSizes();
    NSArray<NSString *> *cats  = IconCategories();
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *base in bases) {
        for (NSString *size in sizes) {
            for (NSString *cat in cats) {
                for (NSString *ext in @[@"png", @"xpm"]) {
                    NSString *path = [NSString stringWithFormat:
                        @"%@/%@/%@/%@.%@", base, size, cat, iconName, ext];
                    if ([fm fileExistsAtPath:path]) return path;
                }
            }
        }
    }

    /* pixmaps fallback */
    for (NSString *ext in @[@"png", @"xpm", @"svg"]) {
        NSString *path = [NSString stringWithFormat:
            @"/usr/share/pixmaps/%@.%@", iconName, ext];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

/* Build an NSImage from an SNI IconPixmap property value.
 *
 * D-Bus type: a(iiay)
 *   Each struct: (int32 width, int32 height, array<byte> ARGB data)
 * We pick the largest struct whose dimensions fit a reasonable icon size. */
static NSImage *ImageFromIconPixmapIter(DBusMessageIter *arrayIter)
{
    if (!arrayIter) return nil;

    int      bestW    = 0, bestH = 0;
    NSData  *bestData = nil;

    DBusMessageIter structIter;
    while (dbus_message_iter_get_arg_type(arrayIter) == DBUS_TYPE_STRUCT) {
        dbus_message_iter_recurse(arrayIter, &structIter);

        int w = 0, h = 0;
        if (dbus_message_iter_get_arg_type(&structIter) == DBUS_TYPE_INT32) {
            dbus_message_iter_get_basic(&structIter, &w);
            dbus_message_iter_next(&structIter);
        }
        if (dbus_message_iter_get_arg_type(&structIter) == DBUS_TYPE_INT32) {
            dbus_message_iter_get_basic(&structIter, &h);
            dbus_message_iter_next(&structIter);
        }

        if (w > 0 && h > 0 &&
            dbus_message_iter_get_arg_type(&structIter) == DBUS_TYPE_ARRAY) {

            DBusMessageIter bytesIter;
            dbus_message_iter_recurse(&structIter, &bytesIter);
            const uint8_t *rawBytes = NULL;
            int            nBytes   = 0;
            dbus_message_iter_get_fixed_array(&bytesIter,
                                              (const void **)&rawBytes,
                                              &nBytes);
            if (rawBytes && nBytes == w * h * 4) {
                /* Choose this pixmap if it is ≤ 48 px and larger than current best. */
                if ((w <= 48 || bestW == 0) && w * h > bestW * bestH) {
                    bestW    = w;
                    bestH    = h;
                    /* Convert ARGB (network byte order) → RGBA for NSBitmapImageRep */
                    NSMutableData *rgba = [NSMutableData dataWithLength:(NSUInteger)nBytes];
                    uint8_t *dst = (uint8_t *)rgba.mutableBytes;
                    for (int i = 0; i < w * h; i++) {
                        uint8_t a = rawBytes[i * 4 + 0];
                        uint8_t r = rawBytes[i * 4 + 1];
                        uint8_t g = rawBytes[i * 4 + 2];
                        uint8_t b = rawBytes[i * 4 + 3];
                        dst[i * 4 + 0] = r;
                        dst[i * 4 + 1] = g;
                        dst[i * 4 + 2] = b;
                        dst[i * 4 + 3] = a;
                    }
                    /* SNI data is top-to-bottom; NSBitmapImageRep (GNUstep/Cairo)
                       expects bottom-to-top, so flip rows vertically. */
                    NSMutableData *flipped = [NSMutableData dataWithLength:(NSUInteger)nBytes];
                    uint8_t *fdst = (uint8_t *)flipped.mutableBytes;
                    for (int row = 0; row < h; row++) {
                        memcpy(fdst + row * w * 4,
                               dst  + (h - 1 - row) * w * 4,
                               (size_t)(w * 4));
                    }
                    bestData = [flipped copy];
                }
            }
        }
        dbus_message_iter_next(arrayIter);
    }

    if (!bestData) return nil;

    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:bestW
                          pixelsHigh:bestH
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSCalibratedRGBColorSpace
                         bytesPerRow:bestW * 4
                        bitsPerPixel:32];
    if (!rep) return nil;
    memcpy([rep bitmapData], bestData.bytes, bestData.length);

    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(bestW, bestH)];
    [img addRepresentation:rep];
    return img;
}

/* ---------------------------------------------------------------------- */

@implementation TrayItem {
    NSString *_busName;
    NSString *_objectPath;
    NSImage  *_icon;
    NSString *_title;
    NSString *_menuPath;   /* com.canonical.dbusmenu object path, or nil */
}

@synthesize busName    = _busName;
@synthesize objectPath = _objectPath;
@synthesize icon       = _icon;
@synthesize title      = _title;
@synthesize menuPath   = _menuPath;
@synthesize delegate   = _delegate;

- (instancetype)initWithBusName:(NSString *)busName
                     objectPath:(NSString *)objectPath
{
    self = [super init];
    if (!self) return nil;
    _busName    = [busName copy];
    _objectPath = objectPath.length ? [objectPath copy]
                                    : @(kSNIObjectPath);
    _title      = @"";
    return self;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Property fetching

- (void)fetchPropertiesWithConnection:(void *)dbusConn
{
    DBusConnection *conn = (DBusConnection *)dbusConn;
    if (!conn) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self _fetchAllWithConnection:conn];
    });
}

- (void)_fetchAllWithConnection:(DBusConnection *)conn
{
    NSImage  *newIcon  = nil;
    NSString *newTitle = @"";

    /* ---- Fetch IconPixmap ---- */
    {
        DBusMessage *msg = dbus_message_new_method_call(
            self->_busName.UTF8String,
            self->_objectPath.UTF8String,
            "org.freedesktop.DBus.Properties",
            "Get");
        if (msg) {
            const char *iface = kSNIInterface;
            const char *prop  = kPropIconPixmap;
            dbus_message_append_args(msg,
                DBUS_TYPE_STRING, &iface,
                DBUS_TYPE_STRING, &prop,
                DBUS_TYPE_INVALID);

            DBusError err;
            dbus_error_init(&err);
            DBusMessage *reply = dbus_connection_send_with_reply_and_block(
                conn, msg, 2000, &err);
            dbus_message_unref(msg);

            if (reply && !dbus_error_is_set(&err)) {
                DBusMessageIter topIter;
                if (dbus_message_iter_init(reply, &topIter) &&
                    dbus_message_iter_get_arg_type(&topIter) == DBUS_TYPE_VARIANT) {
                    DBusMessageIter varIter;
                    dbus_message_iter_recurse(&topIter, &varIter);
                    if (dbus_message_iter_get_arg_type(&varIter) == DBUS_TYPE_ARRAY) {
                        DBusMessageIter arrIter;
                        dbus_message_iter_recurse(&varIter, &arrIter);
                        newIcon = ImageFromIconPixmapIter(&arrIter);
                    }
                }
                dbus_message_unref(reply);
            }
            if (dbus_error_is_set(&err)) dbus_error_free(&err);
        }
    }

    /* ---- Fetch IconName (fallback) ---- */
    if (!newIcon) {
        DBusMessage *msg = dbus_message_new_method_call(
            self->_busName.UTF8String,
            self->_objectPath.UTF8String,
            "org.freedesktop.DBus.Properties",
            "Get");
        if (msg) {
            const char *iface = kSNIInterface;
            const char *prop  = kPropIconName;
            dbus_message_append_args(msg,
                DBUS_TYPE_STRING, &iface,
                DBUS_TYPE_STRING, &prop,
                DBUS_TYPE_INVALID);

            DBusError err;
            dbus_error_init(&err);
            DBusMessage *reply = dbus_connection_send_with_reply_and_block(
                conn, msg, 2000, &err);
            dbus_message_unref(msg);

            if (reply && !dbus_error_is_set(&err)) {
                DBusMessageIter topIter;
                if (dbus_message_iter_init(reply, &topIter) &&
                    dbus_message_iter_get_arg_type(&topIter) == DBUS_TYPE_VARIANT) {
                    DBusMessageIter varIter;
                    dbus_message_iter_recurse(&topIter, &varIter);
                    if (dbus_message_iter_get_arg_type(&varIter) == DBUS_TYPE_STRING) {
                        const char *iconName = NULL;
                        dbus_message_iter_get_basic(&varIter, &iconName);
                        if (iconName && *iconName) {
                            NSString *name = @(iconName);
                            NSString *path = FindIconPath(name);
                            if (path) {
                                newIcon = [[NSImage alloc] initWithContentsOfFile:path];
                            }
                        }
                    }
                }
                dbus_message_unref(reply);
            }
            if (dbus_error_is_set(&err)) dbus_error_free(&err);
        }
    }

    /* ---- Fetch Title ---- */
    {
        DBusMessage *msg = dbus_message_new_method_call(
            self->_busName.UTF8String,
            self->_objectPath.UTF8String,
            "org.freedesktop.DBus.Properties",
            "Get");
        if (msg) {
            const char *iface = kSNIInterface;
            const char *prop  = kPropTitle;
            dbus_message_append_args(msg,
                DBUS_TYPE_STRING, &iface,
                DBUS_TYPE_STRING, &prop,
                DBUS_TYPE_INVALID);

            DBusError err;
            dbus_error_init(&err);
            DBusMessage *reply = dbus_connection_send_with_reply_and_block(
                conn, msg, 2000, &err);
            dbus_message_unref(msg);

            if (reply && !dbus_error_is_set(&err)) {
                DBusMessageIter topIter;
                if (dbus_message_iter_init(reply, &topIter) &&
                    dbus_message_iter_get_arg_type(&topIter) == DBUS_TYPE_VARIANT) {
                    DBusMessageIter varIter;
                    dbus_message_iter_recurse(&topIter, &varIter);
                    if (dbus_message_iter_get_arg_type(&varIter) == DBUS_TYPE_STRING) {
                        const char *t = NULL;
                        dbus_message_iter_get_basic(&varIter, &t);
                        if (t && *t) newTitle = @(t);
                    }
                }
                dbus_message_unref(reply);
            }
            if (dbus_error_is_set(&err)) dbus_error_free(&err);
        }
    }

    /* ---- Fetch Menu (dbusmenu object path, type 'o') ---- */
    NSString *newMenuPath = nil;
    {
        DBusMessage *msg = dbus_message_new_method_call(
            self->_busName.UTF8String,
            self->_objectPath.UTF8String,
            "org.freedesktop.DBus.Properties",
            "Get");
        if (msg) {
            const char *iface = kSNIInterface;
            const char *prop  = kPropMenu;
            dbus_message_append_args(msg,
                DBUS_TYPE_STRING, &iface,
                DBUS_TYPE_STRING, &prop,
                DBUS_TYPE_INVALID);

            DBusError err;
            dbus_error_init(&err);
            DBusMessage *reply = dbus_connection_send_with_reply_and_block(
                conn, msg, 2000, &err);
            dbus_message_unref(msg);

            if (reply && !dbus_error_is_set(&err)) {
                DBusMessageIter topIter;
                if (dbus_message_iter_init(reply, &topIter) &&
                    dbus_message_iter_get_arg_type(&topIter) == DBUS_TYPE_VARIANT) {
                    DBusMessageIter varIter;
                    dbus_message_iter_recurse(&topIter, &varIter);
                    if (dbus_message_iter_get_arg_type(&varIter) == DBUS_TYPE_OBJECT_PATH) {
                        const char *path = NULL;
                        dbus_message_iter_get_basic(&varIter, &path);
                        if (path && *path && strcmp(path, "/") != 0)
                            newMenuPath = @(path);
                    }
                }
                dbus_message_unref(reply);
            }
            if (dbus_error_is_set(&err)) dbus_error_free(&err);
        }
    }

    NSImage  *capturedIcon     = newIcon;
    NSString *capturedTitle    = newTitle;
    NSString *capturedMenuPath = newMenuPath;

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_icon     = capturedIcon;
        self->_title    = capturedTitle;
        self->_menuPath = capturedMenuPath;
        [self->_delegate trayItemDidUpdate:self];
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - dbusmenu layout parsing (C helpers)

/*
 * Strip GTK mnemonic underscores from a dbusmenu label.
 * Rule: "__" → "_" (literal underscore), single "_" → removed.
 */
static NSString *StripMnemonic(const char *raw)
{
    if (!raw || !*raw) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:strlen(raw)];
    for (const char *p = raw; *p; p++) {
        if (*p == '_') {
            if (*(p + 1) == '_') {
                [out appendString:@"_"];
                p++;           /* skip second underscore */
            }
            /* else: skip the mnemonic underscore */
        } else {
            [out appendFormat:@"%c", *p];
        }
    }
    return [out copy];
}

/*
 * Read a single a{sv} property dict from a D-Bus iterator that points to
 * an ARRAY of DICT_ENTRY.  Returns a dictionary with string keys and
 * NSString / NSNumber values for the types we care about.
 */
static NSDictionary *ReadPropertiesDict(DBusMessageIter *arrIter)
{
    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    while (dbus_message_iter_get_arg_type(arrIter) == DBUS_TYPE_DICT_ENTRY) {
        DBusMessageIter entryIter;
        dbus_message_iter_recurse(arrIter, &entryIter);

        const char *key = NULL;
        if (dbus_message_iter_get_arg_type(&entryIter) == DBUS_TYPE_STRING)
            dbus_message_iter_get_basic(&entryIter, &key);
        dbus_message_iter_next(&entryIter);

        if (key && dbus_message_iter_get_arg_type(&entryIter) == DBUS_TYPE_VARIANT) {
            DBusMessageIter varIter;
            dbus_message_iter_recurse(&entryIter, &varIter);
            int vt = dbus_message_iter_get_arg_type(&varIter);

            if (vt == DBUS_TYPE_STRING || vt == DBUS_TYPE_OBJECT_PATH) {
                const char *val = NULL;
                dbus_message_iter_get_basic(&varIter, &val);
                if (val) props[@(key)] = @(val);
            } else if (vt == DBUS_TYPE_BOOLEAN) {
                dbus_bool_t val = FALSE;
                dbus_message_iter_get_basic(&varIter, &val);
                props[@(key)] = @(val ? YES : NO);
            } else if (vt == DBUS_TYPE_INT32) {
                dbus_int32_t val = 0;
                dbus_message_iter_get_basic(&varIter, &val);
                props[@(key)] = @(val);
            } else if (vt == DBUS_TYPE_UINT32) {
                dbus_uint32_t val = 0;
                dbus_message_iter_get_basic(&varIter, &val);
                props[@(key)] = @(val);
            }
        }
        dbus_message_iter_next(arrIter);
    }
    return [props copy];
}

/*
 * Recursively parse one dbusmenu layout node.
 *
 * The iterator must point to a STRUCT of type (i, a{sv}, av):
 *   i      = item id
 *   a{sv}  = properties dict
 *   av     = children (each variant wraps another (i, a{sv}, av) struct)
 *
 * isRoot: when YES the node is the invisible root container (id=0); return
 *         its children directly without wrapping them in a descriptor.
 */
static NSArray *ParseDBusMenuNode(DBusMessageIter *nodeIter,
                                  NSString *busName,
                                  NSString *menuPath,
                                  BOOL isRoot)
{
    if (dbus_message_iter_get_arg_type(nodeIter) != DBUS_TYPE_STRUCT)
        return @[];

    DBusMessageIter si;
    dbus_message_iter_recurse(nodeIter, &si);

    /* id */
    dbus_int32_t itemId = 0;
    if (dbus_message_iter_get_arg_type(&si) == DBUS_TYPE_INT32) {
        dbus_message_iter_get_basic(&si, &itemId);
        dbus_message_iter_next(&si);
    }

    /* properties a{sv} */
    NSDictionary *props = @{};
    if (dbus_message_iter_get_arg_type(&si) == DBUS_TYPE_ARRAY) {
        DBusMessageIter dictIter;
        dbus_message_iter_recurse(&si, &dictIter);
        props = ReadPropertiesDict(&dictIter);
        dbus_message_iter_next(&si);
    }

    /* children av */
    NSMutableArray *children = [NSMutableArray array];
    if (dbus_message_iter_get_arg_type(&si) == DBUS_TYPE_ARRAY) {
        DBusMessageIter childArr;
        dbus_message_iter_recurse(&si, &childArr);
        while (dbus_message_iter_get_arg_type(&childArr) == DBUS_TYPE_VARIANT) {
            DBusMessageIter childVar;
            dbus_message_iter_recurse(&childArr, &childVar);
            NSArray *sub = ParseDBusMenuNode(&childVar, busName, menuPath, NO);
            [children addObjectsFromArray:sub];
            dbus_message_iter_next(&childArr);
        }
    }

    /* Root node (id=0) is just a container — return its children directly */
    if (isRoot) return [children copy];

    /* Separator */
    NSString *type  = props[@"type"];
    NSString *label = props[@"label"];
    if ([type isEqualToString:@"separator"] || (!label.length && !type.length)) {
        return @[@{
            kMenuItemSeparator: @YES,
            kTrayMenuBusName:   busName,
            kTrayMenuPath:      menuPath,
            kTrayMenuItemId:    @(itemId),
        }];
    }

    /* Hidden items */
    NSNumber *visible = props[@"visible"];
    if (visible && ![visible boolValue]) return @[];

    /* Regular item */
    NSNumber *enabled  = props[@"enabled"];
    NSString *cleanLbl = StripMnemonic(label.UTF8String);

    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[kMenuItemTitle]   = cleanLbl.length ? cleanLbl : @"";
    item[kMenuItemEnabled] = enabled ? enabled : @YES;
    item[kTrayMenuBusName] = busName;
    item[kTrayMenuPath]    = menuPath;
    item[kTrayMenuItemId]  = @(itemId);

    if (children.count > 0)
        item[kMenuItemChildren] = [children copy];

    return @[[item copy]];
}

/* ---------------------------------------------------------------------- */
#pragma mark - dbusmenu fetch + activation (public)

- (void)fetchMenuItemsWithConnection:(void *)dbusConn
                           dbusQueue:(dispatch_queue_t)dbusQueue
                          completion:(void (^)(NSArray<NSDictionary *> *))completion
{
    NSString *menuPath = _menuPath;
    if (!menuPath.length || !dbusConn || !dbusQueue) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
        return;
    }

    NSString *busName  = _busName;
    NSString *objPath  = menuPath;

    /* Dispatch to dbusQueue — the same serial queue the TrayManager's timer
     * runs on.  Because the queue is serial, this block and the timer handler
     * cannot execute concurrently, so send_with_reply_and_block cannot race
     * with dbus_connection_read_write / dispatch.                           */
    dispatch_async(dbusQueue, ^{
        DBusConnection *conn = (DBusConnection *)dbusConn;
        NSArray *result      = @[];

        /* ---- AboutToShow(0) ---- courtesy call; ignore errors */
        {
            DBusMessage *msg = dbus_message_new_method_call(
                busName.UTF8String, objPath.UTF8String,
                kDBusMenuIface, kDBusMenuAboutToShow);
            if (msg) {
                dbus_int32_t rootId = 0;
                dbus_message_append_args(msg,
                    DBUS_TYPE_INT32, &rootId, DBUS_TYPE_INVALID);
                DBusError err; dbus_error_init(&err);
                DBusMessage *reply =
                    dbus_connection_send_with_reply_and_block(conn, msg, 1000, &err);
                dbus_message_unref(msg);
                if (reply)   dbus_message_unref(reply);
                if (dbus_error_is_set(&err)) dbus_error_free(&err);
            }
        }

        /* ---- GetLayout(parentId=0, depth=-1, propertyNames=[]) ---- */
        {
            DBusMessage *msg = dbus_message_new_method_call(
                busName.UTF8String, objPath.UTF8String,
                kDBusMenuIface, kDBusMenuGetLayout);
            if (msg) {
                DBusMessageIter mi, ai;
                dbus_message_iter_init_append(msg, &mi);
                dbus_int32_t parentId = 0, depth = -1;
                dbus_message_iter_append_basic(&mi, DBUS_TYPE_INT32, &parentId);
                dbus_message_iter_append_basic(&mi, DBUS_TYPE_INT32, &depth);
                /* Empty string array for propertyNames (fetch all) */
                dbus_message_iter_open_container(&mi, DBUS_TYPE_ARRAY, "s", &ai);
                dbus_message_iter_close_container(&mi, &ai);

                DBusError err; dbus_error_init(&err);
                DBusMessage *reply =
                    dbus_connection_send_with_reply_and_block(conn, msg, 3000, &err);
                dbus_message_unref(msg);

                if (reply && !dbus_error_is_set(&err)) {
                    DBusMessageIter ri;
                    if (dbus_message_iter_init(reply, &ri)) {
                        /* Skip revision (uint32) */
                        if (dbus_message_iter_get_arg_type(&ri) == DBUS_TYPE_UINT32)
                            dbus_message_iter_next(&ri);

                        /* Parse root layout node (struct) */
                        if (dbus_message_iter_get_arg_type(&ri) == DBUS_TYPE_STRUCT) {
                            result = ParseDBusMenuNode(&ri, busName, objPath, YES);
                        }
                    }
                    dbus_message_unref(reply);
                }
                if (dbus_error_is_set(&err)) dbus_error_free(&err);
            }
        }

        NSArray *captured = result;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(captured); });
    });
}

- (void)triggerMenuItemId:(int32_t)itemId
               connection:(void *)dbusConn
                dbusQueue:(dispatch_queue_t)dbusQueue
{
    NSString *menuPath = _menuPath;
    if (!menuPath.length || !dbusConn || !dbusQueue) return;

    NSString *busName = _busName;
    NSString *objPath = menuPath;
    int32_t   mid     = itemId;

    dispatch_async(dbusQueue, ^{
        DBusConnection *conn = (DBusConnection *)dbusConn;
        DBusMessage *msg = dbus_message_new_method_call(
            busName.UTF8String, objPath.UTF8String,
            kDBusMenuIface, kDBusMenuEvent);
        if (!msg) return;

        const char      *eventId = "clicked";
        dbus_uint32_t    ts      = (dbus_uint32_t)time(NULL);
        dbus_int32_t     dataVal = 0;

        DBusMessageIter mi, vi;
        dbus_message_iter_init_append(msg, &mi);
        dbus_message_iter_append_basic(&mi, DBUS_TYPE_INT32,  &mid);
        dbus_message_iter_append_basic(&mi, DBUS_TYPE_STRING, &eventId);
        /* data variant: i = 0 */
        dbus_message_iter_open_container(&mi, DBUS_TYPE_VARIANT, "i", &vi);
        dbus_message_iter_append_basic(&vi, DBUS_TYPE_INT32, &dataVal);
        dbus_message_iter_close_container(&mi, &vi);
        dbus_message_iter_append_basic(&mi, DBUS_TYPE_UINT32, &ts);

        dbus_connection_send(conn, msg, NULL);
        dbus_connection_flush(conn);
        dbus_message_unref(msg);
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Activate / ContextMenu

- (void)activateAtX:(int)x y:(int)y connection:(void *)dbusConn
{
    [self _callMethod:"Activate" x:x y:y connection:dbusConn];
}

- (void)contextMenuAtX:(int)x y:(int)y connection:(void *)dbusConn
{
    [self _callMethod:"ContextMenu" x:x y:y connection:dbusConn];
}

- (void)_callMethod:(const char *)method x:(int)x y:(int)y
         connection:(void *)dbusConn
{
    DBusConnection *conn = (DBusConnection *)dbusConn;
    if (!conn) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        DBusMessage *msg = dbus_message_new_method_call(
            self->_busName.UTF8String,
            self->_objectPath.UTF8String,
            kSNIInterface,
            method);
        if (!msg) return;
        dbus_message_append_args(msg,
            DBUS_TYPE_INT32, &x,
            DBUS_TYPE_INT32, &y,
            DBUS_TYPE_INVALID);
        dbus_connection_send(conn, msg, NULL);
        dbus_connection_flush(conn);
        dbus_message_unref(msg);
    });
}

@end
