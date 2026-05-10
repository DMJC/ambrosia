#import "AudioModule.h"

@implementation AudioModule

- (void)dealloc {
    if (self.context) {
        pa_context_disconnect(self.context);
        pa_context_unref(self.context);
    }
    if (self.mainloop) {
        pa_mainloop_quit(self.mainloop, 0);
        pa_mainloop_free(self.mainloop);
    }
    [super dealloc];
}

- (void)mainViewDidLoad {
    [super mainViewDidLoad];
    self.inputDeviceNames = [NSMutableArray array];
    self.outputDeviceNames = [NSMutableArray array];
    self.inputDeviceIndexes = [NSMutableArray array];
    self.outputDeviceIndexes = [NSMutableArray array];
    [self setupPulseAudio];
    [self setupUI];
}

#pragma mark - UI Setup

- (void)setupUI {
    NSView *contentView = [self mainView];
    CGFloat width = contentView.bounds.size.width;
    //TabView
    // Set up the main view frame
    self.mainView.frame = NSMakeRect(0, 0, 400, 300);
    // Create an NSTabView and set it up
    NSTabView *tabView = [[NSTabView alloc] initWithFrame:self.mainView.bounds];
    tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tabView.tabViewType = NSTopTabsBezelBorder;

    // Add tabs
    NSTabViewItem *audioTab = [[NSTabViewItem alloc] initWithIdentifier:@"Sound Effects"];
    [audioTab setLabel:@"Sound Effects"];

    // Create a view for the General tab
    NSView *generalView = [[NSView alloc] initWithFrame:tabView.bounds];
    generalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Add a label to the General tab
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, generalView.bounds.size.height - 50, 300, 20)];
    label.stringValue = @"Select an Alert Sound:";
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.alignment = NSTextAlignmentLeft;
    label.font = [NSFont systemFontOfSize:13.0];
    [generalView addSubview:label];
    [audioTab setView:generalView];
    [tabView addTabViewItem:audioTab];

    // Add Audio Output Tab
    NSTabViewItem *outputTab = [[NSTabViewItem alloc] initWithIdentifier:@"Output"];
    [outputTab setLabel:@"Output"];
    NSView *outputView = [[NSView alloc] initWithFrame:tabView.bounds];
    [outputTab setView:outputView];
    [tabView addTabViewItem:outputTab];

    // Add the tabView to the mainView
    [self.mainView addSubview:tabView];




    NSTextField *output_top_label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, generalView.bounds.size.height - 50, 300, 20)];
    output_top_label.stringValue = @"Select a device for Sound Output:";
    output_top_label.editable = NO;
    output_top_label.bezeled = NO;
    output_top_label.drawsBackground = NO;
    output_top_label.alignment = NSTextAlignmentLeft;
    output_top_label.font = [NSFont systemFontOfSize:13.0];
    [outputView addSubview:output_top_label];
    // Device Table View
    NSScrollView *outputScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(40, 80, width - 70, 150)];
    self.outputDeviceTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    [self.outputDeviceTableView setDelegate:self];
    [self.outputDeviceTableView setDataSource:self];
    [self.outputDeviceTableView setTag:1];
    
    NSTableColumn *outputcolumn = [[NSTableColumn alloc] initWithIdentifier:@"DeviceColumn"];
    [outputcolumn setTitle:@"Output Devices"];
    [outputcolumn setWidth:width - 40];
    [self.outputDeviceTableView addTableColumn:outputcolumn];
    
    [outputScrollView setDocumentView:self.outputDeviceTableView];
    [outputScrollView setHasVerticalScroller:YES];
    [outputView addSubview:outputScrollView];
    
    NSTextField *outputlabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 30, width - 100, 20)];
    outputlabel.stringValue = @"Output volume:";
    outputlabel.editable = NO;
    outputlabel.bezeled = NO;
    outputlabel.drawsBackground = NO;
    outputlabel.alignment = NSTextAlignmentLeft;
    outputlabel.font = [NSFont systemFontOfSize:13.0];
    [outputView addSubview:outputlabel];

    // Volume Slider
    self.outputVolumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(130, 30, width - 230, 20)];
    [self.outputVolumeSlider setMinValue:0.0];
    [self.outputVolumeSlider setMaxValue:100.0];
    [self.outputVolumeSlider setTarget:self];
    [self.outputVolumeSlider setAction:@selector(outputSliderValueChanged:)];
    [outputView addSubview:self.outputVolumeSlider];
    
    // Mute Button
    self.outputMuteButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 80, 25, 60, 30)];
    [self.outputMuteButton setTitle:@"Mute"];
    [self.outputMuteButton setButtonType:NSSwitchButton];
    [self.outputMuteButton setTarget:self];
    [self.outputMuteButton setAction:@selector(outputMuteButtonPressed:)];
    [outputView addSubview:self.outputMuteButton];

    // Show Volume in Menu Bar checkbox
    self.showVolumeInMenuBarButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 3, width - 20, 20)];
    [self.showVolumeInMenuBarButton setTitle:@"Show volume in menu bar"];
    [self.showVolumeInMenuBarButton setButtonType:NSSwitchButton];
    [self.showVolumeInMenuBarButton setTarget:self];
    [self.showVolumeInMenuBarButton setAction:@selector(showVolumeInMenuBarChanged:)];
    [outputView addSubview:self.showVolumeInMenuBarButton];

    // Restore saved state for the checkbox
    {
        NSString *prefsPath = [NSHomeDirectory() stringByAppendingPathComponent:
                               @"GNUstep/Defaults/AmbrosiaMenuBar.plist"];
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
        BOOL show = [prefs[@"ShowVolumeMenu"] boolValue];
        [self.showVolumeInMenuBarButton
            setState:(show ? NSControlStateValueOn : NSControlStateValueOff)];
    }

    // Add Audio Input Tab
    NSTabViewItem *inputTab = [[NSTabViewItem alloc] initWithIdentifier:@"Input"];
    [inputTab setLabel:@"Input"];
    NSView *inputView = [[NSView alloc] initWithFrame:tabView.bounds];
    [inputTab setView:inputView];
    [tabView addTabViewItem:inputTab];

    NSTextField *input_top_label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, generalView.bounds.size.height - 50, 300, 20)];
    input_top_label.stringValue = @"Select a device for Sound Input:";
    input_top_label.editable = NO;
    input_top_label.bezeled = NO;
    input_top_label.drawsBackground = NO;
    input_top_label.alignment = NSTextAlignmentLeft;
    input_top_label.font = [NSFont systemFontOfSize:13.0];
    [inputView addSubview:input_top_label];
    // Device Table View
    NSScrollView *inputScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(40, 80, width - 70, 150)];
    self.inputDeviceTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    [self.inputDeviceTableView setDelegate:self];
    [self.inputDeviceTableView setDataSource:self];
    [self.inputDeviceTableView setTag:2];
    
    NSTableColumn *inputcolumn = [[NSTableColumn alloc] initWithIdentifier:@"DeviceColumn"];
    [inputcolumn setTitle:@"Input Devices"];
    [inputcolumn setWidth:width - 40];
    [self.inputDeviceTableView addTableColumn:inputcolumn];
    
    [inputScrollView setDocumentView:self.inputDeviceTableView];
    [inputScrollView setHasVerticalScroller:YES];
    [inputView addSubview:inputScrollView];

    NSTextField *inputlabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 30, width - 100, 20)];
    inputlabel.stringValue = @"Input volume:";
    inputlabel.editable = NO;
    inputlabel.bezeled = NO;
    inputlabel.drawsBackground = NO;
    inputlabel.alignment = NSTextAlignmentLeft;
    inputlabel.font = [NSFont systemFontOfSize:13.0];
    [inputView addSubview:inputlabel];
    
    // Volume Slider
    self.inputVolumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(130, 30, width - 230, 20)];
    [self.inputVolumeSlider setMinValue:0.0];
    [self.inputVolumeSlider setMaxValue:100.0];
    [self.inputVolumeSlider setTarget:self];
    [self.inputVolumeSlider setAction:@selector(inputSliderValueChanged:)];
    [inputView addSubview:self.inputVolumeSlider];
    
    // Mute Button
    self.inputMuteButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - 80, 25, 60, 30)];
    [self.inputMuteButton setTitle:@"Mute"];
    [self.inputMuteButton setButtonType:NSSwitchButton];
    [self.inputMuteButton setTarget:self];
    [self.inputMuteButton setAction:@selector(inputMuteButtonPressed:)];
    [inputView addSubview:self.inputMuteButton];
}

