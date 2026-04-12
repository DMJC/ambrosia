#import "NSMenu+AmbrosiaMenus.h"
#import <Foundation/Foundation.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSWindow.h>
#import <objc/runtime.h>

@implementation NSMenu (AmbrosiaMenus)

/**
 * +load installs swizzles on three NSMenu methods that GNUstep uses to show
 * the main menu window.
 *
 * All three swizzles follow the same pattern:
 *   • If this menu IS [NSApp mainMenu] → suppress (orderOut:)
 *   • Otherwise → call through to the original implementation
 *
 * IMPORTANT: The `setGeometry` / `_setGeometry` overrides use
 * method_exchangeImplementations, NOT plain category methods.  A category
 * method completely replaces the original, so any non-main-menu (popup,
 * context, submenu) that relies on `_setGeometry` to position itself would
 * get a silent no-op, which prevents popup menus from appearing.  By
 * swizzling we can call through to the original for all non-main-menu cases.
 *
 * Swizzle table after +load:
 *   -display             → ambrosia_display body   (call-through via ambrosia_display)
 *   -ambrosia_display    → original display IMP
 *   -_setGeometry        → ambrosia__setGeometry body
 *   -ambrosia__setGeometry → original _setGeometry IMP
 *   -setGeometry         → ambrosia_setGeometry body   (only if method exists)
 *   -ambrosia_setGeometry → original setGeometry IMP
 */
+ (void)load
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSMenu class];

        /* -display */
        Method origDisplay = class_getInstanceMethod(cls, @selector(display));
        Method replDisplay = class_getInstanceMethod(cls, @selector(ambrosia_display));
        if (origDisplay && replDisplay)
            method_exchangeImplementations(origDisplay, replDisplay);

        /* -_setGeometry (GNUstep private) */
        Method origSetGeomPriv = class_getInstanceMethod(cls, @selector(_setGeometry));
        Method replSetGeomPriv = class_getInstanceMethod(cls, @selector(ambrosia__setGeometry));
        if (origSetGeomPriv && replSetGeomPriv)
            method_exchangeImplementations(origSetGeomPriv, replSetGeomPriv);

        /* -setGeometry (public alias; may not exist in all GNUstep versions) */
        Method origSetGeomPub = class_getInstanceMethod(cls, @selector(setGeometry));
        Method replSetGeomPub = class_getInstanceMethod(cls, @selector(ambrosia_setGeometry));
        if (origSetGeomPub && replSetGeomPub)
            method_exchangeImplementations(origSetGeomPub, replSetGeomPub);
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Swizzled method bodies

/* After the exchange:
 *   -display          → this body   (suppress main menu; call-through otherwise)
 *   -ambrosia_display → original display IMP
 */
- (void)ambrosia_display
{
    if (NSApp && [self isEqual:[NSApp mainMenu]]) {
        [[self window] orderOut:nil];
        return;
    }
    [self ambrosia_display];
}

/* After the exchange:
 *   -_setGeometry           → this body
 *   -ambrosia__setGeometry  → original _setGeometry IMP
 */
- (void)ambrosia__setGeometry
{
    if (NSApp && [self isEqual:[NSApp mainMenu]]) {
        [[self window] orderOut:nil];
        return;
    }
    [self ambrosia__setGeometry];   /* call original — positions popup menus */
}

/* After the exchange:
 *   -setGeometry          → this body
 *   -ambrosia_setGeometry → original setGeometry IMP
 */
- (void)ambrosia_setGeometry
{
    if (NSApp && [self isEqual:[NSApp mainMenu]]) {
        [[self window] orderOut:nil];
        return;
    }
    [self ambrosia_setGeometry];    /* call original — positions popup menus */
}

@end
