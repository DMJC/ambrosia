#import "AmbrosiaBackground.h"

#include <wlr/util/log.h>
#include <wlr/interfaces/wlr_buffer.h>  /* wlr_buffer_impl, wlr_buffer_init — unstable interface */

#include <cairo/cairo.h>
#include <jpeglib.h>

#include <drm/drm_fourcc.h>   /* DRM_FORMAT_ARGB8888 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <setjmp.h>

/* -------------------------------------------------------------------------
 * Supported image-file extensions
 * ---------------------------------------------------------------------- */

static BOOL ext_is_png(const char *path)
{
    const char *e = strrchr(path, '.');
    return e && strcasecmp(e, ".png") == 0;
}

static BOOL ext_is_jpeg(const char *path)
{
    const char *e = strrchr(path, '.');
    return e && (strcasecmp(e, ".jpg") == 0 || strcasecmp(e, ".jpeg") == 0);
}

/* -------------------------------------------------------------------------
 * Image loading — returns a Cairo ARGB32 surface scaled to (out_w × out_h)
 * using "cover" scaling (fills the frame, crops edges if aspect differs).
 * Returns NULL on error; caller owns the surface.
 * ---------------------------------------------------------------------- */

/* Scale a source surface to cover out_w × out_h, centred. */
static cairo_surface_t *cover_scale(cairo_surface_t *src, int src_w, int src_h,
                                    int out_w, int out_h)
{
    cairo_surface_t *dst =
        cairo_image_surface_create(CAIRO_FORMAT_ARGB32, out_w, out_h);
    if (cairo_surface_status(dst) != CAIRO_STATUS_SUCCESS) return dst;

    cairo_t *cr = cairo_create(dst);
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);

    double sx    = (double)out_w / src_w;
    double sy    = (double)out_h / src_h;
    double scale = sx > sy ? sx : sy;
    double ox    = (out_w - src_w * scale) / 2.0;
    double oy    = (out_h - src_h * scale) / 2.0;

    cairo_translate(cr, ox, oy);
    cairo_scale(cr, scale, scale);
    cairo_set_source_surface(cr, src, 0, 0);
    cairo_paint(cr);
    cairo_destroy(cr);
    return dst;
}

/* PNG loading via Cairo's built-in libpng wrapper. */
static cairo_surface_t *load_png(const char *path, int out_w, int out_h)
{
    cairo_surface_t *src = cairo_image_surface_create_from_png(path);
    if (cairo_surface_status(src) != CAIRO_STATUS_SUCCESS) {
        wlr_log(WLR_ERROR, "background: failed to load PNG '%s'", path);
        cairo_surface_destroy(src);
        return NULL;
    }
    int src_w = cairo_image_surface_get_width(src);
    int src_h = cairo_image_surface_get_height(src);
    cairo_surface_t *dst = cover_scale(src, src_w, src_h, out_w, out_h);
    cairo_surface_destroy(src);
    return dst;
}

/* libjpeg error manager that jumps instead of calling exit(). */
struct ambrosia_jpeg_err {
    struct jpeg_error_mgr mgr;
    jmp_buf               jmp;
};
static void jpeg_error_exit_cb(j_common_ptr cinfo)
{
    struct ambrosia_jpeg_err *e = (struct ambrosia_jpeg_err *)cinfo->err;
    longjmp(e->jmp, 1);
}

