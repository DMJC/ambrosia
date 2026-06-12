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
 *   • Compositor  – transparency, compositor flags
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
@property (nonatomic, strong) IBOutlet NSButton       *enableBlurCheck;
@property (nonatomic, strong) IBOutlet NSButton       *x11DecorationsCheck;

/* Dock settings outlets */
@property (nonatomic, strong) IBOutlet NSSlider       *iconSizeSlider;
@property (nonatomic, strong) IBOutlet NSTextField    *iconSizeLabel;
@property (nonatomic, strong) IBOutlet NSSlider       *zoomFactorSlider;
@property (nonatomic, strong) IBOutlet NSTextField    *zoomFactorLabel;
@property (nonatomic, strong) IBOutlet NSSegmentedControl *positionControl;
@property (nonatomic, strong) IBOutlet NSButton       *autoHideCheck;
@property (nonatomic, strong) IBOutlet NSSlider       *autoHideDelaySlider;
@property (nonatomic, strong) IBOutlet NSTextField    *autoHideDelayLabel;
@property (nonatomic, strong) IBOutlet NSButton       *showRunningIndicatorCheck;
@property (nonatomic, strong) IBOutlet NSTableView    *dockItemsTable;
@property (nonatomic, strong) IBOutlet NSButton       *addItemButton;
@property (nonatomic, strong) IBOutlet NSButton       *removeItemButton;

/* Session settings outlets */
@property (nonatomic, strong) IBOutlet NSTableView    *sessionItemsTable;
@property (nonatomic, strong) IBOutlet NSButton       *addSessionItemButton;
@property (nonatomic, strong) IBOutlet NSButton       *removeSessionItemButton;
@property (nonatomic, strong) IBOutlet NSTableView    *startupCommandsTable;
@property (nonatomic, strong) IBOutlet NSButton       *addStartupCommandButton;
@property (nonatomic, strong) IBOutlet NSButton       *removeStartupCommandButton;

/* Desktop settings outlets */
@property (nonatomic, strong) IBOutlet NSTextField    *bgImagePathField;
@property (nonatomic, strong) IBOutlet NSButton       *bgImageChooseButton;
/* Background mode radio buttons (replaces the old rotatingCheck checkbox) */
@property (nonatomic, strong) IBOutlet NSButton       *bgImageRadio;
@property (nonatomic, strong) IBOutlet NSButton       *rotatingRadio;
@property (nonatomic, strong) IBOutlet NSButton       *bg3DRadio;
/* Rotating-mode controls */
@property (nonatomic, strong) IBOutlet NSTextField    *bgFolderPathField;
@property (nonatomic, strong) IBOutlet NSButton       *bgFolderChooseButton;
@property (nonatomic, strong) IBOutlet NSSlider       *intervalSlider;
@property (nonatomic, strong) IBOutlet NSTextField    *intervalLabel;
/* 3D-mode controls */
@property (nonatomic, strong) IBOutlet NSTextField    *sceneFilePathField;
@property (nonatomic, strong) IBOutlet NSButton       *sceneFileChooseButton;

/* Tab view for switching sections */
@property (nonatomic, strong) IBOutlet NSTabView      *tabView;

/* IBActions */
- (IBAction)transparencyChanged:(id)sender;
- (IBAction)toggleDecorations:(id)sender;
- (IBAction)toggleBlur:(id)sender;
- (IBAction)toggleX11Decorations:(id)sender;

- (IBAction)iconSizeChanged:(id)sender;
- (IBAction)zoomFactorChanged:(id)sender;
- (IBAction)dockPositionChanged:(id)sender;
- (IBAction)toggleAutoHide:(id)sender;
- (IBAction)autoHideDelayChanged:(id)sender;
- (IBAction)toggleRunningIndicator:(id)sender;
- (IBAction)addDockItem:(id)sender;
- (IBAction)removeDockItem:(id)sender;

- (IBAction)addSessionItem:(id)sender;
- (IBAction)removeSessionItem:(id)sender;
- (IBAction)addStartupCommand:(id)sender;
- (IBAction)removeStartupCommand:(id)sender;

- (IBAction)chooseBgImage:(id)sender;
- (IBAction)backgroundModeChanged:(id)sender;
- (IBAction)chooseBgFolder:(id)sender;
- (IBAction)intervalChanged:(id)sender;
- (IBAction)chooseSceneFile:(id)sender;

- (IBAction)applyChanges:(id)sender;
- (IBAction)revertChanges:(id)sender;

@end

#endif /* AMBROSIA_MODULE_H */
