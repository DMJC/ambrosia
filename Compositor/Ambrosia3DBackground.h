/**
 * Ambrosia3DBackground.h
 *
 * Renders an animated 3D space scene as the compositor desktop background,
 * driven by a scene.txt file (same format as 3D_Space_Desktop).
 *
 * Rendering is done into per-output OpenGL FBOs via an EGL offscreen context,
 * then read back with glReadPixels into Cairo ARGB32 surfaces that are pushed
 * to wlr_scene_buffer nodes in scene_layer_bg.
 *
 * Animation is driven by a wl_event_loop timer (~30 fps).  The EGL context is
 * saved and restored around each render tick so the compositor's own GL state
 * is not disturbed.
 */

#ifndef AMBROSIA_3D_BACKGROUND_H
#define AMBROSIA_3D_BACKGROUND_H

#import <Foundation/Foundation.h>

#include <EGL/egl.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>

@interface Ambrosia3DBackground : NSObject

/**
 * @param loop       Compositor's wl_event_loop (for animation timer).
 * @param bgTree     scene_layer_bg sub-tree to attach buffer nodes to.
 * @param layout     Output layout for querying per-output geometry.
 * @param scenePath  Absolute path to the scene.txt file to load.
 * @param eglDisplay The compositor's live EGLDisplay (from wlr_egl_get_display).
 *                   Pass EGL_NO_DISPLAY to fall back to EGL_DEFAULT_DISPLAY.
 */
- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop
                        sceneTree:(struct wlr_scene_tree *)bgTree
                     outputLayout:(struct wlr_output_layout *)layout
                    sceneFilePath:(NSString *)scenePath
                       eglDisplay:(EGLDisplay)eglDisplay;

/** Called after a new output has been committed to the layout. */
- (void)handleOutputAdded:(struct wlr_output *)output;

/** Called when an output is about to be destroyed. */
- (void)handleOutputRemoved:(struct wlr_output *)output;

/** Cancel the animation timer and free GL resources; call before the event loop exits. */
- (void)stop;

@end

#endif /* AMBROSIA_3D_BACKGROUND_H */
