#import "AmbrosiaModule.h"
#include <stdlib.h>

/* Plist file names written by each component */
static NSString *const kCompPlistName    = @"org.gnustep.AmbrosiaCompositor.plist";
static NSString *const kDockPlistName    = @"org.gnustep.AmbrosiaDock.plist";
static NSString *const kSessionPlistName = @"org.gnustep.AmbrosiaSession.plist";
static NSString *const kDesktopPlistName = @"org.gnustep.AmbrosiaDesktop.plist";

/* Notification names (posted over NSDistributedNotificationCenter) */
static NSString *const kDockPrefsChanged    = @"AmbrosiaDocksPrefsChanged";
static NSString *const kCompPrefsChanged    = @"AmbrosiaCompositorPrefsChanged";
static NSString *const kSessionPrefsChanged = @"AmbrosiaSessionPrefsChanged";
static NSString *const kDesktopPrefsChanged = @"AmbrosiaDesktopPrefsChanged";

/* Discrete rotation intervals exposed on the slider (position → seconds). */
static const NSInteger kIntervalValues[] = { 5, 10, 30, 60, 300, 600 };
static const NSUInteger kIntervalCount   = 6;

@interface AmbrosiaModule () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *dockItems;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *sessionItems;
@end

/* ---------------------------------------------------------------------- */
/* Flipped view: y=0 at top, so rows can be appended downward naturally.  */

@interface GNFlippedView : NSView
@end
@implementation GNFlippedView
- (BOOL)isFlipped { return YES; }
@end

/* Layout constants for the preference pane UI */
#define MV_MARGIN   16      /* left/right margin inside a tab */
#define MV_LBL_W   172      /* fixed label column width */
#define MV_CTRL_X  196      /* MV_MARGIN + MV_LBL_W + 8 */
#define MV_ROW_H    22      /* standard row height */
#define MV_ROW_GAP  10      /* vertical gap between rows */
#define MV_VAL_W    65      /* width of slider value labels */
#define MV_TAB_W   520      /* initial content-view width (NSTabView resizes it) */
/* Slider width: fills from CTRL_X to the right margin, room for the value label */
#define MV_SLD_W  (MV_TAB_W - MV_CTRL_X - MV_VAL_W - 8 - MV_MARGIN)

