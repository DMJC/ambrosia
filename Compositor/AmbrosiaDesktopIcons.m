#import "AmbrosiaDesktopIcons.h"

#include <wlr/util/log.h>
#include <wlr/interfaces/wlr_buffer.h>

#include <cairo/cairo.h>
#include <drm/drm_fourcc.h>

#include <sys/inotify.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

/* -------------------------------------------------------------------------
 * Layout constants
 * ---------------------------------------------------------------------- */

#define ICON_IMG_SIZE   64    /* rendered icon pixel width/height           */
#define ICON_CELL_W     80    /* cell width including side padding          */
#define ICON_CELL_H    100    /* 8px top + 64px icon + 4px gap + ~16px label + 8px bot */
#define ICON_GAP         8    /* gap between adjacent cells                 */
#define ICON_PAD_TOP    32    /* top margin (clears the menu bar)           */
#define ICON_PAD_RIGHT  16    /* right margin from screen edge              */
#define ICON_PAD_BOTTOM 72    /* bottom margin (clears the dock)            */
#define DBLCLICK_MS    400    /* double-click window in milliseconds        */

/* -------------------------------------------------------------------------
 * Parsed .desktop entry
 * ---------------------------------------------------------------------- */

@interface _DesktopEntry : NSObject
@property (copy) NSString *name;
@property (copy) NSString *exec;
@property (copy) NSString *iconPath;  /* resolved PNG path, or nil */
@end
@implementation _DesktopEntry @end

/* -------------------------------------------------------------------------
 * Per-icon scene state
 * ---------------------------------------------------------------------- */

@interface _IconNode : NSObject
@property (nonatomic) _DesktopEntry            *entry;
@property (nonatomic) int                       cellX;
@property (nonatomic) int                       cellY;
@property (nonatomic) struct wlr_scene_buffer  *sceneBuffer;
@property (nonatomic) uint32_t                  lastClickTime;
@end
@implementation _IconNode @end

/* -------------------------------------------------------------------------
 * wlr_buffer backed by a Cairo ARGB32 image surface
 * ---------------------------------------------------------------------- */

struct ambrosia_icon_buffer {
    struct wlr_buffer  base;
    cairo_surface_t   *surface;
};

static void icon_buf_destroy(struct wlr_buffer *buf)
{
    struct ambrosia_icon_buffer *b = wl_container_of(buf, b, base);
    cairo_surface_destroy(b->surface);
    free(b);
}

static bool icon_buf_begin_ptr(struct wlr_buffer *buf, uint32_t flags,
                               void **data, uint32_t *fmt, size_t *stride)
{
    (void)flags;
    struct ambrosia_icon_buffer *b = wl_container_of(buf, b, base);
    cairo_surface_flush(b->surface);
    *data   = cairo_image_surface_get_data(b->surface);
    *fmt    = DRM_FORMAT_ARGB8888;
    *stride = (size_t)cairo_image_surface_get_stride(b->surface);
    return true;
}

static void icon_buf_end_ptr(struct wlr_buffer *buf)
{
    struct ambrosia_icon_buffer *b = wl_container_of(buf, b, base);
    cairo_surface_mark_dirty(b->surface);
}

static const struct wlr_buffer_impl icon_buf_impl = {
    .destroy               = icon_buf_destroy,
    .begin_data_ptr_access = icon_buf_begin_ptr,
    .end_data_ptr_access   = icon_buf_end_ptr,
};

/* Takes ownership of surface; returns NULL on allocation failure. */
static struct ambrosia_icon_buffer *icon_buf_create(cairo_surface_t *surface)
{
    struct ambrosia_icon_buffer *b = calloc(1, sizeof(*b));
    if (!b) { cairo_surface_destroy(surface); return NULL; }
    b->surface = surface;
    int w = cairo_image_surface_get_width(surface);
    int h = cairo_image_surface_get_height(surface);
    wlr_buffer_init(&b->base, &icon_buf_impl, w, h);
    return b;
}

/* -------------------------------------------------------------------------
 * inotify context (heap-allocated, freed in -dealloc)
 * ---------------------------------------------------------------------- */

struct ambrosia_icon_inotify {
    struct wl_event_source *source;
    void                   *icons;  /* __bridge AmbrosiaDesktopIcons* */
};