/* JPEG loading via libjpeg-turbo / libjpeg. */
static cairo_surface_t *load_jpeg(const char *path, int out_w, int out_h)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        wlr_log(WLR_ERROR, "background: cannot open JPEG '%s'", path);
        return NULL;
    }

    struct jpeg_decompress_struct cinfo;
    struct ambrosia_jpeg_err      jerr;
    cinfo.err = jpeg_std_error(&jerr.mgr);
    jerr.mgr.error_exit = jpeg_error_exit_cb;

    if (setjmp(jerr.jmp)) {
        jpeg_destroy_decompress(&cinfo);
        fclose(f);
        wlr_log(WLR_ERROR, "background: failed to decode JPEG '%s'", path);
        return NULL;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_stdio_src(&cinfo, f);
    jpeg_read_header(&cinfo, TRUE);
    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);

    int src_w = (int)cinfo.output_width;
    int src_h = (int)cinfo.output_height;

    /* Read into a Cairo ARGB32 surface (BGRX byte order in memory). */
    cairo_surface_t *src =
        cairo_image_surface_create(CAIRO_FORMAT_ARGB32, src_w, src_h);
    cairo_surface_flush(src);
    uint8_t *sd     = cairo_image_surface_get_data(src);
    int      stride = cairo_image_surface_get_stride(src);

    JSAMPLE *row = (JSAMPLE *)malloc((size_t)src_w * 3);
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW rp = row;
        jpeg_read_scanlines(&cinfo, &rp, 1);
        uint8_t *dst_row = sd + (int)(cinfo.output_scanline - 1) * stride;
        for (int x = 0; x < src_w; x++) {
            /* Cairo ARGB32 in memory on LE: B G R A at bytes 0 1 2 3 */
            dst_row[x * 4 + 0] = row[x * 3 + 2]; /* B */
            dst_row[x * 4 + 1] = row[x * 3 + 1]; /* G */
            dst_row[x * 4 + 2] = row[x * 3 + 0]; /* R */
            dst_row[x * 4 + 3] = 0xFF;            /* A */
        }
    }
    free(row);
    cairo_surface_mark_dirty(src);

    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    fclose(f);

    cairo_surface_t *dst = cover_scale(src, src_w, src_h, out_w, out_h);
    cairo_surface_destroy(src);
    return dst;
}

/* Dispatcher: choose loader by extension. */
static cairo_surface_t *load_image(const char *path, int out_w, int out_h)
{
    if (ext_is_png(path))  return load_png(path,  out_w, out_h);
    if (ext_is_jpeg(path)) return load_jpeg(path, out_w, out_h);
    wlr_log(WLR_ERROR, "background: unsupported image format '%s'", path);
    return NULL;
}

/* -------------------------------------------------------------------------
 * wlr_buffer implementation backed by a Cairo image surface.
 *
 * wlr_buffer_impl / wlr_buffer_init live in <wlr/interfaces/wlr_buffer.h>
 * (the wlroots unstable interface header) and require -DWLR_USE_UNSTABLE.
 *
 * The scene calls wlr_buffer_lock on the buffer when it takes ownership;
 * after passing it to wlr_scene_buffer_create / wlr_scene_buffer_set_buffer
 * the caller must call wlr_buffer_drop to release their own reference.
 * When the scene is done the refcount hits zero and bg_buf_destroy fires.
 * ---------------------------------------------------------------------- */

struct ambrosia_bg_buffer {
    struct wlr_buffer  base;
    cairo_surface_t   *surface;
};

static void bg_buf_destroy(struct wlr_buffer *buf)
{
    struct ambrosia_bg_buffer *b = wl_container_of(buf, b, base);
    cairo_surface_destroy(b->surface);
    free(b);
}

static bool bg_buf_begin_ptr(struct wlr_buffer *buf, uint32_t flags,
                              void **data, uint32_t *fmt, size_t *stride)
{
    struct ambrosia_bg_buffer *b = wl_container_of(buf, b, base);
    cairo_surface_flush(b->surface);
    *data   = cairo_image_surface_get_data(b->surface);
    *fmt    = DRM_FORMAT_ARGB8888;
    *stride = (size_t)cairo_image_surface_get_stride(b->surface);
    return true;
}

static void bg_buf_end_ptr(struct wlr_buffer *buf)
{
    struct ambrosia_bg_buffer *b = wl_container_of(buf, b, base);
    cairo_surface_mark_dirty(b->surface);
}

static const struct wlr_buffer_impl bg_buf_impl = {
    .destroy               = bg_buf_destroy,
    .begin_data_ptr_access = bg_buf_begin_ptr,
    .end_data_ptr_access   = bg_buf_end_ptr,
};

/* Takes ownership of surface; returns NULL on allocation failure. */
static struct ambrosia_bg_buffer *bg_buf_create(cairo_surface_t *surface)
{
    struct ambrosia_bg_buffer *b = calloc(1, sizeof(*b));
    if (!b) { cairo_surface_destroy(surface); return NULL; }
    b->surface = surface;
    int w = cairo_image_surface_get_width(surface);
    int h = cairo_image_surface_get_height(surface);
    wlr_buffer_init(&b->base, &bg_buf_impl, w, h);
    return b;
}

