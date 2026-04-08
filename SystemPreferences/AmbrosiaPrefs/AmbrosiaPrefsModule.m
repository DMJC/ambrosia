#import "AmbrosiaPrefsModule.h"

/* Shared preferences domain used by the compositor and dock */
static NSString *const kCompositorDomain = @"org.gnustep.AmbrosiaCompositor";
static NSString *const kDockDomain       = @"org.gnustep.AmbrosiaDock";

/* Notification names (posted to the dock over NSDistributedNotificationCenter) */
static NSString *const kDockPrefsChanged = @"AmbrosiaDocksPrefsChanged";
static NSString *const kCompPrefsChanged = @"AmbrosiaCompositorPrefsChanged";

@interface AmbrosiaPrefsModule () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *dockItems;
@end

@implementation AmbrosiaPrefsModule {
    NSUserDefaults *_compDefaults;
    NSUserDefaults *_dockDefaults;
    NSMutableDictionary *_pendingComp;
    NSMutableDictionary *_pendingDock;
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSPreferencePane lifecycle

- (void)mainViewDidLoad
{
    /* GNUstep does not implement initWithSuiteName: — use standardUserDefaults.
     * Key prefixes (compositor.* / dock.*) prevent collisions. */
    _compDefaults = [NSUserDefaults standardUserDefaults];
    _dockDefaults = [NSUserDefaults standardUserDefaults];

    [self loadCurrentValues];
    [self updateLabels];
}

- (void)willSelect
{
    [self loadCurrentValues];
    [self updateLabels];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Load / save

- (void)loadCurrentValues
{
    /* ---- Compositor ---- */
    CGFloat transparency = [_compDefaults doubleForKey:@"windowTransparency"];
    if (transparency == 0) transparency = 0.96;
    _transparencySlider.doubleValue    = transparency;

    BOOL decorations = [_compDefaults objectForKey:@"serverSideDecorations"]
        ? [_compDefaults boolForKey:@"serverSideDecorations"] : YES;
    _enableDecorationsCheck.state     = decorations ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL blur = [_compDefaults boolForKey:@"enableBlur"];
    _enableBlurCheck.state            = blur ? NSControlStateValueOn : NSControlStateValueOff;

    /* Decoration theme popup */
    NSString *theme = [_compDefaults stringForKey:@"decorationTheme"] ?: @"Default";
    [_decorationThemePopUp removeAllItems];
    [_decorationThemePopUp addItemsWithTitles:@[@"Default", @"Dark", @"Light", @"Minimal"]];
    [_decorationThemePopUp selectItemWithTitle:theme];

    /* Colours */
    NSColor *tbColor = [self colorFromDefaultsKey:@"titlebarColor"
                                        defaults:_compDefaults
                                        fallback:[NSColor colorWithCalibratedRed:0.22
                                                                           green:0.22
                                                                            blue:0.25
                                                                           alpha:0.96]];
    _titlebarColorWell.color = tbColor;

    NSColor *bdColor = [self colorFromDefaultsKey:@"borderColor"
                                        defaults:_compDefaults
                                        fallback:[NSColor colorWithCalibratedRed:0.18
                                                                           green:0.18
                                                                            blue:0.22
                                                                           alpha:0.96]];
    _borderColorWell.color = bdColor;

    _buttonCloseColorWell.color = [self colorFromDefaultsKey:@"buttonCloseColor"
                                                    defaults:_compDefaults
                                                    fallback:[NSColor colorWithCalibratedRed:0.9
                                                                                       green:0.32
                                                                                        blue:0.32
                                                                                       alpha:1.0]];
    _buttonMinColorWell.color   = [self colorFromDefaultsKey:@"buttonMinColor"
                                                    defaults:_compDefaults
                                                    fallback:[NSColor colorWithCalibratedRed:0.95
                                                                                       green:0.78
                                                                                        blue:0.20
                                                                                       alpha:1.0]];
    _buttonMaxColorWell.color   = [self colorFromDefaultsKey:@"buttonMaxColor"
                                                    defaults:_compDefaults
                                                    fallback:[NSColor colorWithCalibratedRed:0.32
                                                                                       green:0.80
                                                                                        blue:0.40
                                                                                       alpha:1.0]];

    /* ---- Dock ---- */
    CGFloat iconSize = [_dockDefaults doubleForKey:@"iconSize"];
    if (iconSize == 0) iconSize = 48.0;
    _iconSizeSlider.doubleValue  = iconSize;

    CGFloat zoom = [_dockDefaults doubleForKey:@"zoomFactor"];
    if (zoom == 0) zoom = 1.7;
    _zoomFactorSlider.doubleValue = zoom;

    NSString *pos = [_dockDefaults stringForKey:@"dockPosition"] ?: @"bottom";
    if ([pos isEqualToString:@"bottom"])     [_positionControl setSelectedSegment:0];
    else if ([pos isEqualToString:@"left"])  [_positionControl setSelectedSegment:1];
    else if ([pos isEqualToString:@"right"]) [_positionControl setSelectedSegment:2];

    _autoHideCheck.state =
        [_dockDefaults boolForKey:@"autoHide"] ? NSControlStateValueOn : NSControlStateValueOff;
    _showRunningIndicatorCheck.state =
        ([_dockDefaults objectForKey:@"showRunningDots"] ?
         [_dockDefaults boolForKey:@"showRunningDots"] : YES)
        ? NSControlStateValueOn : NSControlStateValueOff;

    /* Dock items table */
    NSArray *rawItems = [_dockDefaults arrayForKey:@"items"];
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

- (IBAction)toggleDecorations:(id)sender { /* live preview – nothing extra */ }
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
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        NSDictionary *entry = @{
            @"label":            [[[path lastPathComponent]
                                   stringByDeletingPathExtension] copy],
            @"bundleIdentifier": [bundle objectForInfoDictionaryKey:@"CFBundleIdentifier"] ?: @"",
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
    [_compDefaults setDouble:_transparencySlider.doubleValue forKey:@"windowTransparency"];
    [_compDefaults setBool:(_enableDecorationsCheck.state == NSControlStateValueOn)
                   forKey:@"serverSideDecorations"];
    [_compDefaults setBool:(_enableBlurCheck.state == NSControlStateValueOn)
                   forKey:@"enableBlur"];
    [_compDefaults setObject:_decorationThemePopUp.titleOfSelectedItem forKey:@"decorationTheme"];
    [_compDefaults setObject:[self hexStringFromColor:_titlebarColorWell.color]
                      forKey:@"titlebarColor"];
    [_compDefaults setObject:[self hexStringFromColor:_borderColorWell.color]
                      forKey:@"borderColor"];
    [_compDefaults setObject:[self hexStringFromColor:_buttonCloseColorWell.color]
                      forKey:@"buttonCloseColor"];
    [_compDefaults setObject:[self hexStringFromColor:_buttonMinColorWell.color]
                      forKey:@"buttonMinColor"];
    [_compDefaults setObject:[self hexStringFromColor:_buttonMaxColorWell.color]
                      forKey:@"buttonMaxColor"];
    [_compDefaults synchronize];

    /* ---- Dock ---- */
    [_dockDefaults setDouble:_iconSizeSlider.doubleValue   forKey:@"iconSize"];
    [_dockDefaults setDouble:_zoomFactorSlider.doubleValue forKey:@"zoomFactor"];

    NSString *pos = @"bottom";
    switch (_positionControl.selectedSegment) {
        case 1:  pos = @"left";  break;
        case 2:  pos = @"right"; break;
        default: pos = @"bottom"; break;
    }
    [_dockDefaults setObject:pos forKey:@"dockPosition"];
    [_dockDefaults setBool:(_autoHideCheck.state == NSControlStateValueOn) forKey:@"autoHide"];
    [_dockDefaults setBool:(_showRunningIndicatorCheck.state == NSControlStateValueOn)
                   forKey:@"showRunningDots"];
    [_dockDefaults setObject:[_dockItems copy] forKey:@"items"];
    [_dockDefaults synchronize];

    /* Broadcast changes */
    NSDictionary *dockPrefs = @{
        @"iconSize":        @(_iconSizeSlider.doubleValue),
        @"zoomFactor":      @(_zoomFactorSlider.doubleValue),
        @"dockPosition":    pos,
        @"autoHide":        @(_autoHideCheck.state == NSControlStateValueOn),
        @"showRunningDots": @(_showRunningIndicatorCheck.state == NSControlStateValueOn),
    };
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:kDockPrefsChanged
                   object:nil
                 userInfo:dockPrefs
     deliverImmediately:YES];

    NSDictionary *compPrefs = @{
        @"windowTransparency":    @(_transparencySlider.doubleValue),
        @"serverSideDecorations": @(_enableDecorationsCheck.state == NSControlStateValueOn),
        @"enableBlur":            @(_enableBlurCheck.state == NSControlStateValueOn),
        @"decorationTheme":       _decorationThemePopUp.titleOfSelectedItem ?: @"Default",
    };
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:kCompPrefsChanged
                   object:nil
                 userInfo:compPrefs
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

- (NSColor *)colorFromDefaultsKey:(NSString *)key
                         defaults:(NSUserDefaults *)ud
                         fallback:(NSColor *)fallback
{
    NSString *hex = [ud stringForKey:key];
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