@implementation AmbrosiaModule {
    NSString            *_compPrefsPath;
    NSString            *_dockPrefsPath;
    NSString            *_sessionPrefsPath;
    NSString            *_desktopPrefsPath;
    NSMutableDictionary *_compPrefs;
    NSMutableDictionary *_dockPrefs;
    NSMutableDictionary *_sessionPrefs;
    NSMutableDictionary *_desktopPrefs;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Helpers

static NSString *PrefsDirectory(void)
{
    /* Prefer the path set by GNUstep.sh so the pref pane writes to the same
     * location the compositor reads from. */
    const char *userLib = getenv("GNUSTEP_USER_LIBRARY");
    if (userLib && userLib[0]) {
        return [[NSString stringWithUTF8String:userLib]
                stringByAppendingPathComponent:@"Preferences"];
    }
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

/* Terminate Dock so the compositor can relaunch it with fresh startup args. */
static void KillRunningDockProcess(void)
{
    /* Prefer exact-name match; fallback without -x for environments that
     * report process names differently. */
    int rc = system("pkill -TERM -x AmbrosiaDock >/dev/null 2>&1");
    if (rc != 0) {
        (void)system("pkill -TERM AmbrosiaDock >/dev/null 2>&1");
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - UI construction helpers
/*
 * GNUstep does not implement the NSLayoutAnchor / Auto Layout anchor API.
 * All layout uses explicit frames and autoresizing masks (see constants above).
 */

static NSTextField *MakeLabel(NSString *text)
{
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.stringValue     = text;
    f.editable        = NO;
    f.bordered        = NO;
    f.drawsBackground = NO;
    return f;
}

static NSTextField *MakeValueLabel(void)
{
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.editable        = NO;
    f.bordered        = NO;
    f.drawsBackground = NO;
    f.alignment       = NSTextAlignmentRight;
    return f;
}

static NSButton *MakeCheckbox(NSString *title)
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    [b setButtonType:NSSwitchButton];
    b.title = title;
    b.state = NSControlStateValueOff;
    return b;
}

static NSColorWell *MakeColorWell(void)
{
    return [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 22)];
}

static NSButton *MakePushButton(NSString *title)
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    [b setButtonType:NSMomentaryPushInButton];
    b.bezelStyle = NSRoundedBezelStyle;
    b.title      = title;
    return b;
}

/* Convert a slider position (0…kIntervalCount-1) to its seconds value. */
static NSInteger intervalForSliderPos(NSInteger pos)
{
    if (pos < 0) pos = 0;
    if (pos >= (NSInteger)kIntervalCount) pos = (NSInteger)kIntervalCount - 1;
    return kIntervalValues[(NSUInteger)pos];
}

/* Find the slider position closest to a given seconds value. */
static NSInteger sliderPosForInterval(NSInteger secs)
{
    NSInteger best = 0;
    NSInteger bestDiff = ABS(kIntervalValues[0] - secs);
    for (NSUInteger i = 1; i < kIntervalCount; i++) {
        NSInteger diff = ABS(kIntervalValues[i] - secs);
        if (diff < bestDiff) { bestDiff = diff; best = (NSInteger)i; }
    }
    return best;
}

static NSString *intervalLabel(NSInteger secs)
{
    if (secs < 60) return [NSString stringWithFormat:@"%ld seconds", (long)secs];
    return [NSString stringWithFormat:@"%ld minute%s", (long)(secs / 60),
            (secs / 60 == 1) ? "" : "s"];
}

/* Add a label + slider + value-label row to |tab| at y, return next y */
- (CGFloat)addSliderRow:(NSView *)tab
                  label:(NSString *)labelText
                 slider:(NSSlider *)slider
             valueLabel:(NSTextField *)valLabel
                    atY:(CGFloat)y
{
    NSTextField *lbl = MakeLabel(labelText);
    lbl.frame = NSMakeRect(MV_MARGIN, y, MV_LBL_W, MV_ROW_H);

    slider.frame = NSMakeRect(MV_CTRL_X, y, MV_SLD_W, MV_ROW_H);
    slider.autoresizingMask = NSViewWidthSizable;

    valLabel.frame = NSMakeRect(MV_TAB_W - MV_VAL_W - MV_MARGIN, y, MV_VAL_W, MV_ROW_H);
    valLabel.autoresizingMask = NSViewMinXMargin;

    [tab addSubview:lbl];
    [tab addSubview:slider];
    [tab addSubview:valLabel];
    return y + MV_ROW_H + MV_ROW_GAP;
}

/* Add a label + fixed control row to |tab| at y, return next y */
- (CGFloat)addLabeledRow:(NSView *)tab
                   label:(NSString *)labelText
                 control:(NSView *)control
              controlWidth:(CGFloat)cw
                     atY:(CGFloat)y
{
    NSTextField *lbl = MakeLabel(labelText);
    lbl.frame = NSMakeRect(MV_MARGIN, y, MV_LBL_W, MV_ROW_H);
    control.frame = NSMakeRect(MV_CTRL_X, y, cw, MV_ROW_H);
    [tab addSubview:lbl];
    [tab addSubview:control];
    return y + MV_ROW_H + MV_ROW_GAP;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Build UI programmatically

- (NSView *)buildCompositorTab
{
    NSView *tab = [[GNFlippedView alloc] initWithFrame:NSMakeRect(0, 0, MV_TAB_W, 400)];
    tab.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat y = MV_MARGIN;

    /* Transparency */
    _transparencySlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _transparencySlider.minValue = 0.5;
    _transparencySlider.maxValue = 1.0;
    [_transparencySlider setTarget:self];
    [_transparencySlider setAction:@selector(transparencyChanged:)];
    _transparencyLabel = MakeValueLabel();
    y = [self addSliderRow:tab
                     label:@"Window Transparency:"
                    slider:_transparencySlider
                valueLabel:_transparencyLabel
                       atY:y];

    /* Decoration theme */
    _decorationThemePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_decorationThemePopUp setTarget:self];
    [_decorationThemePopUp setAction:@selector(decorationThemeChanged:)];
    y = [self addLabeledRow:tab
                      label:@"Decoration Theme:"
                    control:_decorationThemePopUp
               controlWidth:180
                        atY:y];

    /* Checkboxes */
    _enableDecorationsCheck = MakeCheckbox(@"Server-side Decorations");
    _enableDecorationsCheck.frame = NSMakeRect(MV_MARGIN, y,
                                               MV_TAB_W - MV_MARGIN * 2, MV_ROW_H);
    _enableDecorationsCheck.autoresizingMask = NSViewWidthSizable;
    [_enableDecorationsCheck setTarget:self];
    [_enableDecorationsCheck setAction:@selector(toggleDecorations:)];
    [tab addSubview:_enableDecorationsCheck];
    y += MV_ROW_H + MV_ROW_GAP;

    _enableBlurCheck = MakeCheckbox(@"Enable Blur");
    _enableBlurCheck.frame = NSMakeRect(MV_MARGIN, y,
                                        MV_TAB_W - MV_MARGIN * 2, MV_ROW_H);
    _enableBlurCheck.autoresizingMask = NSViewWidthSizable;
    [_enableBlurCheck setTarget:self];
    [_enableBlurCheck setAction:@selector(toggleBlur:)];
    [tab addSubview:_enableBlurCheck];
    y += MV_ROW_H + MV_ROW_GAP;

    _x11DecorationsCheck = MakeCheckbox(@"X11 Decorations (theme-styled borders for XWayland windows)");
    _x11DecorationsCheck.frame = NSMakeRect(MV_MARGIN, y,
                                            MV_TAB_W - MV_MARGIN * 2, MV_ROW_H);
    _x11DecorationsCheck.autoresizingMask = NSViewWidthSizable;
    [_x11DecorationsCheck setTarget:self];
    [_x11DecorationsCheck setAction:@selector(toggleX11Decorations:)];
    [tab addSubview:_x11DecorationsCheck];
    y += MV_ROW_H + MV_ROW_GAP;

    /* Color wells */
    _titlebarColorWell = MakeColorWell();
    [_titlebarColorWell setTarget:self];
    [_titlebarColorWell setAction:@selector(titlebarColorChanged:)];
    y = [self addLabeledRow:tab label:@"Titlebar Color:"
                    control:_titlebarColorWell controlWidth:44 atY:y];

    _borderColorWell = MakeColorWell();
    [_borderColorWell setTarget:self];
    [_borderColorWell setAction:@selector(borderColorChanged:)];
    y = [self addLabeledRow:tab label:@"Border Color:"
                    control:_borderColorWell controlWidth:44 atY:y];

    /* Button colours — label + three wells side by side */
    NSTextField *btnLbl = MakeLabel(@"Button Colors (×/−/+):");
    btnLbl.frame = NSMakeRect(MV_MARGIN, y, MV_LBL_W, MV_ROW_H);
    [tab addSubview:btnLbl];

    _buttonCloseColorWell = MakeColorWell();
    _buttonMinColorWell   = MakeColorWell();
    _buttonMaxColorWell   = MakeColorWell();
    [_buttonCloseColorWell setTarget:self]; [_buttonCloseColorWell setAction:@selector(buttonColorsChanged:)];
    [_buttonMinColorWell   setTarget:self]; [_buttonMinColorWell   setAction:@selector(buttonColorsChanged:)];
    [_buttonMaxColorWell   setTarget:self]; [_buttonMaxColorWell   setAction:@selector(buttonColorsChanged:)];

    _buttonCloseColorWell.frame = NSMakeRect(MV_CTRL_X,          y, 44, MV_ROW_H);
    _buttonMinColorWell.frame   = NSMakeRect(MV_CTRL_X + 48,     y, 44, MV_ROW_H);
    _buttonMaxColorWell.frame   = NSMakeRect(MV_CTRL_X + 96,     y, 44, MV_ROW_H);
    [tab addSubview:_buttonCloseColorWell];
    [tab addSubview:_buttonMinColorWell];
    [tab addSubview:_buttonMaxColorWell];

    return tab;
}

- (NSView *)buildDockTab
{
    NSView *tab = [[GNFlippedView alloc] initWithFrame:NSMakeRect(0, 0, MV_TAB_W, 400)];
    tab.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat y = MV_MARGIN;

    /* Icon size */
    _iconSizeSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _iconSizeSlider.minValue = 16;
    _iconSizeSlider.maxValue = 128;
    [_iconSizeSlider setTarget:self];
    [_iconSizeSlider setAction:@selector(iconSizeChanged:)];
    _iconSizeLabel = MakeValueLabel();
    y = [self addSliderRow:tab label:@"Icon Size:"
                    slider:_iconSizeSlider valueLabel:_iconSizeLabel atY:y];

    /* Zoom factor */
    _zoomFactorSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _zoomFactorSlider.minValue = 1.0;
    _zoomFactorSlider.maxValue = 3.0;
    [_zoomFactorSlider setTarget:self];
    [_zoomFactorSlider setAction:@selector(zoomFactorChanged:)];
    _zoomFactorLabel = MakeValueLabel();
    y = [self addSliderRow:tab label:@"Zoom Factor:"
                    slider:_zoomFactorSlider valueLabel:_zoomFactorLabel atY:y];

    /* Dock position */
    _positionControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _positionControl.segmentCount = 3;
    [_positionControl setLabel:@"Bottom" forSegment:0];
    [_positionControl setLabel:@"Left"   forSegment:1];
    [_positionControl setLabel:@"Right"  forSegment:2];
    [_positionControl setTarget:self];
    [_positionControl setAction:@selector(dockPositionChanged:)];
    y = [self addLabeledRow:tab label:@"Position:"
                    control:_positionControl controlWidth:210 atY:y];

    /* Checkboxes */
    _autoHideCheck = MakeCheckbox(@"Auto-hide Dock");
    _autoHideCheck.frame = NSMakeRect(MV_MARGIN, y,
                                      MV_TAB_W - MV_MARGIN * 2, MV_ROW_H);
    _autoHideCheck.autoresizingMask = NSViewWidthSizable;
    [_autoHideCheck setTarget:self];
    [_autoHideCheck setAction:@selector(toggleAutoHide:)];
    [tab addSubview:_autoHideCheck];
    y += MV_ROW_H + MV_ROW_GAP;

    _showRunningIndicatorCheck = MakeCheckbox(@"Show Running Indicators");
    _showRunningIndicatorCheck.frame = NSMakeRect(MV_MARGIN, y,
                                                  MV_TAB_W - MV_MARGIN * 2, MV_ROW_H);
    _showRunningIndicatorCheck.autoresizingMask = NSViewWidthSizable;
    [_showRunningIndicatorCheck setTarget:self];
    [_showRunningIndicatorCheck setAction:@selector(toggleRunningIndicator:)];
    [tab addSubview:_showRunningIndicatorCheck];
    y += MV_ROW_H + MV_ROW_GAP;

    /* Dock items label */
    NSTextField *itemsLbl = MakeLabel(@"Dock Items:");
    itemsLbl.frame = NSMakeRect(MV_MARGIN, y, 200, MV_ROW_H);
    [tab addSubview:itemsLbl];
    y += MV_ROW_H + 4;

    /* Dock items table */
    _dockItemsTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *labelCol = [[NSTableColumn alloc] initWithIdentifier:@"label"];
    labelCol.title = @"Name";
    labelCol.width = 150;
    NSTableColumn *pathCol = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    pathCol.title = @"Path";
    [_dockItemsTable addTableColumn:labelCol];
    [_dockItemsTable addTableColumn:pathCol];

    CGFloat tableH = 120;
    NSScrollView *tableScroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(MV_MARGIN, y,
                                 MV_TAB_W - MV_MARGIN * 2, tableH)];
    tableScroll.autoresizingMask = NSViewWidthSizable;
    tableScroll.hasVerticalScroller   = YES;
    tableScroll.hasHorizontalScroller = NO;
    tableScroll.documentView = _dockItemsTable;
    [tab addSubview:tableScroll];
    y += tableH + MV_ROW_GAP;

    /* Add / Remove buttons */
    _addItemButton    = MakePushButton(@"+");
    _removeItemButton = MakePushButton(@"−");
    _addItemButton.frame    = NSMakeRect(MV_MARGIN,      y, 32, 28);
    _removeItemButton.frame = NSMakeRect(MV_MARGIN + 36, y, 32, 28);
    [_addItemButton    setTarget:self]; [_addItemButton    setAction:@selector(addDockItem:)];
    [_removeItemButton setTarget:self]; [_removeItemButton setAction:@selector(removeDockItem:)];
    [tab addSubview:_addItemButton];
    [tab addSubview:_removeItemButton];

    return tab;
}

