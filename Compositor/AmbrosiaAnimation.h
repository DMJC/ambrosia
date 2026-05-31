#ifndef AMBROSIA_ANIMATION_H
#define AMBROSIA_ANIMATION_H

#import <Foundation/Foundation.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_scene.h>

/* Number of horizontal strips used to approximate the warp curve. */
#define MAGIC_LAMP_N_SLICES   8
/* Approximate width of a dock icon in compositor pixels (animation end-point). */
#define MAGIC_LAMP_ICON_W    64
/* Total animation duration in milliseconds. */
#define MAGIC_LAMP_DURATION 320
/* Timer interval in milliseconds (~60 fps). */
#define MAGIC_LAMP_INTERVAL  16

/**
 * AmbrosiaAnimation — drives a single Magic Lamp (genie) window animation.
 *
 * Creates N wlr_scene_buffer nodes in an overlay scene tree, each showing a
 * horizontal strip of the window's surface buffer.  A wl_event_loop timer
 * updates the strip positions, widths, and opacities every frame so that the
 * bottom of the window collapses to the dock first and the top follows, giving
 * the classic "lamp" warp silhouette.
 *
 * All methods must be called on the compositor's wl_event_loop thread.
 */
@interface AmbrosiaAnimation : NSObject

/**
 * Begin a miniaturize animation (window content → dock).
 *
 * The caller must hide the real window scene tree before or after calling
 * this — the animation shows only a frozen snapshot of the surface buffer,
 * independent of the live scene node.
 *
 * @param surface   The window's wlr_surface; its current committed buffer is
 *                  used as the animation source image.
 * @param wx/wy     Compositor-space top-left of the content area (below any
 *                  server-side decoration titlebar).
 * @param ww/wh     Pixel size of the content area.
 * @param tx/ty     Target compositor-space point (dock icon centre x, dock y).
 * @param overlay   Parent scene tree for animation nodes (scene_layer_overlay).
 * @param loop      Wayland event loop used for the frame timer.
 * @param done      Block invoked on the compositor thread when the animation
 *                  finishes.  The strips have already been destroyed by then.
 */
- (instancetype)initMiniaturizeWithSurface:(struct wlr_surface *)surface
                                  windowX:(int)wx windowY:(int)wy
                                  windowW:(int)ww windowH:(int)wh
                                   targetX:(int)tx targetY:(int)ty
                               overlayTree:(struct wlr_scene_tree *)overlay
                                 eventLoop:(struct wl_event_loop *)loop
                                completion:(void(^)(void))done;

/**
 * Begin a deminiaturize animation (dock → window content).
 *
 * The caller must show the real window scene tree inside the completion block.
 *
 * @param sx/sy     Source compositor-space point (dock icon centre x, dock y).
 *                  Other parameters mirror initMiniaturize…
 */
- (instancetype)initDeminiaturizeWithSurface:(struct wlr_surface *)surface
                                    windowX:(int)wx windowY:(int)wy
                                    windowW:(int)ww windowH:(int)wh
                                     sourceX:(int)sx sourceY:(int)sy
                                 overlayTree:(struct wlr_scene_tree *)overlay
                                   eventLoop:(struct wl_event_loop *)loop
                                  completion:(void(^)(void))done;

/**
 * Cancel the animation immediately.
 * All overlay strip nodes are destroyed and the completion block is discarded.
 * Safe to call even after the animation has already finished.
 */
- (void)cancel;

@end

#endif /* AMBROSIA_ANIMATION_H */
