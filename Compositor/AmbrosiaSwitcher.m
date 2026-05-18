#import "AmbrosiaSwitcher.h"
#import "AmbrosiaCompositor.h"
#import "AmbrosiaWindowView.h"

#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/util/log.h>

#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <cairo/cairo.h>

#ifndef DRM_FORMAT_ARGB8888
#define DRM_FORMAT_ARGB8888 0x34325241
#endif

/* --------------------------------------------------------------------------
 * Layout constants
 * -------------------------------------------------------------------------- */

#define SW_ICON_SIZE     64      /* rendered icon width/height (px)            */
#define SW_SEL_PAD        8      /* padding inside selection rect on each side  */
#define SW_SLOT          (SW_ICON_SIZE + SW_SEL_PAD * 2)  /* = 80 px           */
#define SW_SLOT_GAP      12      /* horizontal gap between adjacent slots       */
#define SW_H_PAD         20      /* left/right panel padding                    */
#define SW_TOP_PAD       16      /* top panel padding                           */
#define SW_LABEL_GAP      8      /* gap from bottom of slot area to label rect  */
#define SW_LABEL_H       26      /* label background height                     */
#define SW_BOT_PAD       14      /* bottom panel padding                        */
#define SW_PANEL_R       10.0    /* panel corner radius                         */
#define SW_SEL_R          4.0    /* selection highlight corner radius           */
#define SW_LABEL_R        6.0    /* label background corner radius              */
#define SW_FONT_SIZE     12.0    /* label font size (pt)                        */

/* --------------------------------------------------------------------------
 * SHM pixel buffer (premultiplied ARGB8888, same pattern as AmbrosiaDecoration)
 * -------------------------------------------------------------------------- */

struct sw_shm_buf {
    struct wlr_buffer  base;
    int                fd;
    void              *data;
    size_t             size;
    int                width;
    int                height;
    size_t             stride;
};

static void sw_buf_destroy(struct wlr_buffer *b)
{
    struct sw_shm_buf *sb = wl_container_of(b, sb, base);
    munmap(sb->data, sb->size);
    close(sb->fd);
    free(sb);
}

static bool sw_buf_get_shm(struct wlr_buffer *b, struct wlr_shm_attributes *a)
{
    struct sw_shm_buf *sb = wl_container_of(b, sb, base);
    a->fd     = sb->fd;
    a->format = DRM_FORMAT_ARGB8888;
    a->width  = sb->width;
    a->height = sb->height;
    a->stride = (int)sb->stride;
    a->offset = 0;
    return true;
}

static bool sw_buf_begin_access(struct wlr_buffer *b, uint32_t flags,
                                 void **data, uint32_t *fmt, size_t *stride)
{
    struct sw_shm_buf *sb = wl_container_of(b, sb, base);
    (void)flags;
    *data   = sb->data;
    *fmt    = DRM_FORMAT_ARGB8888;
    *stride = sb->stride;
    return true;
}

static void sw_buf_end_access(struct wlr_buffer *b) { (void)b; }

static const struct wlr_buffer_impl kSwBufImpl = {
    .destroy               = sw_buf_destroy,
    .get_shm               = sw_buf_get_shm,
    .begin_data_ptr_access = sw_buf_begin_access,
    .end_data_ptr_access   = sw_buf_end_access,
};

static struct sw_shm_buf *sw_shm_buf_create(int w, int h)
{
    struct sw_shm_buf *sb = calloc(1, sizeof(*sb));
    if (!sb) return NULL;
    sb->width  = w;
    sb->height = h;
    sb->stride = (size_t)w * 4;
    sb->size   = sb->stride * (size_t)h;

#ifdef __NR_memfd_create
    sb->fd = (int)syscall(__NR_memfd_create, "ambrosia-sw", 1u /* MFD_CLOEXEC */);
#else
    sb->fd = -1;
#endif
    if (sb->fd < 0) {
        char name[64];
        snprintf(name, sizeof(name), "/ambrosia-sw-%d", (int)getpid());
        sb->fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (sb->fd >= 0) shm_unlink(name);
    }
    if (sb->fd < 0) { free(sb); return NULL; }
    if (ftruncate(sb->fd, (off_t)sb->size) < 0) { close(sb->fd); free(sb); return NULL; }
    sb->data = mmap(NULL, sb->size, PROT_READ | PROT_WRITE, MAP_SHARED, sb->fd, 0);
    if (sb->data == MAP_FAILED) { close(sb->fd); free(sb); return NULL; }
    wlr_buffer_init(&sb->base, &kSwBufImpl, w, h);
    return sb;
}

