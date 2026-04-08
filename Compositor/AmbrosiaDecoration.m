#import "AmbrosiaDecoration.h"

#include <wlr/types/wlr_scene.h>
#include <math.h>

/* --------------------------------------------------------------------------
 * Colour helpers (RGBA floats)
 * -------------------------------------------------------------------------- */

static const float TITLEBAR_ACTIVE[4]   = { 0.22f, 0.22f, 0.25f, 0.96f };
static const float TITLEBAR_INACTIVE[4] = { 0.30f, 0.30f, 0.32f, 0.85f };
static const float BORDER_ACTIVE[4]     = { 0.18f, 0.18f, 0.22f, 0.96f };
static const float BORDER_INACTIVE[4]   = { 0.28f, 0.28f, 0.30f, 0.85f };
static const float BTN_CLOSE[4]         = { 0.90f, 0.32f, 0.32f, 1.00f };
static const float BTN_MINIMIZE[4]      = { 0.95f, 0.78f, 0.20f, 1.00f };
static const float BTN_MAXIMIZE[4]      = { 0.32f, 0.80f, 0.40f, 1.00f };
static const float BTN_INACTIVE[4]      = { 0.45f, 0.45f, 0.45f, 0.80f };

/* --------------------------------------------------------------------------
 * AmbrosiaDecoration
 *
 * All drawing is done with wlr_scene_rect — no custom wlr_buffer needed.
 * Layout (all coords relative to the decoration sub-tree origin):
 *
 *  ┌─────────────────────────────────┐  ← y=0, height=T  (title bar)
 *  │ ● ● ●  [title text – future]   │
 *  ├─────────────────────────────────┤  ← y=T
 *  │                                 │  surface content
 *  └─────────────────────────────────┘  ← y=T+H
 *
 * The decoration tree is positioned at (-B, -T) relative to the surface
 * scene tree so that the surface itself sits at (B, T) within the frame.
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaDecoration {
    struct wlr_scene_tree  *_parentTree;
    struct wlr_scene_tree  *_decorTree;

    /* Solid-colour rects */
    struct wlr_scene_rect  *_titleBar;       /* full-width title bar bg   */
    struct wlr_scene_rect  *_borderLeft;
    struct wlr_scene_rect  *_borderRight;
    struct wlr_scene_rect  *_borderBottom;

    /* Window-control button rects */
    struct wlr_scene_rect  *_btnClose;
    struct wlr_scene_rect  *_btnMinimize;
    struct wlr_scene_rect  *_btnMaximize;

    int     _surfaceWidth;
    int     _surfaceHeight;
}

@synthesize focused    = _focused;
@synthesize scene_tree = _decorTree;

- (instancetype)initWithRenderer:(struct wlr_renderer *)renderer
                       sceneTree:(struct wlr_scene_tree *)parentTree
{
    self = [super init];
    if (!self) return nil;

    _parentTree = parentTree;

    /* Decoration sub-tree — will be offset to (-B, -T) in -updateWith… */
    _decorTree = wlr_scene_tree_create(parentTree);

    /* Lower scene nodes first so they appear behind the surface */
    float dummy[4] = {0,0,0,0};

    _borderLeft   = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _borderRight  = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _borderBottom = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _titleBar     = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    /* Buttons */
    _btnClose    = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _btnMinimize = wlr_scene_rect_create(_decorTree, 1, 1, dummy);
    _btnMaximize = wlr_scene_rect_create(_decorTree, 1, 1, dummy);

    return self;
}

