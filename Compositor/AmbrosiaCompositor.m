#import "AmbrosiaCompositor.h"
#import "AmbrosiaOutput.h"
#import "AmbrosiaView.h"
#import "AmbrosiaDecoration.h"
#import "AmbrosiaInput.h"

#include <wayland-server-core.h>
#include <wlr/util/log.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_keyboard.h>
#include <linux/input-event-codes.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>

/* Forward-declare private methods called from static C callbacks before the
 * @implementation block is visible to the compiler.                       */
@interface AmbrosiaCompositor (PrivateCallbacks)
- (void)applyExclusiveZonesToBox:(struct wlr_box *)box
                       forOutput:(struct wlr_output *)output;
- (void)recalculateUsableTop;
@end

/* --------------------------------------------------------------------------
 * Module-level weak back-reference so static C callbacks can reach ObjC.
 * Only one compositor instance exists per process.
 * -------------------------------------------------------------------------- */
static AmbrosiaCompositor *gCompositor = nil;

/* --------------------------------------------------------------------------
 * C-level listener callbacks
 * -------------------------------------------------------------------------- */

static void handle_new_output(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_output);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewOutput:(struct wlr_output *)data];
}

static void handle_new_xdg_toplevel(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_xdg_toplevel);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewXdgToplevel:(struct wlr_xdg_toplevel *)data];
}

static void handle_new_xdg_popup(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_xdg_popup);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewXdgPopup:(struct wlr_xdg_popup *)data];
}

static void handle_new_toplevel_decoration(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_toplevel_decoration);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewToplevelDecoration:(struct wlr_xdg_toplevel_decoration_v1 *)data];
}

static void handle_cursor_motion(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, cursor_motion);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    struct wlr_pointer_motion_event *event = data;
    [c handleCursorMotionTime:event->time_msec
                           dx:event->delta_x
                           dy:event->delta_y];
}

static void handle_cursor_motion_absolute(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, cursor_motion_absolute);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    struct wlr_pointer_motion_absolute_event *event = data;
    [c handleCursorMotionAbsoluteTime:event->time_msec
                                    x:event->x
                                    y:event->y
                               output:NULL];
}

static void handle_cursor_button(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, cursor_button);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    struct wlr_pointer_button_event *event = data;
    [c handleCursorButtonTime:event->time_msec
                       button:event->button
                        state:(uint32_t)event->state];
}

static void handle_cursor_axis(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, cursor_axis);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    struct wlr_pointer_axis_event *event = data;
    [c handleCursorAxisTime:event->time_msec
                orientation:(uint32_t)event->orientation
                      delta:event->delta
              deltaDiscrete:event->delta_discrete];
}

static void handle_cursor_frame(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, cursor_frame);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    (void)data;
    [c handleCursorFrame];
}

static void handle_new_input(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_input);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewInput:(struct wlr_input_device *)data];
}

static void handle_request_set_cursor(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, request_set_cursor);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleRequestSetCursor:(struct wlr_seat_pointer_request_set_cursor_event *)data];
}

static void handle_request_set_selection(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, request_set_selection);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleRequestSetSelection:(struct wlr_seat_request_set_selection_event *)data];
}

/* --------------------------------------------------------------------------
 * Logout pipe watcher — called on the compositor's wl_event_loop thread
 * -------------------------------------------------------------------------- */

static int handle_logout_pipe(int fd, uint32_t mask, void *data)
{
    char byte;
    (void)read(fd, &byte, 1); /* drain */
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)data;
    [c saveSessionAndLogout];
    return 0;
}

/* --------------------------------------------------------------------------
 * Per-popup state: wlroots 0.18+ requires the compositor to send a configure
 * in response to initial_commit for popups just as it does for toplevels.
 * -------------------------------------------------------------------------- */

struct ambrosia_popup_state {
    struct wlr_xdg_surface *xdg_surface;
    struct wl_listener      surface_commit;
    struct wl_listener      destroy;
};

static void handle_popup_surface_commit(struct wl_listener *listener, void *data)
{
    struct ambrosia_popup_state *s = wl_container_of(listener, s, surface_commit);
    if (s->xdg_surface->initial_commit) {
        wlr_xdg_surface_schedule_configure(s->xdg_surface);
    }
}

static void handle_popup_destroy(struct wl_listener *listener, void *data)
{
    struct ambrosia_popup_state *s = wl_container_of(listener, s, destroy);
    wl_list_remove(&s->surface_commit.link);
    wl_list_remove(&s->destroy.link);
    free(s);
}

/* --------------------------------------------------------------------------
 * Per-layer-surface state: handles wlr-layer-shell-v1 surfaces (e.g. the
 * GNUstep NSMacintoshMenuStyle menu bar at NSMainMenuWindowLevel).
 * -------------------------------------------------------------------------- */

struct ambrosia_layer_surface {
    struct wlr_layer_surface_v1       *wlr_layer_surface;
    struct wlr_scene_layer_surface_v1 *scene_layer;
    struct wl_listener                 surface_commit;
    struct wl_listener                 destroy;
};

static void handle_new_layer_surface(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_layer_surface);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewLayerSurface:(struct wlr_layer_surface_v1 *)data];
}

static void handle_layer_surface_commit(struct wl_listener *listener, void *data)
{
    struct ambrosia_layer_surface *ls = wl_container_of(listener, ls, surface_commit);
    if (!ls->wlr_layer_surface->initial_commit) return;

    struct wlr_output *output = ls->wlr_layer_surface->output;
    if (!output)
        output = wlr_output_layout_get_center_output(gCompositor.state->output_layout);
    if (!output) return;

    struct wlr_box full_area = {0};
    wlr_output_layout_get_box(gCompositor.state->output_layout, output, &full_area);

    /* Build usable_area by applying exclusive zones from all LAYER_TOP/BOTTOM
     * surfaces on this output.  This causes the compositor to place new windows
     * inside the reserved region (below the menu bar, etc.).                   */
    struct wlr_box usable_area = full_area;
    [gCompositor applyExclusiveZonesToBox:&usable_area forOutput:output];

    wlr_scene_layer_surface_v1_configure(ls->scene_layer, &full_area, &usable_area);

    /* Recompute the top margin so window-move clamping stays accurate */
    [gCompositor recalculateUsableTop];
}

