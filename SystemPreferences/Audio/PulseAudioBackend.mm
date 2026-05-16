#import "PulseAudioBackend.h"

@implementation PulseAudioBackend

- (NSArray<NSString *> *)inputDeviceNames  { return _inputDeviceNames; }
- (NSArray<NSString *> *)outputDeviceNames { return _outputDeviceNames; }
- (NSArray<NSNumber *> *)inputDeviceIndexes  { return _inputDeviceIndexes; }
- (NSArray<NSNumber *> *)outputDeviceIndexes { return _outputDeviceIndexes; }

- (void)setup {
    self.inputDeviceNames        = [NSMutableArray array];
    self.outputDeviceNames       = [NSMutableArray array];
    self.inputDeviceIndexes      = [NSMutableArray array];
    self.outputDeviceIndexes     = [NSMutableArray array];
    self.inputDeviceSystemNames  = [NSMutableArray array];
    self.outputDeviceSystemNames = [NSMutableArray array];

    self.mainloop = pa_mainloop_new();
    self.context  = pa_context_new(pa_mainloop_get_api(self.mainloop), "AmbrosiaAudio");

    if (pa_context_connect(self.context, NULL, PA_CONTEXT_NOFLAGS, NULL) < 0) {
        NSLog(@"PulseAudio: connection failed: %s", pa_strerror(pa_context_errno(self.context)));
        return;
    }

    pa_context_set_state_callback(self.context, context_state_callback, (__bridge void *)self);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        pa_mainloop_run(self.mainloop, NULL);
    });
}

- (void)teardown {
    if (self.context) {
        pa_context_disconnect(self.context);
        pa_context_unref(self.context);
        self.context = NULL;
    }
    if (self.mainloop) {
        pa_mainloop_quit(self.mainloop, 0);
        pa_mainloop_free(self.mainloop);
        self.mainloop = NULL;
    }
}

- (void)dealloc {
    [self teardown];
    [super dealloc];
}

- (void)setInputVolume:(double)volume forDeviceIndex:(uint32_t)index {
    pa_cvolume cv;
    pa_cvolume_set(&cv, 2, (uint32_t)(volume * PA_VOLUME_NORM / 100.0));
    pa_context_set_source_volume_by_index(self.context, index, &cv, NULL, NULL);
}

- (void)setOutputVolume:(double)volume forDeviceIndex:(uint32_t)index {
    pa_cvolume cv;
    pa_cvolume_set(&cv, 2, (uint32_t)(volume * PA_VOLUME_NORM / 100.0));
    pa_context_set_sink_volume_by_index(self.context, index, &cv, NULL, NULL);
}

- (void)setInputMute:(BOOL)mute forDeviceIndex:(uint32_t)index {
    pa_context_set_source_mute_by_index(self.context, index, mute, NULL, NULL);
}

- (void)setOutputMute:(BOOL)mute forDeviceIndex:(uint32_t)index {
    pa_context_set_sink_mute_by_index(self.context, index, mute, NULL, NULL);
}

- (void)refreshVolumeForInputDeviceIndex:(uint32_t)index {
    pa_context_get_source_info_by_index(self.context, index, source_info_callback, (__bridge void *)self);
}

- (void)refreshVolumeForOutputDeviceIndex:(uint32_t)index {
    pa_context_get_sink_info_by_index(self.context, index, sink_info_callback, (__bridge void *)self);
}

- (void)setDefaultInputDevice:(uint32_t)index {
    NSUInteger i = [self.inputDeviceIndexes indexOfObject:@(index)];
    if (i == NSNotFound || i >= self.inputDeviceSystemNames.count) return;
    const char *name = [self.inputDeviceSystemNames[i] UTF8String];
    pa_context_set_default_source(self.context, name, NULL, NULL);
}

- (void)setDefaultOutputDevice:(uint32_t)index {
    NSUInteger i = [self.outputDeviceIndexes indexOfObject:@(index)];
    if (i == NSNotFound || i >= self.outputDeviceSystemNames.count) return;
    const char *name = [self.outputDeviceSystemNames[i] UTF8String];
    pa_context_set_default_sink(self.context, name, NULL, NULL);
}

#pragma mark - Callbacks

static void context_state_callback(pa_context *context, void *userdata) {
    if (pa_context_get_state(context) != PA_CONTEXT_READY) return;
    pa_context_get_source_info_list(context, source_list_callback, userdata);
    pa_context_get_sink_info_list(context, sink_list_callback, userdata);
}

static void source_list_callback(pa_context *context, const pa_source_info *info, int eol, void *userdata) {
    if (eol > 0) return;
    PulseAudioBackend *backend = (__bridge PulseAudioBackend *)userdata;
    NSString *desc   = [NSString stringWithUTF8String:info->description];
    NSString *sysName = [NSString stringWithUTF8String:info->name];
    NSNumber *idx    = @(info->index);
    dispatch_async(dispatch_get_main_queue(), ^{
        [backend.inputDeviceNames addObject:desc];
        [backend.inputDeviceSystemNames addObject:sysName];
        [backend.inputDeviceIndexes addObject:idx];
        [backend.delegate audioBackendDidUpdateInputDevices:backend];
    });
}

static void sink_list_callback(pa_context *context, const pa_sink_info *info, int eol, void *userdata) {
    if (eol > 0) return;
    PulseAudioBackend *backend = (__bridge PulseAudioBackend *)userdata;
    NSString *desc    = [NSString stringWithUTF8String:info->description];
    NSString *sysName = [NSString stringWithUTF8String:info->name];
    NSNumber *idx     = @(info->index);
    dispatch_async(dispatch_get_main_queue(), ^{
        [backend.outputDeviceNames addObject:desc];
        [backend.outputDeviceSystemNames addObject:sysName];
        [backend.outputDeviceIndexes addObject:idx];
        [backend.delegate audioBackendDidUpdateOutputDevices:backend];
    });
}

static void source_info_callback(pa_context *context, const pa_source_info *info, int eol, void *userdata) {
    if (eol > 0) return;
    PulseAudioBackend *backend = (__bridge PulseAudioBackend *)userdata;
    double volume = (pa_cvolume_avg(&info->volume) * 100.0) / PA_VOLUME_NORM;
    BOOL mute = (BOOL)info->mute;
    dispatch_async(dispatch_get_main_queue(), ^{
        [backend.delegate audioBackend:backend didUpdateInputVolume:volume mute:mute];
    });
}

static void sink_info_callback(pa_context *context, const pa_sink_info *info, int eol, void *userdata) {
    if (eol > 0) return;
    PulseAudioBackend *backend = (__bridge PulseAudioBackend *)userdata;
    double volume = (pa_cvolume_avg(&info->volume) * 100.0) / PA_VOLUME_NORM;
    BOOL mute = (BOOL)info->mute;
    dispatch_async(dispatch_get_main_queue(), ^{
        [backend.delegate audioBackend:backend didUpdateOutputVolume:volume mute:mute];
    });
}

@end
