#import "DockView.h"
#import "DockController.h"
#import "DockItem.h"

static const CGFloat kItemPadding    = 8.0;
static const CGFloat kDockPadding    = 10.0;
static const CGFloat kRunningDotSize = 4.0;
static const CGFloat kRunningDotGap  = 3.0;
static const CGFloat kZoomRadius     = 80.0;
/* Extra horizontal gap inserted before the recycler icon */
static const CGFloat kRecyclerGap    = 18.0;

@interface DockView ()
@property (nonatomic) NSInteger hoveredIndex;
@property (nonatomic) NSPoint   mouseLocation;
@property (nonatomic) NSInteger draggingFromIndex;
@property (nonatomic) NSInteger dropTargetIndex;
@end

@implementation DockView {
    NSTrackingRectTag _trackingTag;
    BOOL              _hasTrackingRect;
    BOOL              _isDragging;
}

@synthesize controller      = _controller;
@synthesize baseIconSize    = _baseIconSize;
@synthesize maxZoomFactor   = _maxZoomFactor;
@synthesize verticalLayout  = _verticalLayout;
@synthesize isDragging      = _isDragging;

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _baseIconSize      = 48.0;
    _maxZoomFactor     = 1.7;
    _verticalLayout    = NO;
    _hoveredIndex      = -1;
    _draggingFromIndex = -1;
    _dropTargetIndex   = -1;
    [self registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];
    return self;
}

- (BOOL)isFlipped              { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

/* ---------------------------------------------------------------------- */
#pragma mark - Tracking rect

- (void)resetTrackingRect
{
    if (_hasTrackingRect) {
        [self removeTrackingRect:_trackingTag];
        _hasTrackingRect = NO;
    }
    if (self.window) {
        _trackingTag = [self addTrackingRect:self.bounds
                                       owner:self
                                    userData:nil
                                assumeInside:NO];
        _hasTrackingRect = YES;
        [self.window setAcceptsMouseMovedEvents:YES];
    }
}

- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self resetTrackingRect]; }
- (void)setFrameSize:(NSSize)sz { [super setFrameSize:sz]; [self resetTrackingRect]; }

/* ---------------------------------------------------------------------- */
#pragma mark - Layout helpers

- (CGFloat)zoomForIndex:(NSInteger)idx
{
    DockItem *item = _controller.items[(NSUInteger)idx];
    /* Recycler does not magnify */
    if (item.itemType == DockItemTypeRecycler) return 1.0;
    if (_hoveredIndex < 0) return 1.0;
    NSRect r = [self rectForIndex:idx useBaseSize:YES];
    CGFloat dist = _verticalLayout
        ? fabs(_mouseLocation.y - NSMidY(r))
        : fabs(_mouseLocation.x - NSMidX(r));
    if (dist >= kZoomRadius) return 1.0;
    CGFloat t = 1.0 - dist / kZoomRadius;
    return 1.0 + (_maxZoomFactor - 1.0) * sin(t * M_PI_2);
}

/**
 * Returns the icon frame for item at index, in view coordinates.
 * Items after the recycler gap receive an extra kRecyclerGap offset.
 */
- (NSRect)rectForIndex:(NSInteger)idx useBaseSize:(BOOL)useBase
{
    NSArray *items = _controller.items;
    CGFloat x = kDockPadding;
    CGFloat y = kDockPadding;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        DockItem *item = items[(NSUInteger)i];
        /* Insert separator gap immediately before the recycler */
        if (item.itemType == DockItemTypeRecycler) {
            if (_verticalLayout) y += kRecyclerGap;
            else x += kRecyclerGap;
        }
        CGFloat size = useBase ? _baseIconSize
                               : (_baseIconSize * [self zoomForIndex:i]);
        if (i == idx) {
            if (_verticalLayout) {
                return NSMakeRect(kDockPadding + kRunningDotSize + kRunningDotGap,
                                  y, size, size);
            }
            return NSMakeRect(x,
                              kDockPadding + kRunningDotSize + kRunningDotGap,
                              size, size);
        }
        if (_verticalLayout) y += size + kItemPadding;
        else x += size + kItemPadding;
    }
    return NSZeroRect;
}

- (NSInteger)indexAtPoint:(NSPoint)pt
{
    NSArray *items = _controller.items;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        if (NSPointInRect(pt, [self rectForIndex:i useBaseSize:NO])) return i;
    }
    return -1;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Drawing