/* --------------------------------------------------------------------------
 * Icon lookup: Freedesktop themes, GNUstep bundles, and pixmaps.
 *
 * Only PNG paths are returned because Cairo renders icon surfaces via
 * cairo_image_surface_create_from_png.
 * -------------------------------------------------------------------------- */

/* Strip a reverse-DNS prefix to get the bare app name.
 * "org.gnustep.TextEdit" → "TextEdit"
 * "com.foo.MyApp"        → "MyApp"
 * "TextEdit"             → "TextEdit"   (unchanged, fewer than 3 components)
 */
static NSString *sw_bare_name(NSString *identifier)
{
    NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
    return (parts.count >= 3) ? parts.lastObject : identifier;
}

/* Return the path of <appName>.app in the standard GNUstep / system application
 * directories, or nil if no matching bundle is found.
 */
static NSString *sw_gnustep_bundle(NSString *appName)
{
    NSArray<NSString *> *dirs = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"GNUstep/Applications"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"],
        @"/usr/GNUstep/Local/Applications",
        @"/usr/GNUstep/System/Applications",
        @"/usr/local/GNUstep/Local/Applications",
        @"/Applications",
    ];
    NSFileManager *fm      = [NSFileManager defaultManager];
    NSString      *bundle  = [appName stringByAppendingPathExtension:@"app"];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:bundle];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir)
            return path;
    }
    return nil;
}

/* Find a PNG icon inside a GNUstep .app bundle's Resources directory.
 * Reads NSIcon (or CFBundleIconFile) from Info-gnustep.plist to get the
 * declared icon filename, then checks for a .png sibling.
 * Falls back to <appName>.png directly in Resources.
 * Returns nil when only non-PNG icons (e.g. TIFF) are present.
 */
static NSString *sw_bundle_png(NSString *bundlePath, NSString *appName)
{
    NSFileManager *fm  = [NSFileManager defaultManager];
    NSString      *res = [bundlePath stringByAppendingPathComponent:@"Resources"];

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [res stringByAppendingPathComponent:@"Info-gnustep.plist"]];
    NSString *iconFile = info[@"NSIcon"] ?: info[@"CFBundleIconFile"];

    if (iconFile.length) {
        NSString *p = [[res stringByAppendingPathComponent:[iconFile stringByDeletingPathExtension]]
                       stringByAppendingPathExtension:@"png"];
        if ([fm fileExistsAtPath:p]) return p;
    }

    NSString *p = [[res stringByAppendingPathComponent:appName]
                   stringByAppendingPathExtension:@"png"];
    return [fm fileExistsAtPath:p] ? p : nil;
}

/* Search all installed icon themes for <iconName>.png.
 * hicolor is tried first (the standard Freedesktop fallback theme), then every
 * other theme directory found under the base icon path so that the user's
 * active system theme is also searched.
 */
static NSString *sw_theme_find_png(NSString *iconName)
{
    static const int kSizes[] = { 256, 128, 96, 64, 48, 32, 0 };
    NSArray<NSString *> *cats = @[@"apps", @"devices", @"mimetypes"];
    NSArray<NSString *> *baseDirs = @[
        [@"~/.local/share/icons" stringByExpandingTildeInPath],
        @"/usr/share/icons",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *base in baseDirs) {
        NSMutableArray<NSString *> *themes = [NSMutableArray arrayWithObject:@"hicolor"];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:base error:nil]) {
            if ([entry isEqualToString:@"hicolor"]) continue;
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:[base stringByAppendingPathComponent:entry]
                         isDirectory:&isDir] && isDir)
                [themes addObject:entry];
        }
        for (NSString *theme in themes) {
            NSString *themeDir = [base stringByAppendingPathComponent:theme];
            for (int i = 0; kSizes[i]; i++) {
                NSString *size = [NSString stringWithFormat:@"%dx%d", kSizes[i], kSizes[i]];
                for (NSString *cat in cats) {
                    NSString *p = [[[[themeDir stringByAppendingPathComponent:size]
                                     stringByAppendingPathComponent:cat]
                                    stringByAppendingPathComponent:iconName]
                                   stringByAppendingPathExtension:@"png"];
                    if ([fm fileExistsAtPath:p]) return p;
                }
            }
        }
    }
    return nil;
}

