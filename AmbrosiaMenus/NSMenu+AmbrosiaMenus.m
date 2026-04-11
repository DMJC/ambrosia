#import "NSMenu+AmbrosiaMenus.h"
#import <Foundation/Foundation.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSWindow.h>
#import <objc/runtime.h>

@implementation NSMenu (AmbrosiaMenus)

/**
 * +load installs a swizzle on NSMenu -display.
 *
 * -setGeometry / -_setGeometry only fire for the initial placement; GNUstep
 * also calls [menu display] (→ orderFrontRegardless) from -setMainMenu: and
 * from the app-activation path.  Without swizzling -display those paths
 * re-show the main menu window even after we close it in setGeometry.
 *
 * After method_exchangeImplementations:
 *   -display        → ambrosia_display body  (suppress main menu; call-through otherwise)
 *   -ambrosia_display → original display IMP (orderFrontRegardless etc.)
 */
+ (void)load
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSMenu class];
        Method origDisplay = class_getInstanceMethod(cls, @selector(display));
        Method replDisplay = class_getInstanceMethod(cls,
                                 @selector(ambrosia_display));
        if (origDisplay && replDisplay)
            method_exchangeImplementations(origDisplay, replDisplay);
    });
}

/* Called when -display is invoked on any NSMenu instance (after swizzle). */
- (void)ambrosia_display
{
    if (NSApp && [self isEqual:[NSApp mainMenu]]) {
        /* Suppress: close the window instead of ordering it front. */
        [[self window] orderOut:nil];
        return;
    }
    /* For all other menus (submenus, pop-ups) call the original display IMP,
     * which is now registered under the ambrosia_display selector.          */
    [self ambrosia_display];
}

/*
 * Category overrides for the geometry methods.
 *
 * -_setGeometry is the GNUstep-private entry point for positioning the main
 * menu window.  -setGeometry is its public alias.  We replace both: for the
 * main menu we close the window; for any other menu we do nothing (submenus
 * are positioned by NSMenuView, not these methods).
 */
- (void)_setGeometry
{
    [self setGeometry];
}

- (void)setGeometry
{
    if (NSApp && [self isEqual:[NSApp mainMenu]])
        [[self window] orderOut:nil];
}

@end
