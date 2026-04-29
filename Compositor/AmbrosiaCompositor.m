#import "AmbrosiaCompositor.h"
#import "AmbrosiaOutput.h"
#import "AmbrosiaView.h"
#import "AmbrosiaXWaylandView.h"
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
- (void)focusNextWindowExcluding:(nullable id<AmbrosiaWindowView>)excluded;
/** Called from handle_activate_pipe on the wl_event_loop thread. */
- (void)_focusApplicationFromActivateRequest;
/** Called from handle_session_pipe on the wl_event_loop thread. */
- (void)_applySessionPrefsUpdate;
/** Called from handle_desktop_pipe on the wl_event_loop thread. */
- (void)_applyDesktopPrefsUpdate;
/** Pointer constraint management */
- (void)handleNewConstraint:(struct wlr_pointer_constraint_v1 *)constraint;
- (void)activateConstraintForSurface:(struct wlr_surface *)surface;
- (void)deactivateActiveConstraint;
- (void)handleActiveConstraintDestroy;
/** Compositor prefs (X11 decorations etc.) */
- (void)_handleCompPrefsNotification:(NSNotification *)note;
- (void)_applyCompPrefsUpdate;
- (void)_applyX11DecorationsEnabled:(BOOL)enabled colors:(NSDictionary *)colors;
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

static void handle_output_manager_apply(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, output_manager_apply);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleOutputManagerApply:(struct wlr_output_configuration_v1 *)data];
}

static void handle_output_manager_test(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, output_manager_test);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleOutputManagerTest:(struct wlr_output_configuration_v1 *)data];
}

static void handle_drm_lease_request(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, drm_lease_request);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleDrmLeaseRequest:(struct wlr_drm_lease_request_v1 *)data];
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

/* Activate pipe watcher — called on the compositor's wl_event_loop thread */
static int handle_activate_pipe(int fd, uint32_t mask, void *data)
{
    char byte;
    (void)read(fd, &byte, 1); /* drain */
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)data;
    [c _focusApplicationFromActivateRequest];
    return 0;
}

/* Session-prefs pipe watcher — called on the compositor's wl_event_loop thread */
static int handle_session_pipe(int fd, uint32_t mask, void *data)
{
    char byte;
    while (read(fd, &byte, 1) == 1) {} /* drain all queued bytes */
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)data;
    [c _applySessionPrefsUpdate];
    return 0;
}

/* Desktop-prefs pipe watcher — called on the compositor's wl_event_loop thread */
static int handle_desktop_pipe(int fd, uint32_t mask, void *data)
{
    char byte;
    while (read(fd, &byte, 1) == 1) {} /* drain all queued bytes */
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)data;
    [c _applyDesktopPrefsUpdate];
    return 0;
}

/* Compositor-prefs pipe watcher — called on the compositor's wl_event_loop thread */
static int handle_comp_pipe(int fd, uint32_t mask, void *data)
{
    char byte;
    while (read(fd, &byte, 1) == 1) {}
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)data;
    [c _applyCompPrefsUpdate];
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
 * Pointer constraint C-level callbacks
 * -------------------------------------------------------------------------- */

static void handle_new_pointer_constraint(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_constraint);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewConstraint:(struct wlr_pointer_constraint_v1 *)data];
}

static void handle_active_constraint_destroy(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, constraint_destroy);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleActiveConstraintDestroy];
}

/* --------------------------------------------------------------------------
 * XWayland C-level callbacks
 * -------------------------------------------------------------------------- */

static void handle_xwayland_ready(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, xwayland_ready);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleXWaylandReady];
}

static void handle_new_xwayland_surface(struct wl_listener *listener, void *data)
{
    struct ambrosia_compositor_state *s =
        wl_container_of(listener, s, new_xwayland_surface);
    AmbrosiaCompositor *c = (__bridge AmbrosiaCompositor *)s->objc_compositor;
    [c handleNewXWaylandSurface:(struct wlr_xwayland_surface *)data];
}

/* --------------------------------------------------------------------------
 * AmbrosiaCompositor
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaCompositor {
    struct ambrosia_compositor_state *_state;
    NSMutableArray                   *_views;          /* id<AmbrosiaWindowView> */
    NSMutableArray<AmbrosiaOutput *> *_outputs;
    NSMutableArray                   *_layerSurfaces;
    AmbrosiaInput                    *_input;
    id<AmbrosiaWindowView>            _focusedView;
    AmbrosiaSession                  *_session;
    AmbrosiaBackground               *_background;
    BOOL                              _running;

    /* Pending activate request — written by the notification thread,
     * consumed by the compositor's wl_event_loop thread.              */
    NSString *_pendingActivateBundleID;
    NSString *_pendingActivateLaunchPath;
    NSString *_pendingActivateAppName;
    NSLock   *_activateLock;

    /* Pending session-prefs update — written by the notification thread,
     * consumed by the compositor's wl_event_loop thread.              */
    NSArray  *_pendingSessionItems;
    NSLock   *_sessionLock;

    /* Pending desktop-prefs update — written by the notification thread,
     * consumed by the compositor's wl_event_loop thread.              */
    NSDictionary *_pendingDesktopPrefs;
    NSLock       *_desktopLock;

    /* Pending compositor-prefs update */
    NSDictionary *_pendingCompPrefs;
    NSLock       *_compLock;

    /* Current X11 decoration state (applied on compositor thread) */
    BOOL          _x11Decorations;
    NSDictionary *_x11DecorationColors;
}

