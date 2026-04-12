#import "MenuBarController.h"
#import "MenuBarView.h"

static const CGFloat kBarHeight          = 24.0;
static const CGFloat kFallbackWidth      = 1920.0;
static const CGFloat kFallbackScreenH    = 1080.0;

@implementation MenuBarController {
    NSPanel      *_menuPanel;
    MenuBarView  *_menuBarView;
    NSConnection *_doConnection;
    /* Strong reference to the DO proxy for the active app's client.
     * NSDistantObject is an NSProxy subclass and does NOT support ARC
     * zeroing-weak storage; __weak would always yield nil.             */
    id<MenuServerClientProtocol> _clientProxy;
    NSString     *_activeAppName;
    NSArray      *_activeMenuItems;
    id            _activateObserver;
    id            _deactivateObserver;
}

@synthesize menuPanel   = _menuPanel;
@synthesize menuBarView = _menuBarView;

/* ---------------------------------------------------------------------- */
#pragma mark - Public interface

- (void)showMenuBar
{
    [self _createPanel];
    [self _startDOServer];
    [self _observeWorkspace];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Panel creation

- (void)_createPanel
{
    NSScreen *screen = [NSScreen mainScreen];
    NSRect sf = screen ? screen.frame : NSZeroRect;
    if (sf.size.width  < 32) sf.size.width  = kFallbackWidth;
    if (sf.size.height < 32) sf.size.height = kFallbackScreenH;

    /*
     * GNUstep uses a bottom-left coordinate origin; y increases upward.
     *
     * For a 24 px bar sitting flush at the TOP of a 1 080 px screen:
     *   y_gnustep = screenH − barHeight = 1056
     *
     * gnustep-back (Wayland path) converts this to Wayland screen-space:
     *   top_margin = screenH − (y_gnustep + barHeight) = 0
     *
     * wlr_scene_layer_surface_v1_configure then positions the layer-shell
     * surface (namespace "gnustep-mainmenu", layer LAYER_TOP) with a 0 px
     * margin from the top edge of the output.
     */
    NSRect barRect = NSMakeRect(sf.origin.x,
                                sf.origin.y + sf.size.height - kBarHeight,
                                sf.size.width,
                                kBarHeight);

    _menuPanel = [[NSPanel alloc]
                  initWithContentRect:barRect
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:NO];

    /* Window level NSMainMenuWindowLevel (= 20) causes gnustep-back to
     * create a wlr-layer-shell surface at ZWLR_LAYER_SHELL_V1_LAYER_TOP
     * with the namespace "gnustep-mainmenu".                             */
    _menuPanel.level    = NSMainMenuWindowLevel;
    _menuPanel.title    = @"AmbrosiaMenuServer";
    _menuPanel.opaque   = YES;
    _menuPanel.hasShadow = NO;
    /* Prevent the panel from stealing keyboard focus from app windows. */
    [_menuPanel setBecomesKeyOnlyIfNeeded:YES];

    _menuBarView = [[MenuBarView alloc]
                    initWithFrame:((NSView *)_menuPanel.contentView).bounds];
    _menuBarView.controller        = self;
    _menuBarView.autoresizingMask  = NSViewWidthSizable | NSViewHeightSizable;

    [_menuPanel.contentView addSubview:_menuBarView];
    [_menuPanel makeKeyAndOrderFront:nil];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Distributed Objects service

- (void)_startDOServer
{
    _doConnection = [[NSConnection alloc] init];
    [_doConnection setRootObject:self];

    if (![_doConnection registerName:kMenuServerConnectionName]) {
        NSLog(@"MenuServer: could not register DO service \"%@\" -- "
              @"another instance may already be running.",
              kMenuServerConnectionName);
        _doConnection = nil;
    } else {
        NSLog(@"MenuServer: Distributed Objects service \"%@\" registered.",
              kMenuServerConnectionName);
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSWorkspace observation

- (void)_observeWorkspace
{
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    __weak typeof(self) weakSelf = self;

    /* GNUstep does not post activate/deactivate notifications.
     * Use DidLaunchApplication as a best-effort fallback: show the app name
     * in the bar when it launches, unless it has already registered via DO. */
    _activateObserver = [ws.notificationCenter
        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *name = note.userInfo[@"NSApplicationName"];
        if (name.length && ![name isEqualToString:strongSelf->_activeAppName]) {
            [strongSelf _updateActiveApp:name menuItems:nil client:nil];
        }
    }];

    /* Clear the bar when the active app terminates. */
    _deactivateObserver = [ws.notificationCenter
        addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *name = note.userInfo[@"NSApplicationName"];
        if ([name isEqualToString:strongSelf->_activeAppName]) {
            [strongSelf _updateActiveApp:nil menuItems:nil client:nil];
        }
    }];
}

- (void)_updateActiveApp:(NSString *)appName
               menuItems:(NSArray *)items
                  client:(id<MenuServerClientProtocol>)client
{
    _activeAppName   = [appName copy];
    _activeMenuItems = [items copy];
    _clientProxy     = client;           /* weak — released when app exits */
    [_menuBarView setActiveAppName:_activeAppName menuItems:_activeMenuItems];
}

/* ---------------------------------------------------------------------- */
#pragma mark - MenuServerProtocol (DO, called by GNUstep apps)

- (void)applicationDidActivate:(bycopy NSString *)appName
                   menuItems:(bycopy NSArray *)menuItems
                      client:(byref id<MenuServerClientProtocol>)client
{
    /* DO callbacks may arrive on a background thread; marshal to main. */
    NSString *nameCopy  = [appName copy];
    NSArray  *itemsCopy = [menuItems copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _updateActiveApp:nameCopy menuItems:itemsCopy client:client];
    });
}

