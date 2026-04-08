#import "DockController.h"
#import "DockView.h"
#import "DockItem.h"

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

    _dockPanel = [[NSPanel alloc]
                  initWithContentRect:panelRect
                            styleMask:NSWindowStyleMaskBorderless |
                                      NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    _dockPanel.level                = NSStatusWindowLevel;
    _dockPanel.opaque               = NO;
    _dockPanel.backgroundColor      = [NSColor clearColor];
    _dockPanel.hasShadow             = NO;
    _dockPanel.collectionBehavior   = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                      NSWindowCollectionBehaviorStationary;

    _dockView = [[DockView alloc] initWithFrame:((NSView *)_dockPanel.contentView).bounds];
    _dockView.controller     = self;
    _dockView.baseIconSize   = _iconSize;
    _dockView.maxZoomFactor  = _zoomFactor;
    _dockView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [_dockPanel.contentView addSubview:_dockView];
    [_dockPanel makeKeyAndOrderFront:nil];
    (void)screenFrame;
}

- (NSRect)dockRectForScreen:(NSScreen *)screen
{
    NSRect sf    = screen.frame;
    CGFloat h    = _iconSize + 32; /* icon + padding + running dot */
    CGFloat w    = sf.size.width * 0.6;
    CGFloat x    = sf.origin.x + (sf.size.width - w) * 0.5;

    if ([_dockPosition isEqualToString:@"left"]) {
        return NSMakeRect(sf.origin.x, sf.origin.y,
                          _iconSize + 32, sf.size.height);
    }
    if ([_dockPosition isEqualToString:@"right"]) {
        return NSMakeRect(NSMaxX(sf) - (_iconSize + 32), sf.origin.y,
                          _iconSize + 32, sf.size.height);
    }
    /* default: bottom */
    return NSMakeRect(x, sf.origin.y, w, h);
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
    /* Scan /Applications for .app bundles */
    NSArray<NSString *> *appDirs = @[@"/Applications",
                                     [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
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
    /* GNUstep workspace notifications carry plain-string keys in userInfo:
     *   NSApplicationName            → NSString (localised app name)
     *   NSApplicationPath            → NSString (path to .app bundle)
     *   NSApplicationBundleIdentifier → NSString (bundle ID, may be absent)
     *   NSApplicationProcessIdentifier → NSNumber (PID)
     *
     * NSRunningApplication / NSWorkspaceApplicationKey are macOS-only.
     */
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
 * Parse a GNUstep workspace notification userInfo dictionary and update
 * the dock item running-state accordingly.
 */
- (void)syncRunningAppFromUserInfo:(NSDictionary *)info launched:(BOOL)launched
{
    if (!info) return;

    NSString *bundleID = info[@"NSApplicationBundleIdentifier"];
    NSString *appPath  = info[@"NSApplicationPath"];
    NSString *appName  = info[@"NSApplicationName"];

    /* Try to match an existing dock item by bundle ID or launch path */
    DockItem *matched = nil;
    for (DockItem *item in _items) {
        if (bundleID.length && [item.bundleIdentifier isEqualToString:bundleID]) {
            matched = item; break;
        }
        if (appPath.length && [item.launchPath isEqualToString:appPath]) {
            matched = item; break;
        }
    }

    if (matched) {
        matched.isRunning = launched;
        if (!launched) matched.runningApp = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_dockView setNeedsDisplay:YES];
        });
        return;
    }

    /* App not in dock and just launched – add a transient entry */
    if (launched && appPath.length) {
        DockItem *item = [[DockItem alloc] init];
        item.label            = appName ?: [[[appPath lastPathComponent]
                                             stringByDeletingPathExtension] copy];
        item.bundleIdentifier = bundleID;
        item.launchPath       = appPath;
        item.isRunning        = YES;
        item.keepInDock       = NO;
        [item reloadIcon];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_items addObject:item];
            [self->_dockView reloadItems];
        });
    }

    /* Remove transient items when their app quits */
    if (!launched) {
        for (DockItem *item in [_items copy]) {
            BOOL matchID   = bundleID.length && [item.bundleIdentifier isEqualToString:bundleID];
            BOOL matchPath = appPath.length  && [item.launchPath isEqualToString:appPath];
            if (!item.keepInDock && (matchID || matchPath)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_items removeObject:item];
                    [self->_dockView reloadItems];
                });
            }
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
    [_dockView reloadItems];
    [self savePreferences];
}

- (void)removeItem:(DockItem *)item
{
    [_items removeObject:item];
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
    if (!screen) return;
    NSRect rect = [self dockRectForScreen:screen];
    [_dockPanel setFrame:rect display:YES animate:NO];
    _dockView.baseIconSize  = _iconSize;
    _dockView.maxZoomFactor = _zoomFactor;
    [_dockView setNeedsDisplay:YES];
}

@end