#pragma mark - PulseAudio Setup

- (void)setupPulseAudio {
    self.mainloop = pa_mainloop_new();
    self.context = pa_context_new(pa_mainloop_get_api(self.mainloop), "VolumeControlModule");
    
    if (pa_context_connect(self.context, NULL, PA_CONTEXT_NOFLAGS, NULL) < 0) {
        NSLog(@"PulseAudio connection failed: %s", pa_strerror(pa_context_errno(self.context)));
        return;
    }
    pa_context_set_state_callback(self.context, context_state_callback, (__bridge void *)self);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        pa_mainloop_run(self.mainloop, NULL);
    });
}

- (void)updateInputDeviceList {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.inputDeviceTableView reloadData];
    });
}

- (void)updateOutputDeviceList {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.outputDeviceTableView reloadData];
    });
}

#pragma mark - Slider and Button Actions

- (void)inputSliderValueChanged:(NSSlider *)sender {
    NSInteger selectedRow = [self.inputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.inputDeviceIndexes[selectedRow].unsignedIntValue;
        pa_cvolume volume;
        pa_cvolume_set(&volume, 2, (uint32_t)(sender.doubleValue * PA_VOLUME_NORM / 100.0));
        pa_context_set_source_volume_by_index(self.context, index, &volume, NULL, NULL);
    }
}

