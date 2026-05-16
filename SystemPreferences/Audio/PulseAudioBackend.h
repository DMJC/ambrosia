#ifndef PULSEAUDIOBACKEND_H
#define PULSEAUDIOBACKEND_H

#import <Cocoa/Cocoa.h>
#import <pulse/pulseaudio.h>
#import "AudioBackend.h"

@interface PulseAudioBackend : NSObject <AudioBackend>
@property (nonatomic, assign) id<AudioBackendDelegate> delegate;
@property (nonatomic, strong) NSMutableArray<NSString *> *inputDeviceNames;
@property (nonatomic, strong) NSMutableArray<NSString *> *outputDeviceNames;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *inputDeviceIndexes;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *outputDeviceIndexes;
// System (PA) names used with pa_context_set_default_sink/source.
@property (nonatomic, strong) NSMutableArray<NSString *> *inputDeviceSystemNames;
@property (nonatomic, strong) NSMutableArray<NSString *> *outputDeviceSystemNames;
@property (nonatomic) pa_mainloop *mainloop;
@property (nonatomic) pa_context *context;
@end

#endif // PULSEAUDIOBACKEND_H
