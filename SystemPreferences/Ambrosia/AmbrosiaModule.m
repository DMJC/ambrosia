#import "AmbrosiaModule.h"

/* Plist file names written by each component */
static NSString *const kCompPlistName = @"org.gnustep.AmbrosiaCompositor.plist";
static NSString *const kDockPlistName = @"org.gnustep.AmbrosiaDock.plist";

/* Notification names (posted to the dock over NSDistributedNotificationCenter) */
static NSString *const kDockPrefsChanged = @"AmbrosiaDocksPrefsChanged";
static NSString *const kCompPrefsChanged = @"AmbrosiaCompositorPrefsChanged";

@interface AmbrosiaModule () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *dockItems;
@end

@implementation AmbrosiaModule {
    NSString            *_compPrefsPath;
    NSString            *_dockPrefsPath;
    NSMutableDictionary *_compPrefs;
    NSMutableDictionary *_dockPrefs;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Helpers

static NSString *PrefsDirectory(void)
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *lib = dirs.firstObject ?: NSHomeDirectory();
    return [lib stringByAppendingPathComponent:@"Preferences"];
}

static NSMutableDictionary *LoadPlist(NSString *path)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static BOOL SavePlist(NSMutableDictionary *dict, NSString *path)
{
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [dict writeToFile:path atomically:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSPreferencePane lifecycle

- (instancetype)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        NSString *prefsDir = PrefsDirectory();
        _compPrefsPath = [prefsDir stringByAppendingPathComponent:kCompPlistName];
        _dockPrefsPath = [prefsDir stringByAppendingPathComponent:kDockPlistName];
        _compPrefs = LoadPlist(_compPrefsPath);
        _dockPrefs = LoadPlist(_dockPrefsPath);
    }
    return self;
}

