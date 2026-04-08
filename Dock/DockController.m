#import "DockController.h"
#import "DockView.h"
#import "DockItem.h"

#include <dirent.h>
#include <stdio.h>
#include <string.h>

static NSString *const kPrefsIconSize    = @"iconSize";
static NSString *const kPrefsZoomFactor  = @"zoomFactor";
static NSString *const kPrefsPosition    = @"dockPosition";
static NSString *const kPrefsAutoHide    = @"autoHide";
static NSString *const kPrefsShowDots    = @"showRunningDots";
static NSString *const kPrefsItems       = @"items";

@implementation DockController {
    NSMutableArray<DockItem *> *_items;
    NSMutableArray<NSRunningApplication *> *_runningApps;
    id _workspaceObserver;
    BOOL _autoHide;
    BOOL _showRunningDots;
}

@synthesize dockPanel    = _dockPanel;
@synthesize dockView     = _dockView;
@synthesize preferencesPath = _preferencesPath;
@synthesize iconSize     = _iconSize;
@synthesize zoomFactor   = _zoomFactor;
@synthesize dockPosition = _dockPosition;

- (NSMutableArray<DockItem *> *)items { return _items; }

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    _items         = [NSMutableArray array];
    _iconSize      = 48.0;
    _zoomFactor    = 1.7;
    _dockPosition  = @"bottom";
    _autoHide      = NO;
    _showRunningDots = YES;

    /* Determine prefs path */
    NSArray *domainDirs = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libDir = domainDirs.firstObject ?: NSHomeDirectory();
    _preferencesPath = [libDir stringByAppendingPathComponent:
                        @"Preferences/org.gnustep.AmbrosiaDock.plist"];

    return self;
}

