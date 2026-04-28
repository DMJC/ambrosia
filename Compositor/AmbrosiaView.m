#import "AmbrosiaView.h"
#import "AmbrosiaCompositor.h"
#import "AmbrosiaDecoration.h"

#include <wlr/util/log.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <string.h>
#include <stdlib.h>

/* --------------------------------------------------------------------------
 * C callbacks
 * -------------------------------------------------------------------------- */

/* wlroots 0.18+ requires the compositor to send the initial xdg_surface
 * configure in response to the surface's first commit (initial_commit).
 * Without this the surface stays unconfigured and never becomes visible.  */
static void handle_surface_commit(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, surface_commit);
    struct wlr_xdg_surface *xdg = s->xdg_toplevel->base;
    if (xdg->initial_commit) {
        wlr_xdg_surface_schedule_configure(xdg);
    }
}

static void handle_view_map(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, map);
    [(__bridge AmbrosiaView *)s->objc_view handleMap];
}

static void handle_view_unmap(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, unmap);
    [(__bridge AmbrosiaView *)s->objc_view handleUnmap];
}

static void handle_view_destroy(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, destroy);
    [(__bridge AmbrosiaView *)s->objc_view handleDestroy];
}

static void handle_view_request_move(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, request_move);
    struct wlr_xdg_toplevel_move_event *event = data;
    [(__bridge AmbrosiaView *)s->objc_view handleRequestMoveSerial:event->serial];
}

static void handle_view_request_resize(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, request_resize);
    struct wlr_xdg_toplevel_resize_event *event = data;
    [(__bridge AmbrosiaView *)s->objc_view handleRequestResizeSerial:event->serial
                                                               edges:event->edges];
}

static void handle_view_request_maximize(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, request_maximize);
    [(__bridge AmbrosiaView *)s->objc_view handleRequestMaximize];
}

static void handle_view_request_fullscreen(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, request_fullscreen);
    [(__bridge AmbrosiaView *)s->objc_view handleRequestFullscreen];
}

static void handle_view_set_title(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, set_title);
    [(__bridge AmbrosiaView *)s->objc_view handleSetTitle];
}

static void handle_view_set_app_id(struct wl_listener *listener, void *data)
{
    struct ambrosia_view_state *s = wl_container_of(listener, s, set_app_id);
    [(__bridge AmbrosiaView *)s->objc_view handleSetAppId];
}

/* --------------------------------------------------------------------------
 * Helpers
 * -------------------------------------------------------------------------- */

/**
 * Determine if a toplevel is a GNUstep menu and should not receive decorations.
 * GNUstep menus are sent as xdg_popups in modern gnustep-back, but in some
 * configurations they arrive as toplevels with recognisable app_id / title patterns.
 */
static BOOL isMenuToplevel(struct wlr_xdg_toplevel *toplevel)
{
    const char *app_id = toplevel->app_id;
    const char *title  = toplevel->title;

    if (app_id) {
        /* gnustep-back sets app_id to "org.gnustep.NSMenu" for menu windows */
        if (strstr(app_id, "NSMenu")   != NULL) return YES;
        if (strstr(app_id, "GNUstepMenu") != NULL) return YES;
    }
    if (title) {
        if (strncmp(title, "NSMenu", 6) == 0)    return YES;
        if (strcmp(title,  "MainMenu") == 0)      return YES;
    }
    return NO;
}

/**
 * Returns YES if this toplevel is the AmbrosiaDock — also no decorations.
 * We check both app_id and title because gnustep-back may not call
 * xdg_toplevel_set_app_id on all platforms / build configurations.
 */
static BOOL isDock(struct wlr_xdg_toplevel *toplevel)
{
    const char *app_id = toplevel->app_id;
    const char *title  = toplevel->title;
    if (app_id && strstr(app_id, "AmbrosiaDock") != NULL) return YES;
    if (title  && strstr(title,  "AmbrosiaDock") != NULL) return YES;
    return NO;
}

/**
 * Returns YES if this toplevel is a full-screen desktop background window
 * (e.g. GFinder / GWorkspace workspace manager).  These get no decoration
 * and are lowered behind all other windows.
 */