/* Resolve the best PNG icon path for a window identifier (XDG app_id or X11 class).
 *
 * Resolution order (highest priority first):
 *   1. Theme PNG for the bare app name — strips reverse-DNS prefix so that
 *      "org.gnustep.TextEdit" searches themes for "TextEdit".  This is the
 *      system-theme override path.
 *   2. Theme PNG for the full identifier.
 *   3. PNG inside the matching GNUstep .app bundle (Info-gnustep.plist / Resources).
 *   4. /usr/share/pixmaps PNG fallback.
 */
static NSString *sw_find_icon(NSString *name)
{
    if (!name.length) return nil;
    if ([name hasPrefix:@"/"]) {
        return [[NSFileManager defaultManager] fileExistsAtPath:name] ? name : nil;
    }

    /* Strip any trailing extension embedded in a raw icon name field. */
    NSString *base = name;
    for (NSString *ext in @[@".png", @".svg", @".xpm"]) {
        if ([base hasSuffix:ext]) { base = [base substringToIndex:base.length - ext.length]; break; }
    }

    NSString *bareName    = sw_bare_name(base);
    BOOL      hasDNSPrefix = ![bareName isEqualToString:base];

    /* 1. Theme — bare app name (highest priority: system theme override). */
    if (hasDNSPrefix) {
        NSString *p = sw_theme_find_png(bareName);
        if (p) return p;
    }

    /* 2. Theme — full identifier. */
    {
        NSString *p = sw_theme_find_png(base);
        if (p) return p;
    }

    /* 3. GNUstep bundle PNG (try bare name first, then full base if different). */
    for (NSString *candidate in (hasDNSPrefix ? @[bareName, base] : @[base])) {
        NSString *bundlePath = sw_gnustep_bundle(candidate);
        if (bundlePath) {
            NSString *p = sw_bundle_png(bundlePath, candidate);
            if (p) return p;
        }
    }

    /* 4. /usr/share/pixmaps PNG. */
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *candidate in @[
            [[@"/usr/share/pixmaps/" stringByAppendingString:base]
             stringByAppendingPathExtension:@"png"],
            [@"/usr/share/pixmaps/" stringByAppendingString:name]]) {
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }

    return nil;
}

/* --------------------------------------------------------------------------
 * Cairo helpers
 * -------------------------------------------------------------------------- */

static void sw_rounded_rect(cairo_t *cr, double x, double y,
                             double w, double h, double r)
{
    if (r < 0.5) { cairo_rectangle(cr, x, y, w, h); return; }
    cairo_new_path(cr);
    cairo_move_to(cr, x + r, y);
    cairo_line_to(cr, x + w - r, y);
    cairo_arc(cr, x + w - r, y + r,     r, -M_PI_2,  0);
    cairo_line_to(cr, x + w, y + h - r);
    cairo_arc(cr, x + w - r, y + h - r, r,  0,       M_PI_2);
    cairo_line_to(cr, x + r, y + h);
    cairo_arc(cr, x + r,     y + h - r, r,  M_PI_2,  M_PI);
    cairo_line_to(cr, x, y + r);
    cairo_arc(cr, x + r,     y + r,     r,  M_PI,   -M_PI_2);
    cairo_close_path(cr);
}

/* --------------------------------------------------------------------------
 * Per-entry data snapshot (taken when the panel is first shown)
 * -------------------------------------------------------------------------- */

@interface _SWEntry : NSObject
@property (nonatomic, weak)   id<AmbrosiaWindowView> view;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *iconPath;
@end
@implementation _SWEntry @end

