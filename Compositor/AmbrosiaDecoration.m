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

#import <AppKit/AppKit.h>
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

/* Reserved for future PNG overlays; always NULL — buttons are drawn as spheres. */
static cairo_surface_t *_gCloseImg      = NULL;
static cairo_surface_t *_gMiniaturizeImg = NULL;
static cairo_surface_t *_gZoomImg       = NULL;

/* Per-button colours loaded from ThemeExtraColors; fallback to macOS-style defaults */
static float _gCloseColor[4] = { 1.000f, 0.270f, 0.270f, 1.0f };
static float _gMinColor[4]   = { 1.000f, 0.850f, 0.000f, 1.0f };
static float _gZoomColor[4]  = { 0.200f, 0.780f, 0.350f, 1.0f };

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
static const float kTitleTextColor[4]   = { 0.050f, 0.050f, 0.050f, 1.0f  };

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

/* Draw a spherical window button matching GSThemeWindowButtonCell -drawBallWithRect:
 * All coordinates are screen-space (y increases downward).
 * S is the button diameter; base is the RGBA base colour from ThemeExtraColors. */
static void draw_button_ball(cairo_t *cr, double cx, double cy, double S,
                              const float base[4])
{
    double R  = S * 0.5;
    double r  = base[0], g = base[1], b = base[2];
    const double lum = 0.5;

    /* Derived colours — match GSThemeWindowButtonCell logic exactly.
     * highlight(l): blend toward white   → c*(1-l) + l
     * shadow(l):    blend toward black   → c*(1-l)        */
    double sc1r = r*0.6,  sc1g = g*0.6,  sc1b = b*0.6;          /* shadow 0.4 */
    double sc2r = r*0.4,  sc2g = g*0.4,  sc2b = b*0.4;          /* shadow 0.6 */
    double gsc2r = sc1r+(1-sc1r)*lum, gsc2g = sc1g+(1-sc1g)*lum, gsc2b = sc1b+(1-sc1b)*lum;
    double uc1r = r*0.3+0.7, uc1g = g*0.3+0.7, uc1b = b*0.3+0.7; /* highlight 0.7 */
    double dc1r = r*0.5+0.5, dc1g = g*0.5+0.5, dc1b = b*0.5+0.5; /* highlight 0.5 */

    /* Geometry — mirrors Cocoa inset sequence */
    double Ro = R - 0.5;                   /* outer stroke ring */
    double Ri = R - 1.0;                   /* inner stroke ring */
    double Rc = (R - 1.5) * 0.9333;       /* main filled circle */
    double rr = Rc / 6.5;                  /* radial gradient scale */

    /* frame rect (used for halfPath Bezier) */
    double W  = (R - 1.5) * 2.0;
    double x0 = cx - (R - 1.5);
    double y0 = cy - (R - 1.5);

    cairo_pattern_t *p;
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    /* 1. Outer stroke ring — gradientStroke (white@0.2→transparent@1.0)
     *    Cocoa angle 90 = gradient from visual bottom (loc 0) to top (loc 1).
     *    Screen y-down: bottom = cy+Ro, top = cy-Ro.                        */
    p = cairo_pattern_create_linear(cx, cy+Ro, cx, cy-Ro);
    cairo_pattern_add_color_stop_rgba(p, 0.0, 1,1,1, 1.0);
    cairo_pattern_add_color_stop_rgba(p, 0.2, 1,1,1, 1.0);
    cairo_pattern_add_color_stop_rgba(p, 1.0, 1,1,1, 0.0);
    cairo_arc(cr, cx, cy, Ro, 0, 2*M_PI);
    cairo_set_source(cr, p); cairo_fill(cr);
    cairo_pattern_destroy(p);

    /* 2. Inner stroke ring — gradientStroke2 (sc2@0.47→gsc2@1.0)
     *    Cocoa angle -90 = gradient from visual top (loc 0) to bottom (loc 1). */
    p = cairo_pattern_create_linear(cx, cy-Ri, cx, cy+Ri);
    cairo_pattern_add_color_stop_rgba(p, 0.0,  sc2r,sc2g,sc2b, 0.0);
    cairo_pattern_add_color_stop_rgba(p, 0.47, sc2r,sc2g,sc2b, 1.0);
    cairo_pattern_add_color_stop_rgba(p, 1.0,  gsc2r,gsc2g,gsc2b, 1.0);
    cairo_arc(cr, cx, cy, Ri, 0, 2*M_PI);
    cairo_set_source(cr, p); cairo_fill(cr);
    cairo_pattern_destroy(p);

    /* 3. Main sphere — baseGradient (bc@0.0→sc1@0.80) concentric radial */
    cairo_save(cr);
    cairo_arc(cr, cx, cy, Rc, 0, 2*M_PI);
    cairo_clip(cr);
    p = cairo_pattern_create_radial(cx, cy, 2.85*rr, cx, cy, 7.32*rr);
    cairo_pattern_add_color_stop_rgba(p, 0.0,  r,g,b,     1.0);
    cairo_pattern_add_color_stop_rgba(p, 0.80, sc1r,sc1g,sc1b, 1.0);
    cairo_pattern_set_extend(p, CAIRO_EXTEND_PAD);
    cairo_set_source(cr, p); cairo_paint(cr);
    cairo_pattern_destroy(p);
    cairo_restore(cr);

    /* 4. Lower darkening overlay — gradientDown (dc1→transparent) offset radial.
     *    Cocoa offset (-0.98*rr, -6.5*rr) in y-up → screen y-down (+6.5*rr). */
    cairo_save(cr);
    cairo_arc(cr, cx, cy, Rc, 0, 2*M_PI);
    cairo_clip(cr);
    p = cairo_pattern_create_radial(cx-0.98*rr, cy+6.5*rr,  1.54*rr,
                                    cx-1.86*rr, cy+8.73*rr, 8.65*rr);
    cairo_pattern_add_color_stop_rgba(p, 0.0, dc1r,dc1g,dc1b, 1.0);
    cairo_pattern_add_color_stop_rgba(p, 1.0, dc1r,dc1g,dc1b, 0.0);
    cairo_pattern_set_extend(p, CAIRO_EXTEND_PAD);
    cairo_set_source(cr, p); cairo_paint(cr);
    cairo_pattern_destroy(p);
    cairo_restore(cr);

    /* 5. Top glossy cap — gradientUp (uc1@0.1→uc2@0.3→transparent@1.0)
     *    Drawn inside the halfPath (upper portion of button).
     *    halfPath Bezier translated from Cocoa y-up to screen y-down
     *    by mirroring the y fractions: y_screen = y0 + (1 - frac_cocoa)*W  */
    cairo_save(cr);
    cairo_move_to   (cr, x0+0.93316*W, y0+0.53843*W);
    cairo_curve_to  (cr, x0+0.93316*W, y0+0.53843*W,   /* cp1 = start */
                         x0+0.94476*W, y0+0.33624*W,   /* cp2 */
                         x0+0.78652*W, y0+0.18452*W);  /* end */
    cairo_curve_to  (cr, x0+0.62828*W, y0+0.03279*W,
                         x0+0.37172*W, y0+0.03279*W,
                         x0+0.21348*W, y0+0.18452*W);
    cairo_curve_to  (cr, x0+0.05524*W, y0+0.33624*W,
                         x0+0.06684*W, y0+0.53843*W,   /* cp2 = end */
                         x0+0.06684*W, y0+0.53843*W);  /* end */
    cairo_close_path(cr);
    cairo_clip(cr);
    /* Cocoa angle -90 → gradient from screen top (y0) to bottom (y0+W) */
    p = cairo_pattern_create_linear(cx, y0, cx, y0+W);
    cairo_pattern_add_color_stop_rgba(p, 0.0, uc1r,uc1g,uc1b, 1.0);
    cairo_pattern_add_color_stop_rgba(p, 0.1, uc1r,uc1g,uc1b, 1.0);
    cairo_pattern_add_color_stop_rgba(p, 0.3, uc1r,uc1g,uc1b, 0.5);
    cairo_pattern_add_color_stop_rgba(p, 1.0, uc1r,uc1g,uc1b, 0.0);
    cairo_set_source(cr, p); cairo_paint(cr);
    cairo_pattern_destroy(p);
    cairo_restore(cr);
}

