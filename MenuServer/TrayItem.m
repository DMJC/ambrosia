#import "TrayItem.h"
#import <dbus/dbus.h>

/* SNI interface and object path */
static const char * const kSNIInterface  = "org.kde.StatusNotifierItem";
static const char * const kSNIObjectPath = "/StatusNotifierItem";

/* Properties we fetch */
static const char * const kPropIconName   = "IconName";
static const char * const kPropIconPixmap = "IconPixmap";
static const char * const kPropTitle      = "Title";

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
}

@synthesize busName    = _busName;
@synthesize objectPath = _objectPath;
@synthesize icon       = _icon;
@synthesize title      = _title;
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

    NSImage  *capturedIcon  = newIcon;
    NSString *capturedTitle = newTitle;

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_icon  = capturedIcon;
        self->_title = capturedTitle;
        [self->_delegate trayItemDidUpdate:self];
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
