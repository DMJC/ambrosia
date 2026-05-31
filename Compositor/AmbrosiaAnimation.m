#import "AmbrosiaAnimation.h"

#include <wlr/types/wlr_buffer.h>
#include <wlr/util/log.h>
#include <math.h>

@interface AmbrosiaAnimation ()
- (void)_tick;
- (void)_updateFrame;
- (void)_destroyStrips;
@end

/* ---------------------------------------------------------------------- */
#pragma mark - C timer callback

typedef struct {
    struct wl_event_source *timer;
    void                   *objc_anim;  /* __bridge AmbrosiaAnimation * */
} MagicLampCtx;

static int magic_lamp_timer_cb(void *data)
{
    MagicLampCtx *ctx = data;
    AmbrosiaAnimation *anim = (__bridge AmbrosiaAnimation *)ctx->objc_anim;
    [anim _tick];
    return 0;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Easing + math helpers

static inline double ease_in_cubic(double t)
{
    return t * t * t;
}

static inline double ease_out_cubic(double t)
{
    double u = 1.0 - t;
    return 1.0 - u * u * u;
}

static inline double clamp01(double t)
{
    return t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
}

static inline double lerpd(double a, double b, double t)
{
    return a + (b - a) * t;
}

/* ---------------------------------------------------------------------- */
#pragma mark - AmbrosiaAnimation

@implementation AmbrosiaAnimation {
    MagicLampCtx            *_ctx;
    struct wlr_scene_buffer *_strips[MAGIC_LAMP_N_SLICES];
    int                      _nStrips;

    double                   _t;        /* animation progress: 0 → 1 */
    double                   _dt;       /* progress increment per tick  */
    BOOL                     _isMini;   /* YES = miniaturize, NO = demini */

    /* Content-area geometry (compositor-space) */
    int _wx, _wy, _ww, _wh;
    /* Dock target / source point */
    int _tx, _ty;

    /* Strip source heights for source-box computation */
    int _stripSrcH;
    int _lastStripSrcH;

    void(^_done)(void);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Strip creation

- (BOOL)_createStripsFromSurface:(struct wlr_surface *)surface
                     overlayTree:(struct wlr_scene_tree *)overlay
{
    if (!surface) return NO;

    struct wlr_buffer *buf = surface->current.buffer;
    if (!buf) return NO;

    int bw = surface->current.buffer_width;
    int bh = surface->current.buffer_height;
    if (bw <= 0) bw = _ww;
    if (bh <= 0) bh = _wh;
    if (_ww <= 0 || _wh <= 0) return NO;

    float scale_x = (float)bw / (float)_ww;
    float scale_y = (float)bh / (float)_wh;

    /* Compute per-strip surface-unit and buffer-unit heights */
    int strip_h_surf = (_wh + MAGIC_LAMP_N_SLICES - 1) / MAGIC_LAMP_N_SLICES;

    _stripSrcH     = strip_h_surf;
    _lastStripSrcH = _wh - (MAGIC_LAMP_N_SLICES - 1) * strip_h_surf;
    if (_lastStripSrcH <= 0) _lastStripSrcH = strip_h_surf;
    _nStrips = 0;

    for (int i = 0; i < MAGIC_LAMP_N_SLICES; i++) {
        int src_y_surf = i * strip_h_surf;
        int src_h_surf = (i == MAGIC_LAMP_N_SLICES - 1) ? _lastStripSrcH : strip_h_surf;
        if (src_y_surf >= _wh || src_h_surf <= 0) break;

        struct wlr_scene_buffer *sb = wlr_scene_buffer_create(overlay, buf);
        if (!sb) break;

        /* Source box in buffer-pixel coordinates */
        struct wlr_fbox sbox = {
            .x      = 0.0f,
            .y      = (float)src_y_surf * scale_y,
            .width  = (float)bw * scale_x / scale_x, /* full width = bw */
            .height = (float)src_h_surf * scale_y,
        };
        /* Correct: width = bw (full buffer width) */
        sbox.width = (float)bw;

        wlr_scene_buffer_set_source_box(sb, &sbox);
        /* Initial dest size = native surface dimensions */
        wlr_scene_buffer_set_dest_size(sb, _ww, src_h_surf);
        /* Initial position at the content area origin */
        wlr_scene_node_set_position(&sb->node, _wx, _wy + src_y_surf);

        _strips[i] = sb;
        _nStrips++;
    }

    return _nStrips > 0;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Initialisers

- (instancetype)initMiniaturizeWithSurface:(struct wlr_surface *)surface
                                  windowX:(int)wx windowY:(int)wy
                                  windowW:(int)ww windowH:(int)wh
                                   targetX:(int)tx targetY:(int)ty
                               overlayTree:(struct wlr_scene_tree *)overlay
                                 eventLoop:(struct wl_event_loop *)loop
                                completion:(void(^)(void))done
{
    self = [super init];
    if (!self) return nil;

    _wx = wx; _wy = wy; _ww = ww; _wh = wh;
    _tx = tx; _ty = ty;
    _isMini = YES;
    _t  = 0.0;
    _dt = (double)MAGIC_LAMP_INTERVAL / (double)MAGIC_LAMP_DURATION;
    _done = [done copy];

    if (![self _createStripsFromSurface:surface overlayTree:overlay]) {
        wlr_log(WLR_DEBUG, "magic-lamp: no surface buffer, skipping miniaturize animation");
        if (_done) { _done(); _done = nil; }
        return self;
    }

    _ctx = calloc(1, sizeof(MagicLampCtx));
    _ctx->objc_anim = (__bridge void *)self;
    _ctx->timer = wl_event_loop_add_timer(loop, magic_lamp_timer_cb, _ctx);
    wl_event_source_timer_update(_ctx->timer, MAGIC_LAMP_INTERVAL);
    return self;
}

- (instancetype)initDeminiaturizeWithSurface:(struct wlr_surface *)surface
                                    windowX:(int)wx windowY:(int)wy
                                    windowW:(int)ww windowH:(int)wh
                                     sourceX:(int)sx sourceY:(int)sy
                                 overlayTree:(struct wlr_scene_tree *)overlay
                                   eventLoop:(struct wl_event_loop *)loop
                                  completion:(void(^)(void))done
{
    self = [super init];
    if (!self) return nil;

    _wx = wx; _wy = wy; _ww = ww; _wh = wh;
    _tx = sx; _ty = sy;
    _isMini = NO;
    _t  = 0.0;
    _dt = (double)MAGIC_LAMP_INTERVAL / (double)MAGIC_LAMP_DURATION;
    _done = [done copy];

    if (![self _createStripsFromSurface:surface overlayTree:overlay]) {
        wlr_log(WLR_DEBUG, "magic-lamp: no surface buffer, skipping deminiaturize animation");
        if (_done) { _done(); _done = nil; }
        return self;
    }

    /* Position all strips collapsed at the dock source point */
    for (int i = 0; i < _nStrips; i++) {
        if (!_strips[i]) continue;
        wlr_scene_buffer_set_dest_size(_strips[i], MAGIC_LAMP_ICON_W, 1);
        wlr_scene_node_set_position(&_strips[i]->node,
                                    _tx - MAGIC_LAMP_ICON_W / 2, _ty);
        wlr_scene_buffer_set_opacity(_strips[i], 0.0f);
    }

    _ctx = calloc(1, sizeof(MagicLampCtx));
    _ctx->objc_anim = (__bridge void *)self;
    _ctx->timer = wl_event_loop_add_timer(loop, magic_lamp_timer_cb, _ctx);
    wl_event_source_timer_update(_ctx->timer, MAGIC_LAMP_INTERVAL);
    return self;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Animation tick

- (void)_tick
{
    _t += _dt;
    if (_t >= 1.0) {
        _t = 1.0;
        [self _updateFrame];
        [self _destroyStrips];
        if (_done) { _done(); _done = nil; }
        return;
    }
    [self _updateFrame];
    wl_event_source_timer_update(_ctx->timer, MAGIC_LAMP_INTERVAL);
}

- (void)_updateFrame
{
    double t = _t;

    /*
     * The bottom of the window is always "ahead" of the top.
     * For miniaturize: bottom collapses to dock first.
     * For deminiaturize: bottom expands from dock first.
     *
     * bottom_p tracks the progress of the window's bottom edge (0=window, 1=dock).
     * top_p    tracks the progress of the window's top edge, with a 40% lag.
     */
    double bottom_p, top_p;
    if (_isMini) {
        bottom_p = ease_in_cubic(t);
        top_p    = ease_in_cubic(clamp01((t - 0.40) / 0.60));
    } else {
        bottom_p = ease_out_cubic(t);
        top_p    = ease_out_cubic(clamp01((t - 0.40) / 0.60));
    }

    /*
     * Current window-content top and bottom y in compositor space.
     * Mini: window_pos → dock_y.   Demini: dock_y → window_pos.
     */
    double win_top_y, win_bot_y;
    if (_isMini) {
        win_top_y = lerpd((double)_wy,          (double)_ty, top_p);
        win_bot_y = lerpd((double)(_wy + _wh),  (double)_ty, bottom_p);
    } else {
        win_top_y = lerpd((double)_ty, (double)_wy,         top_p);
        win_bot_y = lerpd((double)_ty, (double)(_wy + _wh), bottom_p);
    }

    double total_h = win_bot_y - win_top_y;

    /* Opacity: full during main body; fade in/out at edges of animation */
    float opacity;
    if (_isMini) {
        opacity = (t < 0.75) ? 1.0f : (float)clamp01((1.0 - t) / 0.25);
    } else {
        opacity = (t > 0.25) ? 1.0f : (float)clamp01(t / 0.25);
    }

    double win_cx = (double)_wx + (double)_ww / 2.0;

    for (int i = 0; i < _nStrips; i++) {
        if (!_strips[i]) continue;

        /* Fractional centre position of this strip within the full window */
        double frac = ((double)i + 0.5) / (double)_nStrips;

        /* Interpolate between top_p and bottom_p for this strip's position */
        double strip_p = lerpd(top_p, bottom_p, frac);

        /* Width: narrows to ICON_W when going to dock, expands from it */
        double w;
        if (_isMini)
            w = lerpd((double)_ww, (double)MAGIC_LAMP_ICON_W, strip_p);
        else
            w = lerpd((double)MAGIC_LAMP_ICON_W, (double)_ww, strip_p);
        if (w < 1.0) w = 1.0;

        /* X: centre of strip drifts between window centre and dock centre */
        double cx;
        if (_isMini)
            cx = lerpd(win_cx, (double)_tx, strip_p);
        else
            cx = lerpd((double)_tx, win_cx, strip_p);

        /* Y: strip sits at its proportional position within current window bounds */
        double strip_top_frac = (double)i / (double)_nStrips;
        double dest_y = win_top_y + strip_top_frac * total_h;

        /* Height: compressed proportionally as the window squishes */
        int src_h = (i == _nStrips - 1) ? _lastStripSrcH : _stripSrcH;
        double dest_h = (total_h > 0.0)
            ? (total_h * (double)src_h / (double)_wh)
            : 0.0;
        if (dest_h < 1.0) dest_h = 1.0;

        wlr_scene_buffer_set_dest_size(_strips[i],
                                       (int)round(w),
                                       (int)round(dest_h));
        wlr_scene_node_set_position(&_strips[i]->node,
                                    (int)round(cx - w / 2.0),
                                    (int)round(dest_y));
        wlr_scene_buffer_set_opacity(_strips[i], opacity);
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Cleanup

- (void)_destroyStrips
{
    for (int i = 0; i < MAGIC_LAMP_N_SLICES; i++) {
        if (_strips[i]) {
            wlr_scene_node_destroy(&_strips[i]->node);
            _strips[i] = NULL;
        }
    }
    _nStrips = 0;

    if (_ctx) {
        if (_ctx->timer) wl_event_source_remove(_ctx->timer);
        free(_ctx);
        _ctx = NULL;
    }
}

- (void)cancel
{
    [self _destroyStrips];
    _done = nil;
}

- (void)dealloc
{
    [self _destroyStrips];
}

@end
