#import "AmbrosiaDecoration.h"

#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_scene.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <cairo/cairo.h>

#import <GNUstepGUI/GSTheme.h>

/* DRM_FORMAT_ARGB8888: little-endian 0xAARRGGBB */
#ifndef DRM_FORMAT_ARGB8888
#define DRM_FORMAT_ARGB8888 0x34325241
#endif

/* --------------------------------------------------------------------------
 * Cached theme metrics — loaded once from [GSTheme theme] and reloaded on
 * GSThemeDidActivateNotification.  All layout code reads these instead of
 * the old compile-time constants.
 * -------------------------------------------------------------------------- */

static int   _gTitlebarH   = 24;    /* [GSTheme titlebarHeight]       */
static int   _gBtnSize     = 15;    /* [GSTheme titlebarButtonSize]   */
static int   _gBtnPadLeft  = 10;    /* [GSTheme titlebarPaddingLeft]  */
static int   _gBtnPadRight = 10;    /* [GSTheme titlebarPaddingRight] */
static int   _gBtnPadTop   =  5;    /* [GSTheme titlebarPaddingTop]   */
static float _gCornerR     =  0.f;  /* GSThemeDomain GSWindowCornerRadius */

/* Cairo image surfaces loaded from the theme bundle (NULL = use fallback circles) */
static cairo_surface_t *_gCloseImg      = NULL;
static cairo_surface_t *_gMiniaturizeImg = NULL;

/* --------------------------------------------------------------------------
 * Default colour palette — derived from GNUstep system colors at load time;
 * overridden by ambrosia_gnustep_decoration_palette() in the compositor.
 * -------------------------------------------------------------------------- */

static const float kGradTopActive[4]    = { 1.000f, 1.000f, 1.000f, 1.0f };
static const float kGradBotActive[4]    = { 0.863f, 0.863f, 0.871f, 1.0f };
static const float kGradTopInactive[4]  = { 0.940f, 0.940f, 0.940f, 1.0f };
static const float kGradBotInactive[4]  = { 0.880f, 0.880f, 0.880f, 1.0f };
static const float kSeparatorColor[4]   = { 0.400f, 0.400f, 0.400f, 1.0f };
static const float kBorderStroke[4]     = { 0.400f, 0.400f, 0.400f, 1.0f };
static const float kBodyFill[4]         = { 0.863f, 0.863f, 0.863f, 1.0f };
static const float kBtnActive[4]        = { 0.850f, 0.850f, 0.850f, 1.0f };
static const float kBtnInactive[4]      = { 0.720f, 0.720f, 0.720f, 0.70f };

/* --------------------------------------------------------------------------
 * Shared-memory pixel buffer for the titlebar
 *
 * Backed by an anonymous memfd so both the Pixman and GLES2 renderers can
 * import the pixel data (GLES2 reads it via the fd through get_shm).
 * Uses premultiplied ARGB8888 to match wlroots' blend mode.
 * -------------------------------------------------------------------------- */

struct ambrosia_shm_buf {
    struct wlr_buffer base;
    int      fd;
    void    *data;
    size_t   size;
    int      width;
    int      height;
    size_t   stride;
};

static void shm_buf_destroy(struct wlr_buffer *b)
{
    struct ambrosia_shm_buf *sb = wl_container_of(b, sb, base);
    munmap(sb->data, sb->size);
    close(sb->fd);
    free(sb);
}

static bool shm_buf_get_shm(struct wlr_buffer *b, struct wlr_shm_attributes *a)
{
    struct ambrosia_shm_buf *sb = wl_container_of(b, sb, base);
    a->fd     = sb->fd;
    a->format = DRM_FORMAT_ARGB8888;
    a->width  = sb->width;
    a->height = sb->height;
    a->stride = (int)sb->stride;
    a->offset = 0;
    return true;
}

static bool shm_buf_begin_access(struct wlr_buffer *b, uint32_t flags,
                                  void **data, uint32_t *fmt, size_t *stride)
{
    struct ambrosia_shm_buf *sb = wl_container_of(b, sb, base);
    *data   = sb->data;
    *fmt    = DRM_FORMAT_ARGB8888;
    *stride = sb->stride;
    return true;
}

static void shm_buf_end_access(struct wlr_buffer *b) { (void)b; }