/* -------------------------------------------------------------------------
 * Rotation timer trampoline
 * ---------------------------------------------------------------------- */

struct ambrosia_bg_timer {
    struct wl_event_source *source;
    void                   *bg;  /* __bridge AmbrosiaBackground* */
};

static int bg_timer_cb(void *data);   /* forward */

/* -------------------------------------------------------------------------
 * Per-output background record (ObjC, managed by ARC for its own fields)
 * ---------------------------------------------------------------------- */

@interface _ABGOutput : NSObject
@property (nonatomic) struct wlr_output       *output;
@property (nonatomic) struct wlr_scene_buffer *node;    /* NULL until first image */
@end
@implementation _ABGOutput
@end

/* -------------------------------------------------------------------------
 * AmbrosiaBackground
 * ---------------------------------------------------------------------- */

static NSString *const kDesktopPlistName = @"org.gnustep.AmbrosiaDesktop.plist";

@implementation AmbrosiaBackground {
    struct wl_event_loop      *_loop;
    struct wlr_scene_tree     *_bgTree;
    struct wlr_output_layout  *_layout;

    NSMutableArray<_ABGOutput *> *_outputs;

    /* Current preferences */
    NSString  *_imagePath;       /* single wallpaper path */
    BOOL       _rotating;
    NSString  *_folderPath;
    NSInteger  _intervalSecs;    /* 5/10/30/60/300/600 */

    /* Rotation state */
    NSMutableArray<NSString *> *_imageFiles;  /* sorted paths inside folder */
    NSInteger                   _fileIndex;

    /* Rotation timer */
    struct ambrosia_bg_timer   *_timer;       /* NULL when idle */
}

- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop
                        sceneTree:(struct wlr_scene_tree *)bgTree
                     outputLayout:(struct wlr_output_layout *)layout
{
    self = [super init];
    if (!self) return nil;
    _loop    = loop;
    _bgTree  = bgTree;
    _layout  = layout;
    _outputs = [NSMutableArray array];
    _intervalSecs = 30;
    return self;
}

- (void)dealloc { [self stop]; }

/* ---------------------------------------------------------------------- */
#pragma mark - Public interface

- (void)applyPreferencesFromPlist
{
    NSString *prefsDir;
    const char *userLib = getenv("GNUSTEP_USER_LIBRARY");
    if (userLib && userLib[0]) {
        prefsDir = [[[NSString stringWithUTF8String:userLib]
                     stringByAppendingPathComponent:@"Preferences"] copy];
    } else {
        prefsDir = [NSHomeDirectory()
                    stringByAppendingPathComponent:@"GNUstep/Library/Preferences"];
    }
    NSString *path = [prefsDir stringByAppendingPathComponent:kDesktopPlistName];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path] ?: @{};
    [self applyPreferences:prefs];
}

- (void)applyPreferences:(NSDictionary *)prefs
{
    _imagePath    = [prefs[@"backgroundImagePath"] copy];
    _rotating     = [prefs[@"rotatingImages"] boolValue];
    _folderPath   = [prefs[@"rotatingImagesFolder"] copy];
    _intervalSecs = [prefs[@"rotationInterval"] integerValue];
    if (_intervalSecs <= 0) _intervalSecs = 30;

    [self _stopTimer];

    if (_rotating && _folderPath.length) {
        [self _scanFolder];
        _fileIndex = 0;
    }

    [self _refreshAllOutputs];

    if (_rotating && _imageFiles.count > 1) {
        [self _startTimer];
    }
}

- (void)handleOutputAdded:(struct wlr_output *)output
{
    _ABGOutput *rec = [[_ABGOutput alloc] init];
    rec.output = output;
    rec.node   = NULL;
    [_outputs addObject:rec];
    [self _applyCurrentImageToOutput:rec];
}

- (void)handleOutputRemoved:(struct wlr_output *)output
{
    for (NSUInteger i = 0; i < _outputs.count; i++) {
        _ABGOutput *rec = _outputs[i];
        if (rec.output != output) continue;
        if (rec.node) {
            wlr_scene_node_destroy(&rec.node->node);
            rec.node = NULL;
        }
        [_outputs removeObjectAtIndex:i];
        return;
    }
}

- (void)stop { [self _stopTimer]; }

/* ---------------------------------------------------------------------- */
#pragma mark - Private — folder scanning