/**
 * Draw the recycler (trash-can) icon.
 * When highlighted (drag hovering over it) a red tint is applied so the
 * user understands that dropping will remove the item from the dock.
 */
- (void)_drawRecyclerInRect:(NSRect)r highlighted:(BOOL)highlighted
{
    CGFloat cx = NSMidX(r);
    CGFloat cy = NSMidY(r);
    CGFloat s  = MIN(r.size.width, r.size.height); /* effective icon size */
    CGFloat u  = s / 48.0;                          /* scale unit (1.0 @ 48 pt) */

    [NSGraphicsContext saveGraphicsState];

    /* Red glow behind the icon when it is the active drop target */
    if (highlighted) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.25 blue:0.1 alpha:0.35] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, -6 * u, -6 * u)] fill];
    }

    NSColor *bodyColor = highlighted
        ? [NSColor colorWithCalibratedRed:1.0 green:0.5 blue:0.4 alpha:0.95]
        : [NSColor colorWithCalibratedWhite:0.82 alpha:0.9];

    /* ---- Lid ---- */
    [bodyColor set];
    /* Handle on top of the lid */
    NSRect handle = NSMakeRect(cx - 5 * u, cy + 12 * u, 10 * u, 4 * u);
    [[NSBezierPath bezierPathWithRoundedRect:handle xRadius:2 * u yRadius:2 * u] fill];
    /* Lid bar */
    NSRect lid = NSMakeRect(cx - 13 * u, cy + 8 * u, 26 * u, 5 * u);
    [[NSBezierPath bezierPathWithRoundedRect:lid xRadius:2 * u yRadius:2 * u] fill];

    /* ---- Body (slightly tapered) ---- */
    NSBezierPath *body = [NSBezierPath bezierPath];
    [body moveToPoint:NSMakePoint(cx - 11 * u, cy + 8 * u)];
    [body lineToPoint:NSMakePoint(cx - 13 * u, cy - 14 * u)];
    [body lineToPoint:NSMakePoint(cx + 13 * u, cy - 14 * u)];
    [body lineToPoint:NSMakePoint(cx + 11 * u, cy + 8 * u)];
    [body closePath];
    [bodyColor set];
    [body fill];

    /* ---- Vertical lines inside body ---- */
    [[NSColor colorWithCalibratedWhite:0.35 alpha:0.7] set];
    for (int i = -1; i <= 1; i++) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(cx + i * 5 * u, cy + 6 * u)];
        [line lineToPoint:NSMakePoint(cx + i * 5 * u, cy - 11 * u)];
        [line setLineWidth:1.5 * u];
        [line stroke];
    }

    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = self.bounds;
    CGFloat bgH   = _baseIconSize + 22.0;
    NSRect bgRect = _verticalLayout
        ? NSMakeRect(0, 0, bgH, bounds.size.height)
        : NSMakeRect(0, 0, bounds.size.width, bgH);

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bgRect, 2, 2)
                                                       xRadius:12 yRadius:12];
    [[NSColor colorWithCalibratedWhite:0.12 alpha:0.82] set];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:0.5 alpha:0.3] set];
    [bg stroke];

    NSArray *items = _controller.items;

    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        DockItem *item = items[(NSUInteger)i];
        if (_isDragging && i == _draggingFromIndex) continue;

        NSRect iconRect = [self rectForIndex:i useBaseSize:NO];

        /* ---- Recycler: separator line + special drawing ---- */
        if (item.itemType == DockItemTypeRecycler) {
            /* Thin separator line midway through the gap */
            [[NSColor colorWithCalibratedWhite:0.55 alpha:0.45] set];
            if (_verticalLayout) {
                CGFloat sepY = iconRect.origin.y - kRecyclerGap * 0.5;
                NSRectFill(NSMakeRect(kDockPadding, sepY, _baseIconSize + 4, 1.0));
            } else {
                CGFloat sepX = iconRect.origin.x - kRecyclerGap * 0.5;
                NSRectFill(NSMakeRect(sepX, kDockPadding, 1.0, _baseIconSize + 4));
            }

            BOOL highlighted = (i == _dropTargetIndex);
            [self _drawRecyclerInRect:iconRect highlighted:highlighted];

            /* Hover label */
            if (i == _hoveredIndex || highlighted) {
                NSString *lbl = highlighted ? @"Remove from Dock" : @"Recycler";
                [self _drawLabel:lbl aboveRect:iconRect];
            }
            continue;
        }

        /* ---- Drop insertion indicator (blue bar) ---- */
        if (i == _dropTargetIndex) {
            [[NSColor colorWithCalibratedRed:0.3 green:0.6 blue:1.0 alpha:0.7] set];
            if (_verticalLayout) {
                NSRectFill(NSMakeRect(iconRect.origin.x,
                                      iconRect.origin.y - 2,
                                      iconRect.size.width, 2));
            } else {
                NSRectFill(NSMakeRect(iconRect.origin.x - 2,
                                      iconRect.origin.y, 2, iconRect.size.height));
            }
        }

        if (!item.icon) continue;

        /* ---- Icon with drop shadow ---- */
        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow        = [[NSShadow alloc] init];
        shadow.shadowOffset     = NSMakeSize(0, -2);
        shadow.shadowBlurRadius = 6;
        shadow.shadowColor      = [NSColor colorWithCalibratedWhite:0 alpha:0.6];
        [shadow set];
        [item.icon drawInRect:iconRect
                     fromRect:NSZeroRect
                    operation:NSCompositeSourceOver
                     fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];

        /* ---- Running dot ---- */
        if (item.isRunning) {
            CGFloat dotX = _verticalLayout
                ? kDockPadding * 0.4
                : (NSMidX(iconRect) - kRunningDotSize * 0.5);
            CGFloat dotY = _verticalLayout
                ? (NSMidY(iconRect) - kRunningDotSize * 0.5)
                : (kDockPadding * 0.4);
            [[NSColor colorWithCalibratedWhite:0.9 alpha:0.85] set];
            [[NSBezierPath bezierPathWithOvalInRect:
              NSMakeRect(dotX, dotY, kRunningDotSize, kRunningDotSize)] fill];
        }

        /* ---- Hover label ---- */
        if (i == _hoveredIndex) {
            NSString *label = item.label
                ?: [[item.launchPath lastPathComponent] stringByDeletingPathExtension];
            if (label.length) [self _drawLabel:label aboveRect:iconRect];
        }
    }

    (void)dirtyRect;
}

