#import "MenuBarController.h"
#import "MenuBarView.h"

#include <signal.h>
#include <errno.h>

static const CGFloat kBarHeight          = 24.0;
static const CGFloat kFallbackWidth      = 1920.0;
static const CGFloat kFallbackScreenH    = 1080.0;

@implementation MenuBarController {
    NSPanel              *_menuPanel;
    MenuBarView          *_menuBarView;
    NSConnection         *_doConnection;
    NSString             *_activeAppName;
    NSArray              *_activeMenuItems;
    /* PID of the DO-registered active app, or 0 if no app has registered. */
    int32_t               _activeClientPID;
    id                    _activateObserver;
    id                    _deactivateObserver;
    /* GFinder running-state tracking. */
    int32_t               _gfinderPID;        /* 0 = not running */
    NSString             *_gfinderLaunchPath; /* path seen at launch time */
    id                    _gfinderLaunchObs;
    id                    _gfinderTerminateObs;
    /* Status item plugins */
    BluetoothStatusItem  *_bluetoothItem;
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
    [self _startTrackingGFinder];
    [self _setupStatusPlugins];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Status item plugins

- (void)_setupStatusPlugins
{
    /* Create the Bluetooth status item and wire its delegate to the bar view
     * so it can request redraws after async refreshes.                      */
    _bluetoothItem = [[BluetoothStatusItem alloc] init];
    _bluetoothItem.pluginDelegate = _menuBarView;
    _menuBarView.statusPlugins    = @[ _bluetoothItem ];
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
    _menuPanel.level           = NSMainMenuWindowLevel;
    _menuPanel.title           = @"AmbrosiaMenuServer";
    _menuPanel.opaque          = NO;
    _menuPanel.backgroundColor = [NSColor clearColor];
    _menuPanel.hasShadow       = NO;
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
     * in the bar when a new app launches, unless a DO-registered app is
     * already providing menu data via -applicationDidActivate:menuItems:pid: */
    _activateObserver = [ws.notificationCenter
        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        /* If a DO-registered app is active, it owns the bar — do not
         * override it with the workspace fallback.                      */
        if (strongSelf->_activeClientPID != 0) return;
        NSString *name = note.userInfo[@"NSApplicationName"];
        if (name.length && ![name isEqualToString:strongSelf->_activeAppName]) {
            [strongSelf _updateActiveApp:name menuItems:nil pid:0];
        }
    }];

    /* Clear the bar when the active app terminates.
     * Match by PID first (reliable for DO-registered apps) then by name
     * (fallback for workspace-only apps that never called DO).            */
    _deactivateObserver = [ws.notificationCenter
        addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSNumber *pidNum = note.userInfo[@"NSApplicationProcessIdentifier"];
        int32_t   terminatedPID = pidNum ? (int32_t)[pidNum intValue] : 0;
        NSString *name = note.userInfo[@"NSApplicationName"];
        BOOL matchesPID  = (terminatedPID != 0 &&
                            terminatedPID == strongSelf->_activeClientPID);
        BOOL matchesName = [name isEqualToString:strongSelf->_activeAppName];
        if (matchesPID || matchesName) {
            [strongSelf _updateActiveApp:nil menuItems:nil pid:0];
        }
    }];
}

- (void)_updateActiveApp:(NSString *)appName
               menuItems:(NSArray *)items
                     pid:(int32_t)pid
{
    _activeAppName   = [appName copy];
    _activeMenuItems = [items copy];
    _activeClientPID = pid;
    [_menuBarView setActiveAppName:_activeAppName menuItems:_activeMenuItems];
}

/* ---------------------------------------------------------------------- */
#pragma mark - MenuServerProtocol (DO, called by GNUstep apps)

- (void)applicationDidActivate:(bycopy NSString *)appName
                     menuItems:(bycopy NSArray *)menuItems
                           pid:(bycopy NSNumber *)pid
{
    /* DO callbacks may arrive on a background thread; marshal to main. */
    NSString *nameCopy  = [appName copy];
    NSArray  *itemsCopy = [menuItems copy];
    int32_t   pidValue  = (int32_t)[pid intValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        /* If the currently registered app's process is no longer alive (crash
         * or SIGKILL — it never called deregisterFromServer), evict it so the
         * new app's registration is always accepted.                          */
        if (self->_activeClientPID != 0 &&
            kill((pid_t)self->_activeClientPID, 0) != 0 && errno == ESRCH) {
            NSLog(@"MenuServer: evicting stale registration for \"%@\" (pid %d — dead).",
                  self->_activeAppName, self->_activeClientPID);
            self->_activeClientPID = 0;
        }
        [self _updateActiveApp:nameCopy menuItems:itemsCopy pid:pidValue];
    });
}

- (oneway void)applicationDidDeactivate:(bycopy NSString *)appName
{
    NSString *nameCopy = [appName copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self->_activeAppName isEqualToString:nameCopy]) {
            [self _updateActiveApp:nil menuItems:nil pid:0];
        }
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Menu-item action callback (invoked by MenuBarView)

/**
 * Posts kMenuItemSelectedNotification to NSDistributedNotificationCenter.
 *
 * The notification is delivered to all GNUstep processes.  Each instance of
 * AmbrosiaMenusBundle checks the kMenuItemSelectedPIDKey value against its
 * own PID; only the matching process dispatches the menu action.
 *
 * This replaces the previous "byref DO proxy" approach, which required
 * GNUstep to establish a reverse connection from the server back to the
 * client's anonymous port — a connection that was torn down as soon as
 * -applicationDidActivate:menuItems:pid: returned, before the stored proxy
 * could ever be used.
 */
