#ifndef AUDIOMODULE_H
#define AUDIOMODULE_H

#import <Cocoa/Cocoa.h>
#import <PreferencePanes/PreferencePanes.h>
#import "AudioBackend.h"

@interface AudioModule : NSPreferencePane <NSTableViewDelegate, NSTableViewDataSource, AudioBackendDelegate>
@property (nonatomic, strong) id<AudioBackend> audioBackend;
@property (strong) NSTableView *inputDeviceTableView;
@property (strong) NSTableView *outputDeviceTableView;
@property (strong) NSSlider *inputVolumeSlider;
@property (strong) NSSlider *outputVolumeSlider;
@property (nonatomic, strong) NSButton *outputMuteButton;
@property (nonatomic, strong) NSButton *inputMuteButton;
@property (nonatomic, strong) NSButton *showVolumeInMenuBarButton;
@end

#endif // AUDIOMODULE_H
