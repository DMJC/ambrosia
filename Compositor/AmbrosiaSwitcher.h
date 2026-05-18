#ifndef AMBROSIA_SWITCHER_H
#define AMBROSIA_SWITCHER_H

#import <Foundation/Foundation.h>
#include <wlr/types/wlr_scene.h>

@class AmbrosiaCompositor;

/**
 * Command-Tab application switcher overlay.
 *
 * Renders a translucent rounded-rectangle panel into scene_layer_overlay.
 * The panel shows an icon for each running application at 100 % opacity.
 * The selected icon is surrounded by a black rounded rect (r=4) at 90 % opacity.
 * A rounded label rectangle at 80 % opacity beneath the selected icon shows the
 * app name.
 *
 * Usage from AmbrosiaInput:
 *   - Super+Tab (pressed)          → advanceBy:+1
 *   - Super+Shift+Tab (pressed)    → advanceBy:-1
 *   - Super modifier released      → confirm
 *   - Escape (pressed)             → cancel
 *   - Return (pressed)             → confirm
 */
@interface AmbrosiaSwitcher : NSObject

@property (readonly) BOOL isVisible;

- (instancetype)initWithCompositor:(AmbrosiaCompositor *)compositor;

/**
 * If not yet visible: build the app list and show the panel with the first
 * non-current app pre-selected (delta>0) or the last app (delta<0).
 * If already visible: step the selection by delta, wrapping around.
 * Does nothing when fewer than two distinct apps are running.
 */
- (void)advanceBy:(int)delta;

/** Focus the selected app and hide the panel. */
- (void)confirm;

/** Hide the panel without changing focus. */
- (void)cancel;

@end

#endif /* AMBROSIA_SWITCHER_H */
