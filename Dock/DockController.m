#import "DockController.h"
#import "DockView.h"
#import "DockItem.h"
#import "ForceQuitController.h"

#include <dirent.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static NSString *const kPrefsIconSize    = @"iconSize";
static NSString *const kPrefsZoomFactor  = @"zoomFactor";
static NSString *const kPrefsPosition    = @"dockPosition";
static NSString *const kPrefsAutoHide    = @"autoHide";
static NSString *const kPrefsShowDots    = @"showRunningDots";
static NSString *const kPrefsItems       = @"items";

/* Apps that must never appear in the dock as running-app entries or defaults.
 * These are Ambrosia infrastructure processes, not user-visible applications. */
static BOOL IsSystemInternalApp(NSString *name, NSString *path)
{
    static NSSet *blocklist;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocklist = [NSSet setWithObjects:
                     @"MenuServer", @"AmbrosiaDock",
                     @"AmbrosiaMenuServer", nil];
    });
    if (name.length && [blocklist containsObject:name]) return YES;
    if (path.length) {
        NSString *bn = [[path lastPathComponent] stringByDeletingPathExtension];
        if ([blocklist containsObject:bn]) return YES;
    }
    return NO;
}

/* Returns YES only when pid exists and is not a zombie. */
static BOOL IsLiveNonZombieProcess(pid_t pid)
{
    if (pid <= 0) return NO;
    if (kill(pid, 0) != 0) return NO;

    char statPath[64];
    snprintf(statPath, sizeof(statPath), "/proc/%d/stat", (int)pid);
    FILE *f = fopen(statPath, "r");
    if (!f) return YES; /* If /proc is unavailable, fall back to kill(0) result. */

    char buf[512];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return YES;
    buf[n] = '\0';

    /* /proc/<pid>/stat format: pid (comm) state ... ; parse state char */
    char *endComm = strrchr(buf, ')');
    if (!endComm || *(endComm + 1) == '\0') return YES;
    char state = *(endComm + 2); /* skip ") " */
    return state != 'Z';
}

/* ---------------------------------------------------------------------- */

@implementation DockController {
    NSMutableArray<DockItem *> *_items;
    NSMutableArray<NSRunningApplication *> *_runningApps;
    id _workspaceObserver;
    BOOL _autoHide;
    BOOL _showRunningDots;
    ForceQuitController *_forceQuitController;
    NSTimer *_runningAppsSweepTimer;
    CGFloat _primaryScreenWidth;
    CGFloat _primaryScreenHeight;
    CGFloat _configuredDockX;
    CGFloat _configuredDockY;
    BOOL    _hasConfiguredDockX;
    BOOL    _hasConfiguredDockY;
}

@synthesize dockPanel       = _dockPanel;
@synthesize dockView        = _dockView;
@synthesize preferencesPath = _preferencesPath;
@synthesize iconSize        = _iconSize;
@synthesize zoomFactor      = _zoomFactor;
@synthesize dockPosition    = _dockPosition;

- (NSMutableArray<DockItem *> *)items { return _items; }

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    _items           = [NSMutableArray array];
    _iconSize        = 48.0;
    _zoomFactor      = 1.7;
    _dockPosition    = @"bottom";
    _autoHide        = NO;
    _showRunningDots = YES;
    _primaryScreenWidth  = 0.0;
    _primaryScreenHeight = 0.0;
    _configuredDockX     = 0.0;
    _configuredDockY     = 0.0;
    _hasConfiguredDockX = NO;
    _hasConfiguredDockY = NO;

    NSArray *domainDirs = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libDir = domainDirs.firstObject ?: NSHomeDirectory();
    _preferencesPath = [libDir stringByAppendingPathComponent:
                        @"Preferences/org.gnustep.AmbrosiaDock.plist"];
    return self;
}