static void handle_layer_surface_destroy(struct wl_listener *listener, void *data)
{
    struct ambrosia_layer_surface *ls = wl_container_of(listener, ls, destroy);
    [gCompositor removeLayerSurface:ls];
    wl_list_remove(&ls->surface_commit.link);
    wl_list_remove(&ls->destroy.link);
    free(ls);
    [gCompositor recalculateUsableTop];
}

/* --------------------------------------------------------------------------
 * AmbrosiaCompositor
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaCompositor {
    struct ambrosia_compositor_state *_state;
    NSMutableArray<AmbrosiaView *>   *_views;
    NSMutableArray<AmbrosiaOutput *> *_outputs;
    NSMutableArray                   *_layerSurfaces;
    AmbrosiaInput                    *_input;
    AmbrosiaView                     *_focusedView;
    AmbrosiaSession                  *_session;
    BOOL                              _running;
}

@synthesize state         = _state;
@synthesize session       = _session;
@synthesize views         = _views;
@synthesize outputs       = _outputs;
@synthesize layerSurfaces = _layerSurfaces;

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    _views         = [NSMutableArray array];
    _outputs       = [NSMutableArray array];
    _layerSurfaces = [NSMutableArray array];
    _state   = calloc(1, sizeof(struct ambrosia_compositor_state));
    if (!_state) return nil;

    _state->objc_compositor = (__bridge void *)self;
    _state->cursor_mode = AmbrosiaCursorModePassthrough;
    gCompositor = self;

    return self;
}

- (void)dealloc
{
    if (_state) {
        free(_state);
        _state = NULL;
    }
    gCompositor = nil;
}

- (AmbrosiaView *)focusedView { return _focusedView; }

/* ---------------------------------------------------------------------- */
#pragma mark - Setup