@synthesize state               = _state;
@synthesize session             = _session;
@synthesize background          = _background;
@synthesize views               = _views;
@synthesize outputs             = _outputs;
@synthesize layerSurfaces       = _layerSurfaces;
@synthesize x11Decorations      = _x11Decorations;
@synthesize x11DecorationColors = _x11DecorationColors;

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    _views         = [NSMutableArray array];
    _outputs       = [NSMutableArray array];
    _layerSurfaces = [NSMutableArray array];
    _activateLock  = [[NSLock alloc] init];
    _sessionLock   = [[NSLock alloc] init];
    _desktopLock   = [[NSLock alloc] init];
    _compLock      = [[NSLock alloc] init];
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
    _state->compositor = wlr_compositor_create(_state->display, 5, _state->renderer);
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
    _state->scene_layer_bg          = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_bottom      = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_windows     = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_top         = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_fullscreen  = wlr_scene_tree_create(&_state->scene->tree);
    _state->scene_layer_overlay     = wlr_scene_tree_create(&_state->scene->tree);
    _state->usable_top = 0;
    wlr_log(WLR_DEBUG, "Scene graph initialised (layered sub-trees created)");

    /* Background manager — reads wallpaper prefs and renders into scene_layer_bg. */
    _background = [[AmbrosiaBackground alloc]
                   initWithEventLoop:_state->event_loop
                           sceneTree:_state->scene_layer_bg
                        outputLayout:_state->output_layout];
    [_background applyPreferencesFromPlist];

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

    /* wp-viewporter — allows clients to crop and scale surface content
     * without reallocating buffers; required by many Wayland clients
     * (e.g. video players, game engines) for efficient scaling.           */
    _state->viewporter = wlr_viewporter_create(_state->display);
    wlr_log(WLR_DEBUG, "Viewporter created");

    /* xdg-output-manager (zxdg_output_manager_v1) — lets clients query logical
     * output geometry (position, size, name) from the compositor's output layout. */
    _state->xdg_output_manager =
        wlr_xdg_output_manager_v1_create(_state->display, _state->output_layout);
    wlr_log(WLR_DEBUG, "XDG output manager created");

    /* wlr-output-management-unstable-v1 — lets clients (e.g. wlr-randr, kanshi)
     * enumerate outputs and request configuration changes (mode, scale, position,
     * transform, enable/disable, adaptive sync).                                 */
    _state->output_manager = wlr_output_manager_v1_create(_state->display);
    wlr_log(WLR_DEBUG, "Output manager created");

    /* wp-drm-lease-device-v1 — allows VR runtimes (e.g. Monado/OpenXR) to
     * acquire a DRM lease for non-desktop connectors (VR headsets).  Returns
     * NULL when not running on a DRM backend; that is harmless.              */
    _state->drm_lease_manager =
        wlr_drm_lease_v1_manager_create(_state->display, _state->backend);
    if (_state->drm_lease_manager) {
        _state->drm_lease_request.notify = handle_drm_lease_request;
        wl_signal_add(&_state->drm_lease_manager->events.request,
                      &_state->drm_lease_request);
        wlr_log(WLR_INFO, "DRM lease manager created (VR headset support enabled)");
    } else {
        wlr_log(WLR_DEBUG, "DRM lease manager not available (non-DRM backend)");
    }

    /* zwp_relative_pointer_manager_v1 — lets clients receive unclipped relative
     * pointer deltas (used by SteamVR for the desktop mirror overlay and by
     * games that capture the mouse).                                          */
    _state->relative_pointer_manager =
        wlr_relative_pointer_manager_v1_create(_state->display);
    wlr_log(WLR_DEBUG, "Relative pointer manager created");

    /* zwp_pointer_constraints_v1 — lets clients lock or confine the pointer
     * (used by SteamVR desktop mirror and by first-person games/apps).       */
    _state->pointer_constraints =
        wlr_pointer_constraints_v1_create(_state->display);
    _state->new_constraint.notify = handle_new_pointer_constraint;
    wl_signal_add(&_state->pointer_constraints->events.new_constraint,
                  &_state->new_constraint);
    wlr_log(WLR_DEBUG, "Pointer constraints created");

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

    _state->output_manager_apply.notify = handle_output_manager_apply;
    wl_signal_add(&_state->output_manager->events.apply, &_state->output_manager_apply);

    _state->output_manager_test.notify = handle_output_manager_test;
    wl_signal_add(&_state->output_manager->events.test, &_state->output_manager_test);

    /* Input handler */
    _input = [[AmbrosiaInput alloc] initWithCompositor:self];

    /* XWayland — started lazily; Xwayland process spawns when first X11 client
     * connects.  display_name is determined at creation time (the X socket is
     * opened synchronously) so DISPLAY can be exported before the session
     * starts.  The ready callback merely completes the XWM handshake.        */
    _state->xwayland = wlr_xwayland_create(_state->display, _state->compositor, false);
    if (_state->xwayland) {
        _state->xwayland_ready.notify = handle_xwayland_ready;
        wl_signal_add(&_state->xwayland->events.ready, &_state->xwayland_ready);
        _state->new_xwayland_surface.notify = handle_new_xwayland_surface;
        wl_signal_add(&_state->xwayland->events.new_surface, &_state->new_xwayland_surface);
        wlr_log(WLR_INFO, "XWayland initialised");
    } else {
        wlr_log(WLR_ERROR, "Failed to initialise XWayland — X11 apps will not work");
    }

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

    /* Activate self-pipe: background NSRunLoop thread → wl_event_loop */
    if (pipe(_state->activate_pipe) != 0) {
        wlr_log(WLR_ERROR, "Failed to create activate pipe: %s", strerror(errno));
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:6
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create activate pipe"}];
        return NO;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(_state->activate_pipe[i], F_SETFD, FD_CLOEXEC);
        fcntl(_state->activate_pipe[i], F_SETFL,
              fcntl(_state->activate_pipe[i], F_GETFL) | O_NONBLOCK);
    }
    _state->activate_source = wl_event_loop_add_fd(
        _state->event_loop,
        _state->activate_pipe[0],
        WL_EVENT_READABLE,
        handle_activate_pipe,
        (__bridge void *)self);

    /* Session-prefs self-pipe: background NSRunLoop thread → wl_event_loop */
    if (pipe(_state->session_pipe) != 0) {
        wlr_log(WLR_ERROR, "Failed to create session pipe: %s", strerror(errno));
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:7
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create session pipe"}];
        return NO;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(_state->session_pipe[i], F_SETFD, FD_CLOEXEC);
        fcntl(_state->session_pipe[i], F_SETFL,
              fcntl(_state->session_pipe[i], F_GETFL) | O_NONBLOCK);
    }
    _state->session_source = wl_event_loop_add_fd(
        _state->event_loop,
        _state->session_pipe[0],
        WL_EVENT_READABLE,
        handle_session_pipe,
        (__bridge void *)self);

    /* Desktop-prefs self-pipe: background notification thread → wl_event_loop */
    if (pipe(_state->desktop_pipe) != 0) {
        wlr_log(WLR_ERROR, "Failed to create desktop pipe: %s", strerror(errno));
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:8
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create desktop pipe"}];
        return NO;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(_state->desktop_pipe[i], F_SETFD, FD_CLOEXEC);
        fcntl(_state->desktop_pipe[i], F_SETFL,
              fcntl(_state->desktop_pipe[i], F_GETFL) | O_NONBLOCK);
    }
    _state->desktop_source = wl_event_loop_add_fd(
        _state->event_loop,
        _state->desktop_pipe[0],
        WL_EVENT_READABLE,
        handle_desktop_pipe,
        (__bridge void *)self);

    /* Compositor-prefs self-pipe: background notification thread → wl_event_loop */
    if (pipe(_state->comp_pipe) != 0) {
        wlr_log(WLR_ERROR, "Failed to create comp pipe: %s", strerror(errno));
        if (error) *error = [NSError errorWithDomain:@"AmbrosiaCompositor"
                                                code:9
                                            userInfo:@{NSLocalizedDescriptionKey:@"Failed to create comp pipe"}];
        return NO;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(_state->comp_pipe[i], F_SETFD, FD_CLOEXEC);
        fcntl(_state->comp_pipe[i], F_SETFL,
              fcntl(_state->comp_pipe[i], F_GETFL) | O_NONBLOCK);
    }
    _state->comp_source = wl_event_loop_add_fd(
        _state->event_loop,
        _state->comp_pipe[0],
        WL_EVENT_READABLE,
        handle_comp_pipe,
        (__bridge void *)self);

    /* Load initial compositor prefs from disk */
    {
        NSString *prefsDir = nil;
        const char *userLib = getenv("GNUSTEP_USER_LIBRARY");
        if (userLib && userLib[0])
            prefsDir = [[NSString stringWithUTF8String:userLib]
                        stringByAppendingPathComponent:@"Preferences"];
        else {
            NSArray *dirs = NSSearchPathForDirectoriesInDomains(
                NSLibraryDirectory, NSUserDomainMask, YES);
            prefsDir = [[dirs.firstObject ?: NSHomeDirectory()
                         stringByAppendingPathComponent:@"Preferences"]
                        copy];
        }
        NSString *plistPath = [prefsDir
            stringByAppendingPathComponent:@"org.gnustep.AmbrosiaCompositor.plist"];
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (p) {
            _x11Decorations     = [p[@"x11Decorations"] boolValue];
            _x11DecorationColors = p;
            wlr_log(WLR_INFO, "Compositor prefs loaded: x11Decorations=%s",
                    _x11Decorations ? "YES" : "NO");
        }
    }

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

    if (_state->xwayland && _state->xwayland->display_name) {
        setenv("DISPLAY", _state->xwayland->display_name, 1);
        wlr_log(WLR_INFO, "XWayland socket ready: DISPLAY=%s", _state->xwayland->display_name);
    }

    /* Start the session manager — launches AmbrosiaDock and GFinder,
     * restarting either automatically if they exit unexpectedly.     */
    _session = AmbrosiaSessionCreateDefault(_state->event_loop);
    [_session start];

    /* Background thread: pumps NSRunLoop so NSDistributedNotificationCenter
     * can deliver "AmbrosiaLogoutRequest" and "AmbrosiaActivateApplication"
     * notifications.  Handlers write one byte to the corresponding self-pipe;
     * the wl_event_loop thread wakes up and processes the request there.    */
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
    if (_state->activate_source) {
        wl_event_source_remove(_state->activate_source);
        _state->activate_source = NULL;
    }
    close(_state->activate_pipe[0]);
    close(_state->activate_pipe[1]);
    if (_state->session_source) {
        wl_event_source_remove(_state->session_source);
        _state->session_source = NULL;
    }
    close(_state->session_pipe[0]);
    close(_state->session_pipe[1]);

    if (_state->desktop_source) {
        wl_event_source_remove(_state->desktop_source);
        _state->desktop_source = NULL;
    }
    close(_state->desktop_pipe[0]);
    close(_state->desktop_pipe[1]);
    if (_state->comp_source) {
        wl_event_source_remove(_state->comp_source);
        _state->comp_source = NULL;
    }
    close(_state->comp_pipe[0]);
    close(_state->comp_pipe[1]);
    [_background stop];
    _background = nil;

    /* Tear down all Wayland client connections first.  This causes gnustep-back
     * inside each session process to receive a connection error, which unblocks
     * any pending Wayland call and lets the app's NSRunLoop drain and exit
     * cleanly.  Only then do we send SIGTERM and wait — avoiding a deadlock
     * where a process is blocked on a Wayland round-trip that will never
     * complete because the event loop has already stopped.                   */
    wl_display_destroy_clients(_state->display);
    [_session stop];
    _session = nil;
    if (_state->xwayland) {
        wlr_xwayland_destroy(_state->xwayland);
        _state->xwayland = NULL;
    }
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

