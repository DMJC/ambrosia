#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <PreferencePanes/PreferencePanes.h>

@interface PowerManagementPane : NSPreferencePane {
    NSSlider *sleepSlider;
    NSTextField *sliderLabel;
    NSTextField *sliderValuesLabel;
    NSButton *privilegeEscalationCheckbox;
    NSButton *preventSleepCheckbox;
    NSButton *putDisksToSleepCheckbox;
    NSButton *wakeForNetworkCheckbox;
    NSButton *startupAfterPowerFailureCheckbox;
    NSButton *enablePowerNapCheckbox;
    NSButton *restoreDefaultsButton;
    NSButton *scheduleButton;
    NSView *mainView;
}
@end