- (BOOL)setup:(NSError **)error
{
    wlr_log_init(WLR_DEBUG, NULL);
    wlr_log(WLR_INFO, "Ambrosia: initialising compositor");

    /* Wayland display + event loop */
    _state->display    = wl_display_create();
    _state->event_loop = wl_display_get_event_loop(_state->display);
    if (!_state->display || !_state->event_loop) {
        wlr_log(WLR_ERROR, "Failed to create wl_display");
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create wl_display"}];
        return NO;
    }
    wlr_log(WLR_DEBUG, "Wayland display created");

    /* Backend (DRM/KMS on bare metal, Wayland/X11 nested in an existing compositor) */
    _state->backend = wlr_backend_autocreate(_state->event_loop, &_state->wlr_session);
    if (!_state->backend) {
        wlr_log(WLR_ERROR, "Failed to create backend");
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:2
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create backend"}];
        return NO;
    }
    wlr_log(WLR_DEBUG, "Backend created%s",
            _state->wlr_session ? " (session available, VT switching enabled)" : "");

    /* Renderer */
    _state->renderer = wlr_renderer_autocreate(_state->backend);
    if (!_state->renderer) {
        wlr_log(WLR_ERROR, "Failed to create renderer");
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:3
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create renderer"}];
        return NO;
    }
    wlr_renderer_init_wl_display(_state->renderer, _state->display);
    wlr_log(WLR_DEBUG, "Renderer created");

    /* Allocator */
    _state->allocator = wlr_allocator_autocreate(_state->backend, _state->renderer);
    if (!_state->allocator) {
        wlr_log(WLR_ERROR, "Failed to create allocator");
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:4
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create allocator"}];
        return NO;
    }
    wlr_log(WLR_DEBUG, "Allocator created");

    /* Wayland globals */
    wlr_compositor_create(_state->display, 5, _state->renderer);
    wlr_subcompositor_create(_state->display);
    wlr_data_device_manager_create(_state->display);
    wlr_log(WLR_DEBUG, "Wayland globals registered");

    /* Output layout + scene */
    _state->output_layout = wlr_output_layout_create(_state->display);
    _state->scene         = wlr_scene_create();
    _state->scene_layout  = wlr_scene_attach_output_layout(_state->scene, _state->output_layout);

    /*
     * Create scene sub-trees in ascending z-order.  wlroots renders a tree's
     * children in creation order (first = bottom, last = top), so the order
     * below gives:  background < bottom < windows < top < overlay.
     *
     * Regular app windows are added to scene_layer_windows.
     * wlr_scene_node_raise_to_top() on a window only moves it within that
     * sub-tree, so it can never rise above scene_layer_top (the menu bar).
     */
    _state->scene_layer_bg      = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_bottom  = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_windows = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_top     = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_overlay = wlr_scene_tree_create(&_state->scene->tree);
    _state->usable_top = 0;
    wlr_log(WLR_DEBUG, "Scene graph initialised (layered sub-trees created)");

    /* XDG shell (version 3) */
    _state->xdg_shell = wlr_xdg_shell_create(_state->display, 3);
    wlr_log(WLR_DEBUG, "XDG shell created");

    /* Server-side decoration manager */
    _state->decoration_manager = wlr_xdg_decoration_manager_v1_create(_state->display);
    wlr_log(WLR_DEBUG, "Decoration manager created");

    /* Layer shell (wlr-layer-shell-v1) — used by GNUstep for the menu bar,
     * desktop background, and screen saver windows.                        */
    _state->layer_shell = wlr_layer_shell_v1_create(_state->display, 4);
    wlr_log(WLR_DEBUG, "Layer shell created");

    /* Screen copy (wlr-screencopy-unstable-v1) — enables grim and similar
     * tools to capture frames from this compositor.                        */
    _state->screencopy_manager = wlr_screencopy_manager_v1_create(_state->display);
    wlr_log(WLR_DEBUG, "Screencopy manager created");

    /* xdg-output-manager (zxdg_output_manager_v1) — lets clients query logical
     * output geometry (position, size, name) from the compositor's output layout. */
    _state->xdg_output_manager =
        wlr_xdg_output_manager_v1_create(_state->display, _state->output_layout);
    wlr_log(WLR_DEBUG, "XDG output manager created");

    /* Seat */
    _state->seat = wlr_seat_create(_state->display, "seat0");
    wlr_log(WLR_DEBUG, "Seat 'seat0' created");

    /* Cursor */
    _state->cursor     = wlr_cursor_create();
    _state->cursor_mgr = wlr_xcursor_manager_create(NULL, 24);
    wlr_cursor_attach_output_layout(_state->cursor, _state->output_layout);
    wlr_log(WLR_DEBUG, "Cursor initialised");

    /* Register all listeners */
    _state->new_output.notify = handle_new_output;
    wl_signal_add(&_state->backend->events.new_output, &_state->new_output);

    _state->new_xdg_toplevel.notify = handle_new_xdg_toplevel;
    wl_signal_add(&_state->xdg_shell->events.new_toplevel, &_state->new_xdg_toplevel);

    _state->new_xdg_popup.notify = handle_new_xdg_popup;
    wl_signal_add(&_state->xdg_shell->events.new_popup, &_state->new_xdg_popup);

    _state->new_toplevel_decoration.notify = handle_new_toplevel_decoration;
    wl_signal_add(&_state->decoration_manager->events.new_toplevel_decoration,
                  &_state->new_toplevel_decoration);

    _state->new_layer_surface.notify = handle_new_layer_surface;
    wl_signal_add(&_state->layer_shell->events.new_surface, &_state->new_layer_surface);

    _state->cursor_motion.notify = handle_cursor_motion;
    wl_signal_add(&_state->cursor->events.motion, &_state->cursor_motion);

    _state->cursor_motion_absolute.notify = handle_cursor_motion_absolute;
    wl_signal_add(&_state->cursor->events.motion_absolute, &_state->cursor_motion_absolute);

    _state->cursor_button.notify = handle_cursor_button;
    wl_signal_add(&_state->cursor->events.button, &_state->cursor_button);

    _state->cursor_axis.notify = handle_cursor_axis;
    wl_signal_add(&_state->cursor->events.axis, &_state->cursor_axis);

    _state->cursor_frame.notify = handle_cursor_frame;
    wl_signal_add(&_state->cursor->events.frame, &_state->cursor_frame);

    _state->new_input.notify = handle_new_input;
    wl_signal_add(&_state->backend->events.new_input, &_state->new_input);

    _state->request_set_cursor.notify = handle_request_set_cursor;
    wl_signal_add(&_state->seat->events.request_set_cursor, &_state->request_set_cursor);

    _state->request_set_selection.notify = handle_request_set_selection;
    wl_signal_add(&_state->seat->events.request_set_selection, &_state->request_set_selection);

    /* Input handler */
    _input = [[AmbrosiaInput alloc] initWithCompositor:self];

    /* Logout self-pipe: background NSRunLoop thread → wl_event_loop */
    if (pipe(_state->logout_pipe) != 0) {
        wlr_log(WLR_ERROR, "Failed to create logout pipe: %s", strerror(errno));
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:5
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create logout pipe"}];
        return NO;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(_state->logout_pipe[i], F_SETFD, FD_CLOEXEC);
        fcntl(_state->logout_pipe[i], F_SETFL,
              fcntl(_state->logout_pipe[i], F_GETFL) | O_NONBLOCK);
    }
    _state->logout_source = wl_event_loop_add_fd(
        _state->event_loop,
        _state->logout_pipe[0],
        WL_EVENT_READABLE,
        handle_logout_pipe,
        (__bridge void *)self);

    wlr_log(WLR_INFO, "Ambrosia: compositor setup complete");
    return YES;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Run / Stop

- (void)run
{
    const char *socket = wl_display_add_socket_auto(_state->display);
    if (!socket) {
        wlr_log(WLR_ERROR, "Unable to create Wayland socket");
        return;
    }

    if (!wlr_backend_start(_state->backend)) {
        wlr_log(WLR_ERROR, "Failed to start backend");
        wl_display_destroy(_state->display);
        return;
    }

    setenv("WAYLAND_DISPLAY", socket, 1);
    wlr_log(WLR_INFO, "Ambrosia compositor running on WAYLAND_DISPLAY=%s", socket);

    /* Start the session manager — launches AmbrosiaDock and GFinder,
     * restarting either automatically if they exit unexpectedly.     */
    _session = AmbrosiaSessionCreateDefault(_state->event_loop);
    [_session start];

    /* Background thread: pumps NSRunLoop so NSDistributedNotificationCenter
     * can deliver "AmbrosiaLogoutRequest" notifications.  On arrival the
     * handler writes one byte to logout_pipe[1]; handle_logout_pipe() on the
     * wl_event_loop thread calls saveSessionAndLogout from there.          */
    NSThread *notifThread = [[NSThread alloc]
        initWithTarget:self
              selector:@selector(_runNotificationListener)
                object:nil];
    notifThread.name = @"AmbrosiaNotificationListener";
    [notifThread start];

    _running = YES;
    wl_display_run(_state->display);

    /* Shutdown */
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    if (_state->logout_source) {
        wl_event_source_remove(_state->logout_source);
        _state->logout_source = NULL;
    }
    close(_state->logout_pipe[0]);
    close(_state->logout_pipe[1]);

    [_session stop];
    _session = nil;
    wl_display_destroy_clients(_state->display);
    wlr_xcursor_manager_destroy(_state->cursor_mgr);
    wlr_cursor_destroy(_state->cursor);
    wlr_output_layout_destroy(_state->output_layout);
    wl_display_destroy(_state->display);
}

- (void)stop
{
    wlr_log(WLR_INFO, "Ambrosia: stopping compositor");
    if (_state->display) wl_display_terminate(_state->display);
}

/* ---------------------------------------------------------------------- */
#pragma mark - View management

- (void)addView:(AmbrosiaView *)view
{
    [_views addObject:view];
    wlr_log(WLR_DEBUG, "View added (total: %lu)", (unsigned long)_views.count);
}

- (void)removeView:(AmbrosiaView *)view
{
    if (_focusedView == view) _focusedView = nil;
    [_views removeObject:view];
    wlr_log(WLR_DEBUG, "View removed (total: %lu)", (unsigned long)_views.count);
}

- (nullable AmbrosiaView *)viewAtX:(double)x y:(double)y
                          surface:(struct wlr_surface **)surfaceOut
                           localX:(double *)lx
                           localY:(double *)ly
{
    NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];

    /* Iterate top-to-bottom (last added = topmost) */
    for (NSInteger i = (NSInteger)_views.count - 1; i >= 0; i--) {
        AmbrosiaView *view = _views[i];
        if (!view.isMapped) continue;

        /* Try surface hit first */
        double view_sx = x - view.x;
        double view_sy = y - view.y;
        if (view.decoration) {
            view_sx -= insets.left;
            view_sy -= insets.top;
        }

        struct wlr_surface *found = NULL;
        double sx = 0, sy = 0;
        found = wlr_xdg_surface_surface_at(
            view.state->xdg_toplevel->base, view_sx, view_sy, &sx, &sy);

        if (found) {
            if (surfaceOut) *surfaceOut = found;
            if (lx) *lx = sx;
            if (ly) *ly = sy;
            return view;
        }

        /* The titlebar/borders are compositor-drawn rects, not Wayland surfaces,
         * so wlr_xdg_surface_surface_at will not find them.  Check whether the
         * cursor is inside the decorated bounding box instead.               */
        if (view.decoration) {
            struct wlr_box geo = [view geometry];
            double frameW = insets.left + geo.width  + insets.right;
            double frameH = insets.top  + geo.height + insets.bottom;
            double dx = x - view.x;
            double dy = y - view.y;
            if (dx >= 0 && dx < frameW && dy >= 0 && dy < frameH) {
                if (surfaceOut) *surfaceOut = NULL;
                if (lx) *lx = 0;
                if (ly) *ly = 0;
                return view;
            }
        }
    }
    return nil;
}