- (void)dealloc
{
    if (_workspaceObserver) {
        [[NSWorkspace sharedWorkspace].notificationCenter
         removeObserver:_workspaceObserver];
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self loadPreferences];
    [self createDockPanel];
    [self repositionDock];
    [self observeRunningApps];
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    [self savePreferences];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Panel creation

- (void)createDockPanel
{
    NSRect screenFrame = [NSScreen mainScreen].frame;
    NSRect panelRect   = [self dockRectForScreen:[NSScreen mainScreen]];

    /* NSWindowStyleMaskNonactivatingPanel and NSWindowCollectionBehavior
     * are not supported by GNUstep — use a plain borderless panel. */
    _dockPanel = [[NSPanel alloc]
                  initWithContentRect:panelRect
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:NO];
    _dockPanel.level           = NSStatusWindowLevel;
    _dockPanel.opaque          = NO;
    _dockPanel.backgroundColor = [NSColor clearColor];
    _dockPanel.hasShadow       = NO;

    _dockView = [[DockView alloc] initWithFrame:((NSView *)_dockPanel.contentView).bounds];
    _dockView.controller     = self;
    _dockView.baseIconSize   = _iconSize;
    _dockView.maxZoomFactor  = _zoomFactor;
    _dockView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [_dockPanel.contentView addSubview:_dockView];
    [_dockPanel makeKeyAndOrderFront:nil];
    (void)screenFrame;
}

/**
 * Return the frame for the dock panel given the current item list and
 * the screen geometry.  For "bottom" (default) the dock is sized to fit
 * its items and centred horizontally at the very bottom of the screen.
 */
- (NSRect)dockRectForScreen:(NSScreen *)screen
{
    NSRect sf = screen ? screen.frame : NSZeroRect;

    /* gnustep-back on Wayland may report zero dimensions before the
     * display handshake completes — fall back to a sensible default. */
    if (sf.size.width  < 32) sf.size.width  = 1920;
    if (sf.size.height < 32) sf.size.height = 1080;

    /* Panel height must accommodate icons at maximum zoom factor plus the
     * hover label drawn above the zoomed icon (~11 pt font + 4 pt padding
     * + 4 pt gap = ~20 pt).  Background is painted only over the base-
     * height strip; transparent space above lets icons and labels overflow. */
    CGFloat h = _iconSize * _zoomFactor + 44.0;

    if ([_dockPosition isEqualToString:@"left"]) {
        return NSMakeRect(sf.origin.x, sf.origin.y,
                          _iconSize * _zoomFactor + 44.0, sf.size.height);
    }
    if ([_dockPosition isEqualToString:@"right"]) {
        CGFloat panelW = _iconSize * _zoomFactor + 44.0;
        return NSMakeRect(NSMaxX(sf) - panelW, sf.origin.y,
                          panelW, sf.size.height);
    }

    /* Bottom-centre: width fits the current items with some padding */
    NSUInteger count = _items.count;
    CGFloat itemSlot = _iconSize + 8.0;           /* icon + inter-item gap */
    CGFloat w = MAX(120.0, count * itemSlot + 20.0); /* 10 px side padding × 2 */
    w = MIN(w, sf.size.width - 40.0);             /* never wider than screen */

    /* Centre horizontally; sit flush at the bottom edge */
    CGFloat x = sf.origin.x + floor((sf.size.width - w) * 0.5);
    CGFloat y = sf.origin.y;                       /* y=0 = bottom in GNUstep */

    return NSMakeRect(x, y, w, h);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Preferences

- (void)loadPreferences
{
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:_preferencesPath];
    if (!prefs) {
        [self loadDefaultItems];
        return;
    }

    _iconSize    = [prefs[kPrefsIconSize]   doubleValue] ?: 48.0;
    _zoomFactor  = [prefs[kPrefsZoomFactor] doubleValue] ?: 1.7;
    _dockPosition = prefs[kPrefsPosition] ?: @"bottom";
    _autoHide    = [prefs[kPrefsAutoHide]   boolValue];
    _showRunningDots = prefs[kPrefsShowDots] ? [prefs[kPrefsShowDots] boolValue] : YES;

    NSArray *rawItems = prefs[kPrefsItems];
    if (rawItems) {
        for (NSDictionary *d in rawItems) {
            DockItem *item = [[DockItem alloc] init];
            item.label            = d[@"label"];
            item.bundleIdentifier = d[@"bundleIdentifier"];
            item.launchPath       = d[@"launchPath"];
            item.keepInDock       = [d[@"keepInDock"] boolValue];
            [item reloadIcon];
            [_items addObject:item];
        }
    } else {
        [self loadDefaultItems];
    }
}

- (void)loadDefaultItems
{
    /* Scan standard GNUstep and FHS application directories */
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
            DockItem *item = [[DockItem alloc] init];
            item.label      = [[name stringByDeletingPathExtension] copy];
            item.launchPath = path;
            item.keepInDock = YES;
            [item reloadIcon];
            [_items addObject:item];
            if (_items.count >= 10) break;
        }
        if (_items.count >= 10) break;
    }
}

- (void)savePreferences
{
    NSMutableArray *rawItems = [NSMutableArray array];
    for (DockItem *item in _items) {
        if (!item.keepInDock) continue;
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
    /* Seed running state from /proc — avoids connecting to GWorkspace
     * (which would launch it if it is not already running).            */
    [self seedRunningAppsFromProc];

    /* GNUstep workspace notifications for future launch/quit events.
     * These arrive via the DO notification centre without needing
     * GWorkspace to be the workspace manager.                          */
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

/**
 * Scan /proc/any/cmdline for processes whose argv[0] ends with a known
 * GNUstep app binary pattern (inside an .app bundle).  For each one
 * found, synthesise an info dict and call -syncRunningAppFromUserInfo:.
 *
 * This is Linux-specific but lets us detect already-running apps
 * without requiring GWorkspace to be active.
 */
- (void)seedRunningAppsFromProc
{
    NSFileManager *fm = [NSFileManager defaultManager];
    DIR *proc = opendir("/proc");
    if (!proc) return;

    struct dirent *entry;
    while ((entry = readdir(proc)) != NULL) {
        /* Only numeric directories (PIDs) */
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

        /* argv[0] is the first null-terminated string */
        NSString *argv0 = [NSString stringWithUTF8String:buf];
        if (!argv0.length) continue;

        /* Must be inside a .app bundle */
        NSRange appRange = [argv0 rangeOfString:@".app/"
                                        options:NSBackwardsSearch];
        if (appRange.location == NSNotFound) continue;

        /* Derive the .app bundle path */
        NSString *bundlePath =
            [argv0 substringToIndex:appRange.location + appRange.length - 1];

        /* Verify the bundle exists */
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:bundlePath isDirectory:&isDir] || !isDir)
            continue;

        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        NSString *appName = [bundle objectForInfoDictionaryKey:@"CFBundleName"]
                         ?: [bundle objectForInfoDictionaryKey:@"NSExecutable"]
                         ?: [[bundlePath lastPathComponent]
                             stringByDeletingPathExtension];
        NSString *bundleID = [bundle objectForInfoDictionaryKey:@"CFBundleIdentifier"];

        NSDictionary *info = @{
            @"NSApplicationPath":                bundlePath,
            @"NSApplicationName":                appName ?: @"",
            @"NSApplicationBundleIdentifier":    bundleID ?: @"",
            @"NSApplicationProcessIdentifier":
                [NSNumber numberWithInt:atoi(entry->d_name)],
        };

        [self syncRunningAppFromUserInfo:info launched:YES];
    }
    closedir(proc);
}