- (NSView *)buildSessionTab
{
    NSView *tab = [[GNFlippedView alloc] initWithFrame:NSMakeRect(0, 0, MV_TAB_W, 400)];
    tab.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat y = MV_MARGIN;

    NSTextField *itemsLbl = MakeLabel(@"Session Applications:");
    itemsLbl.frame = NSMakeRect(MV_MARGIN, y, 250, MV_ROW_H);
    [tab addSubview:itemsLbl];
    y += MV_ROW_H + 4;

    _sessionItemsTable = [[NSTableView alloc] initWithFrame:NSZeroRect];

    /* Checkbox column for enabled/disabled */
    NSTableColumn *enabledCol = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    enabledCol.title = @"Auto-start";
    enabledCol.width = 72;
    NSButtonCell *checkCell = [[NSButtonCell alloc] init];
    [checkCell setButtonType:NSSwitchButton];
    checkCell.title       = @"";
    checkCell.controlSize = NSControlSizeSmall;
    enabledCol.dataCell   = checkCell;

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"Name";
    nameCol.width = 140;

    NSTableColumn *pathCol = [[NSTableColumn alloc] initWithIdentifier:@"sessionPath"];
    pathCol.title = @"Path";

    [_sessionItemsTable addTableColumn:enabledCol];
    [_sessionItemsTable addTableColumn:nameCol];
    [_sessionItemsTable addTableColumn:pathCol];

    CGFloat tableH = 200;
    NSScrollView *tableScroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(MV_MARGIN, y, MV_TAB_W - MV_MARGIN * 2, tableH)];
    tableScroll.autoresizingMask       = NSViewWidthSizable | NSViewHeightSizable;
    tableScroll.hasVerticalScroller    = YES;
    tableScroll.hasHorizontalScroller  = NO;
    tableScroll.documentView           = _sessionItemsTable;
    [tab addSubview:tableScroll];
    y += tableH + MV_ROW_GAP;

    _addSessionItemButton    = MakePushButton(@"+");
    _removeSessionItemButton = MakePushButton(@"−");
    _addSessionItemButton.frame    = NSMakeRect(MV_MARGIN,      y, 32, 28);
    _removeSessionItemButton.frame = NSMakeRect(MV_MARGIN + 36, y, 32, 28);
    [_addSessionItemButton    setTarget:self];
    [_addSessionItemButton    setAction:@selector(addSessionItem:)];
    [_removeSessionItemButton setTarget:self];
    [_removeSessionItemButton setAction:@selector(removeSessionItem:)];
    [tab addSubview:_addSessionItemButton];
    [tab addSubview:_removeSessionItemButton];

    return tab;
}

