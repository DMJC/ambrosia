#ifndef AMBROSIA_COMPOSITOR_H
#define AMBROSIA_COMPOSITOR_H

#import <Foundation/Foundation.h>
#import "AmbrosiaSession.h"
#import "AmbrosiaBackground.h"
#import "AmbrosiaWindowView.h"
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_output_management_v1.h>
#include <wlr/types/wlr_drm_lease_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/backend/session.h>
#include <wlr/xwayland.h>

@class AmbrosiaView;
@class AmbrosiaXWaylandView;
@class AmbrosiaOutput;

/* Cursor interaction mode */
typedef NS_ENUM(NSInteger, AmbrosiaCursorMode) {
    AmbrosiaCursorModePassthrough = 0,
    AmbrosiaCursorModeMove,
    AmbrosiaCursorModeResize,
};

/* All C-level Wayland listener state, kept separate for wl_container_of compatibility */
struct ambrosia_compositor_state {
    struct wl_display           *display;
    struct wl_event_loop        *event_loop;
    struct wlr_backend          *backend;
    struct wlr_renderer         *renderer;
    struct wlr_allocator        *allocator;
    struct wlr_scene            *scene;
    struct wlr_scene_output_layout *scene_layout;
    struct wlr_output_layout    *output_layout;

    /*
     * Scene sub-trees, created in ascending z-order so the renderer visits
     * them background → bottom → windows → top → overlay.  This matches the
     * wlr-layer-shell-v1 layer numbering and ensures layer-TOP surfaces
     * (e.g. the Ambrosia menu bar) always render above regular windows.
     */
    struct wlr_scene_tree       *scene_layer_bg;         /* ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND */
    struct wlr_scene_tree       *scene_layer_bottom;     /* ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM     */
    struct wlr_scene_tree       *scene_layer_windows;    /* xdg-toplevel windows (tiling layer)  */
    struct wlr_scene_tree       *scene_layer_top;        /* ZWLR_LAYER_SHELL_V1_LAYER_TOP        */
    struct wlr_scene_tree       *scene_layer_fullscreen; /* fullscreen apps — above menu bar     */
    struct wlr_scene_tree       *scene_layer_overlay;    /* ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY    */

    /* Usable screen area: top margin reserved by LAYER_TOP exclusive zones
     * (e.g. 24 px while the Ambrosia menu bar is running).  Used to clamp
     * window placement so windows cannot be dragged behind the bar.        */
    int                          usable_top;
    struct wlr_compositor       *compositor;
    struct wlr_subcompositor    *subcompositor;
    struct wlr_data_device_manager *data_device_manager;
    struct wlr_xdg_shell        *xdg_shell;
    struct wlr_xdg_decoration_manager_v1 *decoration_manager;
    struct wlr_layer_shell_v1        *layer_shell;
    struct wlr_screencopy_manager_v1 *screencopy_manager;
    struct wlr_viewporter            *viewporter;
    struct wlr_fractional_scale_manager_v1 *fractional_scale_manager;
    struct wlr_xdg_output_manager_v1 *xdg_output_manager;
    struct wlr_output_manager_v1     *output_manager;
    struct wlr_drm_lease_v1_manager  *drm_lease_manager;
    struct wlr_relative_pointer_manager_v1 *relative_pointer_manager;
    struct wlr_pointer_constraints_v1      *pointer_constraints;
    struct wlr_seat                  *seat;
    struct wlr_cursor           *cursor;
    struct wlr_xcursor_manager  *cursor_mgr;
    struct wlr_session          *wlr_session;

    /* Listeners */
    struct wl_listener new_output;
    struct wl_listener new_xdg_toplevel;
    struct wl_listener new_xdg_popup;
    struct wl_listener new_toplevel_decoration;
    struct wl_listener new_layer_surface;
    struct wl_listener cursor_motion;
    struct wl_listener cursor_motion_absolute;
    struct wl_listener cursor_button;
    struct wl_listener cursor_axis;
    struct wl_listener cursor_frame;
    struct wl_listener new_input;
    struct wl_listener request_set_cursor;
    struct wl_listener request_set_selection;
    struct wl_listener output_manager_apply;
    struct wl_listener output_manager_test;
    struct wl_listener drm_lease_request;

    /* Grab / resize state */
    AmbrosiaCursorMode  cursor_mode;
    double              grab_x;
    double              grab_y;
    struct wlr_box      grab_geobox;
    uint32_t            resize_edges;

    /* XWayland — NULL if Xwayland is unavailable or failed to start */
    struct wlr_xwayland         *xwayland;
    struct wl_listener           xwayland_ready;
    struct wl_listener           new_xwayland_surface;

    /* Pointer constraints (zwp_pointer_constraints_v1) */
    struct wl_listener                new_constraint;
    struct wlr_pointer_constraint_v1 *active_constraint;
    struct wl_listener                constraint_destroy;

    /* Logout self-pipe: background notification thread → wl_event_loop */
    int                  logout_pipe[2];
    struct wl_event_source *logout_source;

    /* Activate self-pipe: background notification thread → wl_event_loop
     * Written when an "AmbrosiaActivateApplication" notification arrives so
     * the Wayland focus change happens on the compositor's main thread.      */
    int                  activate_pipe[2];
    struct wl_event_source *activate_source;

    /* Session-prefs self-pipe: background notification thread → wl_event_loop
     * Written when "AmbrosiaSessionPrefsChanged" arrives so the session
     * manager is updated on the compositor's main thread.                    */
    int                  session_pipe[2];
    struct wl_event_source *session_source;

