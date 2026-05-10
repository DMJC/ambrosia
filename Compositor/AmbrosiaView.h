#ifndef AMBROSIA_VIEW_H
#define AMBROSIA_VIEW_H

#import <Foundation/Foundation.h>
#import "AmbrosiaWindowView.h"
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_scene.h>

@class AmbrosiaCompositor;
@class AmbrosiaDecoration;

struct ambrosia_view_state {
    struct wlr_xdg_toplevel *xdg_toplevel;
    struct wlr_scene_tree   *scene_tree;

    /**
     * Back-reference to the xdg-decoration object, set by the compositor when
     * a decoration is negotiated.  NULL when no decoration object exists.
     * Used by handleMap to know whether SSD mode was already agreed.
     */
    struct wlr_xdg_toplevel_decoration_v1 *xdg_decoration;

    struct wl_listener surface_commit; /* fires initial configure (wlroots 0.18+) */
    struct wl_listener map;
    struct wl_listener unmap;
    struct wl_listener destroy;
    struct wl_listener request_move;
    struct wl_listener request_resize;
    struct wl_listener request_maximize;
    struct wl_listener request_fullscreen;
    struct wl_listener request_close;
    struct wl_listener set_title;
    struct wl_listener set_app_id;

    void *objc_view;
};

@interface AmbrosiaView : NSObject <AmbrosiaWindowView>

@property (nonatomic, weak) AmbrosiaCompositor *compositor;
@property (nonatomic, readonly) struct ambrosia_view_state *state;
@property (nonatomic, strong, nullable) AmbrosiaDecoration *decoration;

/** Position of the view (including decoration offset) in compositor space */
@property (nonatomic) int x;
@property (nonatomic) int y;
@property (nonatomic, readonly) BOOL isMapped;
@property (nonatomic, readonly) BOOL isMiniaturized;      /**< YES → scene node hidden by minimize button */
@property (nonatomic, readonly) BOOL isFullscreen;        /**< YES → covering entire output, above menu bar */
@property (nonatomic, readonly) BOOL isMenu;              /**< YES → skip decorations (menu/dock/desktop) */
@property (nonatomic, readonly) BOOL isDockWindow;        /**< YES → position at bottom-centre of output */
@property (nonatomic, readonly) BOOL isDesktopBackground; /**< YES → pin to output origin, behind all windows */

- (instancetype)initWithToplevel:(struct wlr_xdg_toplevel *)toplevel
                      compositor:(AmbrosiaCompositor *)compositor;

/** Expose the underlying wlr_surface of this view */
- (struct wlr_surface *)surface;

/** Geometry of the surface content (no decoration) */
- (struct wlr_box)geometry;

/** Move the scene tree to (x, y) */
- (void)moveTo:(int)x y:(int)y;

/**
 * Miniaturize: hide the window scene node and record minimized state.
 * The compositor should give keyboard focus to another window afterwards.
 * There is no standard XDG-shell signal to inform the client; the window
 * surface continues to commit normally while hidden.
 */
- (void)miniaturize;

/**
 * Deminiaturize: restore the window scene node and clear minimized state.
 * The compositor should give keyboard focus back to this window afterwards.
 */
- (void)deminiaturize;

/**
 * Toggle maximize state (used by the maximize decoration button).
 * Saves the current position on first maximize and restores it on unmaximize.
 */
- (void)toggleMaximize;

/**
 * Toggle fullscreen state.
 * When entering fullscreen the window is moved to the fullscreen scene layer
 * (above the menu bar), sized to cover the entire output, and its decoration
 * is hidden.  Restores position/size/decoration on exit.
 */
- (void)toggleFullscreen;

/** Update title in the decoration (if any) */
- (void)updateTitle;

/**
 * Attach server-side decoration using the given renderer and optional theme
 * colour dictionary.  Called by the compositor when SSD mode is negotiated.
 */
- (void)attachDecorationWithRenderer:(struct wlr_renderer *)renderer
                              colors:(nullable NSDictionary *)colors;

/** Remove server-side decoration (switch back to CSD). */
- (void)removeDecoration;

/** Called by C callbacks */
- (void)handleSurfaceCommit;
- (void)handleMap;
- (void)handleUnmap;
- (void)handleDestroy;
- (void)handleRequestMoveSerial:(uint32_t)serial;
- (void)handleRequestResizeSerial:(uint32_t)serial edges:(uint32_t)edges;
- (void)handleRequestMaximize;
- (void)handleRequestFullscreen;
- (void)handleSetTitle;
- (void)handleSetAppId;

/* AmbrosiaWindowView protocol additions */
- (void)activateFocus:(BOOL)focused;
- (void)close;
- (void)raiseSceneNode;
- (nullable struct wlr_surface *)surfaceAt:(double)x y:(double)y
                                   localX:(double *)lx localY:(double *)ly;
- (nullable struct wl_client *)waylandClient;
- (pid_t)clientPid;

@end

#endif /* AMBROSIA_VIEW_H */