- (NSView *)buildDesktopTab
{
    NSView *tab = [[GNFlippedView alloc] initWithFrame:NSMakeRect(0, 0, MV_TAB_W, 400)];
    tab.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat y   = MV_MARGIN;
    CGFloat fW  = MV_TAB_W - MV_CTRL_X - 80 - MV_MARGIN; /* path-field width */
    CGFloat btnW = 72;

    /* ---- Background Image ---- */
    NSTextField *imgLbl = MakeLabel(@"Background Image:");
    imgLbl.frame = NSMakeRect(MV_MARGIN, y, MV_LBL_W, MV_ROW_H);
    [tab addSubview:imgLbl];

    _bgImagePathField = [[NSTextField alloc] initWithFrame:
                          NSMakeRect(MV_CTRL_X, y, fW, MV_ROW_H)];
    _bgImagePathField.placeholderString = @"(none)";
    _bgImagePathField.editable = YES;
    _bgImagePathField.autoresizingMask = NSViewWidthSizable;
    [tab addSubview:_bgImagePathField];

    _bgImageChooseButton = MakePushButton(@"Choose…");
    _bgImageChooseButton.frame = NSMakeRect(MV_CTRL_X + fW + 8, y, btnW, MV_ROW_H);
    _bgImageChooseButton.autoresizingMask = NSViewMinXMargin;
    [_bgImageChooseButton setTarget:self];
    [_bgImageChooseButton setAction:@selector(chooseBgImage:)];
    [tab addSubview:_bgImageChooseButton];
    y += MV_ROW_H + MV_ROW_GAP;

    /* ---- Rotating Background Images ---- */
    _rotatingCheck = MakeCheckbox(@"Rotating Background Images");
    _rotatingCheck.frame = NSMakeRect(MV_MARGIN, y, MV_TAB_W - MV_MARGIN * 2, MV_ROW_H);
    _rotatingCheck.autoresizingMask = NSViewWidthSizable;
    [_rotatingCheck setTarget:self];
    [_rotatingCheck setAction:@selector(toggleRotating:)];
    [tab addSubview:_rotatingCheck];
    y += MV_ROW_H + MV_ROW_GAP;

    /* ---- Images Folder ---- */
    NSTextField *folderLbl = MakeLabel(@"Images Folder:");
    folderLbl.frame = NSMakeRect(MV_MARGIN, y, MV_LBL_W, MV_ROW_H);
    [tab addSubview:folderLbl];

    _bgFolderPathField = [[NSTextField alloc] initWithFrame:
                           NSMakeRect(MV_CTRL_X, y, fW, MV_ROW_H)];
    _bgFolderPathField.placeholderString = @"(none)";
    _bgFolderPathField.editable = YES;
    _bgFolderPathField.autoresizingMask = NSViewWidthSizable;
    [tab addSubview:_bgFolderPathField];

    _bgFolderChooseButton = MakePushButton(@"Choose…");
    _bgFolderChooseButton.frame = NSMakeRect(MV_CTRL_X + fW + 8, y, btnW, MV_ROW_H);
    _bgFolderChooseButton.autoresizingMask = NSViewMinXMargin;
    [_bgFolderChooseButton setTarget:self];
    [_bgFolderChooseButton setAction:@selector(chooseBgFolder:)];
    [tab addSubview:_bgFolderChooseButton];
    y += MV_ROW_H + MV_ROW_GAP;

    /* ---- Rotation Interval (discrete slider) ---- */
    _intervalSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _intervalSlider.minValue                 = 0;
    _intervalSlider.maxValue                 = (double)(kIntervalCount - 1);
    _intervalSlider.numberOfTickMarks        = (NSInteger)kIntervalCount;
    _intervalSlider.allowsTickMarkValuesOnly = YES;
    [_intervalSlider setTarget:self];
    [_intervalSlider setAction:@selector(intervalChanged:)];
    _intervalLabel = MakeValueLabel();
    y = [self addSliderRow:tab
                     label:@"Change every:"
                    slider:_intervalSlider
                valueLabel:_intervalLabel
                       atY:y];

    /* Update enabled state of folder controls based on checkbox default (off). */
    [self _updateRotatingControlsEnabled:NO];

    return tab;
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSPreferencePane lifecycle

- (NSView *)loadMainView
{
    /* Build the entire UI in code — the .gorm is a stub with no connections. */
    const CGFloat W = 540, H = 480;
    const CGFloat btnH = 36, btnW = 80, gap = 8;

    NSView *mainContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    mainContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    /* Tab view — sits above the button bar */
    CGFloat tabH = H - btnH - gap * 2;
    _tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(0, btnH + gap, W, tabH)];
    _tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTabViewItem *compItem = [[NSTabViewItem alloc] initWithIdentifier:@"compositor"];
    compItem.label = @"Compositor";
    compItem.view  = [self buildCompositorTab];
    [_tabView addTabViewItem:compItem];

    NSTabViewItem *dockItem = [[NSTabViewItem alloc] initWithIdentifier:@"dock"];
    dockItem.label = @"Dock";
    dockItem.view  = [self buildDockTab];
    [_tabView addTabViewItem:dockItem];

    NSTabViewItem *sessionItem = [[NSTabViewItem alloc] initWithIdentifier:@"session"];
    sessionItem.label = @"Session";
    sessionItem.view  = [self buildSessionTab];
    [_tabView addTabViewItem:sessionItem];

    NSTabViewItem *desktopItem = [[NSTabViewItem alloc] initWithIdentifier:@"desktop"];
    desktopItem.label = @"Desktop";
    desktopItem.view  = [self buildDesktopTab];
    [_tabView addTabViewItem:desktopItem];

    /* Apply / Revert buttons — bottom-right */
    NSButton *applyBtn  = MakePushButton(@"Apply");
    NSButton *revertBtn = MakePushButton(@"Revert");
    applyBtn.frame  = NSMakeRect(W - gap - btnW,              gap, btnW, btnH - gap);
    revertBtn.frame = NSMakeRect(W - gap - btnW * 2 - gap,    gap, btnW, btnH - gap);
    applyBtn.autoresizingMask  = NSViewMinXMargin;
    revertBtn.autoresizingMask = NSViewMinXMargin;
    [applyBtn  setTarget:self]; [applyBtn  setAction:@selector(applyChanges:)];
    [revertBtn setTarget:self]; [revertBtn setAction:@selector(revertChanges:)];

    [mainContainer addSubview:_tabView];
    [mainContainer addSubview:applyBtn];
    [mainContainer addSubview:revertBtn];

    [self setMainView:mainContainer];
    [self mainViewDidLoad];
    return mainContainer;
}