- (void)focusView:(AmbrosiaView *)view surface:(struct wlr_surface *)surface
{
    if (_focusedView == view) return;

    /*
     * Modal-dialog protection: if the currently focused app has a mapped
     * transient child window (xdg_toplevel->parent belonging to this app's
     * Wayland client — e.g. an NSAlert panel), redirect focus to that dialog
     * instead of moving to a different app.
     *
     * Without this, gnustep-back receives keyboard.leave and fires
     * NSApplicationDidResignActiveNotification, which terminates the modal
     * session and closes the alert window.
     */
    if (view && _focusedView && !view.isMenu) {
        struct wl_client *fromClient = wl_resource_get_client(
            _focusedView.state->xdg_toplevel->base->resource);
        struct wl_client *toClient = wl_resource_get_client(
            view.state->xdg_toplevel->base->resource);
        if (fromClient != toClient) {
            AmbrosiaView *modal = nil;
            for (AmbrosiaView *candidate in _views) {
                if (!candidate.isMapped) continue;
                struct wlr_xdg_toplevel *tp = candidate.state->xdg_toplevel;
                if (!tp->parent) continue;
                struct wl_client *parentClient =
                    wl_resource_get_client(tp->parent->base->resource);
                if (parentClient == fromClient) {
                    modal = candidate; /* last in list = topmost */
                }
            }
            if (modal) {
                wlr_log(WLR_DEBUG,
                    "focusView: redirecting to modal dialog '%s' "
                    "(blocked cross-app focus change)",
                    modal.state->xdg_toplevel->title ?: "(untitled)");
                view    = modal;
                surface = modal.surface;
            }
        }
    }

    /* Re-check: redirect may have landed on the already-focused view */
    if (_focusedView == view) return;

    if (view) {
        const char *title   = view.state->xdg_toplevel->title   ?: "(untitled)";
        const char *app_id  = view.state->xdg_toplevel->app_id  ?: "(unknown)";
        wlr_log(WLR_DEBUG, "Focus: %s [%s]", title, app_id);
    } else {
        wlr_log(WLR_DEBUG, "Focus cleared");
    }

    /* Unfocus previous */
    if (_focusedView) {
        _focusedView.decoration.focused = NO;
        [_focusedView.decoration updateWithWidth:0 height:0 title:nil]; /* redraw unfocused */
        struct wlr_xdg_surface *prev = _focusedView.state->xdg_toplevel->base;
        wlr_xdg_toplevel_set_activated(prev->toplevel, false);
    }

    _focusedView = view;

    if (!view) {
        wlr_seat_keyboard_notify_clear_focus(_state->seat);
        return;
    }

    view.decoration.focused = YES;

    /* Raise to top of view list */
    [_views removeObject:view];
    [_views addObject:view];

    /* Raise scene tree */
    wlr_scene_node_raise_to_top(&view.state->scene_tree->node);

    /* Activate the xdg toplevel */
    wlr_xdg_toplevel_set_activated(view.state->xdg_toplevel, true);

    /* Notify seat keyboard */
    struct wlr_keyboard *kb = wlr_seat_get_keyboard(_state->seat);
    if (kb) {
        wlr_seat_keyboard_notify_enter(_state->seat,
            surface ?: view.surface,
            kb->keycodes, kb->num_keycodes, &kb->modifiers);
    }

    /* Redraw decoration to show focused state */
    struct wlr_box geo = [view geometry];
    NSString *title = view.state->xdg_toplevel->title
        ? [NSString stringWithUTF8String:view.state->xdg_toplevel->title]
        : @"";
    [view.decoration updateWithWidth:geo.width height:geo.height title:title];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Move / Resize

- (void)beginMoveView:(AmbrosiaView *)view cursor:(struct wlr_cursor *)cursor
{
    wlr_log(WLR_DEBUG, "Begin move: %s",
            view.state->xdg_toplevel->title ?: "(untitled)");
    _state->cursor_mode = AmbrosiaCursorModeMove;
    _state->grab_x = cursor->x - view.x;
    _state->grab_y = cursor->y - view.y;
}

- (void)beginResizeView:(AmbrosiaView *)view
                 cursor:(struct wlr_cursor *)cursor
                  edges:(uint32_t)edges
{
    wlr_log(WLR_DEBUG, "Begin resize: %s (edges: 0x%x)",
            view.state->xdg_toplevel->title ?: "(untitled)", edges);
    _state->cursor_mode  = AmbrosiaCursorModeResize;
    _state->resize_edges = edges;

    struct wlr_box geo = [view geometry];
    NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];

    _state->grab_geobox.x = view.x + (view.decoration ? (int)insets.left : 0);
    _state->grab_geobox.y = view.y + (view.decoration ? (int)insets.top  : 0);
    _state->grab_geobox.width  = geo.width;
    _state->grab_geobox.height = geo.height;

    _state->grab_x = cursor->x + geo.width  * ((edges & WLR_EDGE_RIGHT)  ? 1 : 0);
    _state->grab_y = cursor->y + geo.height * ((edges & WLR_EDGE_BOTTOM) ? 1 : 0);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Cursor processing

- (void)processCursorMotionTime:(uint32_t)time
{
    double cx = _state->cursor->x;
    double cy = _state->cursor->y;

    if (_state->cursor_mode == AmbrosiaCursorModeMove) {
        AmbrosiaView *grabbed = _focusedView;
        if (grabbed) {
            int new_x = (int)(cx - _state->grab_x);
            int new_y = (int)(cy - _state->grab_y);
            /* Clamp so window title bar cannot be dragged above the menu bar */
            if (new_y < _state->usable_top) new_y = _state->usable_top;
            [grabbed moveTo:new_x y:new_y];
        }
        return;
    }

    if (_state->cursor_mode == AmbrosiaCursorModeResize) {
        AmbrosiaView *grabbed = _focusedView;
        if (!grabbed) return;

        struct wlr_box new_geo = _state->grab_geobox;
        uint32_t edges = _state->resize_edges;

        if (edges & WLR_EDGE_RIGHT)  new_geo.width  = (int)(cx - _state->grab_geobox.x);
        if (edges & WLR_EDGE_BOTTOM) new_geo.height = (int)(cy - _state->grab_geobox.y);
        if (edges & WLR_EDGE_LEFT) {
            new_geo.x     = (int)cx;
            new_geo.width = (int)(_state->grab_geobox.x + _state->grab_geobox.width - cx);
        }
        if (edges & WLR_EDGE_TOP) {
            new_geo.y      = (int)cy;
            new_geo.height = (int)(_state->grab_geobox.y + _state->grab_geobox.height - cy);
        }

        if (new_geo.width  < 100) new_geo.width  = 100;
        if (new_geo.height < 60)  new_geo.height = 60;

        NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];
        int frame_x = new_geo.x - (grabbed.decoration ? (int)insets.left : 0);
        int frame_y = new_geo.y - (grabbed.decoration ? (int)insets.top  : 0);
        [grabbed moveTo:frame_x y:frame_y];
        wlr_xdg_toplevel_set_size(grabbed.state->xdg_toplevel,
                                  (uint32_t)new_geo.width,
                                  (uint32_t)new_geo.height);
        return;
    }

    /* Passthrough – update focus and cursor image.
     *
     * Hit-test in visual z-order (highest first):
     *   1. LAYER_OVERLAY / LAYER_TOP surfaces (e.g. the menu bar)
     *   2. xdg-toplevel windows
     *   3. LAYER_BOTTOM / LAYER_BACKGROUND surfaces
     *
     * This ensures the menu bar always receives pointer events even when
     * a window's geometry overlaps its coordinate range.               */
    {
        double lsx = 0, lsy = 0;
        struct wlr_surface *top_ls =
            [self topLayerSurfaceAtX:cx y:cy localX:&lsx localY:&lsy];
        if (top_ls) {
            wlr_seat_pointer_notify_enter(_state->seat, top_ls, lsx, lsy);
            wlr_seat_pointer_notify_motion(_state->seat, time, lsx, lsy);
            wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
            return;
        }
    }

    struct wlr_surface *surface = NULL;
    double sx = 0, sy = 0;
    AmbrosiaView *view = [self viewAtX:cx y:cy surface:&surface localX:&sx localY:&sy];

    if (view) {
        /* Check if pointer is over a decoration */
        if (view.decoration) {
            AmbrosiaDecorationHit hit = [view.decoration hitTestX:(cx - view.x) y:(cy - view.y)];
            if (hit != AmbrosiaDecorationHitNone) {
                wlr_seat_pointer_notify_clear_focus(_state->seat);
                /* Change cursor to appropriate resize cursor */
                const char *cursor_name = "default";
                switch (hit) {
                    case AmbrosiaDecorationHitResizeTop:         cursor_name = "n-resize";  break;
                    case AmbrosiaDecorationHitResizeBottom:      cursor_name = "s-resize";  break;
                    case AmbrosiaDecorationHitResizeLeft:        cursor_name = "w-resize";  break;
                    case AmbrosiaDecorationHitResizeRight:       cursor_name = "e-resize";  break;
                    case AmbrosiaDecorationHitResizeTopLeft:     cursor_name = "nw-resize"; break;
                    case AmbrosiaDecorationHitResizeTopRight:    cursor_name = "ne-resize"; break;
                    case AmbrosiaDecorationHitResizeBottomLeft:  cursor_name = "sw-resize"; break;
                    case AmbrosiaDecorationHitResizeBottomRight: cursor_name = "se-resize"; break;
                    default: break;
                }
                wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, cursor_name);
                return;
            }
        }
        if (surface) {
            wlr_seat_pointer_notify_enter(_state->seat, surface, sx, sy);
            wlr_seat_pointer_notify_motion(_state->seat, time, sx, sy);
        } else {
            wlr_seat_pointer_notify_clear_focus(_state->seat);
        }
        wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
    } else {
        /* No xdg toplevel at this position — check lower layer surfaces */
        double lsx = 0, lsy = 0;
        struct wlr_surface *ls_surface =
            [self layerSurfaceAtX:cx y:cy localX:&lsx localY:&lsy];
        if (ls_surface) {
            wlr_seat_pointer_notify_enter(_state->seat, ls_surface, lsx, lsy);
            wlr_seat_pointer_notify_motion(_state->seat, time, lsx, lsy);
        } else {
            wlr_seat_pointer_notify_clear_focus(_state->seat);
        }
        wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Callback implementations

- (void)handleNewOutput:(struct wlr_output *)output
{
    wlr_log(WLR_INFO, "New output: %s", output->name);
    wlr_output_init_render(output, _state->allocator, _state->renderer);

    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);

    struct wlr_output_mode *mode = wlr_output_preferred_mode(output);
    if (mode) wlr_output_state_set_mode(&state, mode);
    wlr_output_commit_state(output, &state);
    wlr_output_state_finish(&state);

    AmbrosiaOutput *ambOutput = [[AmbrosiaOutput alloc] initWithOutput:output compositor:self];
    [_outputs addObject:ambOutput];

    struct wlr_output_layout_output *layout_output =
        wlr_output_layout_add_auto(_state->output_layout, output);
    struct wlr_scene_output *scene_output =
        wlr_scene_output_create(_state->scene, output);
    wlr_scene_output_layout_add_output(_state->scene_layout, layout_output, scene_output);
    ambOutput.state->scene_output = scene_output;

    wlr_xcursor_manager_load(_state->cursor_mgr, output->scale);

    struct wlr_output_mode *cur_mode = output->current_mode;
    if (cur_mode) {
        wlr_log(WLR_INFO, "Output %s: %dx%d @ %d mHz",
                output->name, cur_mode->width, cur_mode->height, cur_mode->refresh);
    }
}

