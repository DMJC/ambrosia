#ifndef AUDIOMODULE_H
#define AUDIOMODULE_H

#import <Cocoa/Cocoa.h>
#import <pulse/pulseaudio.h>
#import <PreferencePanes/PreferencePanes.h>

@interface AudioModule : NSPreferencePane <NSTableViewDelegate, NSTableViewDataSource>
@property (strong) NSTableView *deviceTableView;
@property (strong) NSTableView *inputDeviceTableView;
@property (strong) NSTableView *outputDeviceTableView;
@property (strong) NSSlider *inputVolumeSlider;
@property (strong) NSSlider *outputVolumeSlider;
@property (nonatomic) pa_mainloop *mainloop;
@property (nonatomic) pa_context *context;
@property (nonatomic, strong) NSMutableArray<NSString *> *inputDeviceNames;
@property (nonatomic, strong) NSMutableArray<NSString *> *outputDeviceNames;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *inputDeviceIndexes;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *outputDeviceIndexes;
@property (nonatomic, strong) NSButton *outputMuteButton;
@property (nonatomic, strong) NSButton *inputMuteButton;
@property (nonatomic, strong) NSButton *showVolumeInMenuBarButton;
@end
#endif //AUDIOMODULE_H
