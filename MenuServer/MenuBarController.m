#import "MenuBarController.h"
#import "MenuBarView.h"

#include <signal.h>
#include <errno.h>

static const CGFloat kBarHeight          = 24.0;
static const CGFloat kFallbackWidth      = 1920.0;
static const CGFloat kFallbackScreenH    = 1080.0;

/* Shared plist path for menu-bar visibility prefs written by SystemPreferences. */
static NSString *MenuBarPrefsPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Defaults/AmbrosiaMenuBar.plist"];
}

static BOOL ReadMenuBarPref(NSString *key)
{
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:MenuBarPrefsPath()];
    return [prefs[key] boolValue];
}

static NSString *SystemPreferencesPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Defaults/SystemPreferences.plist"];
}

static CGFloat ReadNumericValue(id raw)
{
    if ([raw isKindOfClass:[NSNumber class]]) return [raw doubleValue];
    if (![raw isKindOfClass:[NSString class]]) return 0.0;
    NSString *s = (NSString *)raw;
    NSScanner *scanner = [NSScanner scannerWithString:s];
    double v = 0.0;
    if ([scanner scanDouble:&v]) return v;
    NSRange r = [s rangeOfCharacterFromSet:
                 [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"]];
    if (r.location == NSNotFound) return 0.0;
    NSString *tail = [s substringFromIndex:r.location];
    scanner = [NSScanner scannerWithString:tail];
    return [scanner scanDouble:&v] ? v : 0.0;
}

/* ---------------------------------------------------------------------- */

@implementation MenuBarController {
    NSPanel              *_menuPanel;
    MenuBarView          *_menuBarView;
    NSMutableArray<NSPanel *> *_menuPanels;
    NSMutableArray<MenuBarView *> *_menuBarViews;
    NSMapTable<MenuBarView *, NSPanel *> *_panelByView;
    NSMapTable<NSPanel *, NSValue *> *_baseFrameByPanel;
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
    WiFiStatusItem       *_wifiItem;
    VolumeStatusItem     *_volumeItem;
    /* Tray icon manager (SNI / StatusNotifierItem) */
    TrayManager          *_trayManager;
}

@synthesize menuPanel    = _menuPanel;
@synthesize menuBarView  = _menuBarView;
@synthesize trayManager  = _trayManager;

/* ---------------------------------------------------------------------- */
#pragma mark - Public interface

- (void)showMenuBar
{
    [self _createPanel];
    [self _startDOServer];
    [self _observeWorkspace];
    [self _startTrackingGFinder];
    [self _setupStatusPlugins];
    [self _observeMenuBarPrefs];
    [self _startTrayManager];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Tray icon manager (SNI)

- (void)_startTrayManager
{
    _trayManager = [[TrayManager alloc] init];
    _trayManager.delegate = self;
    [_trayManager start];
}

/* TrayManagerDelegate */
- (void)trayManagerDidUpdateItems:(TrayManager *)manager
{
    for (MenuBarView *view in _menuBarViews) {
        view.trayItems = manager.trayItems;
    }
}

- (TrayManager *)trayManager { return _trayManager; }

/* ---------------------------------------------------------------------- */
#pragma mark - Status item plugins

- (void)_setupStatusPlugins
{
    /* Always show Bluetooth. Wi-Fi and Volume are opt-in via SystemPreferences
     * checkboxes; they write ShowWiFiMenu / ShowVolumeMenu to the plist below. */
    for (MenuBarView *view in _menuBarViews) {
        _bluetoothItem = [[BluetoothStatusItem alloc] init];
        _bluetoothItem.pluginDelegate = view;

        NSMutableArray *plugins = [NSMutableArray arrayWithObject:_bluetoothItem];

        /* Plugins are drawn right-to-left: index 0 is rightmost (closest to clock).
         * Desired bar order (right→left): BT | Wi-Fi | Vol               */
        if (ReadMenuBarPref(@"ShowWiFiMenu")) {
            _wifiItem = [[WiFiStatusItem alloc] init];
            _wifiItem.pluginDelegate = view;
            [plugins insertObject:_wifiItem atIndex:0];
        } else {
            _wifiItem = nil;
        }

        if (ReadMenuBarPref(@"ShowVolumeMenu")) {
            _volumeItem = [[VolumeStatusItem alloc] init];
            _volumeItem.pluginDelegate = view;
            [plugins insertObject:_volumeItem atIndex:0];
        } else {
            _volumeItem = nil;
        }

        view.statusPlugins = plugins;
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Menu-bar preference change notification

- (void)_observeMenuBarPrefs
{
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_menuBarPrefsChanged:)
               name:@"AmbrosiaMenuBarPrefsChanged"
             object:nil
  suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
}

- (void)_menuBarPrefsChanged:(NSNotification *)note
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _setupStatusPlugins];
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Panel creation

- (void)_createPanel
{
    _menuPanels = [NSMutableArray array];
    _menuBarViews = [NSMutableArray array];
    _panelByView = [NSMapTable weakToWeakObjectsMapTable];
    _baseFrameByPanel = [NSMapTable weakToStrongObjectsMapTable];

    NSArray *screensConfig = [NSDictionary dictionaryWithContentsOfFile:SystemPreferencesPath()][@"Screens"];
    NSMutableArray<NSValue *> *barRects = [NSMutableArray array];

    for (NSDictionary *entry in screensConfig) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *loc = entry[@"location"];
        NSDictionary *res = entry[@"resolution"];
        CGFloat sx = ReadNumericValue(loc[@"x"]);
        CGFloat sy = ReadNumericValue(loc[@"y"]);
        CGFloat rw = ReadNumericValue(res[@"width"]);
        CGFloat rh = ReadNumericValue(res[@"height"]);
        CGFloat scale = ReadNumericValue(entry[@"scale"]);
        if (scale <= 0.01) scale = 1.0;
        CGFloat logicalW = rw / scale;
        CGFloat barH = kBarHeight;
        if (logicalW < 32 || rh < 32) continue;
        NSRect barRect = NSMakeRect(sx, sy + rh - barH, logicalW, barH);
        [barRects addObject:[NSValue valueWithRect:barRect]];
    }

    if (barRects.count == 0) {
        NSScreen *screen = [NSScreen mainScreen];
        NSRect sf = screen ? screen.frame : NSZeroRect;
        if (sf.size.width  < 32) sf.size.width  = kFallbackWidth;
        if (sf.size.height < 32) sf.size.height = kFallbackScreenH;
        NSRect barRect = NSMakeRect(sf.origin.x,
                                    sf.origin.y + sf.size.height - kBarHeight,
                                    sf.size.width,
                                    kBarHeight);
        [barRects addObject:[NSValue valueWithRect:barRect]];
    }

    for (NSValue *rectValue in barRects) {
        NSRect barRect = [rectValue rectValue];
        NSPanel *panel = [[NSPanel alloc]
                          initWithContentRect:barRect
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
        panel.level           = NSMainMenuWindowLevel;
        panel.title           = @"AmbrosiaMenuServer";
        panel.opaque          = NO;
        panel.backgroundColor = [NSColor clearColor];
        panel.hasShadow       = NO;
        [panel setBecomesKeyOnlyIfNeeded:YES];

        MenuBarView *view = [[MenuBarView alloc]
                             initWithFrame:((NSView *)panel.contentView).bounds];
        view.controller        = self;
        view.autoresizingMask  = NSViewWidthSizable | NSViewHeightSizable;
        [panel.contentView addSubview:view];
        [panel makeKeyAndOrderFront:nil];

        [_menuPanels addObject:panel];
        [_menuBarViews addObject:view];
        [_panelByView setObject:panel forKey:view];
        [_baseFrameByPanel setObject:[NSValue valueWithRect:barRect] forKey:panel];
    }

    _menuPanel = _menuPanels.firstObject;
    _menuBarView = _menuBarViews.firstObject;
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
    for (MenuBarView *view in _menuBarViews) {
        [view setActiveAppName:_activeAppName menuItems:_activeMenuItems];
    }
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
    [self expandPanelForView:_menuBarView dropdownHeight:dropH];
}

- (void)contractPanelDropdown
{
    [self contractPanelForView:_menuBarView];
}

- (void)expandPanelForView:(MenuBarView *)view dropdownHeight:(CGFloat)dropH
{
    NSPanel *panel = [_panelByView objectForKey:view] ?: _menuPanel;
    if (!panel) return;
    NSRect f = panel.frame;
    f.origin.y    -= dropH;
    f.size.height += dropH;
    [panel setFrame:f display:YES animate:NO];
}

- (void)contractPanelForView:(MenuBarView *)view
{
    NSPanel *panel = [_panelByView objectForKey:view] ?: _menuPanel;
    if (!panel) return;
    NSValue *baseFrameValue = [_baseFrameByPanel objectForKey:panel];
    NSRect baseFrame = baseFrameValue ? [baseFrameValue rectValue] : panel.frame;
    [panel setFrame:baseFrame display:YES animate:NO];
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
    /* Prefer Terminal.app (GNUstep).  If it is already running, bring it to
     * focus via the compositor's activate notification instead of launching
     * a second instance.  Fall back to common X11 terminal emulators when
     * Terminal.app is not installed.                                        */
    NSArray<NSString *> *terminalAppCandidates = @[
        @"/usr/GNUstep/Local/Applications/Terminal.app",
        @"/usr/GNUstep/System/Applications/Terminal.app",
        @"/usr/local/GNUstep/Local/Applications/Terminal.app",
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Applications/Terminal.app"],
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *terminalPath = nil;
    for (NSString *path in terminalAppCandidates) {
        if ([fm fileExistsAtPath:path]) {
            terminalPath = path;
            break;
        }
    }

    if (terminalPath) {
        /* Check whether Terminal.app is already in the running-applications list. */
        BOOL alreadyRunning = NO;
        for (NSDictionary *info in [[NSWorkspace sharedWorkspace] launchedApplications]) {
            NSString *appPath = info[@"NSApplicationPath"];
            NSString *appName = info[@"NSApplicationName"];
            if ([appPath isEqualToString:terminalPath] ||
                [appName isEqualToString:@"Terminal"]) {
                alreadyRunning = YES;
                break;
            }
        }

        if (alreadyRunning) {
            /* Terminal is running — ask the compositor to raise it. */
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"AmbrosiaActivateApplication"
                              object:nil
                            userInfo:@{
                                @"appName":    @"Terminal",
                                @"launchPath": terminalPath,
                            }
                  deliverImmediately:YES];
        } else {
            [[NSWorkspace sharedWorkspace] launchApplication:terminalPath];
        }
        return;
    }

    /* Terminal.app not found — fall back to generic X11 terminal emulators. */
    NSArray<NSString *> *fallbacks = @[
        @"/usr/bin/xterm",
        @"/usr/bin/x-terminal-emulator",
        @"/usr/bin/gnome-terminal",
        @"/usr/bin/konsole",
        @"/usr/bin/xfce4-terminal",
        @"/usr/bin/lxterminal",
        @"/usr/bin/mate-terminal",
    ];
    for (NSString *path in fallbacks) {
        if ([fm fileExistsAtPath:path]) {
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