- (void)dealloc
{
    [_runningAppsSweepTimer invalidate];
    _runningAppsSweepTimer = nil;

    if (_workspaceObserver)
        [[NSWorkspace sharedWorkspace].notificationCenter
         removeObserver:_workspaceObserver];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSApplicationDelegate

/**
 * Override position and sizing with values passed by the Compositor at launch.
 * The Compositor reads org.gnustep.AmbrosiaDock.plist and forwards the relevant
 * keys as command-line arguments, making itself the authoritative source of
 * dock geometry.  Arguments take precedence over anything loaded from the
 * preferences file so the two sources cannot diverge.
 */
- (void)_applyCompositorArgs
{
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    for (NSUInteger i = 0; i + 1 < args.count; i++) {
        NSString *flag = args[i];
        NSString *val  = args[i + 1];
        if ([flag isEqualToString:@"-AmbrosiaPosition"]) {
            if (val.length) _dockPosition = [val copy];
        } else if ([flag isEqualToString:@"-AmbrosiaIconSize"]) {
            double v = [val doubleValue];
            if (v > 0) _iconSize = v;
        } else if ([flag isEqualToString:@"-AmbrosiaZoomFactor"]) {
            double v = [val doubleValue];
            if (v > 0) _zoomFactor = v;
        } else if ([flag isEqualToString:@"-AmbrosiaPrimaryWidth"]) {
            double v = [val doubleValue];
            if (v > 0) _primaryScreenWidth = v;
        } else if ([flag isEqualToString:@"-AmbrosiaPrimaryHeight"]) {
            double v = [val doubleValue];
            if (v > 0) _primaryScreenHeight = v;
        } else if ([flag isEqualToString:@"-AmbrosiaDockX"]) {
            _configuredDockX = [val doubleValue];
            _hasConfiguredDockX = YES;
        } else if ([flag isEqualToString:@"-AmbrosiaDockY"]) {
            _configuredDockY = [val doubleValue];
            _hasConfiguredDockY = YES;
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self loadPreferences];
    [self _applyCompositorArgs];   /* compositor-provided geometry wins */
    [self createDockPanel];
    [self repositionDock];
    [self observeRunningApps];
    [self observeForceQuitRequests];
    /* Persist initial state so the preferences file always exists on disk. */
    [self savePreferences];
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    [self savePreferences];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Panel creation

- (void)createDockPanel
{
    NSRect panelRect = [self dockRectForScreen:[NSScreen mainScreen]];

    _dockPanel = [[NSPanel alloc]
                  initWithContentRect:panelRect
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:NO];
    [_dockPanel setTitle:@"AmbrosiaDock"];
    _dockPanel.level           = NSStatusWindowLevel;
    _dockPanel.opaque          = NO;
    _dockPanel.backgroundColor = [NSColor clearColor];
    _dockPanel.hasShadow       = NO;

    _dockView = [[DockView alloc]
                 initWithFrame:((NSView *)_dockPanel.contentView).bounds];
    _dockView.controller      = self;
    _dockView.baseIconSize    = _iconSize;
    _dockView.maxZoomFactor   = _zoomFactor;
    _dockView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [_dockPanel.contentView addSubview:_dockView];
    [_dockPanel makeKeyAndOrderFront:nil];
}

- (NSRect)dockRectForScreen:(NSScreen *)screen
{
    NSRect sf = screen ? screen.frame : NSZeroRect;
    if (_primaryScreenWidth  > 32) sf.size.width  = _primaryScreenWidth;
    if (_primaryScreenHeight > 32) sf.size.height = _primaryScreenHeight;
    if (sf.size.width  < 32) sf.size.width  = 1920;
    if (sf.size.height < 32) sf.size.height = 1080;

    CGFloat h = _iconSize * _zoomFactor + 44.0;
    CGFloat panelW = _iconSize * _zoomFactor + 44.0;

    if ([_dockPosition isEqualToString:@"left"]) {
        NSUInteger count = MAX((NSUInteger)1, _items.count);
        CGFloat itemSlot = _iconSize + 8.0;
        CGFloat vh = MAX(160.0, count * itemSlot + 38.0);
        vh = MIN(vh, sf.size.height - 40.0);
        CGFloat anchorY = _hasConfiguredDockY
            ? _configuredDockY
            : (sf.origin.y + floor(sf.size.height * 0.5));
        CGFloat y = floor(anchorY - vh * 0.5);
        return NSMakeRect(sf.origin.x, y, panelW, vh);
    }
    if ([_dockPosition isEqualToString:@"right"]) {
        NSUInteger count = MAX((NSUInteger)1, _items.count);
        CGFloat itemSlot = _iconSize + 8.0;
        CGFloat vh = MAX(160.0, count * itemSlot + 38.0);
        vh = MIN(vh, sf.size.height - 40.0);
        CGFloat anchorY = _hasConfiguredDockY
            ? _configuredDockY
            : (sf.origin.y + floor(sf.size.height * 0.5));
        CGFloat y = floor(anchorY - vh * 0.5);
        CGFloat rightX = _hasConfiguredDockX ? _configuredDockX : NSMaxX(sf);
        return NSMakeRect(rightX - panelW, y, panelW, vh);
    }

    /* Bottom-centre: count only non-recycler items for regular slots;
     * add a fixed extra slot for the recycler + its separator gap.      */
    NSUInteger regularCount = 0;
    for (DockItem *item in _items) {
        if (item.itemType != DockItemTypeRecycler) regularCount++;
    }
    CGFloat itemSlot = _iconSize + 8.0;
    /* 24 pt extra = recycler icon + 16 pt separator gap */
    CGFloat w = MAX(120.0, regularCount * itemSlot + (_iconSize + 24.0) + 20.0);
    w = MIN(w, sf.size.width - 40.0);

    CGFloat anchorX = _hasConfiguredDockX
        ? _configuredDockX
        : (sf.origin.x + floor(sf.size.width * 0.5));
    CGFloat x = floor(anchorX - w * 0.5);
    return NSMakeRect(x, sf.origin.y, w, h);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Recycler helpers

/** Returns the index of the recycler item, or -1 if absent. */
- (NSInteger)recyclerIndex
{
    for (NSInteger i = (NSInteger)_items.count - 1; i >= 0; i--) {
        if (_items[(NSUInteger)i].itemType == DockItemTypeRecycler) return i;
    }
    return -1;
}

/** Ensure a recycler item is present as the last element. */
- (void)_ensureRecycler
{
    if (_items.lastObject.itemType != DockItemTypeRecycler) {
        DockItem *r  = [[DockItem alloc] init];
        r.itemType   = DockItemTypeRecycler;
        r.label      = @"Recycler";
        r.keepInDock = NO;
        [_items addObject:r];
    }
}

/** Insert an item before the recycler (or at the end if no recycler yet). */
- (void)_insertBeforeRecycler:(DockItem *)item
{
    NSInteger ri = [self recyclerIndex];
    if (ri >= 0)
        [_items insertObject:item atIndex:(NSUInteger)ri];
    else
        [_items addObject:item];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Preferences

/** Load the bundled DockPreferences.plist and return it, or an empty dict. */
- (NSDictionary *)_bundledDefaultPreferences
{
    NSString *path = [[NSBundle mainBundle] pathForResource:@"DockPreferences"
                                                     ofType:@"plist"];
    NSDictionary *d = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    return d ?: @{};
}

- (void)loadPreferences
{
    /* Read bundled defaults first, then overlay the user's saved prefs. */
    NSDictionary *defaults = [self _bundledDefaultPreferences];

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:_preferencesPath];
    if (!prefs) {
        /* Apply defaults from the bundled plist before loading default items. */
        _iconSize        = [defaults[kPrefsIconSize]   doubleValue] ?: 48.0;
        _zoomFactor      = [defaults[kPrefsZoomFactor] doubleValue] ?: 1.7;
        _dockPosition    = defaults[kPrefsPosition] ?: @"bottom";
        _autoHide        = [defaults[kPrefsAutoHide]   boolValue];
        _showRunningDots = defaults[kPrefsShowDots]
                           ? [defaults[kPrefsShowDots] boolValue] : YES;
        [self loadDefaultItems];
        return;
    }

    _iconSize        = [prefs[kPrefsIconSize]   doubleValue]
                       ?: ([defaults[kPrefsIconSize]   doubleValue] ?: 48.0);
    _zoomFactor      = [prefs[kPrefsZoomFactor] doubleValue]
                       ?: ([defaults[kPrefsZoomFactor] doubleValue] ?: 1.7);
    _dockPosition    = prefs[kPrefsPosition]  ?: defaults[kPrefsPosition]  ?: @"bottom";
    _autoHide        = [prefs[kPrefsAutoHide]   boolValue];
    _showRunningDots = prefs[kPrefsShowDots]
                       ? [prefs[kPrefsShowDots] boolValue]
                       : (defaults[kPrefsShowDots]
                          ? [defaults[kPrefsShowDots] boolValue] : YES);

    NSArray *rawItems = prefs[kPrefsItems];
    if (rawItems) {
        for (NSDictionary *d in rawItems) {
            NSString *path  = d[@"launchPath"];
            NSString *name  = d[@"label"];
            /* Skip infrastructure apps that may have been saved from
             * an older version before the blocklist existed.          */
            if (IsSystemInternalApp(name, path)) continue;

            DockItem *item        = [[DockItem alloc] init];
            item.label            = name;
            item.bundleIdentifier = d[@"bundleIdentifier"];
            item.launchPath       = path;
            item.keepInDock       = [d[@"keepInDock"] boolValue];
            /* Restore folder type if the path is a directory */
            BOOL isDir = NO;
            if (path.length &&
                [[NSFileManager defaultManager] fileExistsAtPath:path
                                                     isDirectory:&isDir]
                && isDir && ![path.pathExtension isEqualToString:@"app"]) {
                item.itemType = DockItemTypeFolder;
            }
            [item reloadIcon];
            [_items addObject:item];
        }
    } else {
        [self loadDefaultItems];
        return; /* loadDefaultItems already adds the recycler */
    }

    [self _ensureRecycler];
}

/**
 * Populate the dock from the bundled DefaultDock.plist resource.
 * Falls back to scanning standard application directories if the
 * resource is absent or lists no resolvable paths.
 */
- (void)loadDefaultItems
{
    NSString *plistPath =
        [[NSBundle mainBundle] pathForResource:@"DefaultDock" ofType:@"plist"];

    if (plistPath) {
        NSArray *entries = [NSArray arrayWithContentsOfFile:plistPath];
        for (NSDictionary *entry in entries) {
            NSString *label    = entry[@"label"];
            NSString *bundleID = entry[@"bundleIdentifier"];
            NSArray  *paths    = entry[@"paths"];

            /* Resolve the first candidate path that actually exists */
            NSString *resolved = nil;
            for (NSString *p in paths) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                    resolved = p;
                    break;
                }
            }
            if (!resolved) continue;
            if (IsSystemInternalApp(label, resolved)) continue;

            DockItem *item        = [[DockItem alloc] init];
            item.label            = label ?: [[resolved lastPathComponent]
                                               stringByDeletingPathExtension];
            item.bundleIdentifier = bundleID;
            item.launchPath       = resolved;
            item.keepInDock       = YES;
            [item reloadIcon];
            [_items addObject:item];
        }
    }

    /* If the plist produced at least one item we're done */
    if (_items.count > 0) {
        [self _ensureRecycler];
        return;
    }

    /* Fallback: scan standard application directories */
    NSArray<NSString *> *appDirs = @[
        @"/usr/GNUstep/Local/Applications",
        @"/usr/GNUstep/System/Applications",
        @"/usr/local/GNUstep/Local/Applications",
        @"/Applications",
        [NSHomeDirectory() stringByAppendingPathComponent:@"GNUstep/Applications"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *dir in appDirs) {
        NSArray *contents = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in contents) {
            if (![name hasSuffix:@".app"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSString *label = [name stringByDeletingPathExtension];
            if (IsSystemInternalApp(label, path)) continue;

            DockItem *item  = [[DockItem alloc] init];
            item.label      = [label copy];
            item.launchPath = path;
            item.keepInDock = YES;
            [item reloadIcon];
            [_items addObject:item];
            if (_items.count >= 10) break;
        }
        if (_items.count >= 10) break;
    }

    [self _ensureRecycler];
}

- (void)savePreferences
{
    NSMutableArray *rawItems = [NSMutableArray array];
    for (DockItem *item in _items) {
        /* Skip transient and special items */
        if (!item.keepInDock) continue;
        if (item.itemType == DockItemTypeRecycler) continue;
        [rawItems addObject:@{
            @"label":            item.label ?: @"",
            @"bundleIdentifier": item.bundleIdentifier ?: @"",
            @"launchPath":       item.launchPath ?: @"",
            @"keepInDock":       @(item.keepInDock),
        }];
    }

    NSDictionary *prefs = @{
        kPrefsIconSize:   @(_iconSize),
        kPrefsZoomFactor: @(_zoomFactor),
        kPrefsPosition:   _dockPosition ?: @"bottom",
        kPrefsAutoHide:   @(_autoHide),
        kPrefsShowDots:   @(_showRunningDots),
        kPrefsItems:      rawItems,
    };

    NSString *dir = [_preferencesPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [prefs writeToFile:_preferencesPath atomically:YES];
}

- (void)applyPreferences:(NSDictionary *)prefs
{
    if (prefs[kPrefsIconSize])   _iconSize    = [prefs[kPrefsIconSize]   doubleValue];
    if (prefs[kPrefsZoomFactor]) _zoomFactor  = [prefs[kPrefsZoomFactor] doubleValue];
    if (prefs[kPrefsPosition])   _dockPosition = prefs[kPrefsPosition];
    if (prefs[kPrefsAutoHide])   _autoHide    = [prefs[kPrefsAutoHide]   boolValue];
    if (prefs[kPrefsShowDots])   _showRunningDots = [prefs[kPrefsShowDots] boolValue];

    _dockView.baseIconSize  = _iconSize;
    _dockView.maxZoomFactor = _zoomFactor;
    [self repositionDock];
    [self savePreferences];
    [_dockView reloadItems];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Running app observation

- (void)observeRunningApps
{
    [self seedRunningAppsFromProc];

    /* Some force-quit paths can leave a dead app as a zombie until its parent
     * reaps it. NSWorkspace may not emit a terminate notification in that
     * state, so periodically reconcile dock running-state against /proc. */
    _runningAppsSweepTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(reconcileRunningApps)
                                       userInfo:nil
                                        repeats:YES];

    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    __weak typeof(self) weakSelf = self;

    [ws.notificationCenter addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                                       object:nil queue:nil
                                   usingBlock:^(NSNotification *n) {
        [weakSelf syncRunningAppFromUserInfo:n.userInfo launched:YES];
    }];

    [ws.notificationCenter addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                                       object:nil queue:nil
                                   usingBlock:^(NSNotification *n) {
        [weakSelf syncRunningAppFromUserInfo:n.userInfo launched:NO];
    }];
}

- (void)reconcileRunningApps
{
    /* Reap any children that have exited so they don't linger as zombies.
     * NSWorkspace launchApplication: uses fork/exec, making launched apps
     * direct children of this process.  Without reaping, killed apps remain
     * as zombie entries in the process table until the Dock itself exits. */
    while (waitpid(-1, NULL, WNOHANG) > 0)
        ;

    BOOL changed = NO;
    for (DockItem *item in [_items copy]) {
        if (!item.isRunning || item.pid <= 0) continue;
        if (IsLiveNonZombieProcess((pid_t)item.pid)) continue;

        if (item.keepInDock) {
            item.isRunning = NO;
            item.pid = 0;
        } else if (item.itemType != DockItemTypeRecycler) {
            [_items removeObject:item];
            changed = YES;
        }
        changed = YES;
    }

    if (changed) {
        [self repositionDock];
        [_dockView reloadItems];
    }
}

- (void)observeForceQuitRequests
{
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleForceQuitRequest:)
               name:@"AmbrosiaForceQuitRequest"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_handleSessionWillQuit:)
               name:@"AmbrosiaSessionWillQuit"
             object:nil];
}

- (void)_handleSessionWillQuit:(NSNotification *)note
{
    [self savePreferences];
    [NSApp terminate:nil];
}

- (void)_handleForceQuitRequest:(NSNotification *)note
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showForceQuitPanel];
    });
}