/* --------------------------------------------------------------------------
 * AmbrosiaSwitcher
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaSwitcher {
    AmbrosiaCompositor          *_compositor;
    NSMutableArray<_SWEntry *>  *_entries;
    NSInteger                    _selectedIndex;
    BOOL                         _visible;
    struct wlr_scene_tree       *_sceneTree;   /* child of scene_layer_overlay */
    struct wlr_scene_buffer     *_sceneBuf;
    /* Icon surface cache: persists across panel open/close cycles.
     * Key = absolute icon path (NSString), value = NSValue wrapping cairo_surface_t *.
     * Surfaces are freed in dealloc. */
    NSMutableDictionary<NSString *, NSValue *> *_iconCache;
}

@synthesize isVisible = _visible;

- (void)dealloc
{
    for (NSValue *v in [_iconCache allValues])
        cairo_surface_destroy((cairo_surface_t *)[v pointerValue]);
}

- (instancetype)initWithCompositor:(AmbrosiaCompositor *)compositor
{
    self = [super init];
    if (!self) return nil;
    _compositor    = compositor;
    _entries       = [NSMutableArray array];
    _selectedIndex = 0;
    _visible       = NO;

    _sceneTree = wlr_scene_tree_create(compositor.state->scene_layer_overlay);
    wlr_scene_node_set_enabled(&_sceneTree->node, false);
    _sceneBuf  = wlr_scene_buffer_create(_sceneTree, NULL);
    wlr_scene_node_set_position(&_sceneBuf->node, 0, 0);
    return self;
}

/* ---------------------------------------------------------------------- */
#pragma mark - App list