static int icon_inotify_cb(int fd, uint32_t mask, void *data);  /* forward */

/* -------------------------------------------------------------------------
 * XDG icon theme lookup
 * ---------------------------------------------------------------------- */

static NSString *find_icon_png(NSString *name)
{
    if (!name.length) return nil;

    /* Absolute path */
    if ([name hasPrefix:@"/"]) {
        return ([[NSFileManager defaultManager] fileExistsAtPath:name]) ? name : nil;
    }

    /* Strip a trailing extension so we can add our own */
    NSString *base = name;
    for (NSString *ext in @[@".png", @".svg", @".xpm"]) {
        if ([base hasSuffix:ext]) {
            base = [base substringToIndex:base.length - ext.length];
            break;
        }
    }

    /* Search hicolor at decreasing sizes in user dir then system dir */
    static const int sizes[] = {256, 128, 96, 64, 48, 32, 0};
    NSArray<NSString *> *bases = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/share/icons/hicolor"],
        @"/usr/share/icons/hicolor",
    ];

    for (int i = 0; sizes[i]; i++) {
        NSString *sub = [NSString stringWithFormat:@"%dx%d/apps", sizes[i], sizes[i]];
        for (NSString *b in bases) {
            NSString *p = [[[b stringByAppendingPathComponent:sub]
                            stringByAppendingPathComponent:base]
                           stringByAppendingPathExtension:@"png"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
        }
    }

    /* Fallback: /usr/share/pixmaps */
    for (NSString *candidate in @[
            [[@"/usr/share/pixmaps/" stringByAppendingString:base]
             stringByAppendingPathExtension:@"png"],
            [@"/usr/share/pixmaps/" stringByAppendingString:name]]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    }

    return nil;
}

/* -------------------------------------------------------------------------
 * .desktop file parser
 * ---------------------------------------------------------------------- */

static NSString *strip_exec_field_codes(NSString *exec)
{
    NSMutableString *out = [NSMutableString stringWithCapacity:exec.length];
    const char *s = exec.UTF8String;
    while (s && *s) {
        if (*s == '%' && *(s + 1)) {
            s += 2;
        } else {
            char ch[2] = {*s++, '\0'};
            [out appendString:[NSString stringWithUTF8String:ch]];
        }
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static _DesktopEntry * _Nullable parse_desktop_file(NSString *path)
{
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (!content) return nil;

    BOOL inEntry = NO;
    NSString *name = nil, *exec = nil, *icon = nil, *type = nil;

    NSCharacterSet *nl = [NSCharacterSet newlineCharacterSet];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];

    for (NSString *rawLine in [content componentsSeparatedByCharactersInSet:nl]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:ws];

        if ([line hasPrefix:@"["]) {
            inEntry = [line isEqualToString:@"[Desktop Entry]"];
            continue;
        }
        if (!inEntry || !line.length || [line hasPrefix:@"#"]) continue;

        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;

        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        NSString *val = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];

        /* Prefer the plain (untranslated) key; localised keys look like Name[de]= */
        if ([key isEqualToString:@"Name"] && !name)  name = val;
        if ([key isEqualToString:@"Exec"])            exec = val;
        if ([key isEqualToString:@"Icon"])            icon = val;
        if ([key isEqualToString:@"Type"])            type = val;
    }

    if (![type isEqualToString:@"Application"] || !exec.length) return nil;

    _DesktopEntry *entry = [[_DesktopEntry alloc] init];
    entry.name     = name ?: [[path lastPathComponent] stringByDeletingPathExtension];
    entry.exec     = strip_exec_field_codes(exec);
    entry.iconPath = find_icon_png(icon);
    return entry;
}

/* -------------------------------------------------------------------------
 * Cairo rendering helpers
 * ---------------------------------------------------------------------- */

static void draw_rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r)
{
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + r,     y + r,     r, M_PI,       3 * M_PI / 2);
    cairo_arc(cr, x + w - r, y + r,     r, 3 * M_PI / 2, 2 * M_PI);
    cairo_arc(cr, x + w - r, y + h - r, r, 0,          M_PI / 2);
    cairo_arc(cr, x + r,     y + h - r, r, M_PI / 2,   M_PI);
    cairo_close_path(cr);
}