- (void)showForceQuitPanel
{
    NSMutableArray<DockItem *> *running = [NSMutableArray array];
    for (DockItem *item in _items) {
        if (item.isRunning && item.pid > 0)
            [running addObject:item];
    }
    if (!_forceQuitController)
        _forceQuitController = [[ForceQuitController alloc] init];
    [_forceQuitController updateWithItems:running];
    [_forceQuitController showPanel];
}

- (void)seedRunningAppsFromProc
{
    NSFileManager *fm = [NSFileManager defaultManager];
    DIR *proc = opendir("/proc");
    if (!proc) return;

    struct dirent *entry;
    while ((entry = readdir(proc)) != NULL) {
        if (entry->d_name[0] < '1' || entry->d_name[0] > '9') continue;

        char cmdline_path[64];
        snprintf(cmdline_path, sizeof(cmdline_path),
                 "/proc/%s/cmdline", entry->d_name);

        FILE *f = fopen(cmdline_path, "r");
        if (!f) continue;

        char buf[4096];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        if (n == 0) continue;
        buf[n] = '\0';

        NSString *argv0 = [NSString stringWithUTF8String:buf];
        if (!argv0.length) continue;

        NSRange appRange = [argv0 rangeOfString:@".app/"
                                        options:NSBackwardsSearch];
        if (appRange.location == NSNotFound) continue;

        NSString *bundlePath =
            [argv0 substringToIndex:appRange.location + appRange.length - 1];

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:bundlePath isDirectory:&isDir] || !isDir)
            continue;

        NSBundle *bundle   = [NSBundle bundleWithPath:bundlePath];
        NSString *appName  = [bundle objectForInfoDictionaryKey:@"CFBundleName"]
                          ?: [bundle objectForInfoDictionaryKey:@"NSExecutable"]
                          ?: [[bundlePath lastPathComponent] stringByDeletingPathExtension];
        NSString *bundleID = [bundle objectForInfoDictionaryKey:@"CFBundleIdentifier"];

        /* Skip Ambrosia infrastructure processes */
        if (IsSystemInternalApp(appName, bundlePath)) continue;

        NSDictionary *info = @{
            @"NSApplicationPath":             bundlePath,
            @"NSApplicationName":             appName ?: @"",
            @"NSApplicationBundleIdentifier": bundleID ?: @"",
            @"NSApplicationProcessIdentifier":
                [NSNumber numberWithInt:atoi(entry->d_name)],
        };
        [self syncRunningAppFromUserInfo:info launched:YES];
    }
    closedir(proc);
}