- (instancetype)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        NSString *prefsDir = PrefsDirectory();
        _compPrefsPath    = [prefsDir stringByAppendingPathComponent:kCompPlistName];
        _dockPrefsPath    = [prefsDir stringByAppendingPathComponent:kDockPlistName];
        _sessionPrefsPath = [prefsDir stringByAppendingPathComponent:kSessionPlistName];
        _desktopPrefsPath = [prefsDir stringByAppendingPathComponent:kDesktopPlistName];
        _compPrefs    = LoadPlist(_compPrefsPath);
        _dockPrefs    = LoadPlist(_dockPrefsPath);
        _sessionPrefs = LoadPlist(_sessionPrefsPath);
        _desktopPrefs = LoadPlist(_desktopPrefsPath);
    }
    return self;
}

- (void)mainViewDidLoad
{
    /* Wire up the table views — outlets are guaranteed non-nil here */
    _dockItems = [NSMutableArray array];
    _dockItemsTable.dataSource = self;
    _dockItemsTable.delegate   = self;

    _sessionItems = [NSMutableArray array];
    _sessionItemsTable.dataSource = self;
    _sessionItemsTable.delegate   = self;

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
    _compPrefs    = LoadPlist(_compPrefsPath);
    _dockPrefs    = LoadPlist(_dockPrefsPath);
    _sessionPrefs = LoadPlist(_sessionPrefsPath);
    _desktopPrefs = LoadPlist(_desktopPrefsPath);

    /* ---- Compositor ---- */
    CGFloat transparency = [_compPrefs[@"windowTransparency"] doubleValue];
    if (transparency == 0) transparency = 0.96;
    _transparencySlider.doubleValue = transparency;

    BOOL decorations = _compPrefs[@"serverSideDecorations"]
        ? [_compPrefs[@"serverSideDecorations"] boolValue] : NO;
    _enableDecorationsCheck.state = decorations ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL blur = [_compPrefs[@"enableBlur"] boolValue];
    _enableBlurCheck.state = blur ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL x11Dec = [_compPrefs[@"x11Decorations"] boolValue];
    _x11DecorationsCheck.state = x11Dec ? NSControlStateValueOn : NSControlStateValueOff;

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

    /* ---- Session ---- */
    NSArray *rawSessionItems = _sessionPrefs[@"sessionItems"];
    _sessionItems = [NSMutableArray array];
    for (NSDictionary *d in rawSessionItems) {
        [_sessionItems addObject:[d mutableCopy]];
    }
    [_sessionItemsTable reloadData];

    /* ---- Desktop ---- */
    _bgImagePathField.stringValue  = _desktopPrefs[@"backgroundImagePath"] ?: @"";
    BOOL rotating = [_desktopPrefs[@"rotatingImages"] boolValue];
    _rotatingCheck.state = rotating ? NSControlStateValueOn : NSControlStateValueOff;
    _bgFolderPathField.stringValue = _desktopPrefs[@"rotatingImagesFolder"] ?: @"";
    NSInteger secs = [_desktopPrefs[@"rotationInterval"] integerValue];
    if (secs <= 0) secs = 30;
    _intervalSlider.integerValue = sliderPosForInterval(secs);
    _intervalLabel.stringValue   = intervalLabel(intervalForSliderPos(_intervalSlider.integerValue));
    [self _updateRotatingControlsEnabled:rotating];
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
- (IBAction)toggleX11Decorations:(id)sender { }
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
#pragma mark - IBActions – Session

- (IBAction)addSessionItem:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes    = @[@"app"];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles       = NO;
    [panel beginSheetModalForWindow:self.mainView.window ?: [NSApp mainWindow]
                  completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSString *path = panel.URL.path;
        NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
        NSDictionary *entry = @{
            @"name":    name,
            @"path":    path,
            @"enabled": @YES,
        };
        [self->_sessionItems addObject:[entry mutableCopy]];
        [self->_sessionItemsTable reloadData];
    }];
}