/* Load a PNG and scale it to ICON_IMG_SIZE × ICON_IMG_SIZE (preserving aspect). */
static cairo_surface_t *load_icon_image(NSString *path)
{
    if (!path) return NULL;
    cairo_surface_t *src = cairo_image_surface_create_from_png(path.UTF8String);
    if (cairo_surface_status(src) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(src);
        return NULL;
    }
    int iw = cairo_image_surface_get_width(src);
    int ih = cairo_image_surface_get_height(src);

    cairo_surface_t *dst = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                       ICON_IMG_SIZE, ICON_IMG_SIZE);
    cairo_t *cr = cairo_create(dst);
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    double scale = MIN((double)ICON_IMG_SIZE / iw, (double)ICON_IMG_SIZE / ih);
    double ox = (ICON_IMG_SIZE - iw * scale) / 2.0;
    double oy = (ICON_IMG_SIZE - ih * scale) / 2.0;
    cairo_translate(cr, ox, oy);
    cairo_scale(cr, scale, scale);
    cairo_set_source_surface(cr, src, 0, 0);
    cairo_paint(cr);

    cairo_destroy(cr);
    cairo_surface_destroy(src);
    return dst;
}

/* Shorten label with an ellipsis so it fits within max_width pixels. */
static NSString *fit_label(cairo_t *cr, NSString *label, double max_width)
{
    cairo_text_extents_t ext;
    cairo_text_extents(cr, label.UTF8String ?: "", &ext);
    if (ext.width <= max_width) return label;

    NSMutableString *s = [label mutableCopy];
    while (s.length > 1) {
        [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
        NSString *candidate = [s stringByAppendingString:@"\xe2\x80\xa6"]; /* … */
        cairo_text_extents(cr, candidate.UTF8String, &ext);
        if (ext.width <= max_width) return candidate;
    }
    return @"\xe2\x80\xa6";
}

/* Render one ICON_CELL_W × ICON_CELL_H tile for the given icon and label. */
static cairo_surface_t *render_icon_cell(cairo_surface_t *icon_surf, NSString *label)
{
    int W = ICON_CELL_W;
    int H = ICON_CELL_H;

    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, W, H);
    cairo_t *cr = cairo_create(surf);

    /* Transparent background */
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    /* Semi-transparent pill behind the icon image */
    cairo_set_source_rgba(cr, 0, 0, 0, 0.30);
    draw_rounded_rect(cr, 8, 4, W - 16, ICON_IMG_SIZE + 8, 8);
    cairo_fill(cr);

    /* Icon image centred in the pill */
    if (icon_surf && cairo_surface_status(icon_surf) == CAIRO_STATUS_SUCCESS) {
        cairo_save(cr);
        cairo_set_source_surface(cr, icon_surf,
                                 (W - ICON_IMG_SIZE) / 2.0, 8.0);
        cairo_paint(cr);
        cairo_restore(cr);
    }

    /* Label */
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 11.0);

    NSString *display = fit_label(cr, label, (double)(W - 8));
    cairo_text_extents_t ext;
    cairo_text_extents(cr, display.UTF8String ?: "", &ext);

    double tx = (W - ext.width) / 2.0 - ext.x_bearing;
    double ty = 8.0 + ICON_IMG_SIZE + 4.0 + ext.height;

    /* Drop shadow */
    cairo_set_source_rgba(cr, 0, 0, 0, 0.85);
    cairo_move_to(cr, tx + 1, ty + 1);
    cairo_show_text(cr, display.UTF8String ?: "");

    /* White text */
    cairo_set_source_rgba(cr, 1, 1, 1, 1.0);
    cairo_move_to(cr, tx, ty);
    cairo_show_text(cr, display.UTF8String ?: "");

    cairo_destroy(cr);
    return surf;
}

/* -------------------------------------------------------------------------
 * AmbrosiaDesktopIcons
 * ---------------------------------------------------------------------- */

@implementation AmbrosiaDesktopIcons {
    struct wl_event_loop      *_loop;
    struct wlr_scene_tree     *_iconTree;
    struct wlr_output_layout  *_layout;

    NSMutableArray<_DesktopEntry *> *_entries;
    NSMutableArray<_IconNode *>     *_nodes;

    /* Known outputs; _primaryOutput is where icons are placed. */
    struct wlr_output             *_primaryOutput;
    NSMutableArray                *_knownOutputs;  /* NSValue<wlr_output*> */

    /* inotify */
    int                             _inotifyFd;
    struct ambrosia_icon_inotify   *_inotifyCtx;
}

- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop
                        sceneTree:(struct wlr_scene_tree *)iconTree
                     outputLayout:(struct wlr_output_layout *)layout
{
    self = [super init];
    if (!self) return nil;
    _loop          = loop;
    _iconTree      = iconTree;
    _layout        = layout;
    _entries       = [NSMutableArray array];
    _nodes         = [NSMutableArray array];
    _knownOutputs  = [NSMutableArray array];
    _inotifyFd     = -1;
    _inotifyCtx    = NULL;

    [self _watchDesktopFolder];
    [self reload];
    return self;
}

- (void)dealloc
{
    [self _destroyAllNodes];

    if (_inotifyCtx) {
        if (_inotifyCtx->source)
            wl_event_source_remove(_inotifyCtx->source);
        free(_inotifyCtx);
        _inotifyCtx = NULL;
    }
    if (_inotifyFd >= 0) {
        close(_inotifyFd);
        _inotifyFd = -1;
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Public

- (void)reload
{
    [self _destroyAllNodes];
    [self _loadDesktopFiles];
    if (_primaryOutput)
        [self _layoutIcons];
}

- (BOOL)handleClickAtX:(double)x y:(double)y time:(uint32_t)time
{
    for (_IconNode *node in _nodes) {
        if (x < node.cellX || x >= node.cellX + ICON_CELL_W) continue;
        if (y < node.cellY || y >= node.cellY + ICON_CELL_H) continue;

        uint32_t elapsed = (node.lastClickTime > 0)
                         ? (time - node.lastClickTime)
                         : UINT32_MAX;
        node.lastClickTime = time;

        if (elapsed < DBLCLICK_MS) {
            [self _launchEntry:node.entry];
            node.lastClickTime = 0;  /* prevent triple-click re-launch */
        }
        return YES;
    }
    return NO;
}

- (void)handleOutputAdded:(struct wlr_output *)output
{
    [_knownOutputs addObject:[NSValue valueWithPointer:output]];
    if (!_primaryOutput) {
        _primaryOutput = output;
        [self _layoutIcons];
    }
}

- (void)handleOutputRemoved:(struct wlr_output *)output
{
    [_knownOutputs removeObject:[NSValue valueWithPointer:output]];
    if (_primaryOutput != output) return;

    [self _destroyAllNodes];
    _primaryOutput = _knownOutputs.count > 0
                   ? (struct wlr_output *)[[_knownOutputs firstObject] pointerValue]
                   : NULL;
    if (_primaryOutput)
        [self _layoutIcons];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private — inotify

- (void)_watchDesktopFolder
{
    _inotifyFd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (_inotifyFd < 0) {
        wlr_log(WLR_ERROR, "desktop-icons: inotify_init1 failed");
        return;
    }

    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    int wd = inotify_add_watch(_inotifyFd, dir.UTF8String,
                               IN_CREATE | IN_DELETE |
                               IN_MOVED_FROM | IN_MOVED_TO |
                               IN_CLOSE_WRITE);
    if (wd < 0) {
        wlr_log(WLR_ERROR, "desktop-icons: inotify_add_watch failed for '%s'",
                dir.UTF8String);
        close(_inotifyFd);
        _inotifyFd = -1;
        return;
    }

    _inotifyCtx = calloc(1, sizeof(*_inotifyCtx));
    if (!_inotifyCtx) return;
    _inotifyCtx->icons = (__bridge void *)self;
    _inotifyCtx->source = wl_event_loop_add_fd(_loop, _inotifyFd,
                                                WL_EVENT_READABLE,
                                                icon_inotify_cb, _inotifyCtx);
    if (!_inotifyCtx->source)
        wlr_log(WLR_ERROR, "desktop-icons: failed to add inotify fd to event loop");
}

- (void)_inotifyFired
{
    char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
    while (read(_inotifyFd, buf, sizeof(buf)) > 0) {}  /* drain */
    wlr_log(WLR_INFO, "desktop-icons: ~/Desktop changed, reloading");
    [self reload];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private — loading

- (void)_loadDesktopFiles
{
    [_entries removeAllObjects];

    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    NSArray<NSString *> *files =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];

    for (NSString *name in [files sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasSuffix:@".desktop"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        _DesktopEntry *entry = parse_desktop_file(path);
        if (entry) [_entries addObject:entry];
    }

    wlr_log(WLR_INFO, "desktop-icons: loaded %lu entries",
            (unsigned long)_entries.count);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private — layout & rendering

- (void)_layoutIcons
{
    if (!_primaryOutput || !_entries.count) return;

    struct wlr_box box = {0};
    wlr_output_layout_get_box(_layout, _primaryOutput, &box);

    /* Fill top-right → downward, wrapping left when a column is full. */
    int x   = box.x + box.width  - ICON_CELL_W - ICON_PAD_RIGHT;
    int y   = box.y + ICON_PAD_TOP;
    int maxY = box.y + box.height - ICON_PAD_BOTTOM;

    for (_DesktopEntry *entry in _entries) {
        if (y + ICON_CELL_H > maxY) {
            y  = box.y + ICON_PAD_TOP;
            x -= ICON_CELL_W + ICON_GAP;
            if (x < box.x) break;
        }

        _IconNode *node = [self _createNodeForEntry:entry atX:x y:y];
        if (node) [_nodes addObject:node];

        y += ICON_CELL_H + ICON_GAP;
    }
}

- (_IconNode * _Nullable)_createNodeForEntry:(_DesktopEntry *)entry atX:(int)x y:(int)y
{
    cairo_surface_t *iconSurf = NULL;
    if (entry.iconPath)
        iconSurf = load_icon_image(entry.iconPath);

    cairo_surface_t *cellSurf = render_icon_cell(iconSurf, entry.name);
    if (iconSurf) cairo_surface_destroy(iconSurf);

    if (!cellSurf || cairo_surface_status(cellSurf) != CAIRO_STATUS_SUCCESS) {
        if (cellSurf) cairo_surface_destroy(cellSurf);
        wlr_log(WLR_ERROR, "desktop-icons: failed to render cell for '%s'",
                entry.name.UTF8String);
        return nil;
    }

    struct ambrosia_icon_buffer *buf = icon_buf_create(cellSurf);
    if (!buf) return nil;

    struct wlr_scene_buffer *sb = wlr_scene_buffer_create(_iconTree, &buf->base);
    wlr_buffer_drop(&buf->base);
    if (!sb) return nil;

    wlr_scene_node_set_position(&sb->node, x, y);

    _IconNode *node     = [[_IconNode alloc] init];
    node.entry          = entry;
    node.cellX          = x;
    node.cellY          = y;
    node.sceneBuffer    = sb;
    node.lastClickTime  = 0;
    return node;
}

- (void)_destroyAllNodes
{
    for (_IconNode *node in _nodes) {
        if (node.sceneBuffer)
            wlr_scene_node_destroy(&node.sceneBuffer->node);
    }
    [_nodes removeAllObjects];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private — launch

- (void)_launchEntry:(_DesktopEntry *)entry
{
    if (!entry.exec.length) return;
    wlr_log(WLR_INFO, "desktop-icons: launching '%s': %s",
            entry.name.UTF8String, entry.exec.UTF8String);

    const char *cmd = entry.exec.UTF8String;
    pid_t pid = fork();
    if (pid < 0) {
        wlr_log(WLR_ERROR, "desktop-icons: fork failed for '%s'", entry.name.UTF8String);
        return;
    }
    if (pid == 0) {
        setsid();
        const char *args[] = {"/bin/sh", "-c", cmd, NULL};
        execvp("/bin/sh", (char *const *)args);
        _exit(1);
    }
    /* Parent does not wait; child is re-parented to init after the shell exits. */
}

@end

/* -------------------------------------------------------------------------
 * inotify C callback — called on the wl_event_loop thread
 * ---------------------------------------------------------------------- */

static int icon_inotify_cb(int fd, uint32_t mask, void *data)
{
    (void)fd;
    (void)mask;
    struct ambrosia_icon_inotify *ctx = data;
    AmbrosiaDesktopIcons *icons = (__bridge AmbrosiaDesktopIcons *)ctx->icons;
    [icons _inotifyFired];
    return 0;
}
