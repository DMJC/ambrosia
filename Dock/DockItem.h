#ifndef DOCK_ITEM_H
#define DOCK_ITEM_H

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, DockItemType) {
    DockItemTypeApp       = 0,  /**< Pinned application */
    DockItemTypeSeparator = 1,  /**< Visual separator   */
    DockItemTypeRunningApp = 2, /**< Transient running app (not pinned) */
    DockItemTypeFolder    = 3,  /**< Folder shortcut    */
    DockItemTypeRecycler  = 4,  /**< The recycler widget (always last, never persisted) */
};

@interface DockItem : NSObject <NSCoding, NSCopying>

@property (nonatomic, copy)   NSString     *label;
@property (nonatomic, copy)   NSString     *bundleIdentifier;
@property (nonatomic, copy)   NSString     *launchPath;      /**< Absolute path to .app bundle or folder */
@property (nonatomic, strong) NSImage      *icon;
@property (nonatomic)         DockItemType  itemType;
@property (nonatomic)         BOOL          isRunning;
@property (nonatomic)         BOOL          keepInDock;       /**< Persisted slot */
@property (nonatomic)         NSInteger     pid;             /**< Process ID while running; 0 if unknown */
@property (nonatomic, weak)   NSRunningApplication *runningApp;

/** Load the icon from the bundle at launchPath */
- (void)reloadIcon;

@end

#endif /* DOCK_ITEM_H */