- (IBAction)removeSessionItem:(id)sender
{
    NSInteger row = _sessionItemsTable.selectedRow;
    if (row < 0 || row >= (NSInteger)_sessionItems.count) return;
    [_sessionItems removeObjectAtIndex:(NSUInteger)row];
    [_sessionItemsTable reloadData];
}

/* ---------------------------------------------------------------------- */
#pragma mark - IBActions – Desktop

- (void)_updateRotatingControlsEnabled:(BOOL)enabled
{
    _bgFolderPathField.enabled    = enabled;
    _bgFolderChooseButton.enabled = enabled;
    _intervalSlider.enabled       = enabled;
    _intervalLabel.textColor      = enabled
        ? [NSColor controlTextColor] : [NSColor disabledControlTextColor];
}

- (IBAction)chooseBgImage:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes   = @[@"png", @"jpg", @"jpeg"];
    panel.canChooseFiles     = YES;
    panel.canChooseDirectories = NO;
    [panel beginSheetModalForWindow:self.mainView.window ?: [NSApp mainWindow]
                  completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        self->_bgImagePathField.stringValue = panel.URL.path ?: @"";
    }];
}

- (IBAction)toggleRotating:(id)sender
{
    BOOL on = (_rotatingCheck.state == NSControlStateValueOn);
    [self _updateRotatingControlsEnabled:on];
}

