#import "AmbrosiaXWaylandView.h"
#import "AmbrosiaCompositor.h"
#import "AmbrosiaDecoration.h"

#include <wlr/types/wlr_compositor.h>
#include <wlr/util/log.h>
#include <stdlib.h>
#include <string.h>

/* --------------------------------------------------------------------------
 * C-level listener callbacks
 * -------------------------------------------------------------------------- */

static void handle_xw_associate(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, associate);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleAssociate];
}

static void handle_xw_dissociate(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, dissociate);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleDissociate];
}

static void handle_xw_surface_map(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, surface_map);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleMap];
}

static void handle_xw_surface_unmap(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, surface_unmap);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleUnmap];
}

static void handle_xw_destroy(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, destroy);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleDestroy];
}

static void handle_xw_request_configure(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, request_configure);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view
        handleRequestConfigure:(struct wlr_xwayland_surface_configure_event *)data];
}

static void handle_xw_request_move(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, request_move);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleRequestMove];
}

static void handle_xw_request_resize(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, request_resize);
    struct wlr_xwayland_resize_event *event = data;
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleRequestResize:event->edges];
}

static void handle_xw_request_minimize(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, request_minimize);
    struct wlr_xwayland_minimize_event *event = data;
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleRequestMinimize:event->minimize];
}

static void handle_xw_request_fullscreen(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, request_fullscreen);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleRequestFullscreen];
}

static void handle_xw_request_activate(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, request_activate);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleRequestActivate];
}

static void handle_xw_request_close(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, request_close);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleRequestClose];
}

static void handle_xw_set_title(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, set_title);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleSetTitle];
}

static void handle_xw_set_class(struct wl_listener *listener, void *data)
{
    /* class change treated same as title for logging */
    (void)listener; (void)data;
}

static void handle_xw_set_override_redirect(struct wl_listener *listener, void *data)
{
    struct ambrosia_xwayland_view_state *s =
        wl_container_of(listener, s, set_override_redirect);
    [(__bridge AmbrosiaXWaylandView *)s->objc_view handleSetOverrideRedirect];
}

/* --------------------------------------------------------------------------
 * Helpers
 * -------------------------------------------------------------------------- */

static BOOL isOverrideRedirect(struct wlr_xwayland_surface *xs)
{
    return xs->override_redirect ? YES : NO;
}

/* --------------------------------------------------------------------------
 * AmbrosiaXWaylandView
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaXWaylandView {
    struct ambrosia_xwayland_view_state *_state;
    BOOL  _isMapped;
    BOOL  _isMiniaturized;
    BOOL  _isFullscreen;
    BOOL  _isMenu;
    BOOL  _isDockWindow;
    BOOL  _isDesktopBackground;
    int   _restoreX;
    int   _restoreY;
    int   _restoreFSX;
    int   _restoreFSY;
    uint16_t _restoreFSW;
    uint16_t _restoreFSH;
}

@synthesize compositor          = _compositor;
@synthesize decoration          = _decoration;
@synthesize x                   = _x;
@synthesize y                   = _y;
@synthesize isMapped            = _isMapped;
@synthesize isMiniaturized      = _isMiniaturized;
@synthesize isFullscreen        = _isFullscreen;
@synthesize isMenu              = _isMenu;
@synthesize isDockWindow        = _isDockWindow;
@synthesize isDesktopBackground = _isDesktopBackground;

- (instancetype)initWithXWaylandSurface:(struct wlr_xwayland_surface *)xsurface
                             compositor:(AmbrosiaCompositor *)compositor
{
    self = [super init];
    if (!self) return nil;

    _compositor = compositor;
    _state = calloc(1, sizeof(*_state));
    if (!_state) return nil;

    _state->xwayland_surface = xsurface;
    _state->objc_view        = (__bridge void *)self;

    _isMenu = isOverrideRedirect(xsurface);

    /* xwayland_surface-level listeners */
    _state->associate.notify = handle_xw_associate;
    wl_signal_add(&xsurface->events.associate, &_state->associate);

    _state->dissociate.notify = handle_xw_dissociate;
    wl_signal_add(&xsurface->events.dissociate, &_state->dissociate);

    _state->request_configure.notify = handle_xw_request_configure;
    wl_signal_add(&xsurface->events.request_configure, &_state->request_configure);

    _state->request_move.notify = handle_xw_request_move;
    wl_signal_add(&xsurface->events.request_move, &_state->request_move);

    _state->request_resize.notify = handle_xw_request_resize;
    wl_signal_add(&xsurface->events.request_resize, &_state->request_resize);

    _state->request_minimize.notify = handle_xw_request_minimize;
    wl_signal_add(&xsurface->events.request_minimize, &_state->request_minimize);

    _state->request_fullscreen.notify = handle_xw_request_fullscreen;
    wl_signal_add(&xsurface->events.request_fullscreen, &_state->request_fullscreen);

    _state->request_activate.notify = handle_xw_request_activate;
    wl_signal_add(&xsurface->events.request_activate, &_state->request_activate);

    _state->request_close.notify = handle_xw_request_close;
    wl_signal_add(&xsurface->events.request_close, &_state->request_close);

    _state->set_title.notify = handle_xw_set_title;
    wl_signal_add(&xsurface->events.set_title, &_state->set_title);

    _state->set_class.notify = handle_xw_set_class;
    wl_signal_add(&xsurface->events.set_class, &_state->set_class);

    _state->set_override_redirect.notify = handle_xw_set_override_redirect;
    wl_signal_add(&xsurface->events.set_override_redirect, &_state->set_override_redirect);

    _state->destroy.notify = handle_xw_destroy;
    wl_signal_add(&xsurface->events.destroy, &_state->destroy);

    return self;
}