    /* Desktop-prefs self-pipe: background notification thread → wl_event_loop
     * Written when "AmbrosiaDesktopPrefsChanged" arrives so the background
     * manager is updated on the compositor's main thread.                    */
    int                  desktop_pipe[2];
    struct wl_event_source *desktop_source;

    /* Compositor-prefs self-pipe: background notification thread → wl_event_loop
     * Written when "AmbrosiaCompositorPrefsChanged" arrives so x11Decorations
     * and related settings are applied on the compositor's main thread.      */
    int                  comp_pipe[2];
    struct wl_event_source *comp_source;

    /* Back-reference (not retained – ObjC object owns this struct) */
    void               *objc_compositor;
};

@interface AmbrosiaCompositor : NSObject

@property (readonly) struct ambrosia_compositor_state *state;
@property (readonly) NSMutableArray                   *views;         /**< id<AmbrosiaWindowView> elements */
@property (readonly) NSMutableArray<AmbrosiaOutput *> *outputs;
@property (readonly) NSMutableArray                   *layerSurfaces; /**< NSValue wrapping ambrosia_layer_surface* */
@property (readonly, nullable) id<AmbrosiaWindowView>  focusedView;
@property (readonly)           AmbrosiaSession         *session;
@property (readonly)           AmbrosiaBackground      *background;

/** Whether server-side decorations should be drawn on XWayland managed windows. */
@property (readonly) BOOL           x11Decorations;
/** Colour prefs for X11 decorations (hex strings keyed to titlebarActiveColor etc.) */
@property (readonly, nullable) NSDictionary *x11DecorationColors;

- (instancetype)init;
- (BOOL)setup:(NSError **)error;
- (void)run;
- (void)stop;

/**
 * Save the current window layout to ~/GNUstep/Library/Ambrosia/session.plist
 * and then terminate the compositor.  Safe to call from within the compositor
 * process (e.g. from a Wayland protocol handler or privileged helper).
 * External processes should post an NSDistributedNotification named
 * "AmbrosiaLogoutRequest" instead.
 */
- (void)saveSessionAndLogout;

/* View management */
- (void)addView:(id<AmbrosiaWindowView>)view;
- (void)removeView:(id<AmbrosiaWindowView>)view;
- (nullable id<AmbrosiaWindowView>)viewAtX:(double)x y:(double)y
                                   surface:(struct wlr_surface **)surfaceOut
                                    localX:(double *)lx
                                    localY:(double *)ly;
- (void)focusView:(nullable id<AmbrosiaWindowView>)view surface:(nullable struct wlr_surface *)surface;
- (void)focusNextWindowExcluding:(nullable id<AmbrosiaWindowView>)excluded;
- (void)beginMoveView:(id<AmbrosiaWindowView>)view cursor:(struct wlr_cursor *)cursor;
- (void)beginResizeView:(id<AmbrosiaWindowView>)view
                 cursor:(struct wlr_cursor *)cursor
                  edges:(uint32_t)edges;

/* Called from C callbacks */
- (void)handleNewOutput:(struct wlr_output *)output;
- (void)handleNewXdgToplevel:(struct wlr_xdg_toplevel *)toplevel;
- (void)handleNewXdgPopup:(struct wlr_xdg_popup *)popup;
- (void)handleNewToplevelDecoration:(struct wlr_xdg_toplevel_decoration_v1 *)decoration;
- (void)handleNewLayerSurface:(struct wlr_layer_surface_v1 *)surface;
- (void)removeLayerSurface:(void *)ls; /**< Called from C destroy callback */
- (void)handleCursorMotionTime:(uint32_t)time dx:(double)dx dy:(double)dy;
- (void)handleCursorMotionAbsoluteTime:(uint32_t)time x:(double)x y:(double)y output:(struct wlr_output *)output;
- (void)handleCursorButtonTime:(uint32_t)time button:(uint32_t)button state:(uint32_t)state;
- (void)handleCursorAxisTime:(uint32_t)time orientation:(uint32_t)orientation delta:(double)delta deltaDiscrete:(int32_t)discrete;
- (void)handleCursorFrame;
- (void)handleNewInput:(struct wlr_input_device *)device;
- (void)handleRequestSetCursor:(struct wlr_seat_pointer_request_set_cursor_event *)event;
- (void)handleRequestSetSelection:(struct wlr_seat_request_set_selection_event *)event;
- (void)handleOutputManagerApply:(struct wlr_output_configuration_v1 *)config;
- (void)handleOutputManagerTest:(struct wlr_output_configuration_v1 *)config;
- (void)handleDrmLeaseRequest:(struct wlr_drm_lease_request_v1 *)request;

/** Broadcast the current output configuration to all wlr-output-management clients. */
- (void)notifyOutputManager;
/** Update preferred wp-fractional-scale-v1 for a surface based on its monitor. */
- (void)updateFractionalScaleForSurface:(nullable struct wlr_surface *)surface
                                      x:(int)x
                                      y:(int)y;
/** Recompute preferred wp-fractional-scale-v1 for all known views. */
- (void)refreshFractionalScaleForAllViews;

/* XWayland callbacks */
- (void)handleXWaylandReady;
- (void)handleNewXWaylandSurface:(struct wlr_xwayland_surface *)xsurface;

@end

#endif /* AMBROSIA_COMPOSITOR_H */