- (IBAction)chooseBgFolder:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles        = NO;
    panel.canChooseDirectories  = YES;
    panel.canCreateDirectories  = NO;
    [panel beginSheetModalForWindow:self.mainView.window ?: [NSApp mainWindow]
                  completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        self->_bgFolderPathField.stringValue = panel.URL.path ?: @"";
    }];
}

- (IBAction)intervalChanged:(id)sender
{
    NSInteger pos  = _intervalSlider.integerValue;
    NSInteger secs = intervalForSliderPos(pos);
    _intervalLabel.stringValue = intervalLabel(secs);
}

/* ---------------------------------------------------------------------- */
#pragma mark - GNUstep theme colour extraction

/**
 * Read the visual parameters from the currently active GNUstep theme and
 * return a dictionary of RRGGBBAA hex strings for every key the compositor's
 * AmbrosiaDecoration.updateColorsFromDictionary: understands.
 *
 * For the Milk theme the gradient and stroke colours are taken directly from
 * the Milk source (Milk+Drawings.m / Milk.m) because they are hardcoded there
 * and not exposed through the standard NSColor named-colour lookup.
 * For all other themes we fall back to the system named colours.
 */
- (NSDictionary *)currentThemeDecorationColors
{
    /* Determine active theme name via GSTheme if available */
    NSString *themeName = @"";
    Class gsThemeClass = NSClassFromString(@"GSTheme");
    if (gsThemeClass) {
        id theme = [gsThemeClass performSelector:@selector(theme)];
        if (theme && [theme respondsToSelector:@selector(name)])
            themeName = [theme performSelector:@selector(name)] ?: @"";
    }

    BOOL isMilk = ([themeName rangeOfString:@"Milk"
                                    options:NSCaseInsensitiveSearch].location != NSNotFound);

    if (isMilk) {
        /* Exact values from Milk+Drawings.m _windowTitlebarGradient
         * and Milk.m controlStrokeColor / ThemeColors windowBackgroundColor. */
        return @{
            /* Active gradient: white → (0.863, 0.863, 0.871) */
            @"titlebarGradientTopColor":    @"FFFFFFFF",
            @"titlebarGradientBottomColor": @"DCDCDEFF",
            /* Inactive: subtle neutral grey fade */
            @"titlebarInactiveTopColor":    @"F0F0F0FF",
            @"titlebarInactiveBottomColor": @"E0E0E0FF",
            /* controlStrokeColor = (0.4, 0.4, 0.4) */
            @"titlebarSeparatorColor":      @"666666FF",
            @"windowBorderColor":           @"666666FF",
            /* windowBackgroundColor ≈ (0.863, 0.863, 0.863) */
            @"windowBodyColor":             @"DCDCDCFF",
            /* Standard bezel button colours — no colour coding in Milk */
            @"buttonActiveColor":           @"D9D9D9FF",
            @"buttonInactiveColor":         @"B8B8B8B3",
        };
    }

    /* --- Generic fallback: derive from current theme's named colours --- */
    NSColor *wfColor = [[NSColor windowFrameColor]
                         colorUsingColorSpaceName:NSCalibratedRGBColorSpace]
                    ?: [NSColor colorWithCalibratedWhite:0.22f alpha:0.96f];
    NSColor *bgColor = [[NSColor windowBackgroundColor]
                         colorUsingColorSpaceName:NSCalibratedRGBColorSpace]
                    ?: [NSColor colorWithCalibratedWhite:0.86f alpha:1.f];
    NSColor *shColor = [[NSColor controlShadowColor]
                         colorUsingColorSpaceName:NSCalibratedRGBColorSpace]
                    ?: [NSColor colorWithCalibratedWhite:0.40f alpha:1.f];

    /* Gradient top: highlight the frame colour; bottom = frame colour itself */
    NSColor *gradTop = [wfColor highlightWithLevel:0.60f]
                    ?: [NSColor colorWithCalibratedWhite:0.80f alpha:1.f];
    NSColor *gradBot = wfColor;
    NSColor *gradTopI = [wfColor highlightWithLevel:0.80f] ?: gradTop;
    NSColor *gradBotI = [wfColor highlightWithLevel:0.40f] ?: gradBot;
    NSColor *btnA  = [bgColor shadowWithLevel:0.10f] ?: bgColor;
    NSColor *btnI  = [bgColor shadowWithLevel:0.25f] ?: bgColor;

    return @{
        @"titlebarGradientTopColor":    [self hexStringFromColor:gradTop],
        @"titlebarGradientBottomColor": [self hexStringFromColor:gradBot],
        @"titlebarInactiveTopColor":    [self hexStringFromColor:gradTopI],
        @"titlebarInactiveBottomColor": [self hexStringFromColor:gradBotI],
        @"titlebarSeparatorColor":      [self hexStringFromColor:shColor],
        @"windowBorderColor":           [self hexStringFromColor:shColor],
        @"windowBodyColor":             [self hexStringFromColor:bgColor],
        @"buttonActiveColor":           [self hexStringFromColor:btnA],
        @"buttonInactiveColor":         [self hexStringFromColor:btnI],
    };
}

/* ---------------------------------------------------------------------- */
#pragma mark - Apply / Revert