static const struct wlr_buffer_impl kShmBufImpl = {
    .destroy               = shm_buf_destroy,
    .get_shm               = shm_buf_get_shm,
    .begin_data_ptr_access = shm_buf_begin_access,
    .end_data_ptr_access   = shm_buf_end_access,
};

static struct ambrosia_shm_buf *ambrosia_shm_buf_create(int w, int h)
{
    struct ambrosia_shm_buf *sb = calloc(1, sizeof(*sb));
    if (!sb) return NULL;

    sb->width  = w;
    sb->height = h;
    sb->stride = (size_t)w * 4;
    sb->size   = sb->stride * (size_t)h;

    /* Try memfd_create for a clean anonymous fd */
#ifdef __NR_memfd_create
    sb->fd = (int)syscall(__NR_memfd_create, "ambrosia-tb", 1u /* MFD_CLOEXEC */);
#else
    sb->fd = -1;
#endif
    if (sb->fd < 0) {
        /* Fallback: POSIX shm_open */
        char name[64];
        snprintf(name, sizeof(name), "/ambrosia-tb-%d", (int)getpid());
        sb->fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (sb->fd >= 0) shm_unlink(name);
    }
    if (sb->fd < 0) { free(sb); return NULL; }

    if (ftruncate(sb->fd, (off_t)sb->size) < 0) {
        close(sb->fd); free(sb); return NULL;
    }

    sb->data = mmap(NULL, sb->size, PROT_READ | PROT_WRITE, MAP_SHARED, sb->fd, 0);
    if (sb->data == MAP_FAILED) {
        close(sb->fd); free(sb); return NULL;
    }

    wlr_buffer_init(&sb->base, &kShmBufImpl, w, h);
    return sb;
}

/* --------------------------------------------------------------------------
 * Titlebar pixel rendering
 *
 * Draws a vertical linear gradient with anti-aliased rounded top corners
 * (radius MILK_CORNER_RADIUS) matching Milk.theme's drawTitleBarBackground:.
 * Output is premultiplied ARGB8888 into the buffer's mmap'd data.
 * -------------------------------------------------------------------------- */

/* Draw a single theme button image centred at (cx, cy) scaled to size S×S.
 * Falls back to a solid-colour circle when no image is available. */
static void draw_button(cairo_t *cr,
                        cairo_surface_t *img,
                        float cx, float cy, float S,
                        const float fallback[4])
{
    if (img && cairo_surface_status(img) == CAIRO_STATUS_SUCCESS) {
        int imgW = cairo_image_surface_get_width(img);
        int imgH = cairo_image_surface_get_height(img);
        if (imgW > 0 && imgH > 0) {
            double scale = (imgW >= imgH)
                ? (double)S / imgW
                : (double)S / imgH;
            double ox = cx - (imgW * scale) * 0.5;
            double oy = cy - (imgH * scale) * 0.5;
            cairo_save(cr);
            cairo_translate(cr, ox, oy);
            cairo_scale(cr, scale, scale);
            cairo_set_source_surface(cr, img, 0, 0);
            cairo_paint(cr);
            cairo_restore(cr);
            return;
        }
    }
    /* Fallback: plain filled circle */
    cairo_set_source_rgba(cr, fallback[0], fallback[1], fallback[2], fallback[3]);
    cairo_arc(cr, cx, cy, S * 0.5, 0, 2 * M_PI);
    cairo_fill(cr);
}

