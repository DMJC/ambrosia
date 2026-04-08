#import "DockView.h"
#import "DockController.h"
#import "DockItem.h"

static const CGFloat kItemPadding    = 8.0;
static const CGFloat kDockPadding    = 10.0;
static const CGFloat kRunningDotSize = 4.0;
static const CGFloat kRunningDotGap  = 3.0;
static const CGFloat kZoomRadius     = 80.0;

@interface DockView ()
@property (nonatomic) NSInteger      hoveredIndex;
@property (nonatomic) NSPoint        mouseLocation;
@property (nonatomic) NSInteger      draggingFromIndex;
@property (nonatomic) NSInteger      dropTargetIndex;
@end

@implementation DockView {
    NSTrackingRectTag _trackingTag;
    BOOL              _hasTrackingRect;
    BOOL              _isDragging;
}

@synthesize controller       = _controller;
@synthesize baseIconSize     = _baseIconSize;
@synthesize maxZoomFactor    = _maxZoomFactor;
@synthesize isDragging       = _isDragging;

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _baseIconSize      = 48.0;
    _maxZoomFactor     = 1.7;
    _hoveredIndex      = -1;
    _draggingFromIndex = -1;
    _dropTargetIndex   = -1;

    [self registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];
    return self;
}

- (BOOL)isFlipped         { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

/* ---------------------------------------------------------------------- */
#pragma mark - Tracking rect (GNUstep-compatible mouse tracking)

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
        /* Need mouse-moved events for zoom */
        [self.window setAcceptsMouseMovedEvents:YES];
    }
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self resetTrackingRect];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self resetTrackingRect];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Layout helpers

- (CGFloat)zoomForIndex:(NSInteger)idx
{
    if (_hoveredIndex < 0) return 1.0;
    NSRect r = [self rectForIndex:idx useBaseSize:YES];
    CGFloat dist = fabs(_mouseLocation.x - NSMidX(r));
    if (dist >= kZoomRadius) return 1.0;
    CGFloat t = 1.0 - dist / kZoomRadius;
    return 1.0 + (_maxZoomFactor - 1.0) * sin(t * M_PI_2);
}

- (NSRect)rectForIndex:(NSInteger)idx useBaseSize:(BOOL)useBase
{
    NSArray *items = _controller.items;
    CGFloat x = kDockPadding;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        CGFloat size = useBase ? _baseIconSize : (_baseIconSize * [self zoomForIndex:i]);
        if (i == idx) {
            CGFloat y = kDockPadding + kRunningDotSize + kRunningDotGap;
            return NSMakeRect(x, y, size, size);
        }
        x += size + kItemPadding;
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

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = self.bounds;

    /* Background */
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 2, 2)
                                                       xRadius:12 yRadius:12];
    [[NSColor colorWithCalibratedWhite:0.12 alpha:0.82] set];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:0.5 alpha:0.3] set];
    [bg stroke];

    NSArray *items = _controller.items;
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        DockItem *item = items[i];
        if (!item.icon) continue;
        if (_isDragging && i == _draggingFromIndex) continue;

        /* Drop indicator */
        if (i == _dropTargetIndex) {
            NSRect r = [self rectForIndex:i useBaseSize:NO];
            [[NSColor colorWithCalibratedRed:0.3 green:0.6 blue:1.0 alpha:0.7] set];
            NSRectFill(NSMakeRect(r.origin.x - 2, r.origin.y, 2, r.size.height));
        }

        NSRect iconRect = [self rectForIndex:i useBaseSize:NO];

        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowOffset     = NSMakeSize(0, -2);
        shadow.shadowBlurRadius = 6;
        shadow.shadowColor      = [NSColor colorWithCalibratedWhite:0 alpha:0.6];
        [shadow set];
        /* NSCompositeSourceOver is the GNUstep name */
        [item.icon drawInRect:iconRect
                     fromRect:NSZeroRect
                    operation:NSCompositeSourceOver
                     fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];

        /* Running dot */
        if (item.isRunning) {
            CGFloat dotX = NSMidX(iconRect) - kRunningDotSize * 0.5;
            CGFloat dotY = kDockPadding * 0.4;
            [[NSColor colorWithCalibratedWhite:0.9 alpha:0.85] set];
            [[NSBezierPath bezierPathWithOvalInRect:
              NSMakeRect(dotX, dotY, kRunningDotSize, kRunningDotSize)] fill];
        }

        /* Hover label */
        if (i == _hoveredIndex) {
            NSString *label = item.label
                ?: [[item.launchPath lastPathComponent]
                    stringByDeletingPathExtension];
            if (label.length > 0) {
                NSDictionary *attrs = @{
                    NSFontAttributeName:            [NSFont systemFontOfSize:11],
                    NSForegroundColorAttributeName: [NSColor whiteColor],
                };
                NSSize ts = [label sizeWithAttributes:attrs];
                NSRect lr = NSMakeRect(NSMidX(iconRect) - ts.width * 0.5 - 4,
                                       NSMaxY(iconRect) + 4,
                                       ts.width + 8, ts.height + 4);
                NSBezierPath *lbg = [NSBezierPath bezierPathWithRoundedRect:lr
                                                                    xRadius:4 yRadius:4];
                [[NSColor colorWithCalibratedWhite:0.1 alpha:0.85] set];
                [lbg fill];
                [label drawAtPoint:NSMakePoint(lr.origin.x + 4, lr.origin.y + 2)
                    withAttributes:attrs];
            }
        }
    }
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
    NSPoint pt  = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:pt];
    if (idx < 0) return;
    if (event.clickCount == 2) {
        [_controller launchItem:_controller.items[idx]];
        return;
    }
    _draggingFromIndex = idx;
}

