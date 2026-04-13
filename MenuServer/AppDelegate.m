#import "AppDelegate.h"
#import "MenuBarController.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    _menuBarController = [[MenuBarController alloc] init];
    [_menuBarController showMenuBar];

    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleSessionWillQuit:)
               name:@"AmbrosiaSessionWillQuit"
             object:nil];
}

- (void)_handleSessionWillQuit:(NSNotification *)note
{
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return NO;
}

- (void)dealloc
{
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

@end
