#ifndef AMBROSIA_OUTPUT_H
#define AMBROSIA_OUTPUT_H

#import <Foundation/Foundation.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>

@class AmbrosiaCompositor;

struct ambrosia_output_state {
    struct wlr_output       *output;
    struct wlr_scene_output *scene_output;
    struct wl_listener       frame;
    struct wl_listener       request_state;
    struct wl_listener       destroy;
    void                    *objc_output;
};

@interface AmbrosiaOutput : NSObject

@property (nonatomic, weak) AmbrosiaCompositor *compositor;
@property (nonatomic, readonly) struct ambrosia_output_state *state;

- (instancetype)initWithOutput:(struct wlr_output *)output
                    compositor:(AmbrosiaCompositor *)compositor;

- (void)handleFrame;
- (void)handleRequestState:(const struct wlr_output_event_request_state *)event;
- (void)handleDestroy;

@end

#endif /* AMBROSIA_OUTPUT_H */