- (void)setFocused:(BOOL)focused
{
    _focused = focused;
    [self _applyColors];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Layout

- (void)updateWithWidth:(int)sw height:(int)sh title:(NSString *)title
{
    if (sw > 0) _surfaceWidth  = sw;
    if (sh > 0) _surfaceHeight = sh;

    int W = _surfaceWidth;
    int H = _surfaceHeight;
    int T = AMBROSIA_TITLEBAR_HEIGHT;
    int B = AMBROSIA_BORDER_WIDTH;
    int D = AMBROSIA_BUTTON_DIAMETER;
    int M = AMBROSIA_BUTTON_MARGIN;

    if (W <= 0 || H <= 0) return;

    int totalW = W + B * 2;
    int totalH = H + T + B;

    /* Shift decoration tree so surface origin stays at (B, T) in the view tree */
    wlr_scene_node_set_position(&_decorTree->node, -B, -T);

    /* Title bar — full width, top */
    wlr_scene_rect_set_size(_titleBar, totalW, T);
    wlr_scene_node_set_position(&_titleBar->node, 0, 0);

    /* Left border */
    wlr_scene_rect_set_size(_borderLeft, B, totalH);
    wlr_scene_node_set_position(&_borderLeft->node, 0, 0);

    /* Right border */
    wlr_scene_rect_set_size(_borderRight, B, totalH);
    wlr_scene_node_set_position(&_borderRight->node, totalW - B, 0);

    /* Bottom border */
    wlr_scene_rect_set_size(_borderBottom, totalW, B);
    wlr_scene_node_set_position(&_borderBottom->node, 0, totalH - B);

    /* Buttons — vertically centred in the title bar */
    int btn_y = (T - D) / 2;

    int close_x = M;
    int min_x   = close_x + D + M;
    int max_x   = min_x   + D + M;

    wlr_scene_rect_set_size(_btnClose,    D, D);
    wlr_scene_rect_set_size(_btnMinimize, D, D);
    wlr_scene_rect_set_size(_btnMaximize, D, D);

    wlr_scene_node_set_position(&_btnClose->node,    close_x, btn_y);
    wlr_scene_node_set_position(&_btnMinimize->node, min_x,   btn_y);
    wlr_scene_node_set_position(&_btnMaximize->node, max_x,   btn_y);

    [self _applyColors];
}

- (void)_applyColors
{
    const float *tbColor  = _focused ? TITLEBAR_ACTIVE   : TITLEBAR_INACTIVE;
    const float *bdColor  = _focused ? BORDER_ACTIVE     : BORDER_INACTIVE;

    wlr_scene_rect_set_color(_titleBar,     tbColor);
    wlr_scene_rect_set_color(_borderLeft,   bdColor);
    wlr_scene_rect_set_color(_borderRight,  bdColor);
    wlr_scene_rect_set_color(_borderBottom, bdColor);

    if (_focused) {
        wlr_scene_rect_set_color(_btnClose,    BTN_CLOSE);
        wlr_scene_rect_set_color(_btnMinimize, BTN_MINIMIZE);
        wlr_scene_rect_set_color(_btnMaximize, BTN_MAXIMIZE);
    } else {
        wlr_scene_rect_set_color(_btnClose,    BTN_INACTIVE);
        wlr_scene_rect_set_color(_btnMinimize, BTN_INACTIVE);
        wlr_scene_rect_set_color(_btnMaximize, BTN_INACTIVE);
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Hit testing

- (AmbrosiaDecorationHit)hitTestX:(double)x y:(double)y
{
    /* x, y are relative to the view's top-left = top-left of decoration frame */
    int T = AMBROSIA_TITLEBAR_HEIGHT;
    int B = AMBROSIA_BORDER_WIDTH;
    int D = AMBROSIA_BUTTON_DIAMETER;
    int M = AMBROSIA_BUTTON_MARGIN;
    int W = _surfaceWidth  + B * 2;
    int H = _surfaceHeight + T + B;

    int corner = 10;

    /* Corners */
    if (x < B + corner && y < T + corner)         return AmbrosiaDecorationHitResizeTopLeft;
    if (x > W-B-corner && y < T + corner)          return AmbrosiaDecorationHitResizeTopRight;
    if (x < B + corner && y > H-B-corner)          return AmbrosiaDecorationHitResizeBottomLeft;
    if (x > W-B-corner && y > H-B-corner)          return AmbrosiaDecorationHitResizeBottomRight;

    /* Edges */
    if (y < B)     return AmbrosiaDecorationHitResizeTop;
    if (y > H - B) return AmbrosiaDecorationHitResizeBottom;
    if (x < B)     return AmbrosiaDecorationHitResizeLeft;
    if (x > W - B) return AmbrosiaDecorationHitResizeRight;

    /* Title bar */
    if (y >= 0 && y < T) {
        /* Button hit zones (square, slightly padded) */
        int btn_y_min = (T - D) / 2 - 3;
        int btn_y_max = btn_y_min + D + 6;

        int close_x = M;
        int min_x   = close_x + D + M;
        int max_x   = min_x   + D + M;

        if (x >= close_x-3 && x < close_x+D+3 && y >= btn_y_min && y < btn_y_max)
            return AmbrosiaDecorationHitClose;
        if (x >= min_x-3   && x < min_x+D+3   && y >= btn_y_min && y < btn_y_max)
            return AmbrosiaDecorationHitMinimize;
        if (x >= max_x-3   && x < max_x+D+3   && y >= btn_y_min && y < btn_y_max)
            return AmbrosiaDecorationHitMaximize;

        return AmbrosiaDecorationHitTitlebar;
    }

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