- (void)handleNewXdgToplevel:(struct wlr_xdg_toplevel *)toplevel
{
    wlr_log(WLR_INFO, "New toplevel: %s [%s]",
            toplevel->title  ?: "(untitled)",
            toplevel->app_id ?: "(unknown)");
    AmbrosiaView *view = [[AmbrosiaView alloc] initWithToplevel:toplevel compositor:self];
    [self addView:view];
}

- (void)handleNewXdgPopup:(struct wlr_xdg_popup *)popup
{
    wlr_log(WLR_DEBUG, "New XDG popup");
    /* Popups (including GNUstep menus) are managed entirely by the scene graph.
     * No decorations; the surface is parented to the scene automatically.  */
    struct wlr_xdg_surface *xdg_surface = popup->base;
    struct wlr_scene_tree *parent_tree = &_state->scene->tree;

    /* If the popup has a parent xdg_surface, parent to its scene tree */
    if (popup->parent) {
        struct wlr_xdg_surface *parent_xdg = wlr_xdg_surface_try_from_wlr_surface(popup->parent);
        if (parent_xdg && parent_xdg->data) {
            parent_tree = (struct wlr_scene_tree *)parent_xdg->data;
        }
    }

    struct wlr_scene_tree *scene_tree =
        wlr_scene_xdg_surface_create(parent_tree, xdg_surface);
    xdg_surface->data = scene_tree;

    /* wlroots 0.18+: send configure on initial_commit for popups too */
    struct ambrosia_popup_state *ps = calloc(1, sizeof(*ps));
    ps->xdg_surface = xdg_surface;
    ps->surface_commit.notify = handle_popup_surface_commit;
    wl_signal_add(&xdg_surface->surface->events.commit, &ps->surface_commit);
    ps->destroy.notify = handle_popup_destroy;
    wl_signal_add(&xdg_surface->events.destroy, &ps->destroy);
}

