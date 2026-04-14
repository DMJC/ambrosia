#ifndef AMBROSIA_COMPOSITOR_H
#define AMBROSIA_COMPOSITOR_H

#import <Foundation/Foundation.h>
#import "AmbrosiaSession.h"
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
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/backend/session.h>

@class AmbrosiaView;
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
    struct wlr_scene_tree       *scene_layer_bg;       /* ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND */
    struct wlr_scene_tree       *scene_layer_bottom;   /* ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM     */
    struct wlr_scene_tree       *scene_layer_windows;  /* xdg-toplevel windows (tiling layer)  */
    struct wlr_scene_tree       *scene_layer_top;      /* ZWLR_LAYER_SHELL_V1_LAYER_TOP        */
    struct wlr_scene_tree       *scene_layer_overlay;  /* ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY    */

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
    struct wlr_xdg_output_manager_v1 *xdg_output_manager;
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

    /* Grab / resize state */
    AmbrosiaCursorMode  cursor_mode;
    double              grab_x;
    double              grab_y;
    struct wlr_box      grab_geobox;
    uint32_t            resize_edges;

    /* Logout self-pipe: background notification thread → wl_event_loop */
    int                  logout_pipe[2];
    struct wl_event_source *logout_source;

    /* Activate self-pipe: background notification thread → wl_event_loop
     * Written when an "AmbrosiaActivateApplication" notification arrives so
     * the Wayland focus change happens on the compositor's main thread.      */
    int                  activate_pipe[2];
    struct wl_event_source *activate_source;

    /* Back-reference (not retained – ObjC object owns this struct) */
    void               *objc_compositor;
};

@interface AmbrosiaCompositor : NSObject

@property (readonly) struct ambrosia_compositor_state *state;
@property (readonly) NSMutableArray<AmbrosiaView *>   *views;
@property (readonly) NSMutableArray<AmbrosiaOutput *> *outputs;
@property (readonly) NSMutableArray                   *layerSurfaces; /**< NSValue wrapping ambrosia_layer_surface* */
@property (readonly, nullable) AmbrosiaView            *focusedView;
@property (readonly)           AmbrosiaSession         *session;

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
- (void)addView:(AmbrosiaView *)view;
- (void)removeView:(AmbrosiaView *)view;
- (nullable AmbrosiaView *)viewAtX:(double)x y:(double)y
                         surface:(struct wlr_surface **)surfaceOut
                          localX:(double *)lx
                          localY:(double *)ly;
- (void)focusView:(AmbrosiaView *)view surface:(struct wlr_surface *)surface;
- (void)focusNextWindowExcluding:(AmbrosiaView *)excluded;
- (void)beginMoveView:(AmbrosiaView *)view cursor:(struct wlr_cursor *)cursor;
- (void)beginResizeView:(AmbrosiaView *)view
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

@end

#endif /* AMBROSIA_COMPOSITOR_H */
