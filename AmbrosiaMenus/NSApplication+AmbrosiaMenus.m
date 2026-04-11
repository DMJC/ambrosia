#import "NSApplication+AmbrosiaMenus.h"
#import "AmbrosiaMenusBundle.h"
#import <AppKit/NSMenu.h>
#import <objc/runtime.h>

@implementation NSApplication (AmbrosiaMenus)

/**
 * +load is called by the ObjC runtime when this category's class is loaded,
 * i.e. when the bundle is injected into the host app.  We perform the
 * method exchange exactly once.
 */
+ (void)load
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSApplication class];
        Method orig = class_getInstanceMethod(cls, @selector(setMainMenu:));
        Method repl = class_getInstanceMethod(cls, @selector(ambrosia_setMainMenu:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
    });
}

/**
 * After the swizzle:
 *   • -setMainMenu: → this method's body (suppress + register)
 *   • -ambrosia_setMainMenu: → original NSApplication -setMainMenu: body
 *
 * So `[self ambrosia_setMainMenu:menu]` calls the *original* implementation,
 * letting GNUstep set up its internal state, window level, etc.  We then
 * close the window so no Wayland surface is created / persists for it.
 */
- (void)ambrosia_setMainMenu:(NSMenu *)menu
{
    /* Invoke original NSApplication -setMainMenu: (now bound to this selector
     * after the exchange).                                                    */
    [self ambrosia_setMainMenu:menu];

    /* Suppress the menu window.  NSMenu -_setGeometry (overridden in
     * NSMenu+AmbrosiaMenus) will keep it hidden on subsequent geometry
     * updates, but we also close it here to catch the initial orderFront
     * that NSApplication issues immediately after setMainMenu:.              */
    [[menu window] orderOut:nil];

    /* Tell the bundle to (re)send descriptors to MenuServer.  Wrapped in a
     * delayed perform so we're outside the setMainMenu: call stack, giving
     * GNUstep time to finish setting up the menu before we iterate it.      */
    [[AmbrosiaMenusBundle sharedBundle]
        performSelector:@selector(registerMenuWithServer)
             withObject:nil
             afterDelay:0.0];
}

@end
