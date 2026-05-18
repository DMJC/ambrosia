#import "AudioModule.h"
#import "PulseAudioBackend.h"
#import "PipeWireBackend.h"

@implementation AudioModule

- (void)dealloc {
    [self.audioBackend teardown];
    [super dealloc];
}

- (void)mainViewDidLoad {
    [super mainViewDidLoad];
    [self setupBackend];
    [self setupUI];
}

#pragma mark - Backend Selection

- (void)setupBackend {
    NSUserDefaults *defaults  = [NSUserDefaults standardUserDefaults];
    NSDictionary *globalDomain = [defaults persistentDomainForName:NSGlobalDomain];
    NSString *backendName = globalDomain[@"AudioBackend"] ?: @"PulseAudio";

    if ([backendName isEqualToString:@"Pipewire"] ||
        [backendName isEqualToString:@"PipeWire"]) {
        self.audioBackend = [[PipeWireBackend alloc] init];
    } else {
        self.audioBackend = [[PulseAudioBackend alloc] init];
    }

    self.audioBackend.delegate = self;
    [self.audioBackend setup];
}

#pragma mark - UI Setup

- (void)setupUI {
    NSView *contentView = [self mainView];
    CGFloat width = contentView.bounds.size.width;

    self.mainView.frame = NSMakeRect(0, 0, 400, 300);

    NSTabView *tabView = [[NSTabView alloc] initWithFrame:self.mainView.bounds];
    tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tabView.tabViewType = NSTopTabsBezelBorder;
    tabView.delegate = self;

    // Sound Effects tab
    NSTabViewItem *audioTab = [[NSTabViewItem alloc] initWithIdentifier:@"Sound Effects"];
    [audioTab setLabel:@"Sound Effects"];
    NSView *generalView = [[NSView alloc] initWithFrame:tabView.bounds];
    generalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextField *alertLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, generalView.bounds.size.height - 50, 300, 20)];
    alertLabel.stringValue = @"Select an Alert Sound:";
    alertLabel.editable = NO;
    alertLabel.bezeled = NO;
    alertLabel.drawsBackground = NO;
    alertLabel.alignment = NSTextAlignmentLeft;
    alertLabel.font = [NSFont systemFontOfSize:13.0];
    [generalView addSubview:alertLabel];
    [audioTab setView:generalView];
    [tabView addTabViewItem:audioTab];

    // Output tab
    NSTabViewItem *outputTab = [[NSTabViewItem alloc] initWithIdentifier:@"Output"];
    [outputTab setLabel:@"Output"];
    NSView *outputView = [[NSView alloc] initWithFrame:tabView.bounds];
    [outputTab setView:outputView];
    [tabView addTabViewItem:outputTab];

    NSTextField *outputTopLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, generalView.bounds.size.height - 25, 300, 20)];
    outputTopLabel.stringValue = @"Select a device for Sound Output:";
    outputTopLabel.editable = NO;
    outputTopLabel.bezeled = NO;
    outputTopLabel.drawsBackground = NO;
    outputTopLabel.alignment = NSTextAlignmentLeft;
    outputTopLabel.font = [NSFont systemFontOfSize:13.0];
    [outputView addSubview:outputTopLabel];

    NSScrollView *outputScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(40, 80, width - 70, 150)];
    self.outputDeviceTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    [self.outputDeviceTableView setDelegate:self];
    [self.outputDeviceTableView setDataSource:self];
    [self.outputDeviceTableView setTag:1];
    [self.outputDeviceTableView setDrawsGrid:NO];
    [self.outputDeviceTableView setHeaderView:nil];
    NSTableColumn *outputColumn = [[NSTableColumn alloc] initWithIdentifier:@"DeviceColumn"];
    [outputColumn setTitle:@"Output Devices"];
    [outputColumn setWidth:width - 40];
    [self.outputDeviceTableView addTableColumn:outputColumn];
    [outputScrollView setDocumentView:self.outputDeviceTableView];
    [outputScrollView setHasVerticalScroller:YES];
    [outputView addSubview:outputScrollView];

    NSTextField *outputLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 30, width - 100, 20)];
    outputLabel.stringValue = @"Output volume:";
    outputLabel.editable = NO;
    outputLabel.bezeled = NO;
    outputLabel.drawsBackground = NO;
    outputLabel.alignment = NSTextAlignmentLeft;
    outputLabel.font = [NSFont systemFontOfSize:13.0];
    [outputView addSubview:outputLabel];

    self.outputVolumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(130, 30, width - 230, 20)];
    [self.outputVolumeSlider setMinValue:0.0];
    [self.outputVolumeSlider setMaxValue:100.0];
    [self.outputVolumeSlider setTarget:self];
    [self.outputVolumeSlider setAction:@selector(outputSliderValueChanged:)];
    [outputView addSubview:self.outputVolumeSlider];

    self.outputMuteButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 80, 25, 60, 30)];
    [self.outputMuteButton setTitle:@"Mute"];
    [self.outputMuteButton setButtonType:NSSwitchButton];
    [self.outputMuteButton setTarget:self];
    [self.outputMuteButton setAction:@selector(outputMuteButtonPressed:)];
    [outputView addSubview:self.outputMuteButton];

    self.showVolumeInMenuBarButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 3, width - 20, 20)];
    [self.showVolumeInMenuBarButton setTitle:@"Show volume in menu bar"];
    [self.showVolumeInMenuBarButton setButtonType:NSSwitchButton];
    [self.showVolumeInMenuBarButton setTarget:self];
    [self.showVolumeInMenuBarButton setAction:@selector(showVolumeInMenuBarChanged:)];
    [outputView addSubview:self.showVolumeInMenuBarButton];

    {
        NSString *prefsPath = [NSHomeDirectory() stringByAppendingPathComponent:
                               @"GNUstep/Defaults/AmbrosiaMenuBar.plist"];
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
        BOOL show = [prefs[@"ShowVolumeMenu"] boolValue];
        [self.showVolumeInMenuBarButton setState:(show ? NSControlStateValueOn : NSControlStateValueOff)];
    }

    // Input tab
    NSTabViewItem *inputTab = [[NSTabViewItem alloc] initWithIdentifier:@"Input"];
    [inputTab setLabel:@"Input"];
    NSView *inputView = [[NSView alloc] initWithFrame:tabView.bounds];
    [inputTab setView:inputView];
    [tabView addTabViewItem:inputTab];

    NSTextField *inputTopLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, generalView.bounds.size.height - 25, 300, 20)];
    inputTopLabel.stringValue = @"Select a device for Sound Input:";
    inputTopLabel.editable = NO;
    inputTopLabel.bezeled = NO;
    inputTopLabel.drawsBackground = NO;
    inputTopLabel.alignment = NSTextAlignmentLeft;
    inputTopLabel.font = [NSFont systemFontOfSize:13.0];
    [inputView addSubview:inputTopLabel];

    NSScrollView *inputScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(40, 80, width - 70, 150)];
    self.inputDeviceTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    [self.inputDeviceTableView setDelegate:self];
    [self.inputDeviceTableView setDataSource:self];
    [self.inputDeviceTableView setTag:2];
    [self.inputDeviceTableView setDrawsGrid:NO];
    NSTableColumn *inputColumn = [[NSTableColumn alloc] initWithIdentifier:@"DeviceColumn"];
    [inputColumn setTitle:@"Input Devices"];
    [inputColumn setWidth:width - 40];
    [self.inputDeviceTableView addTableColumn:inputColumn];
    [inputScrollView setDocumentView:self.inputDeviceTableView];
    [inputScrollView setHasVerticalScroller:YES];
    [inputView addSubview:inputScrollView];

    NSTextField *inputLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 30, width - 100, 20)];
    inputLabel.stringValue = @"Input volume:";
    inputLabel.editable = NO;
    inputLabel.bezeled = NO;
    inputLabel.drawsBackground = NO;
    inputLabel.alignment = NSTextAlignmentLeft;
    inputLabel.font = [NSFont systemFontOfSize:13.0];
    [inputView addSubview:inputLabel];

    self.inputVolumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(130, 30, width - 230, 20)];
    [self.inputVolumeSlider setMinValue:0.0];
    [self.inputVolumeSlider setMaxValue:100.0];
    [self.inputVolumeSlider setTarget:self];
    [self.inputVolumeSlider setAction:@selector(inputSliderValueChanged:)];
    [inputView addSubview:self.inputVolumeSlider];

    self.inputMuteButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 80, 25, 60, 30)];
    [self.inputMuteButton setTitle:@"Mute"];
    [self.inputMuteButton setButtonType:NSSwitchButton];
    [self.inputMuteButton setTarget:self];
    [self.inputMuteButton setAction:@selector(inputMuteButtonPressed:)];
    [inputView addSubview:self.inputMuteButton];

    [self.mainView addSubview:tabView];
}