- (void)handleNewToplevelDecoration:(struct wlr_xdg_toplevel_decoration_v1 *)decoration
{
    /* Compositor uses client-side decorations throughout: windows draw their
     * own chrome (or none at all).  Tell every client to use CSD so GNUstep
     * panels and borderless windows are never given an unwanted server frame. */
    wlr_xdg_toplevel_decoration_v1_set_mode(decoration,
        WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
}

- (void)handleNewLayerSurface:(struct wlr_layer_surface_v1 *)layer_surface
{
    wlr_log(WLR_INFO, "New layer surface: namespace='%s' layer=%d anchor=0x%x",
            layer_surface->namespace ?: "(nil)",
            (int)layer_surface->pending.layer,
            (unsigned)layer_surface->pending.anchor);

    /* Assign an output if the client did not specify one */
    if (!layer_surface->output)
        layer_surface->output = wlr_output_layout_get_center_output(_state->output_layout);

    /* Select the scene sub-tree that matches the requested layer.
     * This guarantees TOP surfaces (the menu bar) always render above
     * regular xdg-toplevel windows in scene_layer_windows.             */
    struct wlr_scene_tree *parent_tree;
    switch ((int)layer_surface->pending.layer) {
        case ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND: parent_tree = _state->scene_layer_bg;      break;
        case ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM:     parent_tree = _state->scene_layer_bottom;   break;
        case ZWLR_LAYER_SHELL_V1_LAYER_TOP:        parent_tree = _state->scene_layer_top;      break;
        case ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY:    parent_tree = _state->scene_layer_overlay;  break;
        default:                                   parent_tree = _state->scene_layer_top;      break;
    }

    /* Add to the correct scene sub-tree */
    struct wlr_scene_layer_surface_v1 *scene_layer =
        wlr_scene_layer_surface_v1_create(parent_tree, layer_surface);

    struct ambrosia_layer_surface *ls = calloc(1, sizeof(*ls));
    ls->wlr_layer_surface = layer_surface;
    ls->scene_layer       = scene_layer;

    ls->surface_commit.notify = handle_layer_surface_commit;
    wl_signal_add(&layer_surface->surface->events.commit, &ls->surface_commit);

    ls->destroy.notify = handle_layer_surface_destroy;
    wl_signal_add(&layer_surface->events.destroy, &ls->destroy);

    [_layerSurfaces addObject:[NSValue valueWithPointer:ls]];
}

- (void)removeLayerSurface:(struct ambrosia_layer_surface *)ls
{
    for (NSUInteger i = 0; i < _layerSurfaces.count; i++) {
        if ([[_layerSurfaces objectAtIndex:i] pointerValue] == ls) {
            [_layerSurfaces removeObjectAtIndex:i];
            return;
        }
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Exclusive zone and usable area

/**
 * Apply exclusive zones from all mapped LAYER_TOP and LAYER_BOTTOM surfaces
 * on the given output, shrinking *box inward accordingly.  Passed as the
 * usable_area to wlr_scene_layer_surface_v1_configure so that the compositor
 * reports a correct usable area to clients via xdg-output.
 */
- (void)applyExclusiveZonesToBox:(struct wlr_box *)box
                       forOutput:(struct wlr_output *)output
{
    for (NSValue *v in _layerSurfaces) {
        struct ambrosia_layer_surface *ls = [v pointerValue];
        struct wlr_layer_surface_v1 *wls  = ls->wlr_layer_surface;
        if (wls->output != output) continue;

        int ez = wls->current.exclusive_zone;
        if (ez <= 0) continue;

        uint32_t layer  = (uint32_t)wls->current.layer;
        if (layer != ZWLR_LAYER_SHELL_V1_LAYER_TOP &&
            layer != ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM) continue;

        uint32_t anchor = wls->current.anchor;
        if (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP) {
            box->y      += ez;
            box->height -= ez;
        } else if (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM) {
            box->height -= ez;
        } else if (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT) {
            box->x     += ez;
            box->width -= ez;
        } else if (anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT) {
            box->width -= ez;
        }
    }
}

/**
 * Recompute _state->usable_top from the exclusive zones of all currently
 * mapped LAYER_TOP surfaces anchored to the top edge.  Called after every
 * layer-surface map/configure/destroy event.
 */
- (void)recalculateUsableTop
{
    int top = 0;
    for (NSValue *v in _layerSurfaces) {
        struct ambrosia_layer_surface *ls = [v pointerValue];
        struct wlr_layer_surface_v1 *wls  = ls->wlr_layer_surface;
        if ((uint32_t)wls->current.layer != ZWLR_LAYER_SHELL_V1_LAYER_TOP) continue;
        int ez = wls->current.exclusive_zone;
        if (ez <= 0) continue;
        if (wls->current.anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP) {
            if (ez > top) top = ez;
        }
    }
    _state->usable_top = top;
    wlr_log(WLR_DEBUG, "usable_top updated: %d px", top);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Layer surface hit testing

/**
 * Hit-test ONLY LAYER_TOP and LAYER_OVERLAY surfaces.
 * Used in pointer routing so the menu bar always captures input first,
 * matching its visual z-position above regular windows.
 */
- (struct wlr_surface *)topLayerSurfaceAtX:(double)x y:(double)y
                                    localX:(double *)lx
                                    localY:(double *)ly
{
    for (NSValue *v in [_layerSurfaces reverseObjectEnumerator]) {
        struct ambrosia_layer_surface *ls = [v pointerValue];
        struct wlr_layer_surface_v1 *wls  = ls->wlr_layer_surface;
        if (!wls->surface->mapped) continue;

        uint32_t layer = (uint32_t)wls->current.layer;
        if (layer != ZWLR_LAYER_SHELL_V1_LAYER_TOP &&
            layer != ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY) continue;

        double node_x = ls->scene_layer->tree->node.x;
        double node_y = ls->scene_layer->tree->node.y;
        double sub_x = 0, sub_y = 0;
        struct wlr_surface *found =
            wlr_layer_surface_v1_surface_at(wls, x - node_x, y - node_y,
                                            &sub_x, &sub_y);
        if (found) {
            if (lx) *lx = sub_x;
            if (ly) *ly = sub_y;
            return found;
        }
    }
    return NULL;
}

/** Hit-test all layer surfaces.  Returns the wlr_surface under (x,y) and
 *  fills lx/ly with the surface-local coordinates, or returns NULL. */
- (struct wlr_surface *)layerSurfaceAtX:(double)x y:(double)y
                                 localX:(double *)lx
                                 localY:(double *)ly
{
    for (NSValue *v in [_layerSurfaces reverseObjectEnumerator]) {
        struct ambrosia_layer_surface *ls = [v pointerValue];
        if (!ls->wlr_layer_surface->surface->mapped) continue;

        double node_x = ls->scene_layer->tree->node.x;
        double node_y = ls->scene_layer->tree->node.y;
        double sub_x  = 0, sub_y = 0;
        struct wlr_surface *found =
            wlr_layer_surface_v1_surface_at(ls->wlr_layer_surface,
                                            x - node_x, y - node_y,
                                            &sub_x, &sub_y);
        if (found) {
            if (lx) *lx = sub_x;
            if (ly) *ly = sub_y;
            return found;
        }
    }
    return NULL;
}

- (void)handleCursorMotionTime:(uint32_t)time dx:(double)dx dy:(double)dy
{
    wlr_cursor_move(_state->cursor, NULL, dx, dy);
    [self processCursorMotionTime:time];
}

- (void)handleCursorMotionAbsoluteTime:(uint32_t)time x:(double)x y:(double)y
                               output:(struct wlr_output *)output
{
    wlr_cursor_warp_absolute(_state->cursor, NULL, x, y);
    [self processCursorMotionTime:time];
}

- (void)handleCursorButtonTime:(uint32_t)time button:(uint32_t)button state:(uint32_t)state
{
    if (state == WL_POINTER_BUTTON_STATE_RELEASED) {
        _state->cursor_mode = AmbrosiaCursorModePassthrough;
        wlr_seat_pointer_notify_button(_state->seat, time, button,
                                       (enum wl_pointer_button_state)state);
        return;
    }

    double cx = _state->cursor->x;
    double cy = _state->cursor->y;

    /* Buttons on LAYER_TOP/OVERLAY surfaces (e.g. menu bar) are forwarded
     * directly; they do not focus or raise any window.                    */
    {
        double lsx = 0, lsy = 0;
        struct wlr_surface *top_ls =
            [self topLayerSurfaceAtX:cx y:cy localX:&lsx localY:&lsy];
        if (top_ls) {
            wlr_seat_pointer_notify_button(_state->seat, time, button,
                                           (enum wl_pointer_button_state)state);
            return;
        }
    }

    struct wlr_surface *surface = NULL;
    double sx = 0, sy = 0;
    AmbrosiaView *view = [self viewAtX:cx y:cy surface:&surface localX:&sx localY:&sy];

    /* Ctrl+Super + left button → compositor-managed window move.
     * Consume the event entirely so the client does not see the click. */
    if (button == BTN_LEFT) {
        struct wlr_keyboard *kb = wlr_seat_get_keyboard(_state->seat);
        uint32_t mods = kb ? wlr_keyboard_get_modifiers(kb) : 0;
        if ((mods & WLR_MODIFIER_CTRL) && (mods & WLR_MODIFIER_LOGO)) {
            if (view && !view.isMenu) {
                [self focusView:view surface:surface];
                [self beginMoveView:view cursor:_state->cursor];
            }
            /* Do NOT forward to client — button is consumed by compositor */
            return;
        }
    }

    /* Forward the button press to the focused client */
    wlr_seat_pointer_notify_button(_state->seat, time, button,
                                   (enum wl_pointer_button_state)state);

    if (!view) {
        /* Check if cursor is over a layer surface (e.g. GNUstep menu bar).
         * If so, don't clear keyboard focus — the menu bar handles only
         * pointer interaction and the application window keeps key focus. */
        double lsx = 0, lsy = 0;
        struct wlr_surface *ls_surface =
            [self layerSurfaceAtX:cx y:cy localX:&lsx localY:&lsy];
        if (!ls_surface) {
            [self focusView:nil surface:nil];
        }
        return;
    }

    /* Check decoration hit */
    if (view.decoration) {
        AmbrosiaDecorationHit hit = [view.decoration hitTestX:(cx - view.x) y:(cy - view.y)];
        switch (hit) {
            case AmbrosiaDecorationHitTitlebar:
                [self focusView:view surface:surface];
                [self beginMoveView:view cursor:_state->cursor];
                return;
            case AmbrosiaDecorationHitClose:
                wlr_xdg_toplevel_send_close(view.state->xdg_toplevel);
                return;
            case AmbrosiaDecorationHitMinimize:
                wlr_scene_node_set_enabled(&view.state->scene_tree->node, false);
                return;
            case AmbrosiaDecorationHitMaximize:
                wlr_xdg_toplevel_set_maximized(view.state->xdg_toplevel,
                    !view.state->xdg_toplevel->current.maximized);
                return;
            case AmbrosiaDecorationHitResizeTop:
            case AmbrosiaDecorationHitResizeBottom:
            case AmbrosiaDecorationHitResizeLeft:
            case AmbrosiaDecorationHitResizeRight:
            case AmbrosiaDecorationHitResizeTopLeft:
            case AmbrosiaDecorationHitResizeTopRight:
            case AmbrosiaDecorationHitResizeBottomLeft:
            case AmbrosiaDecorationHitResizeBottomRight: {
                uint32_t edges = 0;
                if (hit == AmbrosiaDecorationHitResizeTop         ||
                    hit == AmbrosiaDecorationHitResizeTopLeft      ||
                    hit == AmbrosiaDecorationHitResizeTopRight)     edges |= WLR_EDGE_TOP;
                if (hit == AmbrosiaDecorationHitResizeBottom       ||
                    hit == AmbrosiaDecorationHitResizeBottomLeft    ||
                    hit == AmbrosiaDecorationHitResizeBottomRight)  edges |= WLR_EDGE_BOTTOM;
                if (hit == AmbrosiaDecorationHitResizeLeft         ||
                    hit == AmbrosiaDecorationHitResizeTopLeft       ||
                    hit == AmbrosiaDecorationHitResizeBottomLeft)   edges |= WLR_EDGE_LEFT;
                if (hit == AmbrosiaDecorationHitResizeRight        ||
                    hit == AmbrosiaDecorationHitResizeTopRight      ||
                    hit == AmbrosiaDecorationHitResizeBottomRight)  edges |= WLR_EDGE_RIGHT;
                [self focusView:view surface:surface];
                [self beginResizeView:view cursor:_state->cursor edges:edges];
                return;
            }
            default:
                break;
        }
    }

    /* Click on surface – focus and pass event.
     * Menu/panel toplevels (isMenu) must not steal keyboard focus; the
     * owning application window already holds it.                       */
    if (!view.isMenu) {
        [self focusView:view surface:surface];
    }
}

- (void)handleCursorAxisTime:(uint32_t)time
                 orientation:(uint32_t)orientation
                       delta:(double)delta
               deltaDiscrete:(int32_t)discrete
{
    wlr_seat_pointer_notify_axis(_state->seat, time,
        (enum wl_pointer_axis)orientation, delta, discrete,
        WL_POINTER_AXIS_SOURCE_WHEEL,
        WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
}

- (void)handleCursorFrame
{
    wlr_seat_pointer_notify_frame(_state->seat);
}

- (void)handleNewInput:(struct wlr_input_device *)device
{
    const char *type_name = "unknown";
    switch (device->type) {
        case WLR_INPUT_DEVICE_KEYBOARD: type_name = "keyboard"; break;
        case WLR_INPUT_DEVICE_POINTER:  type_name = "pointer";  break;
        case WLR_INPUT_DEVICE_TOUCH:    type_name = "touch";    break;
        case WLR_INPUT_DEVICE_TABLET:     type_name = "tablet";     break;
        case WLR_INPUT_DEVICE_TABLET_PAD: type_name = "tablet_pad"; break;
        case WLR_INPUT_DEVICE_SWITCH:     type_name = "switch";     break;
        default: break;
    }
    wlr_log(WLR_INFO, "New input device: %s (%s)", device->name, type_name);
    [_input addDevice:device];

    /* Update seat capabilities */
    uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
    if (_input.keyboards.count > 0) caps |= WL_SEAT_CAPABILITY_KEYBOARD;
    wlr_seat_set_capabilities(_state->seat, caps);
}

- (void)handleRequestSetCursor:(struct wlr_seat_pointer_request_set_cursor_event *)event
{
    struct wlr_seat_client *focused =
        _state->seat->pointer_state.focused_client;
    if (focused != event->seat_client) return;
    wlr_cursor_set_surface(_state->cursor, event->surface,
                           event->hotspot_x, event->hotspot_y);
}

- (void)handleRequestSetSelection:(struct wlr_seat_request_set_selection_event *)event
{
    wlr_seat_set_selection(_state->seat, event->source, event->serial);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Logout / session save

- (void)_runNotificationListener
{
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleLogoutNotification:)
               name:@"AmbrosiaLogoutRequest"
             object:nil];
    wlr_log(WLR_DEBUG, "Notification listener running (AmbrosiaLogoutRequest)");
    /* Runs until the process exits; the observer keeps the loop alive. */
    [[NSRunLoop currentRunLoop] run];
}

- (void)_handleLogoutNotification:(NSNotification *)note
{
    wlr_log(WLR_INFO, "Logout requested via AmbrosiaLogoutRequest notification");
    /* Write one byte to wake up the wl_event_loop on the main thread. */
    char byte = 1;
    (void)write(_state->logout_pipe[1], &byte, 1);
}

- (void)saveSessionAndLogout
{
    wlr_log(WLR_INFO, "Saving session state and logging out");

    /* Build window list from currently mapped views */
    NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
    for (AmbrosiaView *view in _views) {
        if (!view.isMapped) continue;
        struct wlr_box geo = [view geometry];
        const char *appId = view.state->xdg_toplevel->app_id;
        const char *title = view.state->xdg_toplevel->title;
        [windows addObject:@{
            @"AppId":  appId ? [NSString stringWithUTF8String:appId] : @"",
            @"Title":  title ? [NSString stringWithUTF8String:title] : @"",
            @"X":      @(view.x),
            @"Y":      @(view.y),
            @"Width":  @(geo.width),
            @"Height": @(geo.height),
        }];
    }

    NSDictionary *state = @{
        @"SchemaVersion": @1,
        @"Windows":       windows,
    };

    /* ~/GNUstep/Library/Ambrosia/session.plist */
    NSArray *libDirs = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *dir  = [[libDirs firstObject]
                      stringByAppendingPathComponent:@"Ambrosia"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"session.plist"];

    NSError *err = nil;
    NSData  *data = [NSPropertyListSerialization
        dataWithPropertyList:state
                      format:NSPropertyListXMLFormat_v1_0
                     options:0
                       error:&err];
    if (data && [data writeToFile:path atomically:YES]) {
        wlr_log(WLR_INFO, "Session saved: %s (%lu window(s))",
                [path UTF8String], (unsigned long)windows.count);
    } else {
        wlr_log(WLR_ERROR, "Failed to save session: %s",
                err ? [[err localizedDescription] UTF8String] : "write error");
    }

    [self stop];
}

@end
