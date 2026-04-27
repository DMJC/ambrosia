// VideoModule.h
// GNUstep / SystemPreferences module for managing display resolutions with RandR

#import <AppKit/AppKit.h>
#import <PreferencePanes/PreferencePanes.h>
NS_ASSUME_NONNULL_BEGIN

@interface VideoModule : NSPreferencePane <NSTableViewDataSource, NSTableViewDelegate>

// Resolution Settings tab outlets
@property (nonatomic, strong) IBOutlet NSTableView *deviceTableView;
@property (nonatomic, strong) IBOutlet NSTableView *outputDeviceTableView;
@property (nonatomic, strong) IBOutlet NSTableView *inputDeviceTableView;
@property (nonatomic, strong) IBOutlet NSButton    *ApplyButton;

// SystemPreferences entry point
- (void)mainViewDidLoad;

// Actions
- (IBAction)onApply:(id)sender;
- (IBAction)onApplyLayout:(id)sender;

@end

NS_ASSUME_NONNULL_END