#pragma mark - Slider and Button Actions

- (void)inputSliderValueChanged:(NSSlider *)sender {
    NSInteger selectedRow = [self.inputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.audioBackend.inputDeviceIndexes[selectedRow].unsignedIntValue;
        [self.audioBackend setInputVolume:sender.doubleValue forDeviceIndex:index];
    }
}

- (void)outputSliderValueChanged:(NSSlider *)sender {
    NSInteger selectedRow = [self.outputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.audioBackend.outputDeviceIndexes[selectedRow].unsignedIntValue;
        [self.audioBackend setOutputVolume:sender.doubleValue forDeviceIndex:index];
    }
}

- (void)inputMuteButtonPressed:(NSButton *)sender {
    NSInteger selectedRow = [self.inputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.audioBackend.inputDeviceIndexes[selectedRow].unsignedIntValue;
        [self.audioBackend setInputMute:(sender.state == NSControlStateValueOn) forDeviceIndex:index];
    }
}

- (void)outputMuteButtonPressed:(NSButton *)sender {
    NSInteger selectedRow = [self.outputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.audioBackend.outputDeviceIndexes[selectedRow].unsignedIntValue;
        [self.audioBackend setOutputMute:(sender.state == NSControlStateValueOn) forDeviceIndex:index];
    }
}

- (void)showVolumeInMenuBarChanged:(NSButton *)sender {
    NSString *prefsDir  = [NSHomeDirectory() stringByAppendingPathComponent:@"GNUstep/Defaults"];
    NSString *prefsPath = [prefsDir stringByAppendingPathComponent:@"AmbrosiaMenuBar.plist"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSMutableDictionary *prefs =
        [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath]
        ?: [NSMutableDictionary dictionary];
    prefs[@"ShowVolumeMenu"] = @(sender.state == NSControlStateValueOn);
    [prefs writeToFile:prefsPath atomically:YES];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"AmbrosiaMenuBarPrefsChanged"
                      object:nil
                    userInfo:nil
          deliverImmediately:YES];
}