/** Draw a small rounded-rect label centred above iconRect. */
- (void)_drawLabel:(NSString *)label aboveRect:(NSRect)iconRect
{
    NSDictionary *attrs = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor whiteColor],
    };
    NSSize ts  = [label sizeWithAttributes:attrs];
    NSRect lr  = _verticalLayout
        ? NSMakeRect(NSMaxX(iconRect) + 6,
                     NSMidY(iconRect) - (ts.height + 4) * 0.5,
                     ts.width + 8, ts.height + 4)
        : NSMakeRect(NSMidX(iconRect) - ts.width * 0.5 - 4,
                     NSMaxY(iconRect) + 4,
                     ts.width + 8, ts.height + 4);
    NSBezierPath *lbg = [NSBezierPath bezierPathWithRoundedRect:lr xRadius:4 yRadius:4];
    [[NSColor colorWithCalibratedWhite:0.1 alpha:0.85] set];
    [lbg fill];
    [label drawAtPoint:NSMakePoint(lr.origin.x + 4, lr.origin.y + 2)
        withAttributes:attrs];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Mouse events

- (void)mouseMoved:(NSEvent *)event
{
    _mouseLocation = [self convertPoint:event.locationInWindow fromView:nil];
    _hoveredIndex  = [self indexAtPoint:_mouseLocation];
    [self setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)event
{
    _mouseLocation = [self convertPoint:event.locationInWindow fromView:nil];
    _hoveredIndex  = [self indexAtPoint:_mouseLocation];
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event
{
    _hoveredIndex = -1;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint   pt  = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:pt];
    if (idx < 0) return;

    DockItem *item = _controller.items[(NSUInteger)idx];

    /* The recycler cannot be dragged */
    if (item.itemType == DockItemTypeRecycler) return;

    if (event.clickCount == 2) {
        [_controller launchItem:item];
        return;
    }
    _draggingFromIndex = idx;
}

- (void)mouseUp:(NSEvent *)event
{
    NSPoint   pt  = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:pt];
    if (!_isDragging && idx >= 0 && idx == _draggingFromIndex) {
        DockItem *item = _controller.items[(NSUInteger)idx];
        if (item.itemType != DockItemTypeRecycler)
            [_controller launchItem:item];
    }
    _isDragging        = NO;
    _draggingFromIndex = -1;
    _dropTargetIndex   = -1;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (_draggingFromIndex < 0) return;
    if (_isDragging) return;

    _isDragging = YES;

    DockItem *item    = _controller.items[(NSUInteger)_draggingFromIndex];
    NSRect iconRect   = [self rectForIndex:_draggingFromIndex useBaseSize:NO];

    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSDragPboard];
    [pb declareTypes:@[NSStringPboardType] owner:self];
    [pb setString:[@(_draggingFromIndex) stringValue] forType:NSStringPboardType];

    NSImage *dragImg = item.icon ?: [NSImage imageNamed:@"NSApplicationIcon"];
    if (!dragImg) dragImg = [[NSImage alloc] initWithSize:iconRect.size];

    [self dragImage:dragImg
                 at:iconRect.origin
             offset:NSZeroSize
              event:event
         pasteboard:pb
             source:self
          slideBack:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Right-click menu

- (void)rightMouseDown:(NSEvent *)event
{
    NSPoint   pt  = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:pt];

    NSMenu *menu = nil;
    if (idx >= 0) {
        DockItem *item = _controller.items[(NSUInteger)idx];
        if (item.itemType != DockItemTypeRecycler)
            menu = [_controller contextMenuForItem:item];
    }
    if (!menu) {
        menu = [[NSMenu alloc] initWithTitle:@"Dock"];
        [menu addItemWithTitle:@"Dock Preferences…"
                        action:@selector(openDockPrefs:)
                 keyEquivalent:@""];
    }
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSDraggingSource

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    return NSDragOperationMove;
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSDraggingDestination

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    return NSDragOperationMove;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
    NSPoint   pt  = [self convertPoint:sender.draggingLocation fromView:nil];
    NSInteger idx = [self indexAtPoint:pt];
    _dropTargetIndex = idx;
    [self setNeedsDisplay:YES];
    return NSDragOperationMove;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender
{
    _dropTargetIndex = -1;
    [self setNeedsDisplay:YES];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pb = sender.draggingPasteboard;
    NSPoint pt = [self convertPoint:sender.draggingLocation fromView:nil];
    NSInteger toIndex = [self indexAtPoint:pt];

    /* ------ Internal reorder or drop-on-recycler ------ */
    NSString *indexStr = [pb stringForType:NSStringPboardType];
    if (indexStr && _draggingFromIndex >= 0) {
        /* Check if the drop target is the recycler */
        BOOL onRecycler = NO;
        if (toIndex >= 0 && toIndex < (NSInteger)_controller.items.count) {
            onRecycler = (_controller.items[(NSUInteger)toIndex].itemType
                          == DockItemTypeRecycler);
        }

        if (onRecycler) {
            /* Remove the dragged item from the dock */
            DockItem *dragged = _controller.items[(NSUInteger)_draggingFromIndex];
            [_controller removeItem:dragged];
        } else {
            /* Reorder — prevent landing on or after the recycler */
            NSInteger recyclerIdx = [_controller recyclerIndex];
            if (toIndex < 0)
                toIndex = (recyclerIdx >= 0) ? recyclerIdx - 1
                                             : (NSInteger)_controller.items.count - 1;
            if (recyclerIdx >= 0 && toIndex >= recyclerIdx)
                toIndex = recyclerIdx - 1;
            [_controller moveItemFromIndex:_draggingFromIndex toIndex:toIndex];
        }

        _draggingFromIndex = -1;
        _dropTargetIndex   = -1;
        [self reloadItems];
        return YES;
    }

    /* ------ External file/folder drop from a file manager ------ */
    NSArray *files = [pb propertyListForType:NSFilenamesPboardType];
    if (files.count > 0) {
        for (NSString *path in files)
            [_controller addItemAtPath:path];
        _dropTargetIndex = -1;
        [self reloadItems];
        return YES;
    }

    _dropTargetIndex = -1;
    return NO;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Public

- (void)reloadItems          { [self setNeedsDisplay:YES]; }
- (void)insertItemAtIndex:(NSInteger)index { [self setNeedsDisplay:YES]; }
- (void)removeItemAtIndex:(NSInteger)index { [self setNeedsDisplay:YES]; }

@end