/**
 * Update dock running-state from a GNUstep workspace info dictionary.
 *
 * GNUstep keys (all are NSString unless noted):
 *   NSApplicationName                  — localised display name
 *   NSApplicationPath                  — absolute path to .app bundle
 *   NSApplicationProcessIdentifier     — NSNumber (PID)
 *   NSApplicationBundleIdentifier      — bundle ID (present in newer GNUstep; absent in older)
 */
- (void)syncRunningAppFromUserInfo:(NSDictionary *)info launched:(BOOL)launched
{
    if (!info) return;

    NSString *appPath  = info[@"NSApplicationPath"];
    NSString *appName  = info[@"NSApplicationName"];
    NSString *bundleID = info[@"NSApplicationBundleIdentifier"];

    /* Derive bundle ID from the bundle if the notification didn't supply it */
    if (!bundleID.length && appPath.length) {
        NSBundle *b = [NSBundle bundleWithPath:appPath];
        bundleID = [b objectForInfoDictionaryKey:@"CFBundleIdentifier"];
    }

    /* Match priority: bundle ID > path > display name */
    DockItem *matched = nil;
    for (DockItem *item in _items) {
        if (bundleID.length && [item.bundleIdentifier isEqualToString:bundleID]) {
            matched = item; break;
        }
        if (appPath.length && [item.launchPath isEqualToString:appPath]) {
            matched = item; break;
        }
        if (appName.length && [item.label isEqualToString:appName]) {
            matched = item; break;
        }
    }

    if (matched) {
        matched.isRunning = launched;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_dockView setNeedsDisplay:YES];
        });
        return;
    }

    /* Running app not pinned to dock — show as transient entry */
    if (launched) {
        /* Skip apps without a visible path (e.g. background agents) */
        NSString *label = appName;
        if (!label.length && appPath.length)
            label = [[[appPath lastPathComponent] stringByDeletingPathExtension] copy];
        if (!label.length) return;

        DockItem *item    = [[DockItem alloc] init];
        item.label        = label;
        item.launchPath   = appPath;
        item.bundleIdentifier = bundleID;
        item.isRunning    = YES;
        item.keepInDock   = NO;
        [item reloadIcon];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_items addObject:item];
            [self repositionDock];
            [self->_dockView reloadItems];
        });
        return;
    }

    /* App quit — remove any transient entry for it */
    for (DockItem *item in [_items copy]) {
        if (item.keepInDock) continue;
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

- (void)launchItem:(DockItem *)item
{
    if (!item.launchPath) return;
    /* NSRunningApplication / activateWithOptions: are macOS-only.
     * On GNUstep, re-launching brings the app to front if it's already running. */
    [[NSWorkspace sharedWorkspace] launchApplication:item.launchPath];
}

- (void)moveItemFromIndex:(NSInteger)from toIndex:(NSInteger)to
{
    if (from == to) return;
    if (from < 0 || from >= (NSInteger)_items.count) return;
    if (to   < 0 || to   >= (NSInteger)_items.count) return;

    DockItem *item = _items[from];
    [_items removeObjectAtIndex:from];
    NSInteger insertAt = (from < to) ? to : to;
    insertAt = MAX(0, MIN(insertAt, (NSInteger)_items.count));
    [_items insertObject:item atIndex:(NSUInteger)insertAt];
    [self savePreferences];
}

- (void)addAppAtPath:(NSString *)path
{
    /* Check duplicate */
    for (DockItem *item in _items) {
        if ([item.launchPath isEqualToString:path]) return;
    }
    DockItem *item = [[DockItem alloc] init];
    item.launchPath = path;
    item.label = [[[path lastPathComponent] stringByDeletingPathExtension] copy];
    item.keepInDock = YES;
    [item reloadIcon];

    NSBundle *bundle = [NSBundle bundleWithPath:path];
    item.bundleIdentifier = [bundle objectForInfoDictionaryKey:@"CFBundleIdentifier"];

    [_items addObject:item];
    [self repositionDock];
    [_dockView reloadItems];
    [self savePreferences];
}

- (void)removeItem:(DockItem *)item
{
    [_items removeObject:item];
    [self repositionDock];
    [_dockView reloadItems];
    [self savePreferences];
}

- (NSMenu *)contextMenuForItem:(DockItem *)item
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:item.label ?: @""];

    if (item.isRunning) {
        NSMenuItem *activateItem =
            [[NSMenuItem alloc] initWithTitle:@"Activate"
                                       action:@selector(activateApp:)
                                keyEquivalent:@""];
        activateItem.representedObject = item;
        activateItem.target = self;
        [menu addItem:activateItem];

        NSMenuItem *quitItem =
            [[NSMenuItem alloc] initWithTitle:@"Quit"
                                       action:@selector(quitApp:)
                                keyEquivalent:@""];
        quitItem.representedObject = item;
        quitItem.target = self;
        [menu addItem:quitItem];

        [menu addItem:[NSMenuItem separatorItem]];
    } else {
        NSMenuItem *openItem =
            [[NSMenuItem alloc] initWithTitle:@"Open"
                                       action:@selector(openApp:)
                                keyEquivalent:@""];
        openItem.representedObject = item;
        openItem.target = self;
        [menu addItem:openItem];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    /* Keep in dock toggle */
    NSString *keepTitle = item.keepInDock ? @"Remove from Dock" : @"Keep in Dock";
    NSMenuItem *keepItem =
        [[NSMenuItem alloc] initWithTitle:keepTitle
                                   action:@selector(toggleKeepInDock:)
                            keyEquivalent:@""];
    keepItem.representedObject = item;
    keepItem.target = self;
    [menu addItem:keepItem];

    /* Preferences */
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
    DockItem *item = sender.representedObject;
    /* GNUstep: re-launching brings the running app to front */
    if (item.launchPath)
        [[NSWorkspace sharedWorkspace] launchApplication:item.launchPath];
}