- (void)syncRunningAppFromUserInfo:(NSDictionary *)info launched:(BOOL)launched
{
    if (!info) return;

    NSString *appPath  = info[@"NSApplicationPath"];
    NSString *appName  = info[@"NSApplicationName"];
    NSString *bundleID = info[@"NSApplicationBundleIdentifier"];

    /* Never show Ambrosia infrastructure apps in the dock */
    if (IsSystemInternalApp(appName, appPath)) return;

    if (!bundleID.length && appPath.length) {
        NSBundle *b = [NSBundle bundleWithPath:appPath];
        bundleID = [b objectForInfoDictionaryKey:@"CFBundleIdentifier"];
    }

    /* Match against pinned items (skip the recycler) */
    DockItem *matched = nil;
    for (DockItem *item in _items) {
        if (item.itemType == DockItemTypeRecycler) continue;
        if (bundleID.length &&
            [item.bundleIdentifier isEqualToString:bundleID]) { matched = item; break; }
        if (appPath.length &&
            [item.launchPath isEqualToString:appPath])         { matched = item; break; }
        if (appName.length &&
            [item.label isEqualToString:appName])              { matched = item; break; }
    }

    NSInteger pid = [info[@"NSApplicationProcessIdentifier"] integerValue];

    if (matched) {
        matched.isRunning = launched;
        matched.pid       = launched ? pid : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_dockView setNeedsDisplay:YES];
        });
        return;
    }

    if (launched) {
        NSString *label = appName;
        if (!label.length && appPath.length)
            label = [[[appPath lastPathComponent] stringByDeletingPathExtension] copy];
        if (!label.length) return;

        DockItem *item        = [[DockItem alloc] init];
        item.label            = label;
        item.launchPath       = appPath;
        item.bundleIdentifier = bundleID;
        item.isRunning        = YES;
        item.pid              = pid;
        item.keepInDock       = NO;
        [item reloadIcon];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _insertBeforeRecycler:item];
            [self repositionDock];
            [self->_dockView reloadItems];
        });
        return;
    }

    /* App quit — remove transient entries for it */
    for (DockItem *item in [_items copy]) {
        if (item.keepInDock) continue;
        if (item.itemType == DockItemTypeRecycler) continue;
        BOOL byID   = bundleID.length && [item.bundleIdentifier isEqualToString:bundleID];
        BOOL byPath = appPath.length  && [item.launchPath isEqualToString:appPath];
        BOOL byName = appName.length  && [item.label isEqualToString:appName];
        if (byID || byPath || byName) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_items removeObject:item];
                [self repositionDock];
                [self->_dockView reloadItems];
            });
        }
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Actions