- (void)_scanFolder
{
    _imageFiles = [NSMutableArray array];
    if (!_folderPath.length) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries  = [fm contentsOfDirectoryAtPath:_folderPath error:nil];
    for (NSString *name in entries) {
        const char *cname = name.UTF8String;
        if (!ext_is_png(cname) && !ext_is_jpeg(cname)) continue;
        [_imageFiles addObject:[_folderPath stringByAppendingPathComponent:name]];
    }
    [_imageFiles sortUsingSelector:@selector(compare:)];
    wlr_log(WLR_INFO, "background: found %lu image(s) in folder",
            (unsigned long)_imageFiles.count);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private — image application

- (NSString *)_currentImagePath
{
    if (_rotating && _imageFiles.count > 0)
        return _imageFiles[(NSUInteger)(_fileIndex % (NSInteger)_imageFiles.count)];
    return _imagePath;
}

- (void)_refreshAllOutputs
{
    for (_ABGOutput *rec in _outputs)
        [self _applyCurrentImageToOutput:rec];
}

- (void)_applyCurrentImageToOutput:(_ABGOutput *)rec
{
    NSString *path = [self _currentImagePath];
    if (!path.length) {
        if (rec.node)
            wlr_scene_node_set_enabled(&rec.node->node, false);
        return;
    }

    int out_w = rec.output->width;
    int out_h = rec.output->height;
    if (out_w <= 0 || out_h <= 0) return;

    cairo_surface_t *surf = load_image(path.UTF8String, out_w, out_h);
    if (!surf || cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
        if (surf) cairo_surface_destroy(surf);
        return;
    }

    /* bg_buf_create takes ownership of surf; it will be freed in bg_buf_destroy. */
    struct ambrosia_bg_buffer *buf = bg_buf_create(surf);
    if (!buf) return;

    struct wlr_box box = {0};
    wlr_output_layout_get_box(_layout, rec.output, &box);

    if (rec.node == NULL) {
        struct wlr_scene_buffer *sb = wlr_scene_buffer_create(_bgTree, &buf->base);
        wlr_scene_node_set_position(&sb->node, box.x, box.y);
        rec.node = sb;
    } else {
        wlr_scene_buffer_set_buffer(rec.node, &buf->base);
        wlr_scene_node_set_position(&rec.node->node, box.x, box.y);
        wlr_scene_node_set_enabled(&rec.node->node, true);
    }

    /* Drop our reference; the scene holds the buffer alive via wlr_buffer_lock. */
    wlr_buffer_drop(&buf->base);

    wlr_log(WLR_DEBUG, "background: applied '%s' to output %dx%d",
            path.UTF8String, out_w, out_h);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private — rotation timer

- (void)_startTimer
{
    if (_timer) [self _stopTimer];

    _timer = (struct ambrosia_bg_timer *)calloc(1, sizeof(*_timer));
    if (!_timer) return;

    _timer->bg     = (__bridge void *)self;
    _timer->source = wl_event_loop_add_timer(_loop, bg_timer_cb, _timer);
    wl_event_source_timer_update(_timer->source,
                                 (int)(_intervalSecs * 1000));
    wlr_log(WLR_INFO, "background: rotation timer started (%lds)", (long)_intervalSecs);
}

- (void)_stopTimer
{
    if (!_timer) return;
    if (_timer->source) {
        wl_event_source_remove(_timer->source);
        _timer->source = NULL;
    }
    free(_timer);
    _timer = NULL;
}

- (void)_rotationTimerFired
{
    if (!_imageFiles.count) return;
    _fileIndex = (_fileIndex + 1) % (NSInteger)_imageFiles.count;
    [self _refreshAllOutputs];

    /* Re-arm the timer for the next rotation. */
    if (_timer && _timer->source)
        wl_event_source_timer_update(_timer->source,
                                     (int)(_intervalSecs * 1000));
}

@end

/* -------------------------------------------------------------------------
 * Timer callback — called on the wl_event_loop thread.
 * ---------------------------------------------------------------------- */

static int bg_timer_cb(void *data)
{
    struct ambrosia_bg_timer *ctx = data;
    AmbrosiaBackground *bg = (__bridge AmbrosiaBackground *)ctx->bg;
    [bg _rotationTimerFired];
    return 0;
}