- (void)mainViewDidLoad
{
    /* Wire up the table view — outlets are guaranteed non-nil here */
    _dockItems = [NSMutableArray array];
    _dockItemsTable.dataSource = self;
    _dockItemsTable.delegate   = self;

    /* Populate controls from on-disk prefs */
    [self loadCurrentValues];

    /* Update dependent labels */
    [self updateLabels];

    /* Mark as loaded so willSelect can skip a redundant reload */
    loaded = YES;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Load / save

- (void)loadCurrentValues
{
    /* Reload from disk so we always reflect the current on-disk state */
    _compPrefs = LoadPlist(_compPrefsPath);
    _dockPrefs = LoadPlist(_dockPrefsPath);

    /* ---- Compositor ---- */
    CGFloat transparency = [_compPrefs[@"windowTransparency"] doubleValue];
    if (transparency == 0) transparency = 0.96;
    _transparencySlider.doubleValue = transparency;

    BOOL decorations = _compPrefs[@"serverSideDecorations"]
        ? [_compPrefs[@"serverSideDecorations"] boolValue] : NO;
    _enableDecorationsCheck.state = decorations ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL blur = [_compPrefs[@"enableBlur"] boolValue];
    _enableBlurCheck.state = blur ? NSControlStateValueOn : NSControlStateValueOff;

    NSString *theme = _compPrefs[@"decorationTheme"] ?: @"Default";
    [_decorationThemePopUp removeAllItems];
    [_decorationThemePopUp addItemsWithTitles:@[@"Default", @"Dark", @"Light", @"Minimal"]];
    [_decorationThemePopUp selectItemWithTitle:theme];

    _titlebarColorWell.color = [self colorFromDictKey:@"titlebarColor"
                                               dict:_compPrefs
                                           fallback:[NSColor colorWithCalibratedRed:0.22
                                                                              green:0.22
                                                                               blue:0.25
                                                                              alpha:0.96]];
    _borderColorWell.color   = [self colorFromDictKey:@"borderColor"
                                               dict:_compPrefs
                                           fallback:[NSColor colorWithCalibratedRed:0.18
                                                                              green:0.18
                                                                               blue:0.22
                                                                              alpha:0.96]];
    _buttonCloseColorWell.color = [self colorFromDictKey:@"buttonCloseColor"
                                                   dict:_compPrefs
                                               fallback:[NSColor colorWithCalibratedRed:0.9
                                                                                  green:0.32
                                                                                   blue:0.32
                                                                                  alpha:1.0]];
    _buttonMinColorWell.color   = [self colorFromDictKey:@"buttonMinColor"
                                                   dict:_compPrefs
                                               fallback:[NSColor colorWithCalibratedRed:0.95
                                                                                  green:0.78
                                                                                   blue:0.20
                                                                                  alpha:1.0]];
    _buttonMaxColorWell.color   = [self colorFromDictKey:@"buttonMaxColor"
                                                   dict:_compPrefs
                                               fallback:[NSColor colorWithCalibratedRed:0.32
                                                                                  green:0.80
                                                                                   blue:0.40
                                                                                  alpha:1.0]];

    /* ---- Dock ---- */
    CGFloat iconSize = [_dockPrefs[@"iconSize"] doubleValue];
    if (iconSize == 0) iconSize = 48.0;
    _iconSizeSlider.doubleValue = iconSize;

    CGFloat zoom = [_dockPrefs[@"zoomFactor"] doubleValue];
    if (zoom == 0) zoom = 1.7;
    _zoomFactorSlider.doubleValue = zoom;

    NSString *pos = _dockPrefs[@"dockPosition"] ?: @"bottom";
    if ([pos isEqualToString:@"bottom"])     [_positionControl setSelectedSegment:0];
    else if ([pos isEqualToString:@"left"])  [_positionControl setSelectedSegment:1];
    else if ([pos isEqualToString:@"right"]) [_positionControl setSelectedSegment:2];

    _autoHideCheck.state =
        [_dockPrefs[@"autoHide"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    _showRunningIndicatorCheck.state =
        (_dockPrefs[@"showRunningDots"] ? [_dockPrefs[@"showRunningDots"] boolValue] : YES)
        ? NSControlStateValueOn : NSControlStateValueOff;

    NSArray *rawItems = _dockPrefs[@"items"];
    _dockItems = [NSMutableArray array];
    for (NSDictionary *d in rawItems) {
        [_dockItems addObject:[d mutableCopy]];
    }
    [_dockItemsTable reloadData];
}

- (void)updateLabels
{
    _transparencyLabel.stringValue =
        [NSString stringWithFormat:@"%.0f%%", _transparencySlider.doubleValue * 100];
    _iconSizeLabel.stringValue =
        [NSString stringWithFormat:@"%.0f pt", _iconSizeSlider.doubleValue];
    _zoomFactorLabel.stringValue =
        [NSString stringWithFormat:@"×%.1f", _zoomFactorSlider.doubleValue];
}

/* ---------------------------------------------------------------------- */
#pragma mark - IBActions – Compositor

- (IBAction)transparencyChanged:(id)sender
{
    _transparencyLabel.stringValue =
        [NSString stringWithFormat:@"%.0f%%", _transparencySlider.doubleValue * 100];
}

- (IBAction)toggleDecorations:(id)sender { }
- (IBAction)decorationThemeChanged:(id)sender { }
- (IBAction)toggleBlur:(id)sender { }
- (IBAction)titlebarColorChanged:(id)sender { }
- (IBAction)borderColorChanged:(id)sender { }
- (IBAction)buttonColorsChanged:(id)sender { }

/* ---------------------------------------------------------------------- */
#pragma mark - IBActions – Dock

- (IBAction)iconSizeChanged:(id)sender
{
    _iconSizeLabel.stringValue =
        [NSString stringWithFormat:@"%.0f pt", _iconSizeSlider.doubleValue];
}

- (IBAction)zoomFactorChanged:(id)sender
{
    _zoomFactorLabel.stringValue =
        [NSString stringWithFormat:@"×%.1f", _zoomFactorSlider.doubleValue];
}

- (IBAction)dockPositionChanged:(id)sender { }
- (IBAction)toggleAutoHide:(id)sender { }
- (IBAction)toggleRunningIndicator:(id)sender { }

- (IBAction)addDockItem:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes = @[@"app"];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    [panel beginSheetModalForWindow:self.mainView.window ?: [NSApp mainWindow]
                  completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSString *path = panel.URL.path;
        NSBundle *b = [NSBundle bundleWithPath:path];
        NSDictionary *entry = @{
            @"label":            [[[path lastPathComponent]
                                   stringByDeletingPathExtension] copy],
            @"bundleIdentifier": [b objectForInfoDictionaryKey:@"CFBundleIdentifier"] ?: @"",
            @"launchPath":       path,
            @"keepInDock":       @YES,
        };
        [self->_dockItems addObject:[entry mutableCopy]];
        [self->_dockItemsTable reloadData];
    }];
}

- (IBAction)removeDockItem:(id)sender
{
    NSInteger row = _dockItemsTable.selectedRow;
    if (row < 0 || row >= (NSInteger)_dockItems.count) return;
    [_dockItems removeObjectAtIndex:(NSUInteger)row];
    [_dockItemsTable reloadData];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Apply / Revert

- (IBAction)applyChanges:(id)sender
{
    /* ---- Compositor ---- */
    _compPrefs[@"windowTransparency"]    = @(_transparencySlider.doubleValue);
    _compPrefs[@"serverSideDecorations"] = @(_enableDecorationsCheck.state == NSControlStateValueOn);
    _compPrefs[@"enableBlur"]            = @(_enableBlurCheck.state == NSControlStateValueOn);
    _compPrefs[@"decorationTheme"]       = _decorationThemePopUp.titleOfSelectedItem ?: @"Default";
    _compPrefs[@"titlebarColor"]         = [self hexStringFromColor:_titlebarColorWell.color];
    _compPrefs[@"borderColor"]           = [self hexStringFromColor:_borderColorWell.color];
    _compPrefs[@"buttonCloseColor"]      = [self hexStringFromColor:_buttonCloseColorWell.color];
    _compPrefs[@"buttonMinColor"]        = [self hexStringFromColor:_buttonMinColorWell.color];
    _compPrefs[@"buttonMaxColor"]        = [self hexStringFromColor:_buttonMaxColorWell.color];
    SavePlist(_compPrefs, _compPrefsPath);

    /* ---- Dock ---- */
    NSString *pos = @"bottom";
    switch (_positionControl.selectedSegment) {
        case 1:  pos = @"left";  break;
        case 2:  pos = @"right"; break;
        default: pos = @"bottom"; break;
    }
    _dockPrefs[@"iconSize"]        = @(_iconSizeSlider.doubleValue);
    _dockPrefs[@"zoomFactor"]      = @(_zoomFactorSlider.doubleValue);
    _dockPrefs[@"dockPosition"]    = pos;
    _dockPrefs[@"autoHide"]        = @(_autoHideCheck.state == NSControlStateValueOn);
    _dockPrefs[@"showRunningDots"] = @(_showRunningIndicatorCheck.state == NSControlStateValueOn);
    _dockPrefs[@"items"]           = [_dockItems copy];
    SavePlist(_dockPrefs, _dockPrefsPath);

    /* Broadcast changes */
    NSDictionary *dockNotif = @{
        @"iconSize":        _dockPrefs[@"iconSize"],
        @"zoomFactor":      _dockPrefs[@"zoomFactor"],
        @"dockPosition":    pos,
        @"autoHide":        _dockPrefs[@"autoHide"],
        @"showRunningDots": _dockPrefs[@"showRunningDots"],
    };
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:kDockPrefsChanged
                   object:nil
                 userInfo:dockNotif
     deliverImmediately:YES];

    NSDictionary *compNotif = @{
        @"windowTransparency":    _compPrefs[@"windowTransparency"],
        @"serverSideDecorations": _compPrefs[@"serverSideDecorations"],
        @"enableBlur":            _compPrefs[@"enableBlur"],
        @"decorationTheme":       _compPrefs[@"decorationTheme"],
    };
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:kCompPrefsChanged
                   object:nil
                 userInfo:compNotif
     deliverImmediately:YES];
}