#pragma mark - NSTableView DataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView.tag == 1) return (NSInteger)self.audioBackend.outputDeviceNames.count;
    if (tableView.tag == 2) return (NSInteger)self.audioBackend.inputDeviceNames.count;
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView.tag == 1) return self.audioBackend.outputDeviceNames[row];
    if (tableView.tag == 2) return self.audioBackend.inputDeviceNames[row];
    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger inputRow = [self.inputDeviceTableView selectedRow];
    if (inputRow >= 0) {
        uint32_t index = self.audioBackend.inputDeviceIndexes[inputRow].unsignedIntValue;
        [self.audioBackend setDefaultInputDevice:index];
        [self.audioBackend refreshVolumeForInputDeviceIndex:index];
    }
    NSInteger outputRow = [self.outputDeviceTableView selectedRow];
    if (outputRow >= 0) {
        uint32_t index = self.audioBackend.outputDeviceIndexes[outputRow].unsignedIntValue;
        [self.audioBackend setDefaultOutputDevice:index];
        [self.audioBackend refreshVolumeForOutputDeviceIndex:index];
    }
}

#pragma mark - AudioBackendDelegate

- (void)audioBackendDidUpdateInputDevices:(id<AudioBackend>)backend {
    [self.inputDeviceTableView reloadData];
}

- (void)audioBackendDidUpdateOutputDevices:(id<AudioBackend>)backend {
    [self.outputDeviceTableView reloadData];
}

- (void)audioBackend:(id<AudioBackend>)backend didUpdateInputVolume:(double)volume mute:(BOOL)mute {
    self.inputVolumeSlider.doubleValue = volume;
    [self.inputMuteButton setState:(mute ? NSControlStateValueOn : NSControlStateValueOff)];
}

- (void)audioBackend:(id<AudioBackend>)backend didUpdateOutputVolume:(double)volume mute:(BOOL)mute {
    self.outputVolumeSlider.doubleValue = volume;
    [self.outputMuteButton setState:(mute ? NSControlStateValueOn : NSControlStateValueOff)];
}

#pragma mark - NSTabViewDelegate

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    NSString *ident = [tabViewItem identifier];
    if ([ident isEqualToString:@"Output"])
        [self.audioBackend refreshOutputDevices];
    else if ([ident isEqualToString:@"Input"])
        [self.audioBackend refreshInputDevices];
}

@end