static BOOL isDesktopToplevel(struct wlr_xdg_toplevel *toplevel)
{
    const char *app_id = toplevel->app_id;
    const char *title  = toplevel->title;
    if (app_id) {
        if (strstr(app_id, "GFinder")    != NULL) goto check_title;
        if (strstr(app_id, "GWorkspace") != NULL) goto check_title;
    }
    return NO;
check_title:
    /* Desktop background windows have no title or a blank title.
     * Regular file-browser windows will have a non-empty path title. */
    if (!title || title[0] == '\0') return YES;
    if (strcmp(title, "Desktop") == 0) return YES;
    return NO;
}

/* --------------------------------------------------------------------------
 * AmbrosiaView
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaView {
    struct ambrosia_view_state *_state;
    BOOL _isMapped;
    BOOL _isMiniaturized;
    BOOL _isFullscreen;
    BOOL _isMenu;
    BOOL _isDockWindow;
    BOOL _isDesktopBackground;

    /* Pre-maximize restore position (surface origin, compositor space) */
    int  _restoreX;
    int  _restoreY;

    /* Pre-fullscreen restore position */
    int  _restoreFSX;
    int  _restoreFSY;
}

@synthesize state               = _state;
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

- (instancetype)initWithToplevel:(struct wlr_xdg_toplevel *)toplevel
                      compositor:(AmbrosiaCompositor *)compositor
{
    self = [super init];
    if (!self) return nil;

    _compositor = compositor;
    _state = calloc(1, sizeof(struct ambrosia_view_state));
    if (!_state) return nil;

    _state->xdg_toplevel = toplevel;
    _state->objc_view    = (__bridge void *)self;

    /* Create scene tree for this view inside scene_layer_windows.
     * This sub-tree sits below scene_layer_top in z-order, so windows
     * can never render above the menu bar regardless of raise calls.  */
    _state->scene_tree = wlr_scene_xdg_surface_create(
        compositor.state->scene_layer_windows,
        toplevel->base);
    _state->scene_tree->node.data = (__bridge void *)self;
    toplevel->base->data = _state->scene_tree;

    /* Classify window role (may be refined again in handleMap once app_id/title arrive) */
    _isDockWindow        = isDock(toplevel);
    _isDesktopBackground = isDesktopToplevel(toplevel);
    _isMenu              = isMenuToplevel(toplevel) || _isDockWindow || _isDesktopBackground;

    /* Register listeners */
    _state->surface_commit.notify = handle_surface_commit;
    wl_signal_add(&toplevel->base->surface->events.commit, &_state->surface_commit);

    _state->map.notify = handle_view_map;
    wl_signal_add(&toplevel->base->surface->events.map, &_state->map);

    _state->unmap.notify = handle_view_unmap;
    wl_signal_add(&toplevel->base->surface->events.unmap, &_state->unmap);

    _state->destroy.notify = handle_view_destroy;
    wl_signal_add(&toplevel->events.destroy, &_state->destroy);

    _state->request_move.notify = handle_view_request_move;
    wl_signal_add(&toplevel->events.request_move, &_state->request_move);

    _state->request_resize.notify = handle_view_request_resize;
    wl_signal_add(&toplevel->events.request_resize, &_state->request_resize);

    _state->request_maximize.notify = handle_view_request_maximize;
    wl_signal_add(&toplevel->events.request_maximize, &_state->request_maximize);

    _state->request_fullscreen.notify = handle_view_request_fullscreen;
    wl_signal_add(&toplevel->events.request_fullscreen, &_state->request_fullscreen);

    _state->set_title.notify = handle_view_set_title;
    wl_signal_add(&toplevel->events.set_title, &_state->set_title);

    _state->set_app_id.notify = handle_view_set_app_id;
    wl_signal_add(&toplevel->events.set_app_id, &_state->set_app_id);

    return self;
}

- (void)dealloc
{
    if (_state) {
        wl_list_remove(&_state->surface_commit.link);
        wl_list_remove(&_state->map.link);
        wl_list_remove(&_state->unmap.link);
        wl_list_remove(&_state->destroy.link);
        wl_list_remove(&_state->request_move.link);
        wl_list_remove(&_state->request_resize.link);
        wl_list_remove(&_state->request_maximize.link);
        wl_list_remove(&_state->request_fullscreen.link);
        wl_list_remove(&_state->set_title.link);
        wl_list_remove(&_state->set_app_id.link);
        free(_state);
        _state = NULL;
    }
}

- (struct wlr_surface *)surface
{
    return _state->xdg_toplevel->base->surface;
}

- (struct wlr_box)geometry
{
    /* wlroots 0.18+ exposes geometry as a direct field */
    return _state->xdg_toplevel->base->geometry;
}

