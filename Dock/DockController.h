#ifndef DOCK_CONTROLLER_H
#define DOCK_CONTROLLER_H

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "DockItem.h"

@class DockView;

/** Manages dock state: item list, persistence, running-app tracking. */
@interface DockController : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) NSPanel     *dockPanel;
@property (nonatomic, strong) DockView    *dockView;
@property (nonatomic, readonly) NSMutableArray<DockItem *> *items;

/** Path to the preferences plist */
@property (nonatomic, copy) NSString *preferencesPath;

/** Icon size and zoom factor (read from prefs) */
@property (nonatomic) CGFloat iconSize;
@property (nonatomic) CGFloat zoomFactor;

/** Dock position: bottom, left, right */
@property (nonatomic, copy) NSString *dockPosition;

- (instancetype)init;

/** Load items from persisted preferences */
- (void)loadPreferences;

/** Persist current item list and settings */
- (void)savePreferences;

/** Launch an app or open a folder for the given dock item */
- (void)launchItem:(DockItem *)item;

/** Move item from index to index (from drag-and-drop reorder) */
- (void)moveItemFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex;

/**
 * Add a new item to the dock from a filesystem path.
 * Handles .app bundles (DockItemTypeApp) and directories (DockItemTypeFolder).
 * Silently ignores duplicates and system-internal apps.
 */
- (void)addItemAtPath:(NSString *)path;

/** Remove an item from the dock; does not terminate or delete anything on disk */
- (void)removeItem:(DockItem *)item;

/** Build and return the contextual menu for a dock item */
- (NSMenu *)contextMenuForItem:(DockItem *)item;

/** Index of the recycler item (always last); -1 if not present */
- (NSInteger)recyclerIndex;

/** Reposition the dock panel for the current screen and position setting */
- (void)repositionDock;

/** Apply updated preferences (called by SystemPreferences applet) */
- (void)applyPreferences:(NSDictionary *)prefs;

@end

#endif /* DOCK_CONTROLLER_H */
