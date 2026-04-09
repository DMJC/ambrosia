#import "AmbrosiaView.h"
#import "AmbrosiaCompositor.h"
#import "AmbrosiaDecoration.h"

#include <wlr/util/log.h>
#include <string.h>

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
 */
static BOOL isDock(struct wlr_xdg_toplevel *toplevel)
{
    const char *app_id = toplevel->app_id;
    if (app_id && strstr(app_id, "AmbrosiaDock") != NULL) return YES;
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
    BOOL _isMenu;
    BOOL _isDockWindow;
    BOOL _isDesktopBackground;
}

@synthesize state               = _state;
@synthesize compositor          = _compositor;
@synthesize decoration          = _decoration;
@synthesize x                   = _x;
@synthesize y                   = _y;
@synthesize isMapped            = _isMapped;
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

    /* Create scene tree for this view */
    _state->scene_tree = wlr_scene_xdg_surface_create(
        &compositor.state->scene->tree,
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

    if (!_isMenu) {
        /* Create server-side decoration for normal windows */
        _decoration = [[AmbrosiaDecoration alloc]
                       initWithRenderer:_compositor.state->renderer
                              sceneTree:_state->scene_tree];
        [self updateTitle];
    }

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
        int dockX = ob.x + (ob.width  - dockW) / 2;
        int dockY = ob.y +  ob.height - dockH;
        [self moveTo:dockX y:dockY];
        /* Dock does not steal keyboard focus on map */
        return;
    }

    /* ---- Menu toplevels ---- */
    if (_isMenu) {
        /* GNUstep positions menus via request_move; start at origin and let
         * the app reposition.  Focus so keyboard events reach the menu. */
        [self moveTo:0 y:0];
        [_compositor focusView:self surface:self.surface];
        return;
    }

    /* ---- Normal windows: cascade ---- */
    static int cascade = 0;
    NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];
    int startX = 60 + cascade * 30 - (int)insets.left;
    int startY = 60 + cascade * 30 - (int)insets.top;
    cascade = (cascade + 1) % 8;
    [self moveTo:startX y:startY];

    [_compositor focusView:self surface:self.surface];
}

- (void)handleUnmap
{
    _isMapped = NO;
    if (_compositor.focusedView == self) {
        [_compositor focusView:nil surface:nil];
    }
}

- (void)handleDestroy
{
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

- (void)handleRequestMaximize
{
    /* Toggle maximise: send the compositor-chosen size */
    BOOL doMax = _state->xdg_toplevel->requested.maximized;
    if (doMax) {
        /* Find the output the window is mostly on */
        struct wlr_output *output =
            wlr_output_layout_output_at(_compositor.state->output_layout,
                                        _x + 100, _y + 100);
        if (!output) output = wlr_output_layout_get_center_output(_compositor.state->output_layout);
        if (output) {
            struct wlr_box output_box;
            wlr_output_layout_get_box(_compositor.state->output_layout, output, &output_box);
            NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];
            int sw = output_box.width  - (int)(insets.left + insets.right);
            int sh = output_box.height - (int)(insets.top  + insets.bottom);
            wlr_xdg_toplevel_set_size(_state->xdg_toplevel, (uint32_t)sw, (uint32_t)sh);
            [self moveTo:output_box.x y:output_box.y];
        }
        wlr_xdg_toplevel_set_maximized(_state->xdg_toplevel, true);
    } else {
        wlr_xdg_toplevel_set_maximized(_state->xdg_toplevel, false);
    }
    wlr_xdg_surface_schedule_configure(_state->xdg_toplevel->base);
}

- (void)handleRequestFullscreen
{
    BOOL doFull = _state->xdg_toplevel->requested.fullscreen;
    wlr_xdg_toplevel_set_fullscreen(_state->xdg_toplevel, doFull);
    wlr_xdg_surface_schedule_configure(_state->xdg_toplevel->base);
}

- (void)handleSetTitle
{
    [self updateTitle];
}

- (void)handleSetAppId
{
    /* Re-classify all roles */
    BOOL wasMenu = _isMenu;
    _isDockWindow        = isDock(_state->xdg_toplevel);
    _isDesktopBackground = isDesktopToplevel(_state->xdg_toplevel);
    _isMenu              = isMenuToplevel(_state->xdg_toplevel) || _isDockWindow || _isDesktopBackground;
    if (wasMenu != _isMenu && _isMapped) {
        if (_isMenu) {
            _decoration = nil;
        } else {
            _decoration = [[AmbrosiaDecoration alloc]
                           initWithRenderer:_compositor.state->renderer
                                  sceneTree:_state->scene_tree];
            [self updateTitle];
        }
    }
}

@end
