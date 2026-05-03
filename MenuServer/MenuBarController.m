#import "MenuBarController.h"
#import "MenuBarView.h"

#include <signal.h>
#include <errno.h>
#include <ctype.h>

/**
 * Capitalise the first letter of every word in an app name, where words are
 * delimited by hyphens, underscores, or spaces.
 *
 * Examples:
 *   "mate-terminal"  →  "Mate-Terminal"
 *   "google_chrome"  →  "Google_Chrome"
 *   "quake3"         →  "Quake3"
 *   "firefox"        →  "Firefox"
 */
static NSString *CapitaliseAppName(NSString *name)
{
    if (!name.length) return name;
    NSMutableString *out = [NSMutableString stringWithCapacity:name.length];
    BOOL nextUp = YES;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c == '-' || c == '_' || c == ' ') {
            [out appendFormat:@"%C", c];
            nextUp = YES;
        } else if (nextUp) {
            [out appendFormat:@"%C", (unichar)toupper((int)c)];
            nextUp = NO;
        } else {
            [out appendFormat:@"%C", c];
        }
    }
    return [out copy];
}

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

/* Shared plist path for monitor configuration written by SystemPreferences. */
static NSString *SystemPreferencesPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Defaults/SystemPreferences.plist"];
}

static NSDictionary *PrimaryMonitorFromSystemPreferences(void)
{
    NSDictionary *prefs =
        [NSDictionary dictionaryWithContentsOfFile:SystemPreferencesPath()];
    if (![prefs isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *keyCandidates = @[@"Monitors", @"monitors", @"Monitor", @"monitor"];
    NSArray *monitors = nil;
    for (NSString *key in keyCandidates) {
        id value = prefs[key];
        if ([value isKindOfClass:[NSArray class]]) {
            monitors = (NSArray *)value;
            break;
        }
    }
    if (!monitors.count) return nil;

    for (id entry in monitors) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *monitor = (NSDictionary *)entry;
        BOOL isPrimary =
            [monitor[@"primary"] boolValue]  ||
            [monitor[@"Primary"] boolValue]  ||
            [monitor[@"isPrimary"] boolValue]||
            [monitor[@"IsPrimary"] boolValue];
        if (isPrimary) return monitor;
    }
    return nil;
}

static NSRect MenuBarRectForStartupScreen(void)
{
    NSScreen *screen = [NSScreen mainScreen];
    NSRect sf = screen ? screen.frame : NSZeroRect;

    NSDictionary *primaryMonitor = PrimaryMonitorFromSystemPreferences();
    if (primaryMonitor) {
        double width =
            [primaryMonitor[@"width"] doubleValue] ?: [primaryMonitor[@"Width"] doubleValue];
        double scale =
            [primaryMonitor[@"scale"] doubleValue] ?: [primaryMonitor[@"Scale"] doubleValue];

        if (width > 0.0) {
            sf.size.width = (scale > 0.0) ? (CGFloat)(width / scale) : (CGFloat)width;
        }
    }

    if (sf.size.width  < 32) sf.size.width  = kFallbackWidth;
    if (sf.size.height < 32) sf.size.height = kFallbackScreenH;

    return NSMakeRect(sf.origin.x,
                      sf.origin.y + sf.size.height - kBarHeight,
                      sf.size.width,
                      kBarHeight);
}

/* ---------------------------------------------------------------------- */

/* Identifier used as kMenuItemIdentifier for the synthetic Quit item shown
 * when a non-GNUstep (X11 / foreign Wayland) application is in focus.
 * MenuBarController intercepts this in -performMenuItemWithIdentifier:.    */
static NSString * const kForeignQuitIdentifier = @"__ambrosia_quit_foreign__";
static NSString * const kForeignWindowIdentifierPrefix = @"__ambrosia_foreign_window__:";

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
    WiFiStatusItem       *_wifiItem;
    VolumeStatusItem     *_volumeItem;
    /* Tray icon manager (SNI / StatusNotifierItem) */
    TrayManager          *_trayManager;

    /* Non-GNUstep (foreign) application focus tracking.
     * Set when the compositor reports focus on a PID that has no DO
     * registration; cleared as soon as a GNUstep app registers.           */
    int32_t               _activeForeignPID;
    NSString             *_activeForeignName;
    /* Monotonically-increasing token used to cancel pending delayed
     * foreign-app activations if a GNUstep app registers first.           */
    NSInteger             _foreignToken;
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
    [self _observeCompositorFocus];
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
    _menuBarView.trayItems = manager.trayItems;
}

- (TrayManager *)trayManager { return _trayManager; }

/* ---------------------------------------------------------------------- */
#pragma mark - Status item plugins

- (void)_setupStatusPlugins
{
    /* Always show Bluetooth. Wi-Fi and Volume are opt-in via SystemPreferences
     * checkboxes; they write ShowWiFiMenu / ShowVolumeMenu to the plist below. */
    _bluetoothItem = [[BluetoothStatusItem alloc] init];
    _bluetoothItem.pluginDelegate = _menuBarView;

    NSMutableArray *plugins = [NSMutableArray arrayWithObject:_bluetoothItem];

    /* Plugins are drawn right-to-left: index 0 is rightmost (closest to clock).
     * Desired bar order (right→left): BT | Wi-Fi | Vol               */
    if (ReadMenuBarPref(@"ShowWiFiMenu")) {
        _wifiItem = [[WiFiStatusItem alloc] init];
        _wifiItem.pluginDelegate = _menuBarView;
        [plugins insertObject:_wifiItem atIndex:0];
    } else {
        _wifiItem = nil;
    }

    if (ReadMenuBarPref(@"ShowVolumeMenu")) {
        _volumeItem = [[VolumeStatusItem alloc] init];
        _volumeItem.pluginDelegate = _menuBarView;
        [plugins insertObject:_volumeItem atIndex:0];
    } else {
        _volumeItem = nil;
    }

    _menuBarView.statusPlugins = plugins;
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
    NSRect barRect = MenuBarRectForStartupScreen();

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
#pragma mark - Compositor focus observation (non-GNUstep apps)

- (void)_observeCompositorFocus
{
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_compositorFocusChanged:)
               name:kAmbrosiaApplicationActivatedNotification
             object:nil
  suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
}

