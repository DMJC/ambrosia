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

    /* Retry timer: fired when MenuServer wasn't available at first attempt. */
    NSTimer    *_retryTimer;
    NSUInteger  _retryCount;
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
    _itemTable  = [NSMutableDictionary dictionary];
    _retryCount = 0;

    /*
     * Observe kMenuItemSelectedNotification from NSDistributedNotificationCenter.
     *
     * When the user selects a menu item in the bar, MenuServer posts this
     * notification with kMenuItemSelectedPIDKey set to the PID of the app that
     * registered the menu.  We ignore notifications meant for other processes.
     *
     * This replaces the previous "byref DO proxy" callback, which required
     * GNUstep to maintain a reverse connection back to our anonymous port — a
     * connection torn down as soon as -applicationDidActivate:menuItems:pid:
     * returned, so every callback silently failed.
     */
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_menuItemSelected:)
               name:kMenuItemSelectedNotification
             object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    /*
     * Observe kAmbrosiaApplicationActivatedNotification from the compositor.
     *
     * gnustep-back does not reliably translate wl_keyboard.enter into
     * NSWindowDidBecomeKeyNotification for surfaces that are already mapped
     * (e.g. when the user cycles between existing apps with Super+Tab).  The
     * compositor posts this notification whenever keyboard focus moves to a
     * different wl_client; we re-register our menus if the PID matches ours.
     */
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_compositorDidActivateApp:)
               name:kAmbrosiaApplicationActivatedNotification
             object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

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
    /* Do not register when the bundle is loaded inside MenuServer itself.
     * MenuServer is both the DO server and the host process for this bundle;
     * calling [proxy applicationDidActivate:…] from within the server process
     * would be a synchronous intra-process DO call on the same thread — a
     * guaranteed deadlock / abort.                                           */
    NSString *procName = [[NSProcessInfo processInfo] processName];
    if ([procName isEqualToString:@"MenuServer"]) return;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    /* Initial registration: fires after the app finishes launching and its
     * main menu has been set up.                                           */
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification
                   object:nil
                    queue:[NSOperationQueue mainQueue]
               usingBlock:^(NSNotification *note) {
        [[AmbrosiaMenusBundle sharedBundle] registerMenuWithServer];
    }];

    /* Re-register whenever the app regains focus (e.g. user switches back).
     * NSApplicationDidBecomeActiveNotification may only fire once in
     * gnustep-back; NSWindowDidBecomeKeyNotification is more reliable because
     * it fires every time the compositor delivers wlr_seat keyboard.enter to
     * a surface, which gnustep-back translates into a key window change.    */
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                   object:nil
                    queue:[NSOperationQueue mainQueue]
               usingBlock:^(NSNotification *note) {
        [[AmbrosiaMenusBundle sharedBundle] registerMenuWithServer];
    }];

    [nc addObserverForName:NSWindowDidBecomeKeyNotification
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
        return nil;
    }

    [rawProxy setProtocolForProxy:@protocol(MenuServerProtocol)];
    _serverProxy = (id<MenuServerProtocol>)rawProxy;
    _retryCount  = 0;
    [_retryTimer invalidate];
    _retryTimer  = nil;
    NSLog(@"AmbrosiaMenus: connected to MenuServer (%@).",
          kMenuServerConnectionName);
    return _serverProxy;
}

- (void)_invalidateProxy
{
    _serverProxy = nil;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Retry timer

/**
 * If MenuServer wasn't running when the app launched, schedule periodic
 * retries so the bar populates as soon as the server comes up.
 */
- (void)_scheduleRetryIfNeeded
{
    if (_serverProxy || _retryTimer) return;          /* already connected or timer running */
    if (_retryCount >= 20) return;                    /* give up after ~40 s */

    _retryTimer = [NSTimer
        scheduledTimerWithTimeInterval:2.0
                                target:self
                              selector:@selector(_retryTimerFired:)
                              userInfo:nil
                               repeats:NO];
}

- (void)_retryTimerFired:(NSTimer *)timer
{
    _retryTimer = nil;
    _retryCount++;
    NSLog(@"AmbrosiaMenus: retrying MenuServer connection (attempt %lu).",
          (unsigned long)_retryCount);
    [self registerMenuWithServer];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Descriptor building

/**
 * Recursively converts an NSMenu into the NSDictionary descriptor array
 * expected by MenuServerProtocol.  Assigns a UUID identifier to each
 * non-separator item and records the NSMenuItem in _itemTable so that
 * the kMenuItemSelectedNotification handler can dispatch actions.
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
    if (!proxy) {
        NSLog(@"AmbrosiaMenus: MenuServer not available yet; scheduling retry.");
        [self _scheduleRetryIfNeeded];
        return;
    }

    [_itemTable removeAllObjects];

    NSString *appName = [[NSProcessInfo processInfo] processName];
    NSArray  *items   = [self _descriptorsForMenu:mainMenu];
    NSNumber *pid     = @((int32_t)[[NSProcessInfo processInfo] processIdentifier]);

    NSLog(@"AmbrosiaMenus: registering %lu top-level items for \"%@\" (pid %@).",
          (unsigned long)items.count, appName, pid);

    @try {
        [proxy applicationDidActivate:appName menuItems:items pid:pid];
        NSLog(@"AmbrosiaMenus: registration succeeded.");
    } @catch (NSException *ex) {
        NSLog(@"AmbrosiaMenus: registration call failed (%@); "
              @"will retry on next activation.", ex.reason);
        [self _invalidateProxy];
        [self _scheduleRetryIfNeeded];
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
#pragma mark - Compositor focus notification (NSDistributedNotificationCenter callback)

/**
 * Receives kAmbrosiaApplicationActivatedNotification posted by the compositor.
 * Re-registers menus when the compositor reports that our process is now the
 * frontmost application — belt-and-suspenders for the unreliable gnustep-back
 * NSWindowDidBecomeKeyNotification path on already-mapped surfaces.
 */
- (void)_compositorDidActivateApp:(NSNotification *)note
{
    NSNumber *pidNum = note.userInfo[kAmbrosiaActivatedPIDKey];
    int32_t myPID = (int32_t)[[NSProcessInfo processInfo] processIdentifier];
    if (!pidNum || [pidNum intValue] != myPID) return;
    [self registerMenuWithServer];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Menu-item selection (NSDistributedNotificationCenter callback)

/**
 * Receives kMenuItemSelectedNotification posted by MenuServer.
 * Ignores the notification when the PID doesn't match this process.
 * Dispatches the item's action on the main thread.
 */
- (void)_menuItemSelected:(NSNotification *)note
{
    NSNumber *pidNum = note.userInfo[kMenuItemSelectedPIDKey];
    int32_t   myPID  = (int32_t)[[NSProcessInfo processInfo] processIdentifier];
    if (!pidNum || [pidNum intValue] != myPID) return;

    NSString *identifier = note.userInfo[kMenuItemSelectedIdentifierKey];
    if (!identifier.length) return;

    /* Dispatch on the main thread; the notification may arrive on any thread. */
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