- (IBAction)applyChanges:(id)sender
{
    /* ---- Compositor ---- */
    BOOL x11Dec = (_x11DecorationsCheck.state == NSControlStateValueOn);
    _compPrefs[@"windowTransparency"]    = @(_transparencySlider.doubleValue);
    _compPrefs[@"serverSideDecorations"] = @(_enableDecorationsCheck.state == NSControlStateValueOn);
    _compPrefs[@"enableBlur"]            = @(_enableBlurCheck.state == NSControlStateValueOn);
    _compPrefs[@"decorationTheme"]       = _decorationThemePopUp.titleOfSelectedItem ?: @"Default";
    _compPrefs[@"titlebarColor"]         = [self hexStringFromColor:_titlebarColorWell.color];
    _compPrefs[@"borderColor"]           = [self hexStringFromColor:_borderColorWell.color];
    _compPrefs[@"buttonCloseColor"]      = [self hexStringFromColor:_buttonCloseColorWell.color];
    _compPrefs[@"buttonMinColor"]        = [self hexStringFromColor:_buttonMinColorWell.color];
    _compPrefs[@"buttonMaxColor"]        = [self hexStringFromColor:_buttonMaxColorWell.color];
    _compPrefs[@"x11Decorations"]        = @(x11Dec);

    /* When X11 decorations are enabled, bake in the current GNUstep theme
     * colours so the compositor can draw them without needing AppKit.     */
    if (x11Dec) {
        NSDictionary *themeColors = [self currentThemeDecorationColors];
        [_compPrefs addEntriesFromDictionary:themeColors];
    }

    SavePlist(_compPrefs, _compPrefsPath);

    /* ---- Dock ---- */
    NSString *pos = @"bottom";
    NSString *previousPos = _dockPrefs[@"dockPosition"] ?: @"bottom";
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
    if (![previousPos isEqualToString:pos]) {
        KillRunningDockProcess();
    }

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

    /* Build compositor notification — include all keys the compositor reads. */
    NSMutableDictionary *compNotif = [@{
        @"windowTransparency":    _compPrefs[@"windowTransparency"],
        @"serverSideDecorations": _compPrefs[@"serverSideDecorations"],
        @"enableBlur":            _compPrefs[@"enableBlur"],
        @"decorationTheme":       _compPrefs[@"decorationTheme"],
        @"x11Decorations":        _compPrefs[@"x11Decorations"] ?: @NO,
    } mutableCopy];
    /* Propagate all theme colour keys recognised by AmbrosiaDecoration */
    NSSet *colorKeys = [NSSet setWithObjects:
        @"titlebarGradientTopColor", @"titlebarGradientBottomColor",
        @"titlebarInactiveTopColor", @"titlebarInactiveBottomColor",
        @"titlebarSeparatorColor",   @"windowBorderColor",
        @"windowBodyColor",          @"buttonActiveColor", @"buttonInactiveColor", nil];
    for (NSString *key in colorKeys) {
        if (_compPrefs[key]) compNotif[key] = _compPrefs[key];
    }
    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:kCompPrefsChanged
                   object:nil
                 userInfo:compNotif
     deliverImmediately:YES];

    /* ---- Session ---- */
    _sessionPrefs[@"sessionItems"] = [_sessionItems copy];
    SavePlist(_sessionPrefs, _sessionPrefsPath);

    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:kSessionPrefsChanged
                   object:nil
                 userInfo:@{ @"sessionItems": _sessionPrefs[@"sessionItems"] ?: @[] }
     deliverImmediately:YES];

    /* ---- Desktop ---- */
    NSInteger sliderPos   = _intervalSlider.integerValue;
    NSInteger intervalSec = intervalForSliderPos(sliderPos);
    BOOL      rotating    = (_rotatingCheck.state == NSControlStateValueOn);

    _desktopPrefs[@"backgroundImagePath"]   = [_bgImagePathField.stringValue copy] ?: @"";
    _desktopPrefs[@"rotatingImages"]        = @(rotating);
    _desktopPrefs[@"rotatingImagesFolder"]  = [_bgFolderPathField.stringValue copy] ?: @"";
    _desktopPrefs[@"rotationInterval"]      = @(intervalSec);
    SavePlist(_desktopPrefs, _desktopPrefsPath);

    [[NSDistributedNotificationCenter defaultCenter]
     postNotificationName:kDesktopPrefsChanged
                   object:nil
                 userInfo:[_desktopPrefs copy]
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
    if (tv == _sessionItemsTable) return (NSInteger)_sessionItems.count;
    return (NSInteger)_dockItems.count;
}

- (id)tableView:(NSTableView *)tv
objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)row
{
    if (tv == _sessionItemsTable) {
        NSDictionary *item = _sessionItems[row];
        if ([col.identifier isEqualToString:@"enabled"])
            return @([item[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff);
        if ([col.identifier isEqualToString:@"name"])        return item[@"name"];
        if ([col.identifier isEqualToString:@"sessionPath"]) return item[@"path"];
        return @"";
    }
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
    if (tv == _sessionItemsTable) {
        NSMutableDictionary *item = (NSMutableDictionary *)_sessionItems[row];
        if ([col.identifier isEqualToString:@"enabled"])
            item[@"enabled"] = @([obj intValue] == NSControlStateValueOn);
        else if ([col.identifier isEqualToString:@"name"])
            item[@"name"] = obj;
        return;
    }
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
