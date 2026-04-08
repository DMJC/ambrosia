#import "AmbrosiaOutput.h"
#import "AmbrosiaCompositor.h"

#include <wlr/util/log.h>

/* --------------------------------------------------------------------------
 * C callbacks
 * -------------------------------------------------------------------------- */

static void handle_output_frame(struct wl_listener *listener, void *data)
{
    struct ambrosia_output_state *s =
        wl_container_of(listener, s, frame);
    AmbrosiaOutput *output = (__bridge AmbrosiaOutput *)s->objc_output;
    [output handleFrame];
}

static void handle_output_request_state(struct wl_listener *listener, void *data)
{
    struct ambrosia_output_state *s =
        wl_container_of(listener, s, request_state);
    AmbrosiaOutput *output = (__bridge AmbrosiaOutput *)s->objc_output;
    [output handleRequestState:(const struct wlr_output_event_request_state *)data];
}

static void handle_output_destroy(struct wl_listener *listener, void *data)
{
    struct ambrosia_output_state *s =
        wl_container_of(listener, s, destroy);
    AmbrosiaOutput *output = (__bridge AmbrosiaOutput *)s->objc_output;
    [output handleDestroy];
}

/* --------------------------------------------------------------------------
 * AmbrosiaOutput
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaOutput {
    struct ambrosia_output_state *_state;
}

@synthesize state      = _state;
@synthesize compositor = _compositor;

- (instancetype)initWithOutput:(struct wlr_output *)output
                    compositor:(AmbrosiaCompositor *)compositor
{
    self = [super init];
    if (!self) return nil;

    _state = calloc(1, sizeof(struct ambrosia_output_state));
    if (!_state) return nil;

    _state->output     = output;
    _state->objc_output = (__bridge void *)self;
    _compositor = compositor;

    /* Frame listener */
    _state->frame.notify = handle_output_frame;
    wl_signal_add(&output->events.frame, &_state->frame);

    /* Request-state listener */
    _state->request_state.notify = handle_output_request_state;
    wl_signal_add(&output->events.request_state, &_state->request_state);

    /* Destroy listener */
    _state->destroy.notify = handle_output_destroy;
    wl_signal_add(&output->events.destroy, &_state->destroy);

    return self;
}

- (void)dealloc
{
    if (_state) {
        wl_list_remove(&_state->frame.link);
        wl_list_remove(&_state->request_state.link);
        wl_list_remove(&_state->destroy.link);
        free(_state);
        _state = NULL;
    }
}

- (void)handleFrame
{
    if (!_state->scene_output) return;

    struct wlr_scene_output *scene_output = _state->scene_output;
    struct wlr_scene *scene = _compositor.state->scene;

    wlr_scene_output_commit(scene_output, NULL);

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_scene_output_send_frame_done(scene_output, &now);
}

- (void)handleRequestState:(const struct wlr_output_event_request_state *)event
{
    wlr_output_commit_state(_state->output, event->state);
}

- (void)handleDestroy
{
    [_compositor.outputs removeObject:self];
    wl_list_remove(&_state->frame.link);
    wl_list_remove(&_state->request_state.link);
    wl_list_remove(&_state->destroy.link);
}

@end
