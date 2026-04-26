#ifndef AMBROSIA_MODULE_H
#define AMBROSIA_MODULE_H

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <PreferencePanes/PreferencePanes.h>

/**
 * AmbrosiaModule — GNUstep PreferencePane bundle for configuring
 * the Ambrosia Wayland compositor and dock.
 *
 * Sections:
 *   • Compositor  – transparency, decoration theme, compositor flags
 *   • Dock        – icon size, zoom factor, position, auto-hide, items
 */
@interface AmbrosiaModule : NSPreferencePane
{
  BOOL loaded;
}
/* Compositor settings outlets */
@property (nonatomic, strong) IBOutlet NSSlider       *transparencySlider;
@property (nonatomic, strong) IBOutlet NSTextField    *transparencyLabel;
@property (nonatomic, strong) IBOutlet NSButton       *enableDecorationsCheck;
@property (nonatomic, strong) IBOutlet NSPopUpButton  *decorationThemePopUp;
@property (nonatomic, strong) IBOutlet NSButton       *enableBlurCheck;
@property (nonatomic, strong) IBOutlet NSButton       *x11DecorationsCheck;
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

/* Session settings outlets */
@property (nonatomic, strong) IBOutlet NSTableView    *sessionItemsTable;
@property (nonatomic, strong) IBOutlet NSButton       *addSessionItemButton;
@property (nonatomic, strong) IBOutlet NSButton       *removeSessionItemButton;

/* Desktop settings outlets */
@property (nonatomic, strong) IBOutlet NSTextField    *bgImagePathField;
@property (nonatomic, strong) IBOutlet NSButton       *bgImageChooseButton;
@property (nonatomic, strong) IBOutlet NSButton       *rotatingCheck;
@property (nonatomic, strong) IBOutlet NSTextField    *bgFolderPathField;
@property (nonatomic, strong) IBOutlet NSButton       *bgFolderChooseButton;
@property (nonatomic, strong) IBOutlet NSSlider       *intervalSlider;
@property (nonatomic, strong) IBOutlet NSTextField    *intervalLabel;

/* Tab view for switching sections */
@property (nonatomic, strong) IBOutlet NSTabView      *tabView;

/* IBActions */
- (IBAction)transparencyChanged:(id)sender;
- (IBAction)toggleDecorations:(id)sender;
- (IBAction)decorationThemeChanged:(id)sender;
- (IBAction)toggleBlur:(id)sender;
- (IBAction)toggleX11Decorations:(id)sender;
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

- (IBAction)addSessionItem:(id)sender;
- (IBAction)removeSessionItem:(id)sender;

- (IBAction)chooseBgImage:(id)sender;
- (IBAction)toggleRotating:(id)sender;
- (IBAction)chooseBgFolder:(id)sender;
- (IBAction)intervalChanged:(id)sender;

- (IBAction)applyChanges:(id)sender;
- (IBAction)revertChanges:(id)sender;

@end

#endif /* AMBROSIA_MODULE_H */