static void render_titlebar(struct ambrosia_shm_buf *sb,
                             const float gradTop[4],
                             const float gradBot[4],
                             const float button[4],
                             const char *title,
                             const char *fontName,
                             float fontSize)
{
    const int W = sb->width, H = sb->height;
    const int S   = _gBtnSize;
    const int PDL = _gBtnPadLeft;
    const int PDR = _gBtnPadRight;
    const int PT  = _gBtnPadTop;
    const float CR = _gCornerR;

    cairo_surface_t *surf = cairo_image_surface_create_for_data((unsigned char *)sb->data,
        CAIRO_FORMAT_ARGB32, W, H, (int)sb->stride);
    cairo_t *cr = cairo_create(surf);

    /* Clear to transparent */
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo_paint(cr);

    /* Titlebar shape — rounded top corners when theme requests it */
    cairo_new_path(cr);
    if (CR > 0.5f) {
        cairo_move_to(cr, CR, 0);
        cairo_line_to(cr, W - CR, 0);
        cairo_arc(cr, W - CR, CR, CR, -M_PI_2, 0);
        cairo_line_to(cr, W, H);
        cairo_line_to(cr, 0, H);
        cairo_line_to(cr, 0, CR);
        cairo_arc(cr, CR, CR, CR, M_PI, -M_PI_2);
    } else {
        cairo_rectangle(cr, 0, 0, W, H);
    }
    cairo_close_path(cr);
    cairo_clip(cr);

    /* Gradient fill */
    cairo_pattern_t *grad = cairo_pattern_create_linear(0, 0, 0, H);
    cairo_pattern_add_color_stop_rgba(grad, 0, gradTop[0], gradTop[1], gradTop[2], gradTop[3]);
    cairo_pattern_add_color_stop_rgba(grad, 1, gradBot[0], gradBot[1], gradBot[2], gradBot[3]);
    cairo_set_source(cr, grad);
    cairo_paint(cr);
    cairo_pattern_destroy(grad);

    /* Buttons — use theme images over OVER so transparency composites correctly */
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    float radius = (float)S * 0.5f;
    float cy = PT + radius;
    float leftCx  = PDL + radius;          /* miniaturize: left side  */
    float rightCx = W - PDR - radius;     /* close:       right side */

    draw_button(cr, _gMiniaturizeImg, leftCx,  cy, (float)S, button);
    draw_button(cr, _gCloseImg,       rightCx, cy, (float)S, button);

    /* Window title — centred between the two buttons */
    if (title && title[0] != '\0') {
        cairo_text_extents_t ext;
        cairo_select_font_face(cr, (fontName && fontName[0]) ? fontName : "Sans",
            CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
        cairo_set_font_size(cr, fontSize > 1.0f ? fontSize : 12.0f);
        cairo_text_extents(cr, title, &ext);
        double tx = ((double)W - ext.width) * 0.5 - ext.x_bearing;
        double ty = ((double)H - ext.height) * 0.5 - ext.y_bearing;
        cairo_set_source_rgba(cr, 0.05, 0.05, 0.05, 1.0);
        cairo_move_to(cr, tx, ty);
        cairo_show_text(cr, title);
    }

    cairo_destroy(cr);
    cairo_surface_destroy(surf);
}

/* --------------------------------------------------------------------------
 * Colour helpers
 * -------------------------------------------------------------------------- */

static BOOL parseHexColor(NSString *hex, float out[4])
{
    if (!hex) return NO;
    hex = [hex stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceCharacterSet]];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6 && hex.length != 8) return NO;
    unsigned int v = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&v];
    if (hex.length == 8) {
        out[0] = ((v >> 24) & 0xFF) / 255.f;
        out[1] = ((v >> 16) & 0xFF) / 255.f;
        out[2] = ((v >>  8) & 0xFF) / 255.f;
        out[3] = ( v        & 0xFF) / 255.f;
    } else {
        out[0] = ((v >> 16) & 0xFF) / 255.f;
        out[1] = ((v >>  8) & 0xFF) / 255.f;
        out[2] = ( v        & 0xFF) / 255.f;
        out[3] = 1.f;
    }
    return YES;
}

/* Parse a GNUstep font spec "Family [Bold|Italic…] size" into family + size.
 * Falls back to "Sans 12" when the spec is absent or malformed. */
