#import "AmbrosiaDecoration.h"

#include <wlr/types/wlr_scene.h>
#include <string.h>
#include <math.h>

/* --------------------------------------------------------------------------
 * Milk.theme default colour palette
 *
 * Active titlebar gradient: white → (0.863, 0.863, 0.871)   [Milk source]
 * Inactive titlebar gradient: neutral gray fade
 * Border stroke: controlStrokeColor = (0.4, 0.4, 0.4)       [Milk source]
 * Body fill: windowBackgroundColor ≈ (0.863, 0.863, 0.863)   [ThemeColors]
 * Buttons: light gray bezel, no colour coding                 [Milk style]
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

/* Number of gradient bands spanning the title bar */
#define GRADIENT_BANDS  8

/* Parse a 6- or 8-char hex string (RRGGBB or RRGGBBAA, optional leading #). */
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

static inline float lerpf(float a, float b, float t) { return a + (b - a) * t; }

/* --------------------------------------------------------------------------
 * AmbrosiaDecoration
 *
 * Visual layout (Milk.theme style, all coords relative to decoration sub-tree
 * which is positioned at (-B, -T) from the surface scene-tree origin):
 *
 *  ┌──[GRADIENT: 8 bands × 3px = 24px (AMBROSIA_TITLEBAR_HEIGHT)]──────┐ y=0
 *  │  ○ miniaturize (left)              ×  close (right)  │ separator  │
 *  ├──[separator: 1px controlStrokeColor]───────────────────────────────┤ y=T
 *  │ ║ left border (1px stroke + 3px fill)                ║             │
 *  │ ║                 [surface content area]              ║             │
 *  │ ║                                                     ║             │
 *  └──[bottom border (1px stroke + 3px fill)]──────────────────────────┘ y=T+H+B
 *
 * Miniaturize button: x = AMBROSIA_BTN_PAD_SIDE, y = AMBROSIA_BTN_PAD_TOP (LEFT)
 * Close button:       x = totalW - AMBROSIA_BTN_PAD_SIDE - AMBROSIA_BTN_SIZE  (RIGHT)
 * No maximize button (Milk style).
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaDecoration {
    struct wlr_scene_tree  *_parentTree;
    struct wlr_scene_tree  *_decorTree;

    /* Title-bar gradient — GRADIENT_BANDS rects, each AMBROSIA_TITLEBAR_HEIGHT/GRADIENT_BANDS px tall */
    struct wlr_scene_rect  *_titleBands[GRADIENT_BANDS];

    /* 1-px separator line between title bar and body */
    struct wlr_scene_rect  *_separator;

    /* Border strokes (1 px) */
    struct wlr_scene_rect  *_strokeLeft;
    struct wlr_scene_rect  *_strokeRight;
    struct wlr_scene_rect  *_strokeBottom;

    /* Border body fill (AMBROSIA_BORDER_WIDTH-1 px) — between stroke and surface */
    struct wlr_scene_rect  *_fillLeft;
    struct wlr_scene_rect  *_fillRight;
    struct wlr_scene_rect  *_fillBottom;

    /* Window control buttons (Milk: miniaturize LEFT, close RIGHT) */
    struct wlr_scene_rect  *_btnMinimize;
    struct wlr_scene_rect  *_btnClose;

    int  _surfaceWidth;
    int  _surfaceHeight;

    /* Per-instance colour palette (defaults mirror kGrad* / kBorder* above) */
    float _gradTopActive[4];
    float _gradBotActive[4];
    float _gradTopInactive[4];
    float _gradBotInactive[4];
    float _separatorColor[4];
    float _borderStroke[4];
    float _bodyFill[4];
    float _btnActive[4];
    float _btnInactive[4];
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

    float dummy[4] = {0,0,0,0};

    /* Gradient bands (bottom of z-order) */
    for (int i = 0; i < GRADIENT_BANDS; i++)
        _titleBands[i] = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    _separator   = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    /* Fills before strokes so strokes render on top */
    _fillLeft    = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _fillRight   = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _fillBottom  = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    _strokeLeft   = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _strokeRight  = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _strokeBottom = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    /* Buttons (on top of everything else) */
    _btnMinimize = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _btnClose    = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    return self;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Layout