- (NSUInteger)_buildEntries
{
    [_entries removeAllObjects];

    /* Ordered set of PIDs, preserving z-order (topmost = last in _views). */
    NSMutableOrderedSet<NSNumber *> *pidOrder = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSNumber *, id<AmbrosiaWindowView>> *topmost =
        [NSMutableDictionary dictionary];

    for (id<AmbrosiaWindowView> v in _compositor.views) {
        if (!v.isMapped || v.isMiniaturized || v.isMenu) continue;
        pid_t pid = [v clientPid];
        if (pid <= 0) continue;
        NSNumber *key = @(pid);
        [pidOrder addObject:key];
        topmost[key] = v;   /* later entries = higher in z-order */
    }

    if (!_iconCache)
        _iconCache = [NSMutableDictionary dictionary];

    for (NSNumber *key in pidOrder) {
        id<AmbrosiaWindowView> v = topmost[key];
        if (!v) continue;
        NSString *iconPath = sw_find_icon([v iconIdentifier]);

        /* Load icon the first time it is seen; reuse cached surface thereafter. */
        if (iconPath && !_iconCache[iconPath]) {
            cairo_surface_t *surf =
                cairo_image_surface_create_from_png([iconPath UTF8String]);
            _iconCache[iconPath] = [NSValue valueWithPointer:surf];
        }

        _SWEntry *e = [[_SWEntry alloc] init];
        e.view     = v;
        e.name     = [v displayName];
        e.iconPath = iconPath;
        [_entries addObject:e];
    }
    return _entries.count;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Screen geometry

- (void)_screenWidth:(int *)outW height:(int *)outH
{
    struct wlr_output *out =
        wlr_output_layout_get_center_output(_compositor.state->output_layout);
    if (out) {
        struct wlr_box ob = {0};
        wlr_output_layout_get_box(_compositor.state->output_layout, out, &ob);
        *outW = ob.width;
        *outH = ob.height;
    } else {
        *outW = 1280;
        *outH = 720;
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Rendering

- (void)_render
{
    NSUInteger N = _entries.count;
    if (N == 0) return;

    int screenW, screenH;
    [self _screenWidth:&screenW height:&screenH];

    /* Panel dimensions */
    int panelW = SW_H_PAD * 2
               + (int)N * SW_SLOT
               + ((int)N - 1) * SW_SLOT_GAP;
    int panelH = SW_TOP_PAD + SW_SLOT + SW_LABEL_GAP + SW_LABEL_H + SW_BOT_PAD;

    /* Clamp panel width to screen */
    int maxW = screenW - 40;
    if (panelW > maxW) panelW = maxW;

    struct sw_shm_buf *buf = sw_shm_buf_create(panelW, panelH);
    if (!buf) {
        wlr_log(WLR_ERROR, "switcher: failed to create shm buffer");
        return;
    }

    cairo_surface_t *surf = cairo_image_surface_create_for_data(
        (unsigned char *)buf->data,
        CAIRO_FORMAT_ARGB32, panelW, panelH, (int)buf->stride);
    cairo_t *cr = cairo_create(surf);

    /* Clear to transparent */
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo_paint(cr);

    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    /* Panel background — black, 90 % opaque, rounded corners */
    sw_rounded_rect(cr, 0, 0, panelW, panelH, SW_PANEL_R);
    cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.90);
    cairo_fill(cr);

    /* Per-slot rendering */
    for (NSUInteger i = 0; i < N; i++) {
        _SWEntry *entry = _entries[i];
        double slotX = SW_H_PAD + (double)i * (SW_SLOT + SW_SLOT_GAP);
        double slotY = SW_TOP_PAD;

        /* Selection highlight — black rounded rect at 90 % opacity */
        if ((NSInteger)i == _selectedIndex) {
            sw_rounded_rect(cr, slotX, slotY, SW_SLOT, SW_SLOT, SW_SEL_R);
            cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.90);
            cairo_fill(cr);
        }

        double iconX = slotX + SW_SEL_PAD;
        double iconY = slotY + SW_SEL_PAD;

        /* Icon at 100 % opacity — surface looked up from persistent cache. */
        cairo_surface_t *icon = nil;
        if (entry.iconPath) {
            NSValue *cached = _iconCache[entry.iconPath];
            if (cached) icon = (cairo_surface_t *)[cached pointerValue];
        }

        if (icon && cairo_surface_status(icon) == CAIRO_STATUS_SUCCESS) {
            int iw = cairo_image_surface_get_width(icon);
            int ih = cairo_image_surface_get_height(icon);
            if (iw > 0 && ih > 0) {
                double scale = (iw >= ih)
                    ? (double)SW_ICON_SIZE / iw
                    : (double)SW_ICON_SIZE / ih;
                double ox = iconX + (SW_ICON_SIZE - iw * scale) * 0.5;
                double oy = iconY + (SW_ICON_SIZE - ih * scale) * 0.5;
                cairo_save(cr);
                /* Clip to the icon destination rect so cairo_paint only visits
                 * SW_ICON_SIZE² pixels instead of the entire panel buffer. */
                cairo_rectangle(cr, iconX, iconY, SW_ICON_SIZE, SW_ICON_SIZE);
                cairo_clip(cr);
                cairo_translate(cr, ox, oy);
                cairo_scale(cr, scale, scale);
                cairo_set_source_surface(cr, icon, 0, 0);
                cairo_paint(cr);
                cairo_restore(cr);
            }
        } else {
            /* Placeholder: hue-varied rounded square + first letter */
            double hue = (N > 1) ? (double)i / (double)(N - 1) : 0.5;
            sw_rounded_rect(cr, iconX, iconY, SW_ICON_SIZE, SW_ICON_SIZE, 8);
            cairo_set_source_rgba(cr, 0.25 + 0.45 * hue, 0.35, 0.80 - 0.30 * hue, 1.0);
            cairo_fill(cr);

            NSString *letter = entry.name.length
                ? [[entry.name substringToIndex:1] uppercaseString] : @"?";
            cairo_select_font_face(cr, "Sans",
                CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
            cairo_set_font_size(cr, 28.0);
            cairo_text_extents_t ext;
            cairo_text_extents(cr, [letter UTF8String], &ext);
            double tx = iconX + (SW_ICON_SIZE - ext.width) * 0.5 - ext.x_bearing;
            double ty = iconY + (SW_ICON_SIZE + ext.height) * 0.5 - ext.y_bearing
                        - ext.height;
            cairo_set_source_rgba(cr, 1, 1, 1, 1);
            cairo_move_to(cr, tx, ty);
            cairo_show_text(cr, [letter UTF8String]);
        }

    }

    /* Label background and text — only for the selected entry */
    if (_selectedIndex >= 0 && _selectedIndex < (NSInteger)N) {
        _SWEntry *sel = _entries[(NSUInteger)_selectedIndex];

        /* Label rect: fixed width centred under the selection slot,
         * clamped so it stays inside the panel. */
        double slotX = SW_H_PAD + (double)_selectedIndex * (SW_SLOT + SW_SLOT_GAP);
        double lblW  = MAX(SW_SLOT + 24.0, 120.0);
        double lblX  = slotX + (SW_SLOT - lblW) * 0.5;
        lblX = MAX(SW_H_PAD * 0.5, MIN(lblX, panelW - SW_H_PAD * 0.5 - lblW));
        double lblY  = SW_TOP_PAD + SW_SLOT + SW_LABEL_GAP;

        /* Label background — dark, 80 % opaque */
        sw_rounded_rect(cr, lblX, lblY, lblW, SW_LABEL_H, SW_LABEL_R);
        cairo_set_source_rgba(cr, 0.12, 0.12, 0.12, 0.80);
        cairo_fill(cr);

        /* Label text */
        cairo_select_font_face(cr, "Sans",
            CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, SW_FONT_SIZE);

        NSString *labelText = sel.name ?: @"";
        cairo_text_extents_t ext;
        /* Truncate to fit inside label background.
         * Always remove from the base text (no ellipsis) so the length strictly
         * decreases each iteration — appending "…" to the result and re-stripping
         * it on the next pass would otherwise produce the same string forever. */
        cairo_text_extents(cr, [labelText UTF8String], &ext);
        if (ext.width > lblW - 12.0) {
            while (labelText.length > 1) {
                labelText = [labelText substringToIndex:labelText.length - 1];
                NSString *candidate = [labelText stringByAppendingString:@"…"];
                cairo_text_extents(cr, [candidate UTF8String], &ext);
                if (ext.width <= lblW - 12.0) {
                    labelText = candidate;
                    break;
                }
            }
            cairo_text_extents(cr, [labelText UTF8String], &ext);
        }
        double tx = lblX + (lblW - ext.width) * 0.5 - ext.x_bearing;
        double ty = lblY + (SW_LABEL_H - ext.height) * 0.5 - ext.y_bearing;
        cairo_set_source_rgba(cr, 1, 1, 1, 1);
        cairo_move_to(cr, tx, ty);
        cairo_show_text(cr, [labelText UTF8String]);
    }

    cairo_destroy(cr);
    cairo_surface_destroy(surf);

    /* Upload buffer and position the panel centred on screen */
    wlr_scene_buffer_set_buffer(_sceneBuf, &buf->base);
    wlr_buffer_drop(&buf->base);

    int px = (screenW - panelW) / 2;
    int py = (screenH - panelH) / 2;
    wlr_scene_node_set_position(&_sceneTree->node, px, py);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Public API

- (void)advanceBy:(int)delta
{
    if (!_visible) {
        /* First invocation: snapshot app list and open the panel */
        if ([self _buildEntries] < 2) return;

        /* Pre-select index 1 (forward) or last (backward), wrapping */
        NSInteger count = (NSInteger)_entries.count;
        _selectedIndex = (delta > 0) ? 1 : count - 1;
        _visible = YES;
        wlr_scene_node_set_enabled(&_sceneTree->node, true);
    } else {
        NSInteger count = (NSInteger)_entries.count;
        _selectedIndex = ((_selectedIndex + delta) % count + count) % count;
    }
    [self _render];
}

- (void)confirm
{
    if (!_visible) return;
    _visible = NO;
    wlr_scene_node_set_enabled(&_sceneTree->node, false);

    if (_selectedIndex >= 0 && _selectedIndex < (NSInteger)_entries.count) {
        id<AmbrosiaWindowView> target = _entries[(NSUInteger)_selectedIndex].view;
        /* Weak ref may have zeroed if the window closed while switcher was open */
        if (target && target.isMapped)
            [_compositor focusView:target surface:nil];
    }

    [_entries removeAllObjects];
    _selectedIndex = 0;
}

- (void)cancel
{
    if (!_visible) return;
    _visible = NO;
    wlr_scene_node_set_enabled(&_sceneTree->node, false);
    [_entries removeAllObjects];
    _selectedIndex = 0;
}

@end
