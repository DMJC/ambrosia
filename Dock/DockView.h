#ifndef DOCK_VIEW_H
#define DOCK_VIEW_H

#import <AppKit/AppKit.h>
#import "DockItem.h"

@class DockController;

/** The main dock drawing surface. Handles layout, zoom, drag-and-drop, and hit testing. */
/* NSDraggingDestination and NSDraggingSource are informal protocols in GNUstep */
@interface DockView : NSView

@property (nonatomic, weak)   DockController *controller;

/** Base (non-zoomed) icon size in points */
@property (nonatomic) CGFloat baseIconSize;

/** Maximum zoom multiplier for the magnification effect */
@property (nonatomic) CGFloat maxZoomFactor;

/** YES when dock is laid out vertically (left/right position) */
@property (nonatomic) BOOL verticalLayout;

/** YES while a drag is in progress originating from this dock */
@property (nonatomic, readonly) BOOL isDragging;

/** Recomputes layout and redraws after the item list changes */
- (void)reloadItems;

/** Animate adding a new item at index */
- (void)insertItemAtIndex:(NSInteger)index;

/** Animate removing an item */
- (void)removeItemAtIndex:(NSInteger)index;

@end

#endif /* DOCK_VIEW_H */