- (void)moveTo:(int)x y:(int)y
{
    _x = x;
    _y = y;
    wlr_scene_node_set_position(&_state->scene_tree->node, x, y);
}

- (void)updateTitle
{
    if (!_decoration) return;
    struct wlr_box geo = [self geometry];
    NSString *title = _state->xdg_toplevel->title
        ? [NSString stringWithUTF8String:_state->xdg_toplevel->title]
        : @"";
    [_decoration updateWithWidth:geo.width height:geo.height title:title];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Event handlers

- (void)handleMap
{
    _isMapped = YES;

    /* Re-classify now that app_id/title are guaranteed to be set */
    _isDockWindow        = isDock(_state->xdg_toplevel);
    _isDesktopBackground = isDesktopToplevel(_state->xdg_toplevel);
    _isMenu              = isMenuToplevel(_state->xdg_toplevel) || _isDockWindow || _isDesktopBackground;

    wlr_log(WLR_INFO, "map: title='%s' app_id='%s' role=%s",
            _state->xdg_toplevel->title  ?: "(nil)",
            _state->xdg_toplevel->app_id ?: "(nil)",
            _isDesktopBackground ? "desktop" : _isDockWindow ? "dock"
                                 : _isMenu   ? "menu"        : "normal");

    /* ---- Desktop background ---- */
    if (_isDesktopBackground) {
        struct wlr_output *output =
            wlr_output_layout_get_center_output(_compositor.state->output_layout);
        struct wlr_box ob = {0};
        if (output) wlr_output_layout_get_box(_compositor.state->output_layout, output, &ob);
        [self moveTo:ob.x y:ob.y];
        wlr_scene_node_lower_to_bottom(&_state->scene_tree->node);
        /* Desktop never steals keyboard focus */
        return;
    }

    /* ---- Dock ---- */
    if (_isDockWindow) {
        struct wlr_output *output =
            wlr_output_layout_get_center_output(_compositor.state->output_layout);
        struct wlr_box ob = {0};
        if (output) wlr_output_layout_get_box(_compositor.state->output_layout, output, &ob);
        struct wlr_box geo = [self geometry];
        int dockW = geo.width  > 0 ? geo.width  : ob.width;
        int dockH = geo.height > 0 ? geo.height : 64;
        const char *dockPosEnv = getenv("AMBROSIA_DOCK_POSITION");
        const char *dockXEnv   = getenv("AMBROSIA_DOCK_X");
        const char *dockYEnv   = getenv("AMBROSIA_DOCK_Y");

        int anchorX = dockXEnv ? (int)strtol(dockXEnv, NULL, 10) : (ob.width / 2);
        int anchorY = dockYEnv ? (int)strtol(dockYEnv, NULL, 10) : 0;
        NSString *dockPos = dockPosEnv
            ? [NSString stringWithUTF8String:dockPosEnv]
            : @"bottom";

        int dockX = ob.x + anchorX - dockW / 2;
        int dockY = ob.y + anchorY;
        if ([dockPos isEqualToString:@"left"]) {
            dockX = ob.x + anchorX;
            dockY = ob.y + anchorY - dockH / 2;
        } else if ([dockPos isEqualToString:@"right"]) {
            dockX = ob.x + anchorX - dockW;
            dockY = ob.y + anchorY - dockH / 2;
        }
        [self moveTo:dockX y:dockY];
        /* Dock does not steal keyboard focus on map */
        return;
    }

    /* ---- Menu toplevels ---- */
    if (_isMenu) {
        /* Place at the top-left of the primary output.  GNUstep will follow up
         * with request_move events to reach its desired screen position.
         * Menus must NOT steal keyboard focus from the application window —
         * the seat keyboard focus stays with the previously active toplevel. */
        struct wlr_output *output =
            wlr_output_layout_get_center_output(_compositor.state->output_layout);
        struct wlr_box ob = {0};
        if (output) wlr_output_layout_get_box(_compositor.state->output_layout, output, &ob);
        [self moveTo:ob.x y:ob.y];
        return;
    }

    /* ---- Normal windows: cascade below the menu bar ---- */
    static int cascade = 0;
    int usableTop = _compositor.state->usable_top;
    /* Start windows below the menu bar (at least usableTop + 8 px margin) */
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
    /*
     * Remove all Wayland listeners BEFORE releasing the ObjC object.
     * Same ordering requirement as AmbrosiaOutput:
     *   1. wl_list_remove while all signal owners (xdg_toplevel, wl_surface)
     *      are still alive — we are inside xdg_toplevel::events::destroy so
     *      both the toplevel and its backing wl_surface are valid here.
     *   2. free / _state = NULL before removeView: so that if removeView:
     *      drops the last retain and triggers dealloc on this call stack,
     *      dealloc's "if (_state)" guard is already false and no second
     *      wl_list_remove is attempted.
     */
    if (_state) {
        wl_list_remove(&_state->surface_commit.link);
        wl_list_remove(&_state->map.link);
        wl_list_remove(&_state->unmap.link);
        wl_list_remove(&_state->destroy.link);
        wl_list_remove(&_state->request_move.link);
        wl_list_remove(&_state->request_resize.link);
        wl_list_remove(&_state->request_maximize.link);
        wl_list_remove(&_state->request_fullscreen.link);
        wl_list_remove(&_state->set_title.link);
        wl_list_remove(&_state->set_app_id.link);
        free(_state);
        _state = NULL;
    }
    [_compositor removeView:self];
}

- (void)handleRequestMoveSerial:(uint32_t)serial
{
    [_compositor beginMoveView:self cursor:_compositor.state->cursor];
}

- (void)handleRequestResizeSerial:(uint32_t)serial edges:(uint32_t)edges
{
    [_compositor beginResizeView:self cursor:_compositor.state->cursor edges:edges];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Miniaturize / deminiaturize

- (void)miniaturize
{
    if (_isMiniaturized) return;
    _isMiniaturized = YES;
    /* Hide compositor-side scene node.  There is no standard XDG-shell state
     * for "minimized", so the client is not notified; its surface continues
     * to commit normally while invisible.                                   */
    wlr_scene_node_set_enabled(&_state->scene_tree->node, false);
}

- (void)deminiaturize
{
    if (!_isMiniaturized) return;
    _isMiniaturized = NO;
    wlr_scene_node_set_enabled(&_state->scene_tree->node, true);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Fullscreen

/**
 * Enter or exit fullscreen mode.
 *
 * Fullscreen windows are moved to scene_layer_fullscreen, which sits above
 * the menu-bar layer, so they cover the entire output.  The server-side
 * decoration is hidden while fullscreen and restored on exit.
 */
- (void)_setFullscreen:(BOOL)fullscreen
{
    if (fullscreen == _isFullscreen) return;

    struct ambrosia_compositor_state *cs = _compositor.state;

    if (fullscreen) {
        _restoreFSX = _x;
        _restoreFSY = _y;

        struct wlr_output *output =
            wlr_output_layout_output_at(cs->output_layout, _x + 100, _y + 100);
        if (!output)
            output = wlr_output_layout_get_center_output(cs->output_layout);
        if (!output) return;

        struct wlr_box ob = {0};
        wlr_output_layout_get_box(cs->output_layout, output, &ob);

        /* Raise window above the menu bar */
        wlr_scene_node_reparent(&_state->scene_tree->node, cs->scene_layer_fullscreen);

        /* Hide server-side decoration */
        if (_decoration)
            wlr_scene_node_set_enabled(&_decoration.scene_tree->node, false);

        /* Tell the client to fill the output */
        wlr_xdg_toplevel_set_fullscreen(_state->xdg_toplevel, true);
        wlr_xdg_toplevel_set_size(_state->xdg_toplevel,
                                  (uint32_t)ob.width, (uint32_t)ob.height);
        [self moveTo:ob.x y:ob.y];
        _isFullscreen = YES;
    } else {
        /* Return to the normal windows layer */
        wlr_scene_node_reparent(&_state->scene_tree->node, cs->scene_layer_windows);

        /* Restore decoration */
        if (_decoration)
            wlr_scene_node_set_enabled(&_decoration.scene_tree->node, true);

        wlr_xdg_toplevel_set_fullscreen(_state->xdg_toplevel, false);
        /* size 0,0 lets the client choose its preferred size */
        wlr_xdg_toplevel_set_size(_state->xdg_toplevel, 0, 0);
        [self moveTo:_restoreFSX y:_restoreFSY];
        _isFullscreen = NO;
    }

    wlr_xdg_surface_schedule_configure(_state->xdg_toplevel->base);
}

- (void)toggleFullscreen
{
    [self _setFullscreen:!_isFullscreen];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Maximize helpers

/**
 * Shared maximize/unmaximize implementation used by both handleRequestMaximize
 * (client-initiated) and toggleMaximize (decoration button).
 *
 * Coordinate math:
 *   The decoration sub-tree sits at (-B, -T) relative to the surface scene
 *   node.  For the titlebar to appear flush at the top of the usable area
 *   the surface origin must therefore be at (output_x + B, usableTop + T).
 *   Surface size = (output_width − 2B) × (output_height − usableTop − T − B).
 */
- (void)_setMaximized:(BOOL)maximize
{
    if (maximize) {
        /* Save current surface position for later restore */
        _restoreX = _x;
        _restoreY = _y;

        struct wlr_output *output =
            wlr_output_layout_output_at(_compositor.state->output_layout,
                                        _x + 100, _y + 100);
        if (!output)
            output = wlr_output_layout_get_center_output(
                         _compositor.state->output_layout);
        if (output) {
            struct wlr_box ob;
            wlr_output_layout_get_box(_compositor.state->output_layout,
                                      output, &ob);
            int B          = AMBROSIA_BORDER_WIDTH;
            int T          = AMBROSIA_TITLEBAR_HEIGHT;
            int usableTop  = _compositor.state->usable_top;
            int sw = ob.width - B * 2;
            int sh = ob.height - usableTop - T - B;
            if (sw < 1) sw = 1;
            if (sh < 1) sh = 1;
            wlr_xdg_toplevel_set_size(_state->xdg_toplevel,
                                      (uint32_t)sw, (uint32_t)sh);
            [self moveTo:ob.x + B y:ob.y + usableTop + T];
        }
        wlr_xdg_toplevel_set_maximized(_state->xdg_toplevel, true);
    } else {
        wlr_xdg_toplevel_set_maximized(_state->xdg_toplevel, false);
        /* size 0,0 lets the client choose its preferred unmaximized size */
        wlr_xdg_toplevel_set_size(_state->xdg_toplevel, 0, 0);
        [self moveTo:_restoreX y:_restoreY];
    }
    wlr_xdg_surface_schedule_configure(_state->xdg_toplevel->base);
}

- (void)toggleMaximize
{
    [self _setMaximized:!_state->xdg_toplevel->current.maximized];
}

- (void)handleRequestMaximize
{
    if (!_state->xdg_toplevel->base->initialized)
        return;
    [self _setMaximized:_state->xdg_toplevel->requested.maximized];
}

- (void)handleRequestFullscreen
{
    if (!_state->xdg_toplevel->base->initialized)
        return;
    [self _setFullscreen:_state->xdg_toplevel->requested.fullscreen];
}

- (void)handleSetTitle
{
    [self updateTitle];
}

- (void)handleSetAppId
{
    /* Re-classify all roles */
    _isDockWindow        = isDock(_state->xdg_toplevel);
    _isDesktopBackground = isDesktopToplevel(_state->xdg_toplevel);
    _isMenu              = isMenuToplevel(_state->xdg_toplevel) || _isDockWindow || _isDesktopBackground;
}

/* ---------------------------------------------------------------------- */
#pragma mark - AmbrosiaWindowView protocol additions

- (void)activateFocus:(BOOL)focused
{
    wlr_xdg_toplevel_set_activated(_state->xdg_toplevel, focused ? true : false);
}

- (void)close
{
    wlr_xdg_toplevel_send_close(_state->xdg_toplevel);
}

- (void)raiseSceneNode
{
    wlr_scene_node_raise_to_top(&_state->scene_tree->node);
}

- (struct wlr_surface *)surfaceAt:(double)x y:(double)y
                          localX:(double *)lx localY:(double *)ly
{
    NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];
    double view_sx = x - _x;
    double view_sy = y - _y;
    if (_decoration) {
        view_sx -= insets.left;
        view_sy -= insets.top;
    }
    double sx = 0, sy = 0;
    struct wlr_surface *found =
        wlr_xdg_surface_surface_at(_state->xdg_toplevel->base, view_sx, view_sy, &sx, &sy);
    if (found) {
        if (lx) *lx = sx;
        if (ly) *ly = sy;
    }
    return found;
}

- (struct wl_client *)waylandClient
{
    return wl_resource_get_client(_state->xdg_toplevel->base->resource);
}

- (pid_t)clientPid
{
    struct wl_client *client =
        wl_resource_get_client(_state->xdg_toplevel->base->resource);
    pid_t pid = 0;
    wl_client_get_credentials(client, &pid, NULL, NULL);
    return pid;
}

@end