- (struct ambrosia_xwayland_view_state *)state { return _state; }

- (void)dealloc
{
    /* handleDestroy should have already cleaned up; this is a safety net. */
    if (_state) {
        if (_state->surface_listeners_active) {
            wl_list_remove(&_state->surface_map.link);
            wl_list_remove(&_state->surface_unmap.link);
        }
        if (_state->scene_tree) {
            wlr_scene_node_destroy(&_state->scene_tree->node);
        }
        wl_list_remove(&_state->associate.link);
        wl_list_remove(&_state->dissociate.link);
        wl_list_remove(&_state->request_configure.link);
        wl_list_remove(&_state->request_move.link);
        wl_list_remove(&_state->request_resize.link);
        wl_list_remove(&_state->request_minimize.link);
        wl_list_remove(&_state->request_fullscreen.link);
        wl_list_remove(&_state->request_activate.link);
        wl_list_remove(&_state->request_close.link);
        wl_list_remove(&_state->set_title.link);
        wl_list_remove(&_state->set_class.link);
        wl_list_remove(&_state->set_override_redirect.link);
        wl_list_remove(&_state->destroy.link);
        free(_state);
        _state = NULL;
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - AmbrosiaWindowView protocol

- (struct wlr_surface *)surface
{
    if (!_state) return NULL;
    return _state->xwayland_surface->surface;
}

- (struct wlr_box)geometry
{
    struct wlr_box box = { 0, 0, 0, 0 };
    if (_state) {
        box.width  = _state->xwayland_surface->width;
        box.height = _state->xwayland_surface->height;
    }
    return box;
}

- (void)moveTo:(int)x y:(int)y
{
    _x = x;
    _y = y;
    if (_state->scene_tree) {
        wlr_scene_node_set_position(&_state->scene_tree->node, x, y);
    }
    /* Sync X11 window position for managed windows. */
    if (!_isMenu) {
        struct wlr_xwayland_surface *xs = _state->xwayland_surface;
        wlr_xwayland_surface_configure(xs,
            (int16_t)x, (int16_t)y, xs->width, xs->height);
    }
}

- (void)miniaturize
{
    if (_isMiniaturized) return;
    _isMiniaturized = YES;
    if (_state->scene_tree) {
        wlr_scene_node_set_enabled(&_state->scene_tree->node, false);
    }
    wlr_xwayland_surface_set_minimized(_state->xwayland_surface, true);
}

- (void)deminiaturize
{
    if (!_isMiniaturized) return;
    _isMiniaturized = NO;
    if (_state->scene_tree) {
        wlr_scene_node_set_enabled(&_state->scene_tree->node, true);
    }
    wlr_xwayland_surface_set_minimized(_state->xwayland_surface, false);
}

- (void)updateTitle
{
    if (!_decoration) return;
    struct wlr_box geo = [self geometry];
    const char *raw = _state->xwayland_surface->title;
    NSString *title = raw ? [NSString stringWithUTF8String:raw] : @"";
    [_decoration updateWithWidth:geo.width height:geo.height title:title];
}

- (void)activateFocus:(BOOL)focused
{
    if (focused) {
        wlr_xwayland_surface_activate(_state->xwayland_surface, true);
        wlr_xwayland_surface_offer_focus(_state->xwayland_surface);
    } else {
        wlr_xwayland_surface_activate(_state->xwayland_surface, false);
    }
}

- (void)close
{
    wlr_xwayland_surface_close(_state->xwayland_surface);
}

- (void)raiseSceneNode
{
    if (_state->scene_tree) {
        wlr_scene_node_raise_to_top(&_state->scene_tree->node);
    }
}

- (struct wlr_surface *)surfaceAt:(double)x y:(double)y
                          localX:(double *)lx localY:(double *)ly
{
    struct wlr_surface *surf = _state->xwayland_surface->surface;
    if (!surf) return NULL;

    double view_sx = x - _x;
    double view_sy = y - _y;
    double sx = 0, sy = 0;
    struct wlr_surface *found =
        wlr_surface_surface_at(surf, view_sx, view_sy, &sx, &sy);
    if (found) {
        if (lx) *lx = sx;
        if (ly) *ly = sy;
    }
    return found;
}

- (struct wl_client *)waylandClient
{
    struct wlr_surface *surf = _state->xwayland_surface->surface;
    if (!surf) return NULL;
    return wl_resource_get_client(surf->resource);
}

- (pid_t)clientPid
{
    return _state->xwayland_surface->pid;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Lifecycle callbacks

- (void)handleAssociate
{
    struct wlr_xwayland_surface *xs = _state->xwayland_surface;
    wlr_log(WLR_DEBUG, "XWayland associate: title='%s' class='%s'",
            xs->title ?: "(nil)", xs->class ?: "(nil)");

    /* If fullscreen was requested before the surface was associated (e.g. the
     * client set _NET_WM_STATE_FULLSCREEN at window creation time), put the
     * scene tree directly into the fullscreen layer so it's above the menu bar
     * as soon as it becomes visible.                                           */
    struct wlr_scene_tree *layer = _isFullscreen
        ? _compositor.state->scene_layer_fullscreen
        : _compositor.state->scene_layer_windows;

    _state->scene_tree = wlr_scene_tree_create(layer);
    _state->scene_tree->node.data = (__bridge void *)self;
    wlr_scene_surface_create(_state->scene_tree, xs->surface);

    /* Register surface-level map/unmap listeners. */
    _state->surface_map.notify = handle_xw_surface_map;
    wl_signal_add(&xs->surface->events.map, &_state->surface_map);

    _state->surface_unmap.notify = handle_xw_surface_unmap;
    wl_signal_add(&xs->surface->events.unmap, &_state->surface_unmap);

    _state->surface_listeners_active = YES;
}

- (void)handleDissociate
{
    wlr_log(WLR_DEBUG, "XWayland dissociate: title='%s'",
            _state->xwayland_surface->title ?: "(nil)");

    if (_state->surface_listeners_active) {
        wl_list_remove(&_state->surface_map.link);
        wl_list_remove(&_state->surface_unmap.link);
        _state->surface_listeners_active = NO;
    }
    if (_state->scene_tree) {
        wlr_scene_node_destroy(&_state->scene_tree->node);
        _state->scene_tree = NULL;
    }
}

/* Returns YES if this override-redirect window covers an entire output —
 * the SDL1.x / older-engine idiom for fullscreen (no _NET_WM_STATE_FULLSCREEN). */
- (BOOL)_coversEntireOutput
{
    struct wlr_xwayland_surface *xs = _state->xwayland_surface;
    struct wlr_output_layout *layout = _compositor.state->output_layout;
    struct wlr_output *out = wlr_output_layout_output_at(layout, xs->x, xs->y);
    if (!out)
        out = wlr_output_layout_get_center_output(layout);
    if (!out) return NO;
    struct wlr_box ob = {0};
    wlr_output_layout_get_box(layout, out, &ob);
    return (xs->x == ob.x && xs->y == ob.y &&
            xs->width  == (uint16_t)ob.width &&
            xs->height == (uint16_t)ob.height);
}

- (void)handleMap
{
    _isMapped = YES;

    struct wlr_xwayland_surface *xs = _state->xwayland_surface;
    _isMenu = isOverrideRedirect(xs);

    wlr_log(WLR_INFO, "XWayland map: title='%s' class='%s' OR=%d fullscreen=%d",
            xs->title ?: "(nil)", xs->class ?: "(nil)",
            xs->override_redirect, xs->fullscreen);

    if (_isMenu) {
        /* Override-redirect: honour the X11-requested position. */
        [self moveTo:xs->x y:xs->y];

        /* SDL1.x / old engines use OR windows that cover the whole output for
         * fullscreen without setting _NET_WM_STATE_FULLSCREEN.  Detect by
         * comparing the window geometry against the output it landed on.      */
        if (!_isFullscreen && (xs->fullscreen || [self _coversEntireOutput])) {
            if (_state->scene_tree)
                wlr_scene_node_reparent(&_state->scene_tree->node,
                                        _compositor.state->scene_layer_fullscreen);
            _isFullscreen = YES;
        }
        return;
    }

    /* Managed window — if fullscreen was already entered (request_fullscreen
     * fired before map) just focus and return; do not override the position
     * that _setFullscreen:YES already established.                            */
    if (_isFullscreen) {
        [_compositor focusView:self surface:self.surface];
        return;
    }

    /* If the client has _NET_WM_STATE_FULLSCREEN set at map time (e.g. SDL2
     * window created with SDL_WINDOW_FULLSCREEN) enter fullscreen now.        */
    if (xs->fullscreen) {
        [self _setFullscreen:YES];
        [_compositor focusView:self surface:self.surface];
        return;
    }

    /* Normal managed window: cascade below the menu bar. */
    static int cascade = 0;
    int usableTop = _compositor.state->usable_top;
    int startX = 60  + cascade * 30;
    int startY = MAX(usableTop + 8, 50) + cascade * 30;
    cascade = (cascade + 1) % 8;
    [self moveTo:startX y:startY];

    [_compositor focusView:self surface:self.surface];
}

- (void)handleUnmap
{
    _isMapped = NO;
    if (_compositor.focusedView == self) {
        [_compositor focusNextWindowExcluding:self];
    }
}

- (void)handleDestroy
{
    wlr_log(WLR_DEBUG, "XWayland destroy: title='%s'",
            _state ? (_state->xwayland_surface->title ?: "(nil)") : "?");

    if (_state) {
        /* Remove surface listeners first if still active. */
        if (_state->surface_listeners_active) {
            wl_list_remove(&_state->surface_map.link);
            wl_list_remove(&_state->surface_unmap.link);
            _state->surface_listeners_active = NO;
        }
        if (_state->scene_tree) {
            wlr_scene_node_destroy(&_state->scene_tree->node);
            _state->scene_tree = NULL;
        }
        /* Remove all xwayland_surface-level listeners. */
        wl_list_remove(&_state->associate.link);
        wl_list_remove(&_state->dissociate.link);
        wl_list_remove(&_state->request_configure.link);
        wl_list_remove(&_state->request_move.link);
        wl_list_remove(&_state->request_resize.link);
        wl_list_remove(&_state->request_minimize.link);
        wl_list_remove(&_state->request_fullscreen.link);
        wl_list_remove(&_state->request_activate.link);
        wl_list_remove(&_state->request_close.link);
        wl_list_remove(&_state->set_title.link);
        wl_list_remove(&_state->set_class.link);
        wl_list_remove(&_state->set_override_redirect.link);
        wl_list_remove(&_state->destroy.link);
        free(_state);
        _state = NULL;
    }
    [_compositor removeView:self];
}

- (void)handleRequestConfigure:(struct wlr_xwayland_surface_configure_event *)event
{
    /* Override-redirect windows and not-yet-mapped non-fullscreen windows:
     * honour the request verbatim so the client controls its own position.
     * Exception: if the window is already fullscreen (request came in before
     * map), keep the fullscreen position so we don't override it.            */
    if (_isMenu || (!_isMapped && !_isFullscreen)) {
        wlr_xwayland_surface_configure(event->surface,
                                       event->x, event->y,
                                       event->width, event->height);
        if (_state->scene_tree)
            wlr_scene_node_set_position(&_state->scene_tree->node, event->x, event->y);
        _x = event->x;
        _y = event->y;
        return;
    }
    /* Managed window (mapped or fullscreen): honour the requested size but
     * keep our compositor-assigned position.                                 */
    wlr_xwayland_surface_configure(event->surface,
                                   (int16_t)_x, (int16_t)_y,
                                   event->width, event->height);
}

- (void)handleRequestMove
{
    if (_isMenu) return;
    [_compositor beginMoveView:self cursor:_compositor.state->cursor];
}

- (void)handleRequestResize:(uint32_t)edges
{
    if (_isMenu) return;
    [_compositor beginResizeView:self cursor:_compositor.state->cursor edges:edges];
}

- (void)handleRequestMinimize:(BOOL)minimize
{
    if (minimize) {
        [self miniaturize];
        [_compositor focusNextWindowExcluding:self];
    } else {
        [self deminiaturize];
        [_compositor focusView:self surface:self.surface];
    }
}

- (void)_setFullscreen:(BOOL)fullscreen
{
    if (fullscreen == _isFullscreen) return;

    struct ambrosia_compositor_state *cs = _compositor.state;
    struct wlr_xwayland_surface *xs = _state->xwayland_surface;

    if (fullscreen) {
        _restoreFSX = _x;
        _restoreFSY = _y;
        _restoreFSW = xs->width;
        _restoreFSH = xs->height;

        /* Find the output this window is on (or will appear on if not yet mapped). */
        struct wlr_output *output =
            wlr_output_layout_output_at(cs->output_layout, _x + 100, _y + 100);
        if (!output)
            output = wlr_output_layout_get_center_output(cs->output_layout);
        if (!output) return;

        struct wlr_box ob = {0};
        wlr_output_layout_get_box(cs->output_layout, output, &ob);

        /* Move to the fullscreen scene layer (above the menu bar). */
        if (_state->scene_tree)
            wlr_scene_node_reparent(&_state->scene_tree->node, cs->scene_layer_fullscreen);
        if (_decoration)
            wlr_scene_node_set_enabled(&_decoration.scene_tree->node, false);

        wlr_xwayland_surface_set_fullscreen(xs, true);
        wlr_xwayland_surface_configure(xs,
            (int16_t)ob.x, (int16_t)ob.y,
            (uint16_t)ob.width, (uint16_t)ob.height);
        _x = ob.x;
        _y = ob.y;
        if (_state->scene_tree)
            wlr_scene_node_set_position(&_state->scene_tree->node, ob.x, ob.y);
        _isFullscreen = YES;
    } else {
        if (_state->scene_tree)
            wlr_scene_node_reparent(&_state->scene_tree->node, cs->scene_layer_windows);
        if (_decoration)
            wlr_scene_node_set_enabled(&_decoration.scene_tree->node, true);

        wlr_xwayland_surface_set_fullscreen(xs, false);
        _isFullscreen = NO;

        /* Restore the pre-fullscreen size and position. */
        _x = _restoreFSX;
        _y = _restoreFSY;
        wlr_xwayland_surface_configure(xs,
            (int16_t)_restoreFSX, (int16_t)_restoreFSY,
            _restoreFSW, _restoreFSH);
        if (_state->scene_tree)
            wlr_scene_node_set_position(&_state->scene_tree->node,
                                        _restoreFSX, _restoreFSY);
    }
}

- (void)handleRequestFullscreen
{
    /* Do not drop pre-map fullscreen requests — _setFullscreen: is safe to call
     * before the window is mapped (scene_tree guards handle the NULL case).   */
    if (_isMenu) return;
    [self _setFullscreen:_state->xwayland_surface->fullscreen];
}

- (void)toggleFullscreen
{
    [self _setFullscreen:!_isFullscreen];
}

- (void)handleRequestActivate
{
    if (_isMapped && !_isMenu) {
        [_compositor focusView:self surface:self.surface];
    }
}

- (void)handleRequestClose
{
    [self close];
}

- (void)handleSetTitle
{
    [self updateTitle];
}

- (void)handleSetOverrideRedirect
{
    _isMenu = isOverrideRedirect(_state->xwayland_surface);
}

@end
