#import "AppDelegate.h"
#import "MenuBarController.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    _menuBarController = [[MenuBarController alloc] init];
    [_menuBarController showMenuBar];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return NO;
}

@end