/* Draw a button: PNG theme image if available, otherwise the sphere. */
static void draw_button(cairo_t *cr,
                        cairo_surface_t *img,
                        double cx, double cy, double S,
                        const float color[4])
{
    if (img && cairo_surface_status(img) == CAIRO_STATUS_SUCCESS) {
        int imgW = cairo_image_surface_get_width(img);
        int imgH = cairo_image_surface_get_height(img);
        if (imgW > 0 && imgH > 0) {
            double scale = (imgW >= imgH) ? S / imgW : S / imgH;
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
    draw_button_ball(cr, cx, cy, S, color);
}

static void render_titlebar(struct ambrosia_shm_buf *sb,
                             const float gradTop[4],
                             const float gradBot[4],
                             const float closeColor[4],
                             const float minColor[4],
                             const float zoomColor[4],
                             const float titleText[4],
                             const char *title,
                             const char *fontName,
                             float fontSize)
{
    const int W = sb->width, H = sb->height;
    const int S   = _gBtnSize;
    const int PDL = _gBtnPadLeft;
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

    /* Buttons — macOS order: close / miniaturize / zoom, left to right.
     * Gap between buttons = 40% of button size.                          */
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    double radius = S * 0.5;
    double bcy    = PT + radius;
    double gap    = S * 0.4;
    double closeCx = PDL + radius;
    double minCx   = closeCx + S + gap;
    double zoomCx  = minCx  + S + gap;

    draw_button(cr, _gCloseImg,       closeCx, bcy, S, closeColor);
    draw_button(cr, _gMiniaturizeImg, minCx,   bcy, S, minColor);
    draw_button(cr, _gZoomImg,        zoomCx,  bcy, S, zoomColor);

    /* Window title — centred between the two buttons */
    if (title && title[0] != '\0') {
        cairo_text_extents_t ext;
        cairo_select_font_face(cr, (fontName && fontName[0]) ? fontName : "Sans",
            CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
        cairo_set_font_size(cr, fontSize > 1.0f ? fontSize : 12.0f);
        cairo_text_extents(cr, title, &ext);
        double tx = ((double)W - ext.width) * 0.5 - ext.x_bearing;
        double ty = ((double)H - ext.height) * 0.5 - ext.y_bearing;
        cairo_set_source_rgba(cr, titleText[0], titleText[1], titleText[2], titleText[3]);
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
    struct wlr_scene_rect   *_btnMaximize;

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
    float _titleTextColor[4];
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
    memcpy(_titleTextColor,  kTitleTextColor,  sizeof(_titleTextColor));

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
    _btnMaximize = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

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

    /* ---- Buttons: close / miniaturize / zoom, left to right ---- */
    /* Buttons are rasterized into the titlebar buffer; scene_rect nodes are
     * zero-sized (invisible) but mark hit-test zones for the compositor. */
    int gap = (int)(_gBtnSize * 0.4f + 0.5f);
    int closeX = _gBtnPadLeft;
    int minX   = closeX + _gBtnSize + gap;
    int zoomX  = minX   + _gBtnSize + gap;

    wlr_scene_rect_set_size(_btnClose, 0, 0);
    wlr_scene_node_set_position(&_btnClose->node,    closeX, _gBtnPadTop);
    wlr_scene_rect_set_size(_btnMinimize, 0, 0);
    wlr_scene_node_set_position(&_btnMinimize->node, minX,   _gBtnPadTop);
    wlr_scene_rect_set_size(_btnMaximize, 0, 0);
    wlr_scene_node_set_position(&_btnMaximize->node, zoomX,  _gBtnPadTop);

    [self _applyRectColors];
}

/* Render the titlebar gradient into a fresh SHM buffer and upload to scene. */
- (void)_uploadTitlebarWidth:(int)w height:(int)h
{
    const float *gradTop = _focused ? _gradTopActive : _gradTopInactive;
    const float *gradBot = _focused ? _gradBotActive : _gradBotInactive;

    /* Inactive buttons are blended 75 % toward neutral gray. */
    float closeC[4], minC[4], zoomC[4];
    if (_focused) {
        memcpy(closeC, _gCloseColor, sizeof(closeC));
        memcpy(minC,   _gMinColor,   sizeof(minC));
        memcpy(zoomC,  _gZoomColor,  sizeof(zoomC));
    } else {
        for (int i = 0; i < 3; i++) {
            closeC[i] = _gCloseColor[i] * 0.25f + 0.65f * 0.75f;
            minC[i]   = _gMinColor[i]   * 0.25f + 0.65f * 0.75f;
            zoomC[i]  = _gZoomColor[i]  * 0.25f + 0.65f * 0.75f;
        }
        closeC[3] = minC[3] = zoomC[3] = 1.0f;
    }

    struct ambrosia_shm_buf *buf = ambrosia_shm_buf_create(w, h);
    if (!buf) return;

    NSString *fontFamily = nil;
    float fontSize = 12.0f;
    ambrosia_theme_title_font(&fontFamily, &fontSize);
    render_titlebar(buf, gradTop, gradBot,
                    closeC, minC, zoomC,
                    _titleTextColor, _title.UTF8String,
                    fontFamily.UTF8String, fontSize);
    wlr_scene_buffer_set_buffer(_titleSceneBuf, &buf->base);
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
    wlr_scene_rect_set_color(_btnClose,    btn);
    wlr_scene_rect_set_color(_btnMinimize, btn);
    wlr_scene_rect_set_color(_btnMaximize, btn);
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
    parseHexColor(dict[@"titleTextColor"],              _titleTextColor);

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

        /* Buttons: close / miniaturize / zoom, left to right */
        int btn_y0 = PT - 3;
        int btn_y1 = PT + S + 3;
        if ((int)y >= btn_y0 && (int)y < btn_y1) {
            int gap    = (int)(S * 0.4f + 0.5f);
            int closeX = PDL;
            int minX   = closeX + S + gap;
            int zoomX  = minX   + S + gap;
            if (x >= closeX-3 && x < closeX+S+3) return AmbrosiaDecorationHitClose;
            if (x >= minX-3   && x < minX+S+3)   return AmbrosiaDecorationHitMinimize;
            if (x >= zoomX-3  && x < zoomX+S+3)  return AmbrosiaDecorationHitMaximize;
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

    /* Corner radius: read from GSThemeDomain dict; default to square corners. */
    NSDictionary *domain = [theme infoDictionary][@"GSThemeDomain"];
    id cr = domain[@"GSWindowCornerRadius"];
    _gCornerR = cr ? [cr floatValue] : 0.0f;

    /* Button colours from ThemeExtraColors (closeColor / minColor / zoomColor).
     * Falls back to macOS-style defaults when the key is absent.            */
    NSBundle *bundle = [theme bundle];
    NSString *clrPath = [bundle pathForResource:@"ThemeExtraColors" ofType:@"clr"];
    NSColorList *extras = clrPath
        ? [[NSColorList alloc] initWithName:@"ThemeExtraColors" fromFile:clrPath]
        : nil;

    NSColor *(^extra)(NSString *) = ^NSColor *(NSString *key) {
        NSColor *c = [extras colorWithKey:key];
        return c ? [c colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]] : nil;
    };

    NSColor *cc = extra(@"closeColor");
    NSColor *mc = extra(@"minColor");
    NSColor *zc = extra(@"zoomColor");
    if (cc) { CGFloat r,g,b,a; [cc getRed:&r green:&g blue:&b alpha:&a];
               _gCloseColor[0]=r; _gCloseColor[1]=g; _gCloseColor[2]=b; _gCloseColor[3]=a; }
    if (mc) { CGFloat r,g,b,a; [mc getRed:&r green:&g blue:&b alpha:&a];
               _gMinColor[0]=r;   _gMinColor[1]=g;   _gMinColor[2]=b;   _gMinColor[3]=a; }
    if (zc) { CGFloat r,g,b,a; [zc getRed:&r green:&g blue:&b alpha:&a];
               _gZoomColor[0]=r;  _gZoomColor[1]=g;  _gZoomColor[2]=b;  _gZoomColor[3]=a; }

    /* Buttons are drawn programmatically as spheres; clear any stale surfaces. */
    if (_gCloseImg)       { cairo_surface_destroy(_gCloseImg);       _gCloseImg       = NULL; }
    if (_gMiniaturizeImg) { cairo_surface_destroy(_gMiniaturizeImg); _gMiniaturizeImg = NULL; }
    if (_gZoomImg)        { cairo_surface_destroy(_gZoomImg);        _gZoomImg        = NULL; }
}

+ (NSEdgeInsets)frameInsets
{
    return NSEdgeInsetsMake(_gTitlebarH,
                            AMBROSIA_BORDER_WIDTH,
                            AMBROSIA_BORDER_WIDTH,
                            AMBROSIA_BORDER_WIDTH);
}

@end
