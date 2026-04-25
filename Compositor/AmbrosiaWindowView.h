#ifndef AMBROSIA_WINDOW_VIEW_H
#define AMBROSIA_WINDOW_VIEW_H

#import <Foundation/Foundation.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_scene.h>
#include <sys/types.h>

@class AmbrosiaCompositor;
@class AmbrosiaDecoration;

struct wlr_box;
struct wlr_surface;

/**
 * Common interface for managed compositor windows.
 * Adopted by both AmbrosiaView (XDG/Wayland) and AmbrosiaXWaylandView (X11/XWayland).
 */
@protocol AmbrosiaWindowView <NSObject>

@required
@property (nonatomic, weak) AmbrosiaCompositor *compositor;
@property (nonatomic, strong, nullable) AmbrosiaDecoration *decoration;
@property (nonatomic) int x;
@property (nonatomic) int y;
@property (nonatomic, readonly) BOOL isMapped;
@property (nonatomic, readonly) BOOL isMiniaturized;
@property (nonatomic, readonly) BOOL isFullscreen;
@property (nonatomic, readonly) BOOL isMenu;
@property (nonatomic, readonly) BOOL isDockWindow;
@property (nonatomic, readonly) BOOL isDesktopBackground;

- (nullable struct wlr_surface *)surface;
- (struct wlr_box)geometry;
- (void)moveTo:(int)x y:(int)y;
- (void)miniaturize;
- (void)deminiaturize;
- (void)toggleFullscreen;
- (void)updateTitle;

/** Activate or deactivate keyboard focus for this window. */
- (void)activateFocus:(BOOL)focused;

/** Request that the window close itself. */
- (void)close;

/** Raise this window's scene node to the top of its parent tree. */
- (void)raiseSceneNode;

/**
 * Hit-test this window at compositor-space coordinates (x, y).
 * Returns the wlr_surface under the point with surface-local coordinates in
 * lx/ly, or NULL if the point misses this window's surface.
 */
- (nullable struct wlr_surface *)surfaceAt:(double)x y:(double)y
                                   localX:(double *)lx localY:(double *)ly;

/**
 * Returns the wl_client for this window's Wayland connection.
 * XDG views: the app's direct client.
 * XWayland views: the shared Xwayland process client.
 */
- (nullable struct wl_client *)waylandClient;

/** Returns the OS pid of the client process. */
- (pid_t)clientPid;

@end

#endif /* AMBROSIA_WINDOW_VIEW_H */
