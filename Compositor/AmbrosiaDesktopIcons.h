/**
 * AmbrosiaDesktopIcons.h
 *
 * Reads Freedesktop.org .desktop files from ~/Desktop and renders them
 * as clickable icon + label tiles inside the compositor's scene graph.
 *
 * Icons are arranged in a grid starting from the top-right corner of
 * the primary output, filling downward then leftward.  Double-clicking
 * an icon launches the command from its Exec= field.
 *
 * Icon images are resolved via the XDG hicolor icon theme and rendered
 * using Cairo.  The inotify API is used to detect changes to ~/Desktop
 * so that icons are reloaded automatically.
 */

#ifndef AMBROSIA_DESKTOP_ICONS_H
#define AMBROSIA_DESKTOP_ICONS_H

#import <Foundation/Foundation.h>

#include <wayland-server-core.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>

@interface AmbrosiaDesktopIcons : NSObject

/**
 * @param loop      Compositor's wl_event_loop (for inotify fd).
 * @param iconTree  Scene tree to attach icon buffer nodes to.
 * @param layout    Output layout for querying per-output geometry.
 */
- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop
                        sceneTree:(struct wlr_scene_tree *)iconTree
                     outputLayout:(struct wlr_output_layout *)layout;

/** Rescan ~/Desktop and redraw all icons. */
- (void)reload;

/** Called after a new output is committed to the layout. */
- (void)handleOutputAdded:(struct wlr_output *)output;

/** Called when an output is about to be destroyed. */
- (void)handleOutputRemoved:(struct wlr_output *)output;

/**
 * Handle a button-press at compositor coordinates (x, y).
 * Returns YES if the click landed on a desktop icon (consuming the event).
 * Tracks double-click timing internally and launches the app on the second click.
 */
- (BOOL)handleClickAtX:(double)x y:(double)y time:(uint32_t)time;

@end

#endif /* AMBROSIA_DESKTOP_ICONS_H */