- (void)outputSliderValueChanged:(NSSlider *)sender {
    NSInteger selectedRow = [self.outputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.outputDeviceIndexes[selectedRow].unsignedIntValue;
        pa_cvolume volume;
        pa_cvolume_set(&volume, 2, (uint32_t)(sender.doubleValue * PA_VOLUME_NORM / 100.0));
        pa_context_set_sink_volume_by_index(self.context, index, &volume, NULL, NULL);
    }
}

- (void)inputMuteButtonPressed:(NSButton *)sender {
    NSInteger selectedRow = [self.inputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.inputDeviceIndexes[selectedRow].unsignedIntValue;
        BOOL mute = (sender.state == NSControlStateValueOn);
        pa_context_set_source_mute_by_index(self.context, index, mute, NULL, NULL);
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

- (void)outputMuteButtonPressed:(NSButton *)sender {
    NSInteger selectedRow = [self.outputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.outputDeviceIndexes[selectedRow].unsignedIntValue;
        BOOL mute = (sender.state == NSControlStateValueOn);
        pa_context_set_sink_mute_by_index(self.context, index, mute, NULL, NULL);
    }
}

#pragma mark - NSTableView DataSource and Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView.tag == 1) {
        return self.outputDeviceNames.count;
    } else if (tableView.tag == 2) {
        return self.inputDeviceNames.count;
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView.tag == 1) {
        return self.outputDeviceNames[row];
    } else if (tableView.tag == 2) {
        return self.inputDeviceNames[row];
    }
    return 0;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger selectedRow = [self.inputDeviceTableView selectedRow];
    if (selectedRow >= 0) {
        uint32_t index = self.inputDeviceIndexes[selectedRow].unsignedIntValue;
        pa_context_get_source_info_by_index(self.context, index, source_info_callback, (__bridge void *)self);
    }
    NSInteger outputSelectedRow = [self.outputDeviceTableView selectedRow];
    if (outputSelectedRow >= 0) {
        uint32_t index = self.outputDeviceIndexes[outputSelectedRow].unsignedIntValue;
        pa_context_get_sink_info_by_index(self.context, index, sink_info_callback, (__bridge void *)self);
    }
}

#pragma mark - PulseAudio Callbacks

static void context_state_callback(pa_context *context, void *userdata) {
    if (pa_context_get_state(context) == PA_CONTEXT_READY) {
        pa_context_get_source_info_list(context, source_list_callback, userdata);
        pa_context_get_sink_info_list(context, sink_list_callback, userdata);
    }
}

static void source_list_callback(pa_context *context, const pa_source_info *info, int eol, void *userdata) {
    if (eol > 0) return; // End of list
    AudioModule *self = (__bridge AudioModule *)userdata;
    [self.inputDeviceNames addObject:[NSString stringWithUTF8String:info->description]];
    [self.inputDeviceIndexes addObject:@(info->index)];
    [self updateInputDeviceList];
}

static void source_info_callback(pa_context *context, const pa_source_info *info, int eol, void *userdata) {
    if (eol > 0) return;
    AudioModule *self = (__bridge AudioModule *)userdata;
    dispatch_async(dispatch_get_main_queue(), ^{
        uint32_t avg_volume = pa_cvolume_avg(&info->volume);
        self.inputVolumeSlider.doubleValue = (avg_volume * 100.0) / PA_VOLUME_NORM;
        [self.inputMuteButton setState:(info->mute ? NSControlStateValueOn : NSControlStateValueOff)];
    });
}

static void sink_list_callback(pa_context *context, const pa_sink_info *info, int eol, void *userdata) {
    if (eol > 0) return; // End of list
    AudioModule *self = (__bridge AudioModule *)userdata;
    [self.outputDeviceNames addObject:[NSString stringWithUTF8String:info->description]];
    [self.outputDeviceIndexes addObject:@(info->index)];
    [self updateOutputDeviceList];
}

static void sink_info_callback(pa_context *context, const pa_sink_info *info, int eol, void *userdata) {
    if (eol > 0) return;
    AudioModule *self = (__bridge AudioModule *)userdata;
    dispatch_async(dispatch_get_main_queue(), ^{
        uint32_t avg_volume = pa_cvolume_avg(&info->volume);
        self.outputVolumeSlider.doubleValue = (avg_volume * 100.0) / PA_VOLUME_NORM;
        [self.outputMuteButton setState:(info->mute ? NSControlStateValueOn : NSControlStateValueOff)];
    });
}
@end