/**
 * Fired by the compositor whenever keyboard focus moves to a different process.
 *
 * If the newly focused PID belongs to a GNUstep app that is already DO-
 * registered we do nothing — the app will update the bar itself.  Otherwise
 * we schedule a short delay (100 ms) to let a GNUstep app potentially
 * register via DO.  If no registration arrives in that window, we show a
 * minimal menu with just the app name and a Quit item.
 */
- (void)_compositorFocusChanged:(NSNotification *)note
{
    NSDictionary *info   = note.userInfo;
    int32_t       pid    = (int32_t)[info[@"pid"] intValue];
    NSString     *name   = info[@"appName"];

    if (pid <= 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        /* Already the registered GNUstep app — it handles its own bar. */
        if (pid == self->_activeClientPID) return;

        /* Bump the token so any previous pending activation is cancelled. */
        NSInteger myToken = ++self->_foreignToken;

        /* Allow GNUstep apps time to call -applicationDidActivate:menuItems:pid:
         * via Distributed Objects before we commit to a foreign-app menu.     */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(100 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            /* Cancelled: a newer focus event has arrived. */
            if (self->_foreignToken != myToken) return;
            /* A GNUstep app registered in the meantime — leave it alone. */
            if (self->_activeClientPID == pid) return;

            [self _activateForeignAppWithPID:pid name:name windows:info[@"windows"]];
        });
    });
}

/** Resolve and display a synthetic menu for a non-GNUstep focused window. */
- (void)_activateForeignAppWithPID:(int32_t)pid name:(NSString *)name
{
    [self _activateForeignAppWithPID:pid name:name windows:nil];
}

- (void)_activateForeignAppWithPID:(int32_t)pid
                              name:(NSString *)name
                           windows:(NSArray<NSDictionary *> *)windows
{
    /* If no name arrived from the compositor, fall back to /proc/pid/comm */
    if (!name.length) {
        NSString *commPath =
            [NSString stringWithFormat:@"/proc/%d/comm", pid];
        NSString *comm = [NSString stringWithContentsOfFile:commPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        name = [comm stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (!name.length) name = @"Application";

    name = CapitaliseAppName(name);

    _activeForeignPID  = pid;
    _activeForeignName = [name copy];

    /* Synthetic menu: app menu + optional Windows submenu. */
    NSString *quitTitle = [NSString stringWithFormat:@"Quit %@", name];
    NSMutableArray *children = [NSMutableArray arrayWithObject:@{
        kMenuItemTitle:      quitTitle,
        kMenuItemIdentifier: kForeignQuitIdentifier,
        kMenuItemKeyEquiv:   @"q",
    }];
    if (windows.count > 0) {
        NSMutableArray *windowItems = [NSMutableArray array];
        for (NSDictionary *w in windows) {
            NSString *title = [w[@"title"] isKindOfClass:[NSString class]] ? w[@"title"] : @"Window";
            NSInteger idx = [w[@"index"] integerValue];
            [windowItems addObject:@{
                kMenuItemTitle: title,
                kMenuItemIdentifier: [NSString stringWithFormat:@"%@%d:%ld",
                                      kForeignWindowIdentifierPrefix, pid, (long)idx],
            }];
        }
        [children addObject:@{
            kMenuItemTitle: @"Windows",
            kMenuItemChildren: windowItems,
        }];
    }
    NSArray *syntheticItems = @[@{
        kMenuItemTitle:    name,
        kMenuItemChildren: children,
    }];

    [self _updateActiveApp:name menuItems:syntheticItems pid:0];
}

/** Send SIGTERM to the currently focused non-GNUstep application. */
- (void)_quitForeignApp
{
    if (_activeForeignPID <= 0) return;
    NSLog(@"MenuServer: sending SIGTERM to foreign app \"%@\" (pid %d)",
          _activeForeignName, _activeForeignPID);
    kill((pid_t)_activeForeignPID, SIGTERM);
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
        /* A GNUstep app is now the owner — clear any pending foreign state. */
        self->_activeForeignPID  = 0;
        self->_activeForeignName = nil;
        ++self->_foreignToken;   /* cancel any queued foreign activation */
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
    if (!identifier.length) return;

    /* Synthetic quit for a non-GNUstep (foreign) focused window. */
    if ([identifier isEqualToString:kForeignQuitIdentifier]) {
        [self _quitForeignApp];
        return;
    }
    if ([identifier hasPrefix:kForeignWindowIdentifierPrefix]) {
        NSString *rest = [identifier substringFromIndex:kForeignWindowIdentifierPrefix.length];
        NSArray<NSString *> *parts = [rest componentsSeparatedByString:@":"];
        if (parts.count == 2) {
            int32_t pid = (int32_t)[parts[0] intValue];
            NSInteger idx = [parts[1] integerValue];
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"AmbrosiaActivateWindow"
                              object:nil
                            userInfo:@{ @"pid": @(pid), @"index": @(idx) }
                  deliverImmediately:YES];
        }
        return;
    }

    if (_activeClientPID == 0) return;

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
    NSRect barRect = MenuBarRectForStartupScreen();
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
