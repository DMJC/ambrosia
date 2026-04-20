/**
 * AmbrosiaBackground.h
 *
 * Manages compositor-rendered desktop background images.
 *
 * One wlr_scene_buffer node is created per connected output inside the
 * scene_layer_bg tree.  Images are loaded with Cairo (PNG) or libjpeg
 * (JPEG) and scaled to cover each output.
 *
 * When rotating backgrounds is enabled a wl_event_loop timer advances
 * through the sorted file list in the configured folder at the chosen
 * interval (5 / 10 / 30 / 60 / 300 / 600 seconds).
 *
 * Preferences are stored in
 *   ~/GNUstep/Library/Preferences/org.gnustep.AmbrosiaDesktop.plist
 * and delivered live via the AmbrosiaDesktopPrefsChanged distributed
 * notification, which the compositor routes here on the event-loop thread.
 */

#ifndef AMBROSIA_BACKGROUND_H
#define AMBROSIA_BACKGROUND_H

#import <Foundation/Foundation.h>

#include <wayland-server-core.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>

@interface AmbrosiaBackground : NSObject

/**
 * @param loop    Compositor's wl_event_loop (for rotation timer).
 * @param bgTree  scene_layer_bg sub-tree to attach buffer nodes to.
 * @param layout  Output layout for querying per-output geometry.
 */
- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop
                        sceneTree:(struct wlr_scene_tree *)bgTree
                     outputLayout:(struct wlr_output_layout *)layout;

/** Read org.gnustep.AmbrosiaDesktop.plist from disk and apply. */
- (void)applyPreferencesFromPlist;

/** Apply a prefs dict; safe to call only on the wl_event_loop thread. */
- (void)applyPreferences:(NSDictionary *)prefs;

/** Called after a new output has been committed to the layout. */
- (void)handleOutputAdded:(struct wlr_output *)output;

/** Called when an output is about to be destroyed. */
- (void)handleOutputRemoved:(struct wlr_output *)output;

/** Cancel all timers; call before the event loop exits. */
- (void)stop;

@end

#endif /* AMBROSIA_BACKGROUND_H */
