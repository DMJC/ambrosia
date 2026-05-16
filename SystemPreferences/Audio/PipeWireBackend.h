#ifndef PIPEWIREBACKEND_H
#define PIPEWIREBACKEND_H

#import <Cocoa/Cocoa.h>
#import "AudioBackend.h"

@interface PipeWireBackend : NSObject <AudioBackend>
@property (nonatomic, assign) id<AudioBackendDelegate> delegate;
@property (nonatomic, strong) NSMutableArray<NSString *> *inputDeviceNames;
@property (nonatomic, strong) NSMutableArray<NSString *> *outputDeviceNames;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *inputDeviceIndexes;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *outputDeviceIndexes;
@end

#endif // PIPEWIREBACKEND_H