- (void)_openFolderInGFinder:(NSString *)path
{
    NSArray<NSString *> *candidates = @[
        @"/usr/GNUstep/Local/Applications/GFinder.app",
        @"/usr/GNUstep/System/Applications/GFinder.app",
        @"/usr/local/GNUstep/Local/Applications/GFinder.app",
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Applications/GFinder.app"],
    ];
    for (NSString *gfinderPath in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:gfinderPath]) {
            [[NSWorkspace sharedWorkspace] openFile:path withApplication:gfinderPath];
            return;
        }
    }
    /* GFinder not found; fall back to system default */
    [[NSWorkspace sharedWorkspace] openFile:path];
}

- (void)launchItem:(DockItem *)item
{
    if (!item.launchPath) return;
    if (item.itemType == DockItemTypeFolder) {
        [self _openFolderInGFinder:item.launchPath];
        return;
    }

    /* If the application is already running, raise its existing windows
     * instead of spawning a second instance. */
    if (item.isRunning) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (item.bundleIdentifier.length)
            info[@"bundleIdentifier"] = item.bundleIdentifier;
        if (item.launchPath.length)
            info[@"launchPath"] = item.launchPath;
        if (item.label.length)
            info[@"appName"] = item.label;
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:@"AmbrosiaActivateApplication"
                          object:nil
                        userInfo:info
              deliverImmediately:YES];
        return;
    }

    [[NSWorkspace sharedWorkspace] launchApplication:item.launchPath];
}