static void parse_font_spec(NSString *spec, NSString **familyOut, float *sizeOut)
{
    if (!spec || !spec.length) return;
    NSArray<NSString *> *parts = [spec componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [tokens addObject:p];
    if (tokens.count < 2) return;
    NSString *last = tokens.lastObject;
    float parsed = [last floatValue];
    if (parsed > 1.0f) {
        if (sizeOut) *sizeOut = parsed;
        [tokens removeLastObject];
    }
    NSString *joined = [tokens componentsJoinedByString:@" "];
    if (joined.length && familyOut) *familyOut = joined;
}

static void ambrosia_theme_title_font(NSString **familyOut, float *sizeOut)
{
    NSString *family = @"Sans";
    float size = 12.0f;

    /* Prefer NSTitleBarFont from the active theme's info dictionary, then fall
     * back to the user default TitleBarFont / NSFont keys. */
    GSTheme *theme = [GSTheme theme];
    NSDictionary *info = theme ? [theme infoDictionary] : nil;
    NSString *spec = info[@"NSTitleBarFont"];
    if (!spec) {
        /* Some themes store the title font under the plain NSFont key */
        spec = info[@"NSBoldFont"] ?: info[@"NSFont"];
    }
    if (!spec) {
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        spec = [defs objectForKey:@"TitleBarFont"] ?: [defs objectForKey:@"NSFont"];
    }

    parse_font_spec(spec, &family, &size);

    if (familyOut) *familyOut = family;
    if (sizeOut) *sizeOut = size;
}

/* --------------------------------------------------------------------------
 * AmbrosiaDecoration
 *
 * Visual layout (positions relative to the decoration sub-tree which sits
 * at (-B, -T) from the surface scene-tree origin):
 *
 *  ┌─[TITLEBAR BUFFER: gradient + optional rounded top corners, totalW×T px]─┐ y=0
 *  │  [miniaturize img] (left)                       [close img] (right)      │
 *  ├─[separator 1px]────────────────────────────────────────────────────────┤ y=T
 *  │ ║ left (1px stroke + 3px fill)   [surface]  ║ right (same)              │
 *  └─[bottom border (1px stroke + 3px fill)]───────────────────────────────────┘ y=T+H+B
 *
 * Titlebar dimensions, button size, and padding come from [GSTheme theme] so
 * that the SSD matches whatever GNUstep theme is currently active.
 * Button images are loaded from the theme bundle via Cairo PNG.
 * Titlebar buffer is a wlr_scene_buffer backed by a memfd SHM allocation so
 * both the Pixman and GLES2 wlroots renderers can import it.
 * -------------------------------------------------------------------------- */

/* Load a Cairo PNG image from the given path; returns NULL on any error. */
static cairo_surface_t *load_png_image(NSString *path)
{
    if (!path) return NULL;
    cairo_surface_t *s = cairo_image_surface_create_from_png([path UTF8String]);
    if (!s || cairo_surface_status(s) != CAIRO_STATUS_SUCCESS) {
        if (s) cairo_surface_destroy(s);
        return NULL;
    }
    return s;
}

@implementation AmbrosiaDecoration {
    struct wlr_scene_tree   *_parentTree;
    struct wlr_scene_tree   *_decorTree;

    /* Titlebar — rendered into an SHM pixel buffer for gradient + AA corners */
    struct wlr_scene_buffer *_titleSceneBuf;

    /* 1-px separator between titlebar and body */
    struct wlr_scene_rect   *_separator;

    /* Border body fills (B-1 = 3 px between stroke and surface) */
    struct wlr_scene_rect   *_fillLeft;
    struct wlr_scene_rect   *_fillRight;
    struct wlr_scene_rect   *_fillBottom;

    /* Border outer strokes (1 px) */
    struct wlr_scene_rect   *_strokeLeft;
    struct wlr_scene_rect   *_strokeRight;
    struct wlr_scene_rect   *_strokeBottom;

    /* Window control buttons (Milk: miniaturize LEFT, close RIGHT, no maximize) */
    struct wlr_scene_rect   *_btnMinimize;
    struct wlr_scene_rect   *_btnClose;

    int  _surfaceWidth;
    int  _surfaceHeight;

    /* Per-instance colour palette */
    float _gradTopActive[4];
    float _gradBotActive[4];
    float _gradTopInactive[4];
    float _gradBotInactive[4];
    float _separatorColor[4];
    float _borderStroke[4];
    float _bodyFill[4];
    float _btnActive[4];
    float _btnInactive[4];
    NSString *_title;
}

@synthesize focused    = _focused;
@synthesize scene_tree = _decorTree;

- (instancetype)initWithRenderer:(struct wlr_renderer *)renderer
                       sceneTree:(struct wlr_scene_tree *)parentTree
{
    self = [super init];
    if (!self) return nil;

    _parentTree = parentTree;

    /* Copy default palette */
    memcpy(_gradTopActive,   kGradTopActive,   sizeof(_gradTopActive));
    memcpy(_gradBotActive,   kGradBotActive,   sizeof(_gradBotActive));
    memcpy(_gradTopInactive, kGradTopInactive, sizeof(_gradTopInactive));
    memcpy(_gradBotInactive, kGradBotInactive, sizeof(_gradBotInactive));
    memcpy(_separatorColor,  kSeparatorColor,  sizeof(_separatorColor));
    memcpy(_borderStroke,    kBorderStroke,    sizeof(_borderStroke));
    memcpy(_bodyFill,        kBodyFill,        sizeof(_bodyFill));
    memcpy(_btnActive,       kBtnActive,       sizeof(_btnActive));
    memcpy(_btnInactive,     kBtnInactive,     sizeof(_btnInactive));

    /* Decoration sub-tree — positioned at (-B, -T) in updateWith… */
    _decorTree = wlr_scene_tree_create(parentTree);

    /* Titlebar scene buffer — content set on first updateWith… */
    _titleSceneBuf = wlr_scene_buffer_create(_decorTree, NULL);
    wlr_scene_node_set_position(&_titleSceneBuf->node, 0, 0);

    float dummy[4] = {0, 0, 0, 0};

    _separator   = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    /* Fills before strokes so strokes render on top */
    _fillLeft    = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _fillRight   = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _fillBottom  = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    _strokeLeft   = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _strokeRight  = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _strokeBottom = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    /* Buttons (rendered on top) */
    _btnMinimize = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _btnClose    = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    return self;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Layout

- (void)updateWithWidth:(int)sw height:(int)sh title:(NSString *)title
{
    _title = title ?: @"";
    if (sw > 0) _surfaceWidth  = sw;
    if (sh > 0) _surfaceHeight = sh;

    int W  = _surfaceWidth;
    int H  = _surfaceHeight;
    int T  = _gTitlebarH;
    int B  = AMBROSIA_BORDER_WIDTH;

    if (W <= 0 || H <= 0) return;

    int totalW = W + B * 2;
    int totalH = H + T + B;
    int fillW  = B - 1;   /* 3 px — between 1px stroke and surface */

    /* Shift decoration tree so surface origin sits at (B, T) in the view tree */
    wlr_scene_node_set_position(&_decorTree->node, -B, -T);

    /* ---- Titlebar pixel buffer (gradient + theme images) ---- */
    [self _uploadTitlebarWidth:totalW height:T];
    wlr_scene_node_set_position(&_titleSceneBuf->node, 0, 0);

    /* ---- Separator ---- */
    wlr_scene_rect_set_size(_separator, totalW, 1);
    wlr_scene_node_set_position(&_separator->node, 0, T - 1);

    /* ---- Border fills ---- */
    wlr_scene_rect_set_size(_fillLeft,   fillW, H + B);
    wlr_scene_node_set_position(&_fillLeft->node,   1,          T);
    wlr_scene_rect_set_size(_fillRight,  fillW, H + B);
    wlr_scene_node_set_position(&_fillRight->node,  totalW - B, T);
    wlr_scene_rect_set_size(_fillBottom, totalW, B - 1);
    wlr_scene_node_set_position(&_fillBottom->node, 0,          T + H);

    /* ---- Border strokes ---- */
    wlr_scene_rect_set_size(_strokeLeft,   1, H + B);
    wlr_scene_node_set_position(&_strokeLeft->node,   0,          T);
    wlr_scene_rect_set_size(_strokeRight,  1, H + B);
    wlr_scene_node_set_position(&_strokeRight->node,  totalW - 1, T);
    wlr_scene_rect_set_size(_strokeBottom, totalW, 1);
    wlr_scene_node_set_position(&_strokeBottom->node, 0,          totalH - 1);

    /* ---- Buttons ---- */
    /* Buttons are rasterized into the titlebar buffer; keep scene_rect nodes
     * zero-sized so they don't render but still mark the hit-test zones. */
    wlr_scene_rect_set_size(_btnMinimize, 0, 0);
    wlr_scene_node_set_position(&_btnMinimize->node, _gBtnPadLeft,                _gBtnPadTop);
    wlr_scene_rect_set_size(_btnClose, 0, 0);
    wlr_scene_node_set_position(&_btnClose->node,    totalW - _gBtnPadRight - _gBtnSize, _gBtnPadTop);

    [self _applyRectColors];
}

/* Render the titlebar gradient into a fresh SHM buffer and upload to scene. */
- (void)_uploadTitlebarWidth:(int)w height:(int)h
{
    const float *gradTop = _focused ? _gradTopActive : _gradTopInactive;
    const float *gradBot = _focused ? _gradBotActive : _gradBotInactive;
    const float *btn     = _focused ? _btnActive     : _btnInactive;

    struct ambrosia_shm_buf *buf = ambrosia_shm_buf_create(w, h);
    if (!buf) return;

    NSString *fontFamily = nil;
    float fontSize = 12.0f;
    ambrosia_theme_title_font(&fontFamily, &fontSize);
    render_titlebar(buf, gradTop, gradBot, btn, _title.UTF8String, fontFamily.UTF8String, fontSize);
    wlr_scene_buffer_set_buffer(_titleSceneBuf, &buf->base);
    /* Drop the producer reference — the scene now holds the only lock. */
    wlr_buffer_drop(&buf->base);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Colour application

- (void)setFocused:(BOOL)focused
{
    _focused = focused;
    /* Re-render titlebar with the new gradient (active/inactive palette). */
    if (_surfaceWidth > 0 && _surfaceHeight > 0) {
        int totalW = _surfaceWidth + AMBROSIA_BORDER_WIDTH * 2;
        [self _uploadTitlebarWidth:totalW height:_gTitlebarH];
    }
    [self _applyRectColors];
}

/* Apply colours to the scene_rect nodes (separator, borders, buttons). */
- (void)_applyRectColors
{
    const float *btn = _focused ? _btnActive : _btnInactive;

    wlr_scene_rect_set_color(_separator,    _separatorColor);
    wlr_scene_rect_set_color(_fillLeft,     _bodyFill);
    wlr_scene_rect_set_color(_fillRight,    _bodyFill);
    wlr_scene_rect_set_color(_fillBottom,   _bodyFill);
    wlr_scene_rect_set_color(_strokeLeft,   _borderStroke);
    wlr_scene_rect_set_color(_strokeRight,  _borderStroke);
    wlr_scene_rect_set_color(_strokeBottom, _borderStroke);
    wlr_scene_rect_set_color(_btnMinimize,  btn);
    wlr_scene_rect_set_color(_btnClose,     btn);
}

- (void)updateColorsFromDictionary:(NSDictionary *)dict
{
    parseHexColor(dict[@"titlebarGradientTopColor"],    _gradTopActive);
    parseHexColor(dict[@"titlebarGradientBottomColor"], _gradBotActive);
    parseHexColor(dict[@"titlebarInactiveTopColor"],    _gradTopInactive);
    parseHexColor(dict[@"titlebarInactiveBottomColor"], _gradBotInactive);
    parseHexColor(dict[@"titlebarSeparatorColor"],      _separatorColor);
    parseHexColor(dict[@"windowBorderColor"],           _borderStroke);
    parseHexColor(dict[@"windowBodyColor"],             _bodyFill);
    parseHexColor(dict[@"buttonActiveColor"],           _btnActive);
    parseHexColor(dict[@"buttonInactiveColor"],         _btnInactive);

    /* Re-render titlebar and refresh rect colours */
    if (_surfaceWidth > 0 && _surfaceHeight > 0) {
        int totalW = _surfaceWidth + AMBROSIA_BORDER_WIDTH * 2;
        [self _uploadTitlebarWidth:totalW height:_gTitlebarH];
    }
    [self _applyRectColors];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Hit testing

- (AmbrosiaDecorationHit)hitTestX:(double)x y:(double)y
{
    int T      = _gTitlebarH;
    int B      = AMBROSIA_BORDER_WIDTH;
    int S      = _gBtnSize;
    int PDL    = _gBtnPadLeft;
    int PDR    = _gBtnPadRight;
    int PT     = _gBtnPadTop;
    int totalW = _surfaceWidth  + B * 2;
    int totalH = _surfaceHeight + T + B;
    int corner = 12;

    /* ---- Title bar (y 0 .. T) ---------------------------------------- */
    if (y >= 0 && y < T) {
        /* Resize strip at very top */
        if (y < B) {
            if (x < corner)        return AmbrosiaDecorationHitResizeTopLeft;
            if (x > totalW-corner) return AmbrosiaDecorationHitResizeTopRight;
            return AmbrosiaDecorationHitResizeTop;
        }

        /* Buttons: miniaturize LEFT, close RIGHT */
        int btn_y0 = PT - 3;
        int btn_y1 = PT + S + 3;
        if ((int)y >= btn_y0 && (int)y < btn_y1) {
            int minX   = PDL;
            int closeX = totalW - PDR - S;
            if (x >= minX-3   && x < minX+S+3)   return AmbrosiaDecorationHitMinimize;
            if (x >= closeX-3 && x < closeX+S+3) return AmbrosiaDecorationHitClose;
        }

        return AmbrosiaDecorationHitTitlebar;
    }

    /* ---- Below title bar: corners then edges -------------------------- */
    if (x < corner  && y > totalH-corner) return AmbrosiaDecorationHitResizeBottomLeft;
    if (x > totalW-corner && y > totalH-corner) return AmbrosiaDecorationHitResizeBottomRight;
    if (x < corner  && y < T+corner)  return AmbrosiaDecorationHitResizeTopLeft;
    if (x > totalW-corner && y < T+corner) return AmbrosiaDecorationHitResizeTopRight;

    if (y > totalH - B) return AmbrosiaDecorationHitResizeBottom;
    if (x < B)          return AmbrosiaDecorationHitResizeLeft;
    if (x > totalW - B) return AmbrosiaDecorationHitResizeRight;

    return AmbrosiaDecorationHitNone;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Class helpers

+ (void)reloadThemeMetrics
{
    GSTheme *theme = [GSTheme theme];
    if (!theme) return;

    _gTitlebarH   = MAX(1, (int)ceilf([theme titlebarHeight]));
    _gBtnSize     = MAX(4, (int)roundf([theme titlebarButtonSize]));
    _gBtnPadLeft  = MAX(1, (int)roundf([theme titlebarPaddingLeft]));
    _gBtnPadRight = MAX(1, (int)roundf([theme titlebarPaddingRight]));
    _gBtnPadTop   = MAX(1, (int)roundf([theme titlebarPaddingTop]));

    /* Corner radius: read from GSThemeDomain dict; fall back to 6 for Milk.
     * Use [theme name] (not infoDictionary[@"GSThemeName"]) — the latter key
     * is absent from standard GNUstep theme plists and always returns nil. */
    NSDictionary *domain = [theme infoDictionary][@"GSThemeDomain"];
    id cr = domain[@"GSWindowCornerRadius"];
    if (cr) {
        _gCornerR = [cr floatValue];
    } else {
        NSString *name = [theme name];
        _gCornerR = ([name rangeOfString:@"Milk"
                                 options:NSCaseInsensitiveSearch].location != NSNotFound)
                    ? 6.0f : 0.0f;
    }

    /* Button images from the theme bundle.
     * GNUstep theme bundles store images under "Images/", not "ThemeImages/". */
    if (_gCloseImg)       { cairo_surface_destroy(_gCloseImg);       _gCloseImg       = NULL; }
    if (_gMiniaturizeImg) { cairo_surface_destroy(_gMiniaturizeImg); _gMiniaturizeImg = NULL; }

    NSBundle *bundle = [theme bundle];
    if (bundle) {
        NSString *closePath =
            [bundle pathForResource:@"common_Close" ofType:@"png" inDirectory:@"Images"]
            ?: [bundle pathForResource:@"common_Close" ofType:@"png" inDirectory:@"ThemeImages"]
            ?: [bundle pathForResource:@"common_Close" ofType:@"png"];
        NSString *miniPath =
            [bundle pathForResource:@"common_Miniaturize" ofType:@"png" inDirectory:@"Images"]
            ?: [bundle pathForResource:@"common_Miniaturize" ofType:@"png" inDirectory:@"ThemeImages"]
            ?: [bundle pathForResource:@"common_Miniaturize" ofType:@"png"];
        _gCloseImg       = load_png_image(closePath);
        _gMiniaturizeImg = load_png_image(miniPath);
    }
}

+ (NSEdgeInsets)frameInsets
{
    return NSEdgeInsetsMake(_gTitlebarH,
                            AMBROSIA_BORDER_WIDTH,
                            AMBROSIA_BORDER_WIDTH,
                            AMBROSIA_BORDER_WIDTH);
}

@end