- (oneway void)applicationDidDeactivate:(bycopy NSString *)appName
{
    NSString *nameCopy = [appName copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self->_activeAppName isEqualToString:nameCopy]) {
            [self _updateActiveApp:nil menuItems:nil client:nil];
        }
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Menu-item action callback (invoked by MenuBarView)

/**
 * Called when the user selects an item in a DO-registered app's menu.
 * Forwards the action to the app via its client proxy.
 */
- (void)performMenuItemWithIdentifier:(NSString *)identifier
{
    id<MenuServerClientProtocol> proxy = _clientProxy;
    if (proxy && identifier.length) {
        @try {
            [proxy performMenuItemWithIdentifier:identifier];
        } @catch (NSException *ex) {
            NSLog(@"MenuServer: client DO call failed (%@); clearing proxy.", ex.reason);
            _clientProxy = nil;
        }
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - System actions (called by MenuBarView)

- (void)showAbout
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Ambrosia"];
    [alert setInformativeText:
        @"Ambrosia Desktop Environment\n"
        @"A GNUstep desktop for Wayland.\n\n"
        @"Compositor: ambrosia-compositor\n"
        @"Menu Server: MenuServer"];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)openSystemPreferences
{
    NSArray<NSString *> *candidates = @[
        @"/usr/GNUstep/Local/Applications/SystemPreferences.app",
        @"/usr/GNUstep/System/Applications/SystemPreferences.app",
        @"/usr/local/GNUstep/Local/Applications/SystemPreferences.app",
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Applications/SystemPreferences.app"],
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSWorkspace sharedWorkspace] launchApplication:path];
            return;
        }
    }
    NSLog(@"MenuServer: SystemPreferences.app not found in standard locations.");
}

- (void)logout
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Log Out"];
    [alert setInformativeText:@"Are you sure you want to end the session?"];
    [alert addButtonWithTitle:@"Log Out"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:@"AmbrosiaLogoutRequest"
                          object:nil
                        userInfo:nil
              deliverImmediately:YES];
    }
}

@end