- (void)addView:(id<AmbrosiaWindowView>)view
{
    [_views addObject:view];
    wlr_log(WLR_DEBUG, "View added (total: %lu)", (unsigned long)_views.count);
}

- (void)removeView:(id<AmbrosiaWindowView>)view
{
    if (_focusedView == view) _focusedView = nil;
    [_views removeObject:view];
    wlr_log(WLR_DEBUG, "View removed (total: %lu)", (unsigned long)_views.count);
}

- (nullable id<AmbrosiaWindowView>)viewAtX:(double)x y:(double)y
                                   surface:(struct wlr_surface **)surfaceOut
                                    localX:(double *)lx
                                    localY:(double *)ly
{
    NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];

    /* Iterate top-to-bottom (last added = topmost) */
    for (NSInteger i = (NSInteger)_views.count - 1; i >= 0; i--) {
        id<AmbrosiaWindowView> view = _views[(NSUInteger)i];
        if (!view.isMapped) continue;

        double sx = 0, sy = 0;
        struct wlr_surface *found = [view surfaceAt:x y:y localX:&sx localY:&sy];

        if (found) {
            if (surfaceOut) *surfaceOut = found;
            if (lx) *lx = sx;
            if (ly) *ly = sy;
            return view;
        }

        /* The titlebar/borders are compositor-drawn rects, not Wayland surfaces.
         * Check whether the cursor is inside the decorated bounding box.
         * The decoration extends insets.left left and insets.top above the
         * surface, so shift to frame-relative coordinates for the test.      */
        if (view.decoration) {
            struct wlr_box geo = [view geometry];
            double frameW = insets.left + geo.width  + insets.right;
            double frameH = insets.top  + geo.height + insets.bottom;
            double dx = x - view.x + insets.left;   /* frame-relative x */
            double dy = y - view.y + insets.top;    /* frame-relative y */
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

- (void)focusView:(nullable id<AmbrosiaWindowView>)view
          surface:(nullable struct wlr_surface *)surface
{
    if (_focusedView == view) return;

    /*
     * Modal-dialog protection (XDG toplevels only): if the currently focused
     * XDG app has a mapped transient child, redirect focus to that dialog.
     */
    if ([_focusedView isKindOfClass:[AmbrosiaView class]]) {
        AmbrosiaView *xdgFocused = (AmbrosiaView *)_focusedView;
        struct wl_client *focusedClient =
            wl_resource_get_client(xdgFocused.state->xdg_toplevel->base->resource);

        AmbrosiaView *modal = nil;
        for (id<AmbrosiaWindowView> candidate in _views) {
            if (![candidate isKindOfClass:[AmbrosiaView class]]) continue;
            AmbrosiaView *v = (AmbrosiaView *)candidate;
            if (!v.isMapped) continue;
            struct wlr_xdg_toplevel *tp = v.state->xdg_toplevel;
            if (!tp->parent) continue;
            struct wl_client *parentClient =
                wl_resource_get_client(tp->parent->base->resource);
            if (parentClient == focusedClient) {
                modal = v;
            }
        }

        if (modal && (id<AmbrosiaWindowView>)modal != view) {
            wlr_log(WLR_DEBUG,
                "focusView: redirecting to modal dialog '%s'",
                modal.state->xdg_toplevel->title ?: "(untitled)");
            view    = modal;
            surface = modal.surface;
        }
    }

    if (_focusedView == view) return;

    if (view) {
        if ([view isKindOfClass:[AmbrosiaView class]]) {
            AmbrosiaView *v = (AmbrosiaView *)view;
            wlr_log(WLR_DEBUG, "Focus: %s [%s]",
                    v.state->xdg_toplevel->title  ?: "(untitled)",
                    v.state->xdg_toplevel->app_id ?: "(unknown)");
        } else if ([view isKindOfClass:[AmbrosiaXWaylandView class]]) {
            AmbrosiaXWaylandView *v = (AmbrosiaXWaylandView *)view;
            wlr_log(WLR_DEBUG, "Focus XWayland: %s [%s]",
                    v.state->xwayland_surface->title ?: "(untitled)",
                    v.state->xwayland_surface->class ?: "(unknown)");
        }
    } else {
        wlr_log(WLR_DEBUG, "Focus cleared");
    }

    /* Track previous pid for app-change detection. */
    pid_t prevPid = [_focusedView clientPid];

    /* Unfocus previous */
    if (_focusedView) {
        _focusedView.decoration.focused = NO;
        [_focusedView.decoration updateWithWidth:0 height:0 title:nil];
        [_focusedView activateFocus:NO];
    }

    /* Release any active pointer constraint before transferring focus. */
    [self deactivateActiveConstraint];

    _focusedView = view;

    if (!view) {
        wlr_seat_keyboard_notify_clear_focus(_state->seat);
        return;
    }

    view.decoration.focused = YES;

    /* Raise to top of view list and scene graph */
    [_views removeObject:view];
    [_views addObject:view];
    [view raiseSceneNode];

    /* Activate the window (XDG: set_activated; XWayland: activate + offer_focus) */
    [view activateFocus:YES];

    /* Notify seat keyboard */
    struct wlr_keyboard *kb = wlr_seat_get_keyboard(_state->seat);
    struct wlr_surface *focusSurface = surface ?: [view surface];
    if (kb && focusSurface) {
        wlr_seat_keyboard_notify_enter(_state->seat,
            focusSurface, kb->keycodes, kb->num_keycodes, &kb->modifiers);
    }

    /* Re-activate any pointer constraint registered for this surface. */
    if (focusSurface)
        [self activateConstraintForSurface:focusSurface];

    /* Redraw decoration to show focused state */
    [view updateTitle];

    /* Broadcast AmbrosiaApplicationActivated when the active app changes.
     *
     * Keyed on client PID — this works for both Wayland (one pid per process)
     * and XWayland (each X11 app has a distinct pid via xsurface->pid).
     * Also include a best-effort app name so the menu bar can label non-GNUstep
     * windows without needing a /proc lookup: XDG uses app_id, XWayland uses
     * WM_CLASS (the class field), with title as fallback for both.            */
    pid_t newPid = [view clientPid];
    if (newPid > 0 && newPid != prevPid) {
        NSMutableDictionary *activateInfo =
            [@{ @"pid": @((int32_t)newPid) } mutableCopy];

        const char *rawName = NULL;
        if ([view isKindOfClass:[AmbrosiaView class]]) {
            AmbrosiaView *xdg = (AmbrosiaView *)view;
            rawName = xdg.state->xdg_toplevel->app_id
                   ?: xdg.state->xdg_toplevel->title;
        } else if ([view isKindOfClass:[AmbrosiaXWaylandView class]]) {
            AmbrosiaXWaylandView *xw = (AmbrosiaXWaylandView *)view;
            rawName = xw.state->xwayland_surface->class
                   ?: xw.state->xwayland_surface->title;
        }
        if (rawName && rawName[0])
            activateInfo[@"appName"] = @(rawName);

        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:@"AmbrosiaApplicationActivated"
                          object:nil
                        userInfo:activateInfo
              deliverImmediately:YES];
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Move / Resize

- (void)beginMoveView:(id<AmbrosiaWindowView>)view cursor:(struct wlr_cursor *)cursor
{
    wlr_log(WLR_DEBUG, "Begin move");
    _state->cursor_mode = AmbrosiaCursorModeMove;
    _state->grab_x = cursor->x - view.x;
    _state->grab_y = cursor->y - view.y;
}

- (void)beginResizeView:(id<AmbrosiaWindowView>)view
                 cursor:(struct wlr_cursor *)cursor
                  edges:(uint32_t)edges
{
    wlr_log(WLR_DEBUG, "Begin resize (edges: 0x%x)", edges);
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
        id<AmbrosiaWindowView> grabbed = _focusedView;
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
        id<AmbrosiaWindowView> grabbed = _focusedView;
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

        if ([grabbed isKindOfClass:[AmbrosiaView class]]) {
            wlr_xdg_toplevel_set_size(((AmbrosiaView *)grabbed).state->xdg_toplevel,
                                      (uint32_t)new_geo.width, (uint32_t)new_geo.height);
        } else if ([grabbed isKindOfClass:[AmbrosiaXWaylandView class]]) {
            AmbrosiaXWaylandView *xw = (AmbrosiaXWaylandView *)grabbed;
            wlr_xwayland_surface_configure(xw.state->xwayland_surface,
                (int16_t)new_geo.x, (int16_t)new_geo.y,
                (uint16_t)new_geo.width, (uint16_t)new_geo.height);
            if (xw.decoration) {
                const char *raw = xw.state->xwayland_surface->title;
                NSString *title = raw ? [NSString stringWithUTF8String:raw] : @"";
                [xw.decoration updateWithWidth:new_geo.width
                                        height:new_geo.height
                                         title:title];
            }
        }
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
     * a window's geometry overlaps its coordinate range.
     *
     * Cursor reset rule: only reset to the default xcursor when the pointer
     * enters a DIFFERENT surface.  If still over the same surface, leave the
     * cursor image alone so that a client-set cursor (e.g. a game crosshair
     * or an invisible cursor for pointer-locked apps) is not overwritten on
     * every frame.                                                           */
    NSEdgeInsets insets       = [AmbrosiaDecoration frameInsets];
    struct wlr_surface *prev_focused = _state->seat->pointer_state.focused_surface;

    {
        double lsx = 0, lsy = 0;
        struct wlr_surface *top_ls =
            [self topLayerSurfaceAtX:cx y:cy localX:&lsx localY:&lsy];
        if (top_ls) {
            /*
             * GNUstep's Wayland backend conflates wl_pointer.enter with
             * key-window activation.  If a non-menu xdg-toplevel from the
             * same Wayland client as this layer surface is keyboard-focused
             * (e.g. an NSAlert modal shown by the MenuServer process), do
             * NOT deliver wl_pointer.enter to the bar.  Doing so would make
             * the bar panel key, fire NSApplicationDidResignActiveNotification
             * in the client, and terminate the modal session — closing the
             * alert before the user can interact with it.
             *
             * When this guard fires the pointer falls through to normal
             * xdg-toplevel hit-testing so the alert itself can still receive
             * pointer events.
             */
            BOOL skipLayerPointer = NO;
            if (_focusedView && !_focusedView.isMenu) {
                struct wl_client *focusedClient = [_focusedView waylandClient];
                for (NSValue *v in _layerSurfaces) {
                    struct ambrosia_layer_surface *ls = [v pointerValue];
                    if (!ls->wlr_layer_surface->surface->mapped) continue;
                    uint32_t layer = (uint32_t)ls->wlr_layer_surface->current.layer;
                    if (layer != ZWLR_LAYER_SHELL_V1_LAYER_TOP &&
                        layer != ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY) continue;
                    struct wl_client *lsClient = wl_resource_get_client(
                        ls->wlr_layer_surface->resource);
                    if (lsClient == focusedClient) {
                        skipLayerPointer = YES;
                        break;
                    }
                }
            }
            if (!skipLayerPointer) {
                if (top_ls != prev_focused)
                    wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
                wlr_seat_pointer_notify_enter(_state->seat, top_ls, lsx, lsy);
                wlr_seat_pointer_notify_motion(_state->seat, time, lsx, lsy);
                return;
            }
        }
    }

    struct wlr_surface *surface = NULL;
    double sx = 0, sy = 0;
    id<AmbrosiaWindowView> view = [self viewAtX:cx y:cy surface:&surface localX:&sx localY:&sy];

    if (view) {
        /* Check if pointer is over a decoration */
        if (view.decoration) {
            AmbrosiaDecorationHit hit = [view.decoration hitTestX:(cx - view.x + insets.left)
                                                                  y:(cy - view.y + insets.top)];
            if (hit != AmbrosiaDecorationHitNone) {
                wlr_seat_pointer_notify_clear_focus(_state->seat);
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
            /* Only reset to default on surface entry; leave client cursor alone
             * during normal motion over the same surface.                      */
            if (surface != prev_focused)
                wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
            wlr_seat_pointer_notify_enter(_state->seat, surface, sx, sy);
            wlr_seat_pointer_notify_motion(_state->seat, time, sx, sy);
        } else {
            wlr_seat_pointer_notify_clear_focus(_state->seat);
            wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
        }
    } else {
        /* No xdg toplevel at this position — check lower layer surfaces */
        double lsx = 0, lsy = 0;
        struct wlr_surface *ls_surface =
            [self layerSurfaceAtX:cx y:cy localX:&lsx localY:&lsy];
        if (ls_surface) {
            if (ls_surface != prev_focused)
                wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
            wlr_seat_pointer_notify_enter(_state->seat, ls_surface, lsx, lsy);
            wlr_seat_pointer_notify_motion(_state->seat, time, lsx, lsy);
        } else {
            wlr_seat_pointer_notify_clear_focus(_state->seat);
            wlr_cursor_set_xcursor(_state->cursor, _state->cursor_mgr, "default");
        }
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Pointer constraint management

- (void)handleNewConstraint:(struct wlr_pointer_constraint_v1 *)constraint
{
    /* Activate immediately if the constrained surface is already pointer-focused. */
    struct wlr_surface *focused = _state->seat->pointer_state.focused_surface;
    if (focused && focused == constraint->surface)
        [self activateConstraintForSurface:constraint->surface];
}

- (void)activateConstraintForSurface:(struct wlr_surface *)surface
{
    if (!_state->pointer_constraints || !surface) return;
    struct wlr_pointer_constraint_v1 *constraint =
        wlr_pointer_constraints_v1_constraint_for_surface(
            _state->pointer_constraints, surface, _state->seat);
    if (!constraint || constraint == _state->active_constraint) return;

    [self deactivateActiveConstraint];

    _state->active_constraint = constraint;
    _state->constraint_destroy.notify = handle_active_constraint_destroy;
    wl_signal_add(&constraint->events.destroy, &_state->constraint_destroy);
    wlr_pointer_constraint_v1_send_activated(constraint);
    wlr_log(WLR_DEBUG, "Pointer constraint activated (%s)",
            constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED
                ? "locked" : "confined");
}

- (void)deactivateActiveConstraint
{
    if (!_state->active_constraint) return;
    wl_list_remove(&_state->constraint_destroy.link);
    wlr_pointer_constraint_v1_send_deactivated(_state->active_constraint);
    wlr_log(WLR_DEBUG, "Pointer constraint deactivated");
    _state->active_constraint = NULL;
}

- (void)handleActiveConstraintDestroy
{
    /* Constraint was destroyed by the client — clear without sending deactivated. */
    wl_list_remove(&_state->constraint_destroy.link);
    _state->active_constraint = NULL;
    wlr_log(WLR_DEBUG, "Active pointer constraint destroyed by client");
}

/* ---------------------------------------------------------------------- */
#pragma mark - Callback implementations

- (void)handleNewOutput:(struct wlr_output *)output
{
    wlr_log(WLR_INFO, "New output: %s%s", output->name,
            output->non_desktop ? " [non-desktop]" : "");

    /* Non-desktop connectors (VR headsets) are offered to the DRM lease
     * manager so an OpenXR runtime can acquire them directly.  They are not
     * added to the output layout or rendered by the compositor.             */
    if (output->non_desktop) {
        wlr_log(WLR_INFO, "Non-desktop output detected: %s (VR headset / direct-mode display)",
                output->name);
        if (_state->drm_lease_manager) {
            if (wlr_drm_lease_v1_manager_offer_output(_state->drm_lease_manager, output)) {
                wlr_log(WLR_INFO, "Output %s offered via wp-drm-lease-device-v1 "
                                  "(VR runtimes can now request a DRM lease)", output->name);
            } else {
                wlr_log(WLR_ERROR, "Failed to offer non-desktop output %s for DRM lease — "
                                   "check that the backend is a DRM backend and the output "
                                   "belongs to it", output->name);
            }
        } else {
            wlr_log(WLR_INFO, "Output %s is non-desktop but DRM lease manager unavailable "
                              "(not running on a DRM backend?); ignoring", output->name);
        }
        return;
    }

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

    /* Render the desktop background on this output. */
    [_background handleOutputAdded:output];

    [self notifyOutputManager];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Output management (wlr-output-management-unstable-v1)

/**
 * Broadcasts the current output configuration to all connected
 * wlr-output-management clients.  Must be called whenever the set of
 * active outputs changes or a configuration is applied.
 */
- (void)notifyOutputManager
{
    if (!_state->output_manager) return;

    struct wlr_output_configuration_v1 *config =
        wlr_output_configuration_v1_create();

    /* wlr_output_configuration_head_v1_create() auto-fills state (enabled,
     * mode, scale, transform, position, adaptive_sync) from the output and
     * output-layout objects.                                                */
    for (AmbrosiaOutput *ambOutput in _outputs) {
        wlr_output_configuration_head_v1_create(config, ambOutput.state->output);
    }

    /* Transfers ownership of config to the manager. */
    wlr_output_manager_v1_set_configuration(_state->output_manager, config);
}

/**
 * Apply a client-requested output configuration atomically.
 * Uses wlr_backend_test then wlr_backend_commit so that either ALL
 * outputs transition to the new state or none do.
 */
- (void)handleOutputManagerApply:(struct wlr_output_configuration_v1 *)config
{
    size_t states_len = 0;
    struct wlr_backend_output_state *states =
        wlr_output_configuration_v1_build_state(config, &states_len);

    BOOL ok = NO;
    if (states) {
        /* Test before committing so we don't leave outputs in a broken state */
        ok = wlr_backend_test(_state->backend, states, states_len);
        if (ok) {
            ok = wlr_backend_commit(_state->backend, states, states_len);
        }
        free(states);
    }

    if (ok) {
        /* Update output-layout positions for every enabled head.
         * wlr_output_layout_add() switches the output from auto-placed to
         * explicitly positioned, honouring whatever the client requested.   */
        struct wlr_output_configuration_head_v1 *head;
        wl_list_for_each(head, &config->heads, link) {
            if (!head->state.enabled) continue;
            wlr_output_layout_add(_state->output_layout,
                                  head->state.output,
                                  head->state.x,
                                  head->state.y);
        }
        wlr_output_configuration_v1_send_succeeded(config);
        wlr_log(WLR_INFO, "Output manager: configuration applied");
    } else {
        wlr_output_configuration_v1_send_failed(config);
        wlr_log(WLR_ERROR, "Output manager: configuration apply failed");
    }

    /* Config ownership transfers to us on the apply signal; destroy it now. */
    wlr_output_configuration_v1_destroy(config);

    /* Broadcast updated state regardless of success so clients stay in sync. */
    [self notifyOutputManager];
}

/**
 * Test a client-requested output configuration without committing it.
 * Sends succeeded/failed feedback but makes no persistent changes.
 */
- (void)handleOutputManagerTest:(struct wlr_output_configuration_v1 *)config
{
    size_t states_len = 0;
    struct wlr_backend_output_state *states =
        wlr_output_configuration_v1_build_state(config, &states_len);

    BOOL ok = (states != NULL) &&
              wlr_backend_test(_state->backend, states, states_len);
    free(states);

    if (ok) {
        wlr_output_configuration_v1_send_succeeded(config);
    } else {
        wlr_output_configuration_v1_send_failed(config);
    }
    wlr_output_configuration_v1_destroy(config);
}

/* ---------------------------------------------------------------------- */
#pragma mark - DRM lease (wp-drm-lease-device-v1 / VR headset support)

/**
 * A client (e.g. an OpenXR runtime like Monado) is requesting a DRM lease
 * for one or more non-desktop connectors.  Grant it unconditionally — the
 * lease manager already validated that all requested connectors are offered
 * and not already leased.  The wlr_output objects for the leased connectors
 * are destroyed for the duration of the lease and re-emitted via
 * backend->events.new_output when the lease ends.
 */
- (void)handleDrmLeaseRequest:(struct wlr_drm_lease_request_v1 *)request
{
    for (size_t i = 0; i < request->n_connectors; i++) {
        struct wlr_output *out = request->connectors[i]->output;
        wlr_log(WLR_INFO, "DRM lease request: connector[%zu] = %s",
                i, out ? out->name : "(null)");
    }
    wlr_log(WLR_INFO, "DRM lease: granting request for %zu connector(s)",
            request->n_connectors);

    struct wlr_drm_lease_v1 *lease = wlr_drm_lease_request_v1_grant(request);
    if (lease) {
        wlr_log(WLR_INFO, "DRM lease granted — VR client now has direct display access");
    } else {
        wlr_log(WLR_ERROR, "DRM lease grant failed (drmModeCreateLease returned error); "
                           "rejecting — check kernel logs for CRTC/connector routing issues");
        wlr_drm_lease_request_v1_reject(request);
    }
}

/* ---------------------------------------------------------------------- */

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
    /* Always use client-side decorations: GNUstep windows draw their own
     * chrome and borderless panels must not receive an unwanted server frame.
     *
     * wlr_xdg_toplevel_decoration_v1_set_mode() calls
     * wlr_xdg_surface_schedule_configure(), which asserts surface->initialized.
     * That flag is set only after the client's first wl_surface.commit, but
     * new_toplevel_decoration fires before that commit.  When the surface is
     * not yet initialized, prime scheduled_mode directly; the decoration
     * module's internal surface_configure listener (WLR_PRIVATE) will include
     * it in the initial configure that handle_surface_commit schedules on
     * initial_commit.  If the decoration is bound late (surface already
     * initialized) the normal path is safe to use immediately. */
    if (decoration->toplevel->base->initialized) {
        wlr_xdg_toplevel_decoration_v1_set_mode(decoration,
            WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE);
    } else {
        decoration->scheduled_mode =
            WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
    }
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

- (void)handleXWaylandReady
{
    wlr_log(WLR_INFO, "XWayland ready: DISPLAY=%s", _state->xwayland->display_name ?: "(nil)");
    wlr_xwayland_set_seat(_state->xwayland, _state->seat);
}

- (void)handleNewXWaylandSurface:(struct wlr_xwayland_surface *)xsurface
{
    wlr_log(WLR_INFO, "New XWayland surface: title='%s' class='%s' override_redirect=%d",
            xsurface->title ?: "(nil)",
            xsurface->class ?: "(nil)",
            xsurface->override_redirect);
    AmbrosiaXWaylandView *view =
        [[AmbrosiaXWaylandView alloc] initWithXWaylandSurface:xsurface compositor:self];
    [self addView:view];
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

- (void)focusNextWindowExcluding:(nullable id<AmbrosiaWindowView>)excluded
{
    /* Iterate views in reverse insertion order (topmost first) */
    for (NSInteger i = (NSInteger)_views.count - 1; i >= 0; i--) {
        id<AmbrosiaWindowView> candidate = _views[(NSUInteger)i];
        if (candidate == excluded)    continue;
        if (!candidate.isMapped)      continue;
        if (candidate.isMiniaturized) continue;
        if (candidate.isMenu)         continue;
        [self focusView:candidate surface:[candidate surface]];
        return;
    }
    [self focusView:nil surface:nil];
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
    /* Always forward relative motion — games consume this regardless of lock state. */
    if (_state->relative_pointer_manager)
        wlr_relative_pointer_manager_v1_send_relative_motion(
            _state->relative_pointer_manager, _state->seat,
            (uint64_t)time * 1000, dx, dy, dx, dy);

    /* When the pointer is locked, do not move the physical cursor and do not
     * deliver absolute wl_pointer::motion events — the client uses only the
     * relative_motion events above.                                          */
    if (_state->active_constraint &&
        _state->active_constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED)
        return;

    wlr_cursor_move(_state->cursor, NULL, dx, dy);
    [self processCursorMotionTime:time];
}

- (void)handleCursorMotionAbsoluteTime:(uint32_t)time x:(double)x y:(double)y
                               output:(struct wlr_output *)output
{
    /* Absolute motion (e.g. touchpad or nested backend) is also suppressed
     * while a pointer lock is active.                                        */
    if (_state->active_constraint &&
        _state->active_constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED)
        return;

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
    id<AmbrosiaWindowView> view = [self viewAtX:cx y:cy surface:&surface localX:&sx localY:&sy];

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
        NSEdgeInsets insets = [AmbrosiaDecoration frameInsets];
        AmbrosiaDecorationHit hit = [view.decoration hitTestX:(cx - view.x + insets.left)
                                                            y:(cy - view.y + insets.top)];
        switch (hit) {
            case AmbrosiaDecorationHitTitlebar:
                [self focusView:view surface:surface];
                [self beginMoveView:view cursor:_state->cursor];
                return;
            case AmbrosiaDecorationHitClose:
                [self focusView:view surface:surface];
                [view close];
                return;
            case AmbrosiaDecorationHitMinimize:
                /* Hide the window and transfer focus to the next available
                 * window.  The XDG-shell protocol has no "minimized" state,
                 * so the client is not notified; its surface continues
                 * committing normally while the scene node is hidden.        */
                [view miniaturize];
                [self focusNextWindowExcluding:view];
                return;
            case AmbrosiaDecorationHitMaximize:
                [self focusView:view surface:surface];
                if ([view isKindOfClass:[AmbrosiaView class]])
                    [(AmbrosiaView *)view toggleMaximize];
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
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleActivateApplicationNotification:)
               name:@"AmbrosiaActivateApplication"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleSessionPrefsNotification:)
               name:@"AmbrosiaSessionPrefsChanged"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleDesktopPrefsNotification:)
               name:@"AmbrosiaDesktopPrefsChanged"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleCompPrefsNotification:)
               name:@"AmbrosiaCompositorPrefsChanged"
             object:nil];
    wlr_log(WLR_DEBUG,
        "Notification listener running (Logout, Activate, Session, Desktop, Compositor)");
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

- (void)_handleActivateApplicationNotification:(NSNotification *)note
{
    NSDictionary *info = note.userInfo;
    wlr_log(WLR_DEBUG, "AmbrosiaActivateApplication: bundleID=%s",
            [info[@"bundleIdentifier"] UTF8String] ?: "(nil)");
    [_activateLock lock];
    _pendingActivateBundleID   = info[@"bundleIdentifier"];
    _pendingActivateLaunchPath = info[@"launchPath"];
    _pendingActivateAppName    = info[@"appName"];
    [_activateLock unlock];
    char byte = 1;
    (void)write(_state->activate_pipe[1], &byte, 1);
}

- (void)_handleSessionPrefsNotification:(NSNotification *)note
{
    NSArray *items = note.userInfo[@"sessionItems"] ?: @[];
    wlr_log(WLR_DEBUG, "AmbrosiaSessionPrefsChanged: %lu item(s)",
            (unsigned long)items.count);
    [_sessionLock lock];
    _pendingSessionItems = items;
    [_sessionLock unlock];
    char byte = 1;
    (void)write(_state->session_pipe[1], &byte, 1);
}

/**
 * Called on the wl_event_loop thread when the session pipe becomes readable.
 * Applies the pending session-prefs update to the running session manager.
 */
- (void)_applySessionPrefsUpdate
{
    [_sessionLock lock];
    NSArray *items = _pendingSessionItems;
    _pendingSessionItems = nil;
    [_sessionLock unlock];

    wlr_log(WLR_INFO, "session: applying prefs update (%lu item(s))",
            (unsigned long)items.count);
    [_session syncUserApps:items];
}

- (void)_handleDesktopPrefsNotification:(NSNotification *)note
{
    NSDictionary *prefs = note.userInfo ?: @{};
    [_desktopLock lock];
    _pendingDesktopPrefs = prefs;
    [_desktopLock unlock];
    char byte = 1;
    (void)write(_state->desktop_pipe[1], &byte, 1);
}

/**
 * Called on the wl_event_loop thread when the desktop pipe becomes readable.
 * Forwards the latest prefs to AmbrosiaBackground on the compositor thread.
 */
- (void)_applyDesktopPrefsUpdate
{
    [_desktopLock lock];
    NSDictionary *prefs = _pendingDesktopPrefs;
    _pendingDesktopPrefs = nil;
    [_desktopLock unlock];

    wlr_log(WLR_INFO, "background: applying desktop prefs update");
    [_background applyPreferences:prefs];
}

- (void)_handleCompPrefsNotification:(NSNotification *)note
{
    NSDictionary *prefs = note.userInfo ?: @{};
    [_compLock lock];
    _pendingCompPrefs = prefs;
    [_compLock unlock];
    char byte = 1;
    (void)write(_state->comp_pipe[1], &byte, 1);
}

- (void)_applyCompPrefsUpdate
{
    [_compLock lock];
    NSDictionary *prefs = _pendingCompPrefs;
    _pendingCompPrefs = nil;
    [_compLock unlock];

    BOOL enabled = [prefs[@"x11Decorations"] boolValue];
    wlr_log(WLR_INFO, "compositor prefs: x11Decorations=%s", enabled ? "YES" : "NO");
    [self _applyX11DecorationsEnabled:enabled colors:prefs];
}

- (void)_applyX11DecorationsEnabled:(BOOL)enabled colors:(NSDictionary *)colors
{
    _x11Decorations      = enabled;
    _x11DecorationColors = colors;

    for (id<AmbrosiaWindowView> view in _views) {
        if (![view isKindOfClass:[AmbrosiaXWaylandView class]]) continue;
        AmbrosiaXWaylandView *xw = (AmbrosiaXWaylandView *)view;
        if (!xw.isMapped || xw.isMenu || xw.isFullscreen) continue;

        if (enabled && !xw.decoration) {
            [xw attachDecorationWithRenderer:_state->renderer colors:colors];
        } else if (!enabled && xw.decoration) {
            [xw removeDecoration];
        } else if (enabled && xw.decoration) {
            [xw.decoration updateColorsFromDictionary:colors];
        }
    }
}

/**
 * Called on the wl_event_loop thread when the activate pipe becomes readable.
 * Finds the topmost mapped window belonging to the requested application and
 * gives it keyboard focus, deminiaturizing it first if necessary.
 */
- (void)_focusApplicationFromActivateRequest
{
    [_activateLock lock];
    NSString *bundleID   = _pendingActivateBundleID;
    NSString *launchPath = _pendingActivateLaunchPath;
    NSString *appName    = _pendingActivateAppName;
    _pendingActivateBundleID   = nil;
    _pendingActivateLaunchPath = nil;
    _pendingActivateAppName    = nil;
    [_activateLock unlock];

    /* Derive a short app name from launchPath (/path/to/MyApp.app → "MyApp") */
    NSString *pathBaseName = launchPath.length
        ? [[launchPath lastPathComponent] stringByDeletingPathExtension]
        : nil;

    wlr_log(WLR_DEBUG,
        "_focusApplicationFromActivateRequest bundleID=%s appName=%s path=%s",
        bundleID.UTF8String ?: "-",
        appName.UTF8String  ?: "-",
        launchPath.UTF8String ?: "-");

    /* Search _views in reverse (topmost first).  Prefer non-miniaturized
     * windows; keep a miniaturized fallback in case all windows are hidden.
     * Only search XDG views — XWayland apps use X11 app_id semantics.     */
    AmbrosiaView *target               = nil;
    AmbrosiaView *miniaturizedFallback = nil;

    for (NSInteger i = (NSInteger)_views.count - 1; i >= 0; i--) {
        if (![_views[(NSUInteger)i] isKindOfClass:[AmbrosiaView class]]) continue;
        AmbrosiaView *v = _views[(NSUInteger)i];
        if (!v.isMapped)           continue;
        if (v.isMenu)              continue;
        if (v.isDockWindow)        continue;
        if (v.isDesktopBackground) continue;

        const char *rawAppId = v.state->xdg_toplevel->app_id;
        if (!rawAppId)           continue;
        NSString *appId = [NSString stringWithUTF8String:rawAppId];

        BOOL match = NO;
        /* 1. Exact bundle identifier match */
        if (!match && bundleID.length)
            match = [appId isEqualToString:bundleID];
        /* 2. Bundle ID ends with the app_id (e.g. "org.gnustep.GCalc" ↔ "GCalc") */
        if (!match && bundleID.length)
            match = [bundleID hasSuffix:appId];
        /* 3. Exact app name match */
        if (!match && appName.length)
            match = [appId isEqualToString:appName];
        /* 4. Base name from .app path */
        if (!match && pathBaseName.length)
            match = [appId isEqualToString:pathBaseName];
        /* 5. Case-insensitive substring (broadest fallback) */
        if (!match && appName.length)
            match = ([appId rangeOfString:appName
                                  options:NSCaseInsensitiveSearch].location != NSNotFound);

        if (match) {
            if (!v.isMiniaturized) { target = v; break; }
            if (!miniaturizedFallback) miniaturizedFallback = v;
        }
    }

    if (!target) target = miniaturizedFallback;

    if (target) {
        wlr_log(WLR_INFO, "Activating existing window for app_id='%s'",
                target.state->xdg_toplevel->app_id ?: "(nil)");
        if (target.isMiniaturized) [target deminiaturize];
        [self focusView:target surface:target.surface];
    } else {
        wlr_log(WLR_DEBUG, "_focusApplicationFromActivateRequest: no matching window found");
    }
}

- (void)saveSessionAndLogout
{
    wlr_log(WLR_INFO, "Saving session state and logging out");

    /* Build window list from currently mapped XDG views */
    NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
    for (id<AmbrosiaWindowView> wv in _views) {
        if (![wv isKindOfClass:[AmbrosiaView class]]) continue;
        AmbrosiaView *view = (AmbrosiaView *)wv;
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

    /* Notify all session processes that the compositor is about to stop.
     * Posting before wl_display_terminate gives Dock, MenuServer, and any
     * other GNUstep clients a chance to run applicationWillTerminate: (save
     * prefs, invalidate DO connections, etc.) while the Wayland event loop
     * is still processing their surface-destroy / unmap protocol messages. */
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"AmbrosiaSessionWillQuit"
                      object:nil
                    userInfo:nil
          deliverImmediately:YES];

    [self stop];
}

@end
