#import "AmbrosiaMenusBundle.h"
#import <AppKit/AppKit.h>

/* ---------------------------------------------------------------------- */
#pragma mark - AmbrosiaMenusBundle

@implementation AmbrosiaMenusBundle {
    /* DO proxy to the MenuServer.  Nilled on failure so we retry next time. */
    id<MenuServerProtocol> _serverProxy;

    /*
     * Maps the UUID identifiers we embed in menu descriptors back to the live
     * NSMenuItem objects.  Rebuilt on every call to registerMenuWithServer.
     */
    NSMutableDictionary<NSString *, NSMenuItem *> *_itemTable;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Singleton

+ (instancetype)sharedBundle
{
    static AmbrosiaMenusBundle *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _itemTable = [NSMutableDictionary dictionary];
    return self;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Bundle entry point

/**
 * +load runs when the ObjC runtime injects this bundle into the host app,
 * before NSApplicationMain().  We set up notification observers here;
 * swizzles are installed by NSApplication+AmbrosiaMenus +load.
 */
+ (void)load
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    /* Initial registration: fires after the app finishes launching and its
     * main menu has been set up.                                           */
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification
                   object:nil
                    queue:[NSOperationQueue mainQueue]
               usingBlock:^(NSNotification *note) {
        [[AmbrosiaMenusBundle sharedBundle] registerMenuWithServer];
    }];

    /* Re-register whenever the app regains focus (e.g. user switches back). */
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                   object:nil
                    queue:[NSOperationQueue mainQueue]
               usingBlock:^(NSNotification *note) {
        [[AmbrosiaMenusBundle sharedBundle] registerMenuWithServer];
    }];

    /* Deregister on termination so MenuServer clears the bar cleanly. */
    [nc addObserverForName:NSApplicationWillTerminateNotification
                   object:nil
                    queue:[NSOperationQueue mainQueue]
               usingBlock:^(NSNotification *note) {
        [[AmbrosiaMenusBundle sharedBundle] deregisterFromServer];
    }];
}

/* ---------------------------------------------------------------------- */
#pragma mark - DO connection

/** Returns the cached server proxy, connecting lazily on first call. */
- (id<MenuServerProtocol>)_serverProxy
{
    if (_serverProxy) return _serverProxy;

    id rawProxy = [NSConnection
        rootProxyForConnectionWithRegisteredName:kMenuServerConnectionName
                                            host:nil];
    if (!rawProxy) {
        NSLog(@"AmbrosiaMenus: could not connect to MenuServer (%@) -- "
              @"menu bar integration unavailable.", kMenuServerConnectionName);
        return nil;
    }

    [rawProxy setProtocolForProxy:@protocol(MenuServerProtocol)];
    _serverProxy = (id<MenuServerProtocol>)rawProxy;
    return _serverProxy;
}

- (void)_invalidateProxy
{
    _serverProxy = nil;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Descriptor building

/**
 * Recursively converts an NSMenu into the NSDictionary descriptor array
 * expected by MenuServerProtocol.  Assigns a UUID identifier to each
 * non-separator item and records the NSMenuItem in _itemTable so that
 * callbacks from the server can dispatch actions to the right target.
 *
 * Top-level items whose title equals the process name (the macOS-style
 * "application menu") are passed through so the user can access About,
 * Preferences, and Quit from the bar.
 */
- (NSArray *)_descriptorsForMenu:(NSMenu *)menu
{
    NSMutableArray *result = [NSMutableArray array];

    for (NSMenuItem *item in menu.itemArray) {
        NSMutableDictionary *desc = [NSMutableDictionary dictionary];

        if (item.isSeparatorItem) {
            desc[kMenuItemSeparator] = @YES;
            [result addObject:[desc copy]];
            continue;
        }

        NSString *identifier = [[NSUUID UUID] UUIDString];
        desc[kMenuItemTitle]      = item.title ?: @"";
        desc[kMenuItemIdentifier] = identifier;
        desc[kMenuItemEnabled]    = @(item.isEnabled);

        if (item.keyEquivalent.length)
            desc[kMenuItemKeyEquiv] = item.keyEquivalent;

        if (item.submenu)
            desc[kMenuItemChildren] =
                [self _descriptorsForMenu:item.submenu];

        /* Record the live item so performMenuItemWithIdentifier: can look it
         * up.  Items with submenus are included because their action (if any)
         * can still be triggered directly.                                    */
        _itemTable[identifier] = item;

        [result addObject:[desc copy]];
    }

    return [result copy];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Server registration

- (void)registerMenuWithServer
{
    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) return;

    id<MenuServerProtocol> proxy = [self _serverProxy];
    if (!proxy) return;

    [_itemTable removeAllObjects];

    NSString *appName = [[NSProcessInfo processInfo] processName];
    NSArray  *items   = [self _descriptorsForMenu:mainMenu];

    @try {
        [proxy applicationDidActivate:appName menuItems:items client:self];
    } @catch (NSException *ex) {
        NSLog(@"AmbrosiaMenus: registration call failed (%@); "
              @"will retry on next activation.", ex.reason);
        [self _invalidateProxy];
    }
}

- (void)deregisterFromServer
{
    id<MenuServerProtocol> proxy = _serverProxy; /* read ivar directly */
    if (!proxy) return;

    NSString *appName = [[NSProcessInfo processInfo] processName];
    @try {
        [proxy applicationDidDeactivate:appName];
    } @catch (NSException *ex) {
        NSLog(@"AmbrosiaMenus: deregister call failed (%@).", ex.reason);
    }
    [self _invalidateProxy];
}

/* ---------------------------------------------------------------------- */
#pragma mark - MenuServerClientProtocol

/**
 * Called by MenuServer (on a DO thread) when the user selects a menu item.
 * Dispatches the item's action to its target on the main thread.
 */
- (oneway void)performMenuItemWithIdentifier:(bycopy NSString *)identifier
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenuItem *item = self->_itemTable[identifier];
        if (!item) {
            NSLog(@"AmbrosiaMenus: received unknown identifier: %@", identifier);
            return;
        }
        if (!item.isEnabled || !item.action) return;
        [NSApp sendAction:item.action to:item.target from:item];
    });
}

@end
