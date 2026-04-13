#import <AppKit/AppKit.h>
#import "AppDelegate.h"
#include <signal.h>

int main(int argc, const char *argv[])
{
    /* NSWorkspace may spawn child processes when launching apps from the dock.
     * Ignore SIGCHLD so exited launcher children are auto-reaped and cannot
     * accumulate as zombies under AmbrosiaDock. */
    signal(SIGCHLD, SIG_IGN);

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;

        [app run];
    }
    return 0;
}
