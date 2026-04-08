#import "AppDelegate.h"

@implementation AppDelegate

@synthesize dockController = _dockController;

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    _dockController = [[DockController alloc] init];
    [NSApp setDelegate:_dockController];
    [_dockController applicationDidFinishLaunching:notification];
}

@end