- (void)moveItemFromIndex:(NSInteger)from toIndex:(NSInteger)to
{
    if (from < 0 || from >= (NSInteger)_items.count) return;
    if (_items[(NSUInteger)from].itemType == DockItemTypeRecycler) return;

    /* Clamp target so items cannot be moved to or past the recycler */
    NSInteger recyclerIdx = [self recyclerIndex];
    NSInteger maxTo = (recyclerIdx >= 0) ? recyclerIdx - 1
                                         : (NSInteger)_items.count - 1;
    to = MAX(0, MIN(to, maxTo));
    if (from == to) return;

    DockItem *item = _items[(NSUInteger)from];
    [_items removeObjectAtIndex:(NSUInteger)from];
    NSInteger insertAt = MAX(0, MIN(to, (NSInteger)_items.count));
    [_items insertObject:item atIndex:(NSUInteger)insertAt];
    [self savePreferences];
}

- (void)addItemAtPath:(NSString *)path
{
    if (!path.length) return;

    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

    if ([path.pathExtension isEqualToString:@"app"]) {
        [self _addAppAtPath:path];
    } else if (isDir) {
        [self _addFolderAtPath:path];
    }
    /* Other file types are silently ignored */
}

- (void)_addAppAtPath:(NSString *)path
{
    NSString *label = [[path lastPathComponent] stringByDeletingPathExtension];
    if (IsSystemInternalApp(label, path)) return;

    for (DockItem *item in _items) {
        if ([item.launchPath isEqualToString:path]) return; /* already present */
    }

    DockItem *item        = [[DockItem alloc] init];
    item.launchPath       = path;
    item.label            = [label copy];
    item.keepInDock       = YES;
    item.itemType         = DockItemTypeApp;
    [item reloadIcon];

    NSBundle *bundle      = [NSBundle bundleWithPath:path];
    item.bundleIdentifier = [bundle objectForInfoDictionaryKey:@"CFBundleIdentifier"];

    [self _insertBeforeRecycler:item];
    [self repositionDock];
    [_dockView reloadItems];
    [self savePreferences];
}