- (void)updateWithWidth:(int)sw height:(int)sh title:(NSString *)title
{
    if (sw > 0) _surfaceWidth  = sw;
    if (sh > 0) _surfaceHeight = sh;

    int W  = _surfaceWidth;
    int H  = _surfaceHeight;
    int T  = AMBROSIA_TITLEBAR_HEIGHT;   /* 24 */
    int B  = AMBROSIA_BORDER_WIDTH;      /* 4  */
    int S  = AMBROSIA_BTN_SIZE;          /* 15 */
    int PD = AMBROSIA_BTN_PAD_SIDE;      /* 10 */
    int PT = AMBROSIA_BTN_PAD_TOP;       /* 5  */

    if (W <= 0 || H <= 0) return;

    int totalW = W + B * 2;
    int totalH = H + T + B;
    int bandH  = T / GRADIENT_BANDS;    /* 3 px per band */

    /* Shift decoration tree so surface origin is at (B, T) in the view tree */
    wlr_scene_node_set_position(&_decorTree->node, -B, -T);

    /* ---- Gradient bands ---- */
    for (int i = 0; i < GRADIENT_BANDS; i++) {
        int y0 = i * bandH;
        int h  = (i == GRADIENT_BANDS - 1) ? T - y0 : bandH; /* last absorbs remainder */
        wlr_scene_rect_set_size(_titleBands[i], totalW, h);
        wlr_scene_node_set_position(&_titleBands[i]->node, 0, y0);
    }

    /* ---- Separator ---- */
    wlr_scene_rect_set_size(_separator, totalW, 1);
    wlr_scene_node_set_position(&_separator->node, 0, T - 1);

    /* ---- Border fills (AMBROSIA_BORDER_WIDTH-1 px wide/tall) ---- */
    int fillW = B - 1; /* 3 px */
    wlr_scene_rect_set_size(_fillLeft,   fillW, H + B);
    wlr_scene_node_set_position(&_fillLeft->node,   1,              T);
    wlr_scene_rect_set_size(_fillRight,  fillW, H + B);
    wlr_scene_node_set_position(&_fillRight->node,  totalW - B,     T);
    wlr_scene_rect_set_size(_fillBottom, totalW, B - 1);
    wlr_scene_node_set_position(&_fillBottom->node, 0,              T + H);

    /* ---- Border strokes (1 px) ---- */
    wlr_scene_rect_set_size(_strokeLeft,   1, H + B);
    wlr_scene_node_set_position(&_strokeLeft->node,   0,              T);
    wlr_scene_rect_set_size(_strokeRight,  1, H + B);
    wlr_scene_node_set_position(&_strokeRight->node,  totalW - 1,    T);
    wlr_scene_rect_set_size(_strokeBottom, totalW, 1);
    wlr_scene_node_set_position(&_strokeBottom->node, 0,              totalH - 1);

    /* ---- Buttons ---- */
    /* Miniaturize: LEFT side of titlebar */
    wlr_scene_rect_set_size(_btnMinimize, S, S);
    wlr_scene_node_set_position(&_btnMinimize->node, PD, PT);

    /* Close: RIGHT side of titlebar */
    wlr_scene_rect_set_size(_btnClose, S, S);
    wlr_scene_node_set_position(&_btnClose->node, totalW - PD - S, PT);

    [self _applyColors];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Colour application

- (void)setFocused:(BOOL)focused
{
    _focused = focused;
    [self _applyColors];
}

- (void)_applyColors
{
    const float *gradTop = _focused ? _gradTopActive : _gradTopInactive;
    const float *gradBot = _focused ? _gradBotActive : _gradBotInactive;
    const float *btn     = _focused ? _btnActive     : _btnInactive;

    /* Gradient bands: linearly interpolate top→bottom */
    for (int i = 0; i < GRADIENT_BANDS; i++) {
        float t = (GRADIENT_BANDS > 1) ? (float)i / (float)(GRADIENT_BANDS - 1) : 0.f;
        float c[4] = {
            lerpf(gradTop[0], gradBot[0], t),
            lerpf(gradTop[1], gradBot[1], t),
            lerpf(gradTop[2], gradBot[2], t),
            lerpf(gradTop[3], gradBot[3], t),
        };
        wlr_scene_rect_set_color(_titleBands[i], c);
    }

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
    parseHexColor(dict[@"titlebarGradientTopColor"],        _gradTopActive);
    parseHexColor(dict[@"titlebarGradientBottomColor"],     _gradBotActive);
    parseHexColor(dict[@"titlebarInactiveTopColor"],        _gradTopInactive);
    parseHexColor(dict[@"titlebarInactiveBottomColor"],     _gradBotInactive);
    parseHexColor(dict[@"titlebarSeparatorColor"],          _separatorColor);
    parseHexColor(dict[@"windowBorderColor"],               _borderStroke);
    parseHexColor(dict[@"windowBodyColor"],                 _bodyFill);
    parseHexColor(dict[@"buttonActiveColor"],               _btnActive);
    parseHexColor(dict[@"buttonInactiveColor"],             _btnInactive);
    [self _applyColors];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Hit testing

- (AmbrosiaDecorationHit)hitTestX:(double)x y:(double)y
{
    /* x, y are frame-relative (top-left of decoration frame = origin) */
    int T      = AMBROSIA_TITLEBAR_HEIGHT;
    int B      = AMBROSIA_BORDER_WIDTH;
    int S      = AMBROSIA_BTN_SIZE;
    int PD     = AMBROSIA_BTN_PAD_SIDE;
    int PT     = AMBROSIA_BTN_PAD_TOP;
    int totalW = _surfaceWidth  + B * 2;
    int totalH = _surfaceHeight + T + B;
    int corner = 12;

    /* ---- Title bar (y 0 .. T) ---------------------------------------- */
    if (y >= 0 && y < T) {
        /* Resize from very top strip */
        if (y < B) {
            if (x < corner)        return AmbrosiaDecorationHitResizeTopLeft;
            if (x > totalW-corner) return AmbrosiaDecorationHitResizeTopRight;
            return AmbrosiaDecorationHitResizeTop;
        }

        /* Buttons — Milk layout: miniaturize LEFT, close RIGHT */
        int btn_y0 = PT - 3;
        int btn_y1 = PT + S + 3;
        if ((int)y >= btn_y0 && (int)y < btn_y1) {
            int minX   = PD;
            int closeX = totalW - PD - S;
            if (x >= minX-3   && x < minX+S+3)   return AmbrosiaDecorationHitMinimize;
            if (x >= closeX-3 && x < closeX+S+3) return AmbrosiaDecorationHitClose;
        }

        return AmbrosiaDecorationHitTitlebar;
    }

    /* ---- Below title bar: corners then edges -------------------------- */
    if (x < corner  && y > totalH - corner) return AmbrosiaDecorationHitResizeBottomLeft;
    if (x > totalW-corner && y > totalH-corner) return AmbrosiaDecorationHitResizeBottomRight;
    if (x < corner  && y < T + corner)  return AmbrosiaDecorationHitResizeTopLeft;
    if (x > totalW-corner && y < T+corner) return AmbrosiaDecorationHitResizeTopRight;

    if (y > totalH - B) return AmbrosiaDecorationHitResizeBottom;
    if (x < B)          return AmbrosiaDecorationHitResizeLeft;
    if (x > totalW - B) return AmbrosiaDecorationHitResizeRight;

    return AmbrosiaDecorationHitNone;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Class helpers

+ (NSEdgeInsets)frameInsets
{
    return NSEdgeInsetsMake(AMBROSIA_TITLEBAR_HEIGHT,
                            AMBROSIA_BORDER_WIDTH,
                            AMBROSIA_BORDER_WIDTH,
                            AMBROSIA_BORDER_WIDTH);
}

@end
