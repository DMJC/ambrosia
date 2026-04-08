#ifndef AMBROSIA_PREFS_MODULE_H
#define AMBROSIA_PREFS_MODULE_H

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <PreferencePanes/PreferencePanes.h>

/**
 * AmbrosiaPrefsModule — GNUstep PreferencePane bundle for configuring
 * the Ambrosia Wayland compositor and dock.
 *
 * Sections:
 *   • Compositor  – transparency, decoration theme, compositor flags
 *   • Dock        – icon size, zoom factor, position, auto-hide, items
 */
@interface AmbrosiaPrefsModule : NSPreferencePane

/* Compositor settings outlets */
@property (nonatomic, strong) IBOutlet NSSlider       *transparencySlider;
@property (nonatomic, strong) IBOutlet NSTextField    *transparencyLabel;
@property (nonatomic, strong) IBOutlet NSButton       *enableDecorationsCheck;
@property (nonatomic, strong) IBOutlet NSPopUpButton  *decorationThemePopUp;
@property (nonatomic, strong) IBOutlet NSButton       *enableBlurCheck;
@property (nonatomic, strong) IBOutlet NSColorWell    *titlebarColorWell;
@property (nonatomic, strong) IBOutlet NSColorWell    *borderColorWell;
@property (nonatomic, strong) IBOutlet NSColorWell    *buttonCloseColorWell;
@property (nonatomic, strong) IBOutlet NSColorWell    *buttonMinColorWell;
@property (nonatomic, strong) IBOutlet NSColorWell    *buttonMaxColorWell;

/* Dock settings outlets */
@property (nonatomic, strong) IBOutlet NSSlider       *iconSizeSlider;
@property (nonatomic, strong) IBOutlet NSTextField    *iconSizeLabel;
@property (nonatomic, strong) IBOutlet NSSlider       *zoomFactorSlider;
@property (nonatomic, strong) IBOutlet NSTextField    *zoomFactorLabel;
@property (nonatomic, strong) IBOutlet NSSegmentedControl *positionControl;
@property (nonatomic, strong) IBOutlet NSButton       *autoHideCheck;
@property (nonatomic, strong) IBOutlet NSButton       *showRunningIndicatorCheck;
@property (nonatomic, strong) IBOutlet NSTableView    *dockItemsTable;
@property (nonatomic, strong) IBOutlet NSButton       *addItemButton;
@property (nonatomic, strong) IBOutlet NSButton       *removeItemButton;

/* Tab view for switching sections */
@property (nonatomic, strong) IBOutlet NSTabView      *tabView;

/* IBActions */
- (IBAction)transparencyChanged:(id)sender;
- (IBAction)toggleDecorations:(id)sender;
- (IBAction)decorationThemeChanged:(id)sender;
- (IBAction)toggleBlur:(id)sender;
- (IBAction)titlebarColorChanged:(id)sender;
- (IBAction)borderColorChanged:(id)sender;
- (IBAction)buttonColorsChanged:(id)sender;

- (IBAction)iconSizeChanged:(id)sender;
- (IBAction)zoomFactorChanged:(id)sender;
- (IBAction)dockPositionChanged:(id)sender;
- (IBAction)toggleAutoHide:(id)sender;
- (IBAction)toggleRunningIndicator:(id)sender;
- (IBAction)addDockItem:(id)sender;
- (IBAction)removeDockItem:(id)sender;

- (IBAction)applyChanges:(id)sender;
- (IBAction)revertChanges:(id)sender;

@end

#endif /* AMBROSIA_PREFS_MODULE_H */