- (void)quitApp:(NSMenuItem *)sender
{
    DockItem *item = sender.representedObject;
    /* Send SIGTERM to the app's process via NSTask if we know its PID,
     * otherwise fall back to NSRunningApplication if available. */
    if (item.runningApp) {
        [item.runningApp terminate];
    }
}

- (void)openApp:(NSMenuItem *)sender
{
    DockItem *item = sender.representedObject;
    [self launchItem:item];
}

- (void)toggleKeepInDock:(NSMenuItem *)sender
{
    DockItem *item = sender.representedObject;
    item.keepInDock = !item.keepInDock;
    if (!item.keepInDock && !item.isRunning) {
        [self removeItem:item];
    } else {
        [self savePreferences];
    }
}

- (void)openDockPrefs:(id)sender
{
    /* Launch SystemPreferences pointing to our pane */
    NSString *prefsApp = @"/Applications/SystemPreferences.app";
    [[NSWorkspace sharedWorkspace] openFile:prefsApp];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Repositioning

- (void)repositionDock
{
    NSScreen *screen = [NSScreen mainScreen];
    NSRect rect = [self dockRectForScreen:screen]; /* handles nil screen */
    [_dockPanel setFrame:rect display:YES animate:NO];
    _dockView.baseIconSize  = _iconSize;
    _dockView.maxZoomFactor = _zoomFactor;
    [_dockView setFrame:((NSView *)_dockPanel.contentView).bounds];
    [_dockView setNeedsDisplay:YES];
}

@end