- (IBAction)revertChanges:(id)sender
{
    [self loadCurrentValues];
    [self updateLabels];
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)_dockItems.count;
}

- (id)tableView:(NSTableView *)tv
objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)row
{
    NSDictionary *item = _dockItems[row];
    if ([col.identifier isEqualToString:@"label"]) return item[@"label"];
    if ([col.identifier isEqualToString:@"path"])  return item[@"launchPath"];
    return @"";
}

- (void)tableView:(NSTableView *)tv
   setObjectValue:(id)obj
   forTableColumn:(NSTableColumn *)col
              row:(NSInteger)row
{
    NSMutableDictionary *item = (NSMutableDictionary *)_dockItems[row];
    if ([col.identifier isEqualToString:@"label"]) item[@"label"] = obj;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Colour helpers

- (NSColor *)colorFromDictKey:(NSString *)key
                         dict:(NSDictionary *)dict
                     fallback:(NSColor *)fallback
{
    NSString *hex = dict[key];
    if (!hex) return fallback;
    return [self colorFromHexString:hex] ?: fallback;
}

- (NSColor *)colorFromHexString:(NSString *)hex
{
    hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 8 && hex.length != 6) return nil;

    unsigned int rgba = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgba];

    CGFloat r, g, b, a = 1.0;
    if (hex.length == 8) {
        r = ((rgba >> 24) & 0xFF) / 255.0;
        g = ((rgba >> 16) & 0xFF) / 255.0;
        b = ((rgba >>  8) & 0xFF) / 255.0;
        a = ( rgba        & 0xFF) / 255.0;
    } else {
        r = ((rgba >> 16) & 0xFF) / 255.0;
        g = ((rgba >>  8) & 0xFF) / 255.0;
        b = ( rgba        & 0xFF) / 255.0;
    }
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];
}

- (NSString *)hexStringFromColor:(NSColor *)color
{
    CGFloat r, g, b, a;
    [[color colorUsingColorSpaceName:NSCalibratedRGBColorSpace]
     getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02X%02X%02X%02X",
            (unsigned)(r * 255),
            (unsigned)(g * 255),
            (unsigned)(b * 255),
            (unsigned)(a * 255)];
}

@end
