#ifndef AUDIOBACKEND_H
#define AUDIOBACKEND_H

#import <Cocoa/Cocoa.h>

@protocol AudioBackend;

@protocol AudioBackendDelegate <NSObject>
- (void)audioBackendDidUpdateInputDevices:(id<AudioBackend>)backend;
- (void)audioBackendDidUpdateOutputDevices:(id<AudioBackend>)backend;
- (void)audioBackend:(id<AudioBackend>)backend didUpdateInputVolume:(double)volume mute:(BOOL)mute;
- (void)audioBackend:(id<AudioBackend>)backend didUpdateOutputVolume:(double)volume mute:(BOOL)mute;
@end

@protocol AudioBackend <NSObject>
@property (nonatomic, assign) id<AudioBackendDelegate> delegate;
@property (nonatomic, readonly) NSArray<NSString *> *inputDeviceNames;
@property (nonatomic, readonly) NSArray<NSString *> *outputDeviceNames;
@property (nonatomic, readonly) NSArray<NSNumber *> *inputDeviceIndexes;
@property (nonatomic, readonly) NSArray<NSNumber *> *outputDeviceIndexes;
- (void)setup;
- (void)teardown;
- (void)setInputVolume:(double)volume forDeviceIndex:(uint32_t)index;
- (void)setOutputVolume:(double)volume forDeviceIndex:(uint32_t)index;
- (void)setInputMute:(BOOL)mute forDeviceIndex:(uint32_t)index;
- (void)setOutputMute:(BOOL)mute forDeviceIndex:(uint32_t)index;
- (void)refreshVolumeForInputDeviceIndex:(uint32_t)index;
- (void)refreshVolumeForOutputDeviceIndex:(uint32_t)index;
- (void)setDefaultInputDevice:(uint32_t)index;
- (void)setDefaultOutputDevice:(uint32_t)index;
@end

#endif // AUDIOBACKEND_H
