#import "PowerModule.h"
#import <systemd/sd-bus.h>

@implementation PowerManagementPane {
    sd_bus *bus;
    BOOL isPrivileged;
}

- (instancetype)initWithBundle:(NSBundle *)bundle {
    self = [super initWithBundle:bundle];
    if (self) {
        sd_bus_open_system(&bus);
        isPrivileged = NO;
        [self setupUI];
        [self loadCurrentSettings];
    }
    return self;
}

- (void)requestPrivileges:(id)sender {
    // Use polkit to escalate privileges
    int ret = system("pkexec true");
    if (ret == 0) {
        isPrivileged = YES;
        [privilegeEscalationCheckbox setState:NSControlStateValueOn];
        [self enableUIElements:YES];
    } else {
        [privilegeEscalationCheckbox setState:NSControlStateValueOff];
    }
}

- (void)enableUIElements:(BOOL)enabled {
    [sleepSlider setEnabled:enabled];
    [preventSleepCheckbox setEnabled:enabled];
    [enablePowerNapCheckbox setEnabled:enabled];
    [startupAfterPowerFailureCheckbox setEnabled:enabled];
    [wakeForNetworkCheckbox setEnabled:enabled];
    [putDisksToSleepCheckbox setEnabled:enabled];
}

- (void)loadCurrentSettings {
    if (!bus) return;
    
    [self enableUIElements:NO];
    
    int suspendAllowed = 0;
    sd_bus_message *msg = NULL;
    sd_bus_call_method(bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.DBus.Properties",
        "Get",
        NULL, &msg,
        "ss", "org.freedesktop.login1.Manager", "CanSuspend");
    
    if (msg) {
        const char *result;
        sd_bus_message_read(msg, "s", &result);
        suspendAllowed = (strcmp(result, "yes") == 0);
        sd_bus_message_unref(msg);
    }
    
    [preventSleepCheckbox setState:suspendAllowed ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)updateSleepSetting:(id)sender {
    if (!bus) return;
    
    int sleepTime = (int)[sleepSlider intValue] * 60; // Convert minutes to seconds

    sd_bus_message *msg = NULL;
    int r = sd_bus_call_method(bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.DBus.Properties",
        "Set",
        NULL, &msg,
        "ssv", "org.freedesktop.login1.Manager", "IdleActionSec",
        "t", (uint64_t)sleepTime); // Correct type for systemd property

    if (r < 0) {
        NSLog(@"Failed to set IdleActionSec: %s", strerror(-r));
    }
    sd_bus_message_unref(msg);

//     Restart systemd-logind to apply changes
    sd_bus_call_method(bus,
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "RestartUnit",
        NULL, NULL,
        "ss", "systemd-logind.service", "replace");
}

- (void)togglePreventSleep:(id)sender {
    if (!bus) return;
    
    BOOL newState = ([preventSleepCheckbox state] == NSControlStateValueOn);
    
    /* Example: Prevent or allow suspend via logind */
    sd_bus_call_method(bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
        "Inhibit",
        NULL, NULL,
        "ssss", "sleep", "PowerManagementPane", "Preventing sleep", newState ? "block" : "" );
}

- (void)togglePowerNap:(id)sender {
    if (!bus) return;
    
    BOOL newState = ([enablePowerNapCheckbox state] == NSControlStateValueOn);
    
    /* Example: Enable or disable automatic updates during sleep */
    sd_bus_call_method(bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.DBus.Properties",
        "Set",
        NULL, NULL,
        "ssv", "org.freedesktop.login1.Manager", "PowerNapEnabled", "b", newState);
}

- (void)toggleStartupAfterPowerFailure:(id)sender {
    if (!bus) return;
    
    BOOL newState = ([startupAfterPowerFailureCheckbox state] == NSControlStateValueOn);
    
    /* Example: Enable or disable startup after power failure */
    sd_bus_call_method(bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.DBus.Properties",
        "Set",
        NULL, NULL,
        "ssv", "org.freedesktop.login1.Manager", "HandlePowerKey", "s", newState ? "poweroff" : "ignore");
}


- (void)setupUI {
    mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];

    sliderLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 240, 360, 20)];
    [sliderLabel setStringValue:@"Set computer sleep time:"];
    [sliderLabel setBezeled:NO];
    [sliderLabel setDrawsBackground:NO];
    [sliderLabel setEditable:NO];
    [sliderLabel setSelectable:NO];
    [mainView addSubview:sliderLabel];

    sleepSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(20, 210, 360, 20)];
    [sleepSlider setMinValue:1];
    [sleepSlider setMaxValue:180];
    [sleepSlider setNumberOfTickMarks:7];
    [sleepSlider setAllowsTickMarkValuesOnly:YES];
    [sleepSlider setTarget:self];
    [sleepSlider setAction:@selector(updateSleepSetting:)];
    [mainView addSubview:sleepSlider];

    sliderValuesLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 190, 360, 20)];
    [sliderValuesLabel setStringValue:@"1m       15m       30m       1h       2h       3h       Never"];
    [sliderValuesLabel setAlignment:NSTextAlignmentCenter];
    [sliderValuesLabel setBezeled:NO];
    [sliderValuesLabel setDrawsBackground:NO];
    [sliderValuesLabel setEditable:NO];
    [sliderValuesLabel setSelectable:NO];
    [mainView addSubview:sliderValuesLabel];

    preventSleepCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 180, 360, 20)];
    [preventSleepCheckbox setButtonType:NSSwitchButton];
    [preventSleepCheckbox setTitle:@"Prevent computer from sleeping automatically when the display is off"];
    [preventSleepCheckbox setAction:@selector(togglePreventSleep:)];
    [preventSleepCheckbox setTarget:self];
    [mainView addSubview:preventSleepCheckbox];

    putDisksToSleepCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 150, 360, 20)];
    [putDisksToSleepCheckbox setButtonType:NSSwitchButton];
    [putDisksToSleepCheckbox setTitle:@"Put hard disks to sleep when possible"];
    [mainView addSubview:putDisksToSleepCheckbox];

    wakeForNetworkCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 120, 360, 20)];
    [wakeForNetworkCheckbox setButtonType:NSSwitchButton];
    [wakeForNetworkCheckbox setTitle:@"Wake for Ethernet network access"];
    [mainView addSubview:wakeForNetworkCheckbox];

    startupAfterPowerFailureCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 90, 360, 20)];
    [startupAfterPowerFailureCheckbox setButtonType:NSSwitchButton];
    [startupAfterPowerFailureCheckbox setTitle:@"Start up automatically after a power failure"];
    [startupAfterPowerFailureCheckbox setTarget:self];
    [startupAfterPowerFailureCheckbox setAction:@selector(toggleStartupAfterPowerFailure:)];
    [mainView addSubview:startupAfterPowerFailureCheckbox];

    enablePowerNapCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 60, 360, 20)];
    [enablePowerNapCheckbox setButtonType:NSSwitchButton];
    [enablePowerNapCheckbox setTitle:@"Enable Power Nap (update while sleeping)"];
    [enablePowerNapCheckbox setTarget:self];
    [enablePowerNapCheckbox setAction:@selector(togglePowerNap:)];
    [mainView addSubview:enablePowerNapCheckbox];

    restoreDefaultsButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 20, 150, 30)];
    [restoreDefaultsButton setTitle:@"Restore Defaults"];
    [restoreDefaultsButton setTarget:self];
    [restoreDefaultsButton setAction:@selector(restoreDefaults)];
    [mainView addSubview:restoreDefaultsButton];

    scheduleButton = [[NSButton alloc] initWithFrame:NSMakeRect(230, 20, 150, 30)];
    [scheduleButton setTitle:@"Schedule..."];
    [scheduleButton setTarget:self];
    [scheduleButton setAction:@selector(openScheduleDialog)];
    [mainView addSubview:scheduleButton];

    privilegeEscalationCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(500, 20, 80, 20)];
    [privilegeEscalationCheckbox setButtonType:NSSwitchButton];
    [privilegeEscalationCheckbox setTitle:@"Unlock"];
    [privilegeEscalationCheckbox setTarget:self];
    [privilegeEscalationCheckbox setAction:@selector(requestPrivileges:)];
    [mainView addSubview:privilegeEscalationCheckbox];
    [self enableUIElements:NO];
}

- (void)restoreDefaults {
    [sleepSlider setDoubleValue:30];
    [preventSleepCheckbox setState:NSControlStateValueOff];
    [putDisksToSleepCheckbox setState:NSControlStateValueOn];
    [wakeForNetworkCheckbox setState:NSControlStateValueOn];
    [startupAfterPowerFailureCheckbox setState:NSControlStateValueOff];
    [enablePowerNapCheckbox setState:NSControlStateValueOn];
}

- (void)openScheduleDialog {
    // Placeholder for schedule dialog
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Schedule power management tasks"];
    [alert runModal];
}

- (NSView *)mainView {
    return mainView;
}

@end