- (void)mouseUp:(NSEvent *)event
{
    NSPoint pt  = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:pt];
    if (!_isDragging && idx >= 0 && idx == _draggingFromIndex) {
        [_controller launchItem:_controller.items[idx]];
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

    DockItem *item = _controller.items[_draggingFromIndex];
    NSRect iconRect = [self rectForIndex:_draggingFromIndex useBaseSize:NO];

    /* Write the source index to the drag pasteboard */
    NSPasteboard *pb = [NSPasteboard pasteboardWithName:NSDragPboard];
    [pb declareTypes:@[NSStringPboardType] owner:self];
    [pb setString:[@(_draggingFromIndex) stringValue] forType:NSStringPboardType];

    NSImage *dragImg = item.icon
        ?: [NSImage imageNamed:@"NSApplicationIcon"];
    if (!dragImg) dragImg = [[NSImage alloc] initWithSize:iconRect.size];

    /* GNUstep drag API */
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
    NSPoint pt  = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:pt];
    NSMenu *menu;
    if (idx >= 0)
        menu = [_controller contextMenuForItem:_controller.items[idx]];
    else {
        menu = [[NSMenu alloc] initWithTitle:@"Dock"];
        [menu addItemWithTitle:@"Dock Preferences…"
                        action:@selector(openDockPrefs:)
                 keyEquivalent:@""];
    }
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSDraggingSource (informal protocol, GNUstep-compatible)

/** Called by GNUstep drag machinery to determine allowed operations */
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    return NSDragOperationMove;
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSDraggingDestination (informal protocol)

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    return NSDragOperationMove;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
    NSPoint pt = [self convertPoint:sender.draggingLocation fromView:nil];
    _dropTargetIndex = [self indexAtPoint:pt];
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

    /* Internal reorder: pasteboard contains the source index as a string */
    NSString *indexStr = [pb stringForType:NSStringPboardType];
    if (indexStr && _draggingFromIndex >= 0) {
        NSPoint pt = [self convertPoint:sender.draggingLocation fromView:nil];
        NSInteger toIndex = [self indexAtPoint:pt];
        if (toIndex < 0)
            toIndex = (NSInteger)_controller.items.count - 1;
        [_controller moveItemFromIndex:_draggingFromIndex toIndex:toIndex];
        _draggingFromIndex = -1;
        _dropTargetIndex   = -1;
        [self reloadItems];
        return YES;
    }

    /* File drop — add .app bundles */
    NSArray *files = [pb propertyListForType:NSFilenamesPboardType];
    for (NSString *path in files) {
        if ([path.pathExtension isEqualToString:@"app"])
            [_controller addAppAtPath:path];
    }
    _dropTargetIndex = -1;
    [self reloadItems];
    return YES;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Public

- (void)reloadItems          { [self setNeedsDisplay:YES]; }
- (void)insertItemAtIndex:(NSInteger)index { [self setNeedsDisplay:YES]; }
- (void)removeItemAtIndex:(NSInteger)index { [self setNeedsDisplay:YES]; }

@end