- (void)_addFolderAtPath:(NSString *)path
{
    for (DockItem *item in _items) {
        if ([item.launchPath isEqualToString:path]) return; /* already present */
    }

    DockItem *item  = [[DockItem alloc] init];
    item.launchPath = path;
    item.label      = [[path lastPathComponent] copy];
    item.keepInDock = YES;
    item.itemType   = DockItemTypeFolder;
    [item reloadIcon];

    [self _insertBeforeRecycler:item];
    [self repositionDock];
    [_dockView reloadItems];
    [self savePreferences];
}

- (void)removeItem:(DockItem *)item
{
    if (!item || item.itemType == DockItemTypeRecycler) return;
    [_items removeObject:item];
    [self repositionDock];
    [_dockView reloadItems];
    [self savePreferences];
}

- (NSMenu *)contextMenuForItem:(DockItem *)item
{
    if (item.itemType == DockItemTypeRecycler) return nil;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:item.label ?: @""];

    if (item.isRunning) {
        NSMenuItem *activateItem =
            [[NSMenuItem alloc] initWithTitle:@"Activate"
                                       action:@selector(activateApp:)
                                keyEquivalent:@""];
        activateItem.representedObject = item;
        activateItem.target = self;
        [menu addItem:activateItem];

        NSMenuItem *closeItem =
            [[NSMenuItem alloc] initWithTitle:@"Close"
                                       action:@selector(closeApp:)
                                keyEquivalent:@""];
        closeItem.representedObject = item;
        closeItem.target = self;
        [menu addItem:closeItem];

        NSMenuItem *killItem =
            [[NSMenuItem alloc] initWithTitle:@"Kill"
                                       action:@selector(killApp:)
                                keyEquivalent:@""];
        killItem.representedObject = item;
        killItem.target = self;
        [menu addItem:killItem];
        [menu addItem:[NSMenuItem separatorItem]];
    } else {
        NSString *openTitle = (item.itemType == DockItemTypeFolder) ? @"Open" : @"Open";
        NSMenuItem *openItem =
            [[NSMenuItem alloc] initWithTitle:openTitle
                                       action:@selector(openApp:)
                                keyEquivalent:@""];
        openItem.representedObject = item;
        openItem.target = self;
        [menu addItem:openItem];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSString *keepTitle = item.keepInDock ? @"Remove from Dock" : @"Keep in Dock";
    NSMenuItem *keepItem =
        [[NSMenuItem alloc] initWithTitle:keepTitle
                                   action:@selector(toggleKeepInDock:)
                            keyEquivalent:@""];
    keepItem.representedObject = item;
    keepItem.target = self;
    [menu addItem:keepItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *prefsItem =
        [[NSMenuItem alloc] initWithTitle:@"Dock Preferences…"
                                   action:@selector(openDockPrefs:)
                            keyEquivalent:@""];
    prefsItem.target = self;
    [menu addItem:prefsItem];

    return menu;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Menu actions

- (void)activateApp:(NSMenuItem *)sender
{
    [self launchItem:sender.representedObject];
}

- (void)closeApp:(NSMenuItem *)sender
{
    DockItem *item = sender.representedObject;
    if (item.pid > 0) kill((pid_t)item.pid, SIGTERM);
}

- (void)killApp:(NSMenuItem *)sender
{
    DockItem *item = sender.representedObject;
    if (item.pid > 0) kill((pid_t)item.pid, SIGKILL);
}

- (void)openApp:(NSMenuItem *)sender
{
    [self launchItem:sender.representedObject];
}

- (void)toggleKeepInDock:(NSMenuItem *)sender
{
    DockItem *item = sender.representedObject;
    item.keepInDock = !item.keepInDock;
    if (!item.keepInDock && !item.isRunning)
        [self removeItem:item];
    else
        [self savePreferences];
}

- (void)openDockPrefs:(id)sender
{
    NSString *prefsApp = @"/Applications/SystemPreferences.app";
    [[NSWorkspace sharedWorkspace] openFile:prefsApp];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Repositioning

- (void)repositionDock
{
    NSScreen *screen = [NSScreen mainScreen];
    NSRect rect = [self dockRectForScreen:screen];
    [_dockPanel setFrame:rect display:YES animate:NO];
    _dockView.baseIconSize  = _iconSize;
    _dockView.maxZoomFactor = _zoomFactor;
    _dockView.verticalLayout = ![_dockPosition isEqualToString:@"bottom"];
    [_dockView setFrame:((NSView *)_dockPanel.contentView).bounds];
    [_dockView setNeedsDisplay:YES];
}

@end