- (void)performMenuItemWithIdentifier:(NSString *)identifier
{
    if (!identifier.length || _activeClientPID == 0) return;

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kMenuItemSelectedNotification
                      object:nil
                    userInfo:@{
                        kMenuItemSelectedPIDKey:        @(_activeClientPID),
                        kMenuItemSelectedIdentifierKey: identifier,
                    }
          deliverImmediately:YES];
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

/* ---------------------------------------------------------------------- */
#pragma mark - GFinder running-state tracking

- (void)_startTrackingGFinder
{
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    __weak typeof(self) weakSelf = self;

    _gfinderLaunchObs = [ws.notificationCenter
        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSDictionary *info = note.userInfo;
        NSString *bundleID = info[@"NSApplicationBundleIdentifier"];
        NSString *name     = info[@"NSApplicationName"];
        if ([bundleID isEqualToString:@"org.gnustep.GFinder"] ||
            [name isEqualToString:@"GFinder"]) {
            strongSelf->_gfinderPID        = [info[@"NSApplicationProcessIdentifier"] intValue];
            strongSelf->_gfinderLaunchPath = info[@"NSApplicationPath"];
        }
    }];

    _gfinderTerminateObs = [ws.notificationCenter
        addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSDictionary *info = note.userInfo;
        NSString *bundleID = info[@"NSApplicationBundleIdentifier"];
        NSString *name     = info[@"NSApplicationName"];
        int32_t   pid      = [info[@"NSApplicationProcessIdentifier"] intValue];
        if ([bundleID isEqualToString:@"org.gnustep.GFinder"] ||
            [name isEqualToString:@"GFinder"] ||
            (pid != 0 && pid == strongSelf->_gfinderPID)) {
            strongSelf->_gfinderPID        = 0;
            strongSelf->_gfinderLaunchPath = nil;
        }
    }];
}

- (void)openGFinder
{
    if (_gfinderPID != 0) {
        /* GFinder is already running — ask the compositor to bring it to focus. */
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"bundleIdentifier"] = @"org.gnustep.GFinder";
        info[@"appName"]          = @"GFinder";
        if (_gfinderLaunchPath.length)
            info[@"launchPath"] = _gfinderLaunchPath;
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:@"AmbrosiaActivateApplication"
                          object:nil
                        userInfo:info
              deliverImmediately:YES];
        return;
    }

    /* GFinder is not running — launch it. */
    NSArray<NSString *> *candidates = @[
        @"/usr/GNUstep/Local/Applications/GFinder.app",
        @"/usr/GNUstep/System/Applications/GFinder.app",
        @"/usr/local/GNUstep/Local/Applications/GFinder.app",
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Applications/GFinder.app"],
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSWorkspace sharedWorkspace] launchApplication:path];
            return;
        }
    }
    NSLog(@"MenuServer: GFinder.app not found in standard locations.");
}

/* ---------------------------------------------------------------------- */
#pragma mark - Panel geometry (called by MenuBarView)

- (void)expandPanelByDropdownHeight:(CGFloat)dropH
{
    /* Grow the panel downward (decrease origin.y, increase height).
     * The layer-shell compositor keeps the top edge anchored at the top of
     * the screen; gnustep-back will update the wlr_layer_surface_v1 size.  */
    NSRect f = _menuPanel.frame;
    f.origin.y    -= dropH;
    f.size.height += dropH;
    [_menuPanel setFrame:f display:YES animate:NO];
}

- (void)contractPanelDropdown
{
    /* Restore to the standard kBarHeight-pixel bar. */
    NSScreen *screen = [NSScreen mainScreen];
    NSRect sf = screen ? screen.frame : NSZeroRect;
    if (sf.size.width  < 32) sf.size.width  = kFallbackWidth;
    if (sf.size.height < 32) sf.size.height = kFallbackScreenH;

    NSRect barRect = NSMakeRect(sf.origin.x,
                                sf.origin.y + sf.size.height - kBarHeight,
                                sf.size.width,
                                kBarHeight);
    [_menuPanel setFrame:barRect display:YES animate:NO];
}

/* ---------------------------------------------------------------------- */

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

- (void)openTerminal
{
    NSArray<NSString *> *candidates = @[
        @"/usr/bin/xterm",
        @"/usr/bin/x-terminal-emulator",
        @"/usr/bin/gnome-terminal",
        @"/usr/bin/konsole",
        @"/usr/bin/xfce4-terminal",
        @"/usr/bin/lxterminal",
        @"/usr/bin/mate-terminal",
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSWorkspace sharedWorkspace] launchApplication:path];
            return;
        }
    }
    NSLog(@"MenuServer: no terminal emulator found in standard locations.");
}

- (void)shutdown
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Shut Down"];
    [alert setInformativeText:@"Are you sure you want to shut down?"];
    [alert addButtonWithTitle:@"Shut Down"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[NSTask launchedTaskWithLaunchPath:@"/bin/sh"
                                  arguments:@[@"-c", @"systemctl poweroff"]] waitUntilExit];
    }
}

- (void)reboot
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Restart"];
    [alert setInformativeText:@"Are you sure you want to restart?"];
    [alert addButtonWithTitle:@"Restart"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[NSTask launchedTaskWithLaunchPath:@"/bin/sh"
                                  arguments:@[@"-c", @"systemctl reboot"]] waitUntilExit];
    }
}

@end
