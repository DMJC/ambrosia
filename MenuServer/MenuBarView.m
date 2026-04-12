#import "MenuBarView.h"
#import "MenuBarController.h"
#import "MenuServerProtocol.h"

/* ---- Bar geometry ---- */
static const CGFloat kBarHeight      = 24.0;

/* ---- Bar appearance ---- */
static const CGFloat kBarPad         = 6.0;
static const CGFloat kItemPad        = 6.0;
static const CGFloat kItemGap        = 2.0;
static const CGFloat kSepWidth       = 1.0;
static const CGFloat kSepInset       = 4.0;
static const CGFloat kFontSize       = 11.5;
static const CGFloat kBoldFontSize   = 12.0;
static const CGFloat kHighlightAlpha = 0.25;

/* ---- Dropdown geometry ---- */
static const CGFloat kDropItemH      = 22.0;   /* normal item row height          */
static const CGFloat kDropSepH       = 8.0;    /* separator row height            */
static const CGFloat kDropPadX       = 14.0;   /* horizontal text inset           */
static const CGFloat kDropMinW       = 180.0;  /* minimum dropdown panel width    */
static const CGFloat kDropExtraBot   = 4.0;    /* extra padding below last item   */

/* ---- Hit-region tags ---- */
typedef NS_ENUM(NSInteger, MenuBarRegion) {
    MenuBarRegionNone     = -1,
    MenuBarRegionAmbrosia =  0,
    MenuBarRegionSession  =  1,
    MenuBarRegionMenuItem =  100,  /* items >= 100; index = tag − 100 */
};

/* ---- NSDictionary keys for system-menu item descriptors ---- */
static NSString * const kSysItemTitle    = @"sysTitle";
static NSString * const kSysItemSel     = @"sysSel";     /* NSString selector name */
static NSString * const kSysItemSep     = @"sysSep";     /* @YES = separator row  */

/* ---- Colour / font helpers ---- */
static NSColor *BarBg(void)
{
    return [NSColor colorWithCalibratedRed:0.10 green:0.10 blue:0.16 alpha:1.0];
}
static NSColor *DropBg(void)
{
    return [NSColor colorWithCalibratedRed:0.13 green:0.13 blue:0.20 alpha:1.0];
}
static NSColor *DropBorder(void)
{
    return [NSColor colorWithCalibratedWhite:0.35 alpha:0.9];
}
static NSColor *BarHighlight(void)
{
    return [NSColor colorWithCalibratedWhite:1.0 alpha:kHighlightAlpha];
}
static NSColor *DropHighlight(void)
{
    return [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.80 alpha:0.85];
}
static NSColor *BarSep(void)
{
    return [NSColor colorWithCalibratedWhite:0.40 alpha:0.8];
}
static NSDictionary *NormalAttrs(void)
{
    return @{
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.92 alpha:1.0],
        NSFontAttributeName: [NSFont systemFontOfSize:kFontSize],
    };
}
static NSDictionary *BoldAttrs(void)
{
    return @{
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:1.0],
        NSFontAttributeName: [NSFont boldSystemFontOfSize:kBoldFontSize],
    };
}
static NSDictionary *DisabledAttrs(void)
{
    return @{
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.55 alpha:1.0],
        NSFontAttributeName: [NSFont systemFontOfSize:kFontSize],
    };
}
static NSDictionary *DropItemAttrs(BOOL highlighted)
{
    NSColor *fg = highlighted
        ? [NSColor whiteColor]
        : [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
    return @{
        NSForegroundColorAttributeName: fg,
        NSFontAttributeName: [NSFont systemFontOfSize:kFontSize],
    };
}

/* Centre a string rect vertically inside a bar-item rect */
static NSRect CentreInRect(NSString *s, NSDictionary *a, NSRect r)
{
    NSSize sz = [s sizeWithAttributes:a];
    CGFloat y = r.origin.y + (r.size.height - sz.height) * 0.5;
    return NSMakeRect(r.origin.x, y, sz.width, sz.height);
}

/* ---------------------------------------------------------------------- */

@implementation MenuBarView {
    /* ---- Bar state ---- */
    NSArray   *_activeMenuItems;   /* NSArray<NSDictionary*> from DO app */
    NSString  *_clockString;
    NSTimer   *_clockTimer;

    /* ---- Pre-computed bar hit rects (view coords, isFlipped=YES) ---- */
    NSRect              _ambrosiaRect;
    NSRect              _appNameRect;
    NSMutableArray     *_menuRects;        /* NSValue(NSRect) per clickable top-level item */
    NSMutableArray     *_menuItemIndices;  /* NSNumber: index into _activeMenuItems */
    NSRect              _clockRect;
    NSRect              _sessionRect;
    NSInteger           _pressedRegion;    /* MenuBarRegion; -1 = none */

    /* ---- Inline dropdown state ---- */
    NSInteger           _openTag;          /* which header is open (MenuBarRegion); -1 = none */
    NSArray            *_openDescriptors;  /* items for open dropdown; NSDictionary array */
    NSMutableArray     *_dropdownRects;    /* NSValue(NSRect) per dropdown row (view coords) */
    CGFloat             _dropdownX;        /* left edge of open dropdown */
    CGFloat             _dropdownW;        /* width of open dropdown */
    NSInteger           _hoveredIdx;       /* hovered item index (-1 = none) */
}

/* ---------------------------------------------------------------------- */
#pragma mark - Initialisation

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _menuRects       = [NSMutableArray array];
    _menuItemIndices = [NSMutableArray array];
    _dropdownRects   = [NSMutableArray array];
    _pressedRegion   = MenuBarRegionNone;
    _openTag         = MenuBarRegionNone;
    _hoveredIdx      = -1;

    [self _updateClockString];
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   target:self
                                                 selector:@selector(_tickClock:)
                                                 userInfo:nil
                                                  repeats:YES];
    return self;
}

- (void)dealloc
{
    [_clockTimer invalidate];
    _clockTimer = nil;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Coordinate system

/**
 * Use a top-left origin so the bar occupies y=0…kBarHeight and the
 * dropdown (when expanded) occupies y=kBarHeight…kBarHeight+dropH.
 * This is the natural direction for a menu that drops downward.
 */
- (BOOL)isFlipped { return YES; }

/* ---------------------------------------------------------------------- */
#pragma mark - Public API

- (void)setActiveAppName:(NSString *)appName menuItems:(NSArray *)menuItems
{
    /* If a dropdown is open for an app menu, close it first. */
    if (_openTag >= MenuBarRegionMenuItem) [self _closeDropdown];

    _activeMenuItems = [menuItems copy];
    [self setNeedsDisplay:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Clock

- (void)_updateClockString
{
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss"];
    _clockString = [fmt stringFromDate:[NSDate date]];
}

- (void)_tickClock:(NSTimer *)timer
{
    [self _updateClockString];
    [self setNeedsDisplayInRect:_clockRect];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect  bounds = self.bounds;
    CGFloat W      = bounds.size.width;

    /* Erase the entire view to transparent first.  The panel is non-opaque
     * (backgroundColor = clearColor) so the area outside the bar strip and
     * dropdown box will be fully transparent rather than showing the default
     * grey window background.                                               */
    NSRectFillUsingOperation(bounds, NSCompositeClear);

    /* ================================================================
     * BAR SECTION  (y = 0 … kBarHeight, isFlipped so y increases down)
     * ================================================================ */

    NSRect barBounds = NSMakeRect(0, 0, W, kBarHeight);
    [BarBg() set];
    NSRectFill(barBounds);

    [_menuRects removeAllObjects];
    [_menuItemIndices removeAllObjects];

    CGFloat leftX  = kBarPad;
    CGFloat rightX = W - kBarPad;

    /* ---- RIGHT SIDE ---- */
    NSString *sessionStr = @"\u23FB";
    NSSize sessionSz = [sessionStr sizeWithAttributes:NormalAttrs()];
    CGFloat sessionW = sessionSz.width + kItemPad * 2;
    _sessionRect = NSMakeRect(rightX - sessionW, 0, sessionW, kBarHeight);
    [self _drawBarButton:_sessionRect
                  label:sessionStr
                  attrs:NormalAttrs()
              isPressed:(_pressedRegion == MenuBarRegionSession)
                isOpen:(_openTag == MenuBarRegionSession)];
    rightX -= sessionW + kItemGap;

    [self _drawBarSepAtX:rightX];
    rightX -= kSepWidth + kItemGap;

    NSString *clock = _clockString ?: @"--:--:--";
    NSSize clockSz  = [clock sizeWithAttributes:NormalAttrs()];
    CGFloat clockW  = clockSz.width + kItemPad * 2;
    _clockRect = NSMakeRect(rightX - clockW, 0, clockW, kBarHeight);
    [self _drawLabelInRect:_clockRect label:clock attrs:NormalAttrs()];
    rightX -= clockW + kItemGap;

    /* ---- LEFT SIDE: Ambrosia button ---- */
    NSString *ambStr = @"  Ambrosia  ";
    NSSize    ambSz  = [ambStr sizeWithAttributes:BoldAttrs()];
    CGFloat   ambW   = ambSz.width;
    _ambrosiaRect = NSMakeRect(leftX, 0, ambW, kBarHeight);
    [self _drawBarButton:_ambrosiaRect
                  label:ambStr
                  attrs:BoldAttrs()
              isPressed:(_pressedRegion == MenuBarRegionAmbrosia)
                isOpen:(_openTag == MenuBarRegionAmbrosia)];
    leftX += ambW + kItemGap;

    [self _drawBarSepAtX:leftX];
    leftX += kSepWidth + kItemGap;

    /* Top-level app menu items */
    NSUInteger activeItemIndex = 0;
    for (NSDictionary *item in _activeMenuItems) {
        if ([item[kMenuItemSeparator] boolValue]) { activeItemIndex++; continue; }

        NSString *title   = item[kMenuItemTitle] ?: @"";
        NSSize    titleSz = [title sizeWithAttributes:NormalAttrs()];
        CGFloat   itemW   = titleSz.width + kItemPad * 2 + 8;

        if (leftX + itemW + kBarPad > rightX) break;

        NSInteger menuIdx = (NSInteger)_menuRects.count;
        NSRect itemRect = NSMakeRect(leftX, 0, itemW, kBarHeight);
        [_menuRects addObject:[NSValue valueWithRect:itemRect]];
        [_menuItemIndices addObject:@(activeItemIndex)];

        BOOL isPressed = (_pressedRegion == MenuBarRegionMenuItem + menuIdx);
        BOOL isOpen    = (_openTag       == MenuBarRegionMenuItem + menuIdx);
        NSString *label = [title stringByAppendingString:@" \u25BE"];
        [self _drawBarButton:itemRect
                       label:label
                       attrs:NormalAttrs()
                   isPressed:isPressed
                      isOpen:isOpen];

        leftX += itemW + kItemGap;
        activeItemIndex++;
    }

    /* Bottom border */
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.4] set];
    NSRectFill(NSMakeRect(0, kBarHeight - 1.0, W, 1.0));

    /* ================================================================
     * DROPDOWN SECTION  (y = kBarHeight … kBarHeight+dropH)
     * Only drawn when a menu is open.
     * ================================================================ */
    if (_openTag == MenuBarRegionNone || !_openDescriptors.count) {
        (void)dirtyRect;
        return;
    }

    [self _drawDropdown];
    (void)dirtyRect;
}

/* ---- Bar drawing helpers ---- */

- (void)_drawBarButton:(NSRect)rect
                 label:(NSString *)label
                 attrs:(NSDictionary *)attrs
             isPressed:(BOOL)pressed
                isOpen:(BOOL)open
{
    if (pressed || open) {
        [BarHighlight() set];
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);
    }
    [self _drawLabelInRect:rect label:label attrs:attrs];
}

- (void)_drawLabelInRect:(NSRect)rect label:(NSString *)label attrs:(NSDictionary *)attrs
{
    NSRect tr = CentreInRect(label, attrs, rect);
    tr.size.width = MIN(tr.size.width, rect.size.width);
    [label drawInRect:tr withAttributes:attrs];
}

- (void)_drawBarSepAtX:(CGFloat)x
{
    [BarSep() set];
    NSBezierPath *line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(x + 0.5, kSepInset)];
    [line lineToPoint:NSMakePoint(x + 0.5, kBarHeight - kSepInset)];
    [line setLineWidth:kSepWidth];
    [line stroke];
}

/* ---- Dropdown drawing ---- */

- (void)_drawDropdown
{
    [_dropdownRects removeAllObjects];

    /* Calculate dropdown width */
    CGFloat maxTitleW = kDropMinW - kDropPadX * 2;
    for (NSDictionary *item in _openDescriptors) {
        if ([item[kSysItemSep] boolValue] || [item[kMenuItemSeparator] boolValue]) continue;
        NSString *title = item[kSysItemTitle] ?: item[kMenuItemTitle] ?: @"";
        NSSize sz = [title sizeWithAttributes:NormalAttrs()];
        if (sz.width > maxTitleW) maxTitleW = sz.width;
    }
    _dropdownW = MAX(kDropMinW, maxTitleW + kDropPadX * 2 + 20.0);

    /* Clamp to screen width */
    CGFloat W = self.bounds.size.width;
    if (_dropdownX + _dropdownW > W - 4.0)
        _dropdownX = MAX(4.0, W - _dropdownW - 4.0);

    /* Background */
    CGFloat y = kBarHeight;
    CGFloat totalH = [self _dropdownTotalHeight];
    NSRect dropBounds = NSMakeRect(_dropdownX, y, _dropdownW, totalH);
    [DropBg() set];
    NSRectFill(dropBounds);
    [DropBorder() set];
    NSFrameRect(dropBounds);

    /* Items */
    NSUInteger idx = 0;
    for (NSDictionary *item in _openDescriptors) {
        BOOL isSep = [item[kSysItemSep] boolValue] || [item[kMenuItemSeparator] boolValue];
        if (isSep) {
            CGFloat rowH = kDropSepH;
            NSRect rowRect = NSMakeRect(_dropdownX, y, _dropdownW, rowH);
            [_dropdownRects addObject:[NSValue valueWithRect:rowRect]];

            /* Draw separator line */
            CGFloat lineY = y + rowH * 0.5;
            [[NSColor colorWithCalibratedWhite:0.45 alpha:0.8] set];
            NSBezierPath *line = [NSBezierPath bezierPath];
            [line moveToPoint:NSMakePoint(_dropdownX + kDropPadX,       lineY + 0.5)];
            [line lineToPoint:NSMakePoint(_dropdownX + _dropdownW - kDropPadX, lineY + 0.5)];
            [line setLineWidth:1.0];
            [line stroke];

            y += rowH;
        } else {
            BOOL enabled = item[kMenuItemEnabled]
                           ? [item[kMenuItemEnabled] boolValue] : YES;
            BOOL hovered = (_hoveredIdx == (NSInteger)idx);
            CGFloat rowH = kDropItemH;
            NSRect rowRect = NSMakeRect(_dropdownX, y, _dropdownW, rowH);
            [_dropdownRects addObject:[NSValue valueWithRect:rowRect]];

            if (hovered) {
                [DropHighlight() set];
                NSRectFill(rowRect);
            }

            NSString *title = item[kSysItemTitle] ?: item[kMenuItemTitle] ?: @"";
            NSDictionary *attrs = enabled
                                  ? DropItemAttrs(hovered)
                                  : DisabledAttrs();
            NSSize sz = [title sizeWithAttributes:attrs];
            CGFloat textY = y + (rowH - sz.height) * 0.5;
            [title drawAtPoint:NSMakePoint(_dropdownX + kDropPadX, textY)
                withAttributes:attrs];

            /* Key equivalent (right-aligned) */
            NSString *keyEquiv = item[kMenuItemKeyEquiv];
            if (keyEquiv.length) {
                NSString *hint = [@"\u2318" stringByAppendingString:keyEquiv.uppercaseString];
                NSDictionary *hintAttrs = DisabledAttrs();
                NSSize hintSz = [hint sizeWithAttributes:hintAttrs];
                CGFloat hintX = _dropdownX + _dropdownW - hintSz.width - kDropPadX;
                [hint drawAtPoint:NSMakePoint(hintX, textY) withAttributes:hintAttrs];
            }

            y += rowH;
        }
        idx++;
    }

    /* Bottom padding */
    y += kDropExtraBot;
}

- (CGFloat)_dropdownTotalHeight
{
    CGFloat h = 0;
    for (NSDictionary *item in _openDescriptors) {
        BOOL isSep = [item[kSysItemSep] boolValue] || [item[kMenuItemSeparator] boolValue];
        h += isSep ? kDropSepH : kDropItemH;
    }
    return h + kDropExtraBot;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Mouse handling

- (void)mouseDown:(NSEvent *)event
{
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];

    /* ---- Click inside an open dropdown ---- */
    if (_openTag != MenuBarRegionNone) {
        NSInteger hitIdx = [self _dropdownIndexForPoint:pt];
        if (hitIdx >= 0) {
            NSDictionary *item = _openDescriptors[(NSUInteger)hitIdx];
            BOOL isSep = [item[kSysItemSep] boolValue] || [item[kMenuItemSeparator] boolValue];
            BOOL enabled = item[kMenuItemEnabled]
                           ? [item[kMenuItemEnabled] boolValue] : YES;
            if (!isSep && enabled) {
                /* Close (and contract the panel) BEFORE activating the item.
                 * Some actions (e.g. logout) call [NSAlert runModal] which is
                 * blocking; if the dropdown is still open the panel stays
                 * expanded and mouse-moved events continue to fire against
                 * stale dropdown state while the alert is on screen.
                 *
                 * Defer the activation to the next run-loop pass so that the
                 * current Wayland pointer event (including the pending button-UP
                 * that will fire when the user releases the mouse button) is
                 * fully drained before the modal session starts.  Without this
                 * the button-UP lands on the newly-visible alert at whatever
                 * coordinates the pointer is at and can instantly dismiss it.  */
                [self _closeDropdown];
                NSDictionary *deferred = item;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self _activateDropdownItem:deferred];
                });
            }
            return;
        }
        /* Click outside the dropdown → close it */
        [self _closeDropdown];
        /* Fall through: if the click also hit a bar region, handle it. */
    }

    /* ---- Click in bar ---- */
    NSInteger region = [self _barRegionForPoint:pt];
    if (region == MenuBarRegionNone) return;

    _pressedRegion = region;
    [self setNeedsDisplay:YES];
    [self _toggleDropdownForRegion:region];
    _pressedRegion = MenuBarRegionNone;
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event
{
    if (_openTag == MenuBarRegionNone) return;
    NSPoint pt  = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger i = [self _dropdownIndexForPoint:pt];
    if (i != _hoveredIdx) {
        _hoveredIdx = i;
        [self setNeedsDisplayInRect:[self _dropdownBoundsRect]];
    }
}

- (void)mouseExited:(NSEvent *)event
{
    if (_hoveredIdx != -1) {
        _hoveredIdx = -1;
        [self setNeedsDisplayInRect:[self _dropdownBoundsRect]];
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Hit testing

- (NSInteger)_barRegionForPoint:(NSPoint)pt
{
    /* Only test within the bar strip */
    if (pt.y < 0 || pt.y > kBarHeight) return MenuBarRegionNone;

    if (NSPointInRect(pt, _ambrosiaRect)) return MenuBarRegionAmbrosia;
    if (NSPointInRect(pt, _sessionRect))  return MenuBarRegionSession;
    for (NSUInteger i = 0; i < _menuRects.count; i++) {
        NSRect r = [[_menuRects objectAtIndex:i] rectValue];
        if (NSPointInRect(pt, r)) return MenuBarRegionMenuItem + (NSInteger)i;
    }
    return MenuBarRegionNone;
}

- (NSInteger)_dropdownIndexForPoint:(NSPoint)pt
{
    for (NSUInteger i = 0; i < _dropdownRects.count; i++) {
        NSRect r = [[_dropdownRects objectAtIndex:i] rectValue];
        if (NSPointInRect(pt, r)) return (NSInteger)i;
    }
    return -1;
}

- (NSRect)_dropdownBoundsRect
{
    CGFloat dropH = [self _dropdownTotalHeight];
    return NSMakeRect(_dropdownX, kBarHeight, _dropdownW, dropH);
}

/* ---------------------------------------------------------------------- */
#pragma mark - Dropdown open / close

/**
 * Toggle the dropdown for the given bar region.  If the same region is
 * already open, close it; otherwise open the new one.
 */
- (void)_toggleDropdownForRegion:(NSInteger)region
{
    if (_openTag == region) {
        [self _closeDropdown];
        return;
    }
    /* Close any previously open dropdown first (without panel resize yet). */
    if (_openTag != MenuBarRegionNone) {
        _openTag         = MenuBarRegionNone;
        _openDescriptors = nil;
        [_dropdownRects removeAllObjects];
        _hoveredIdx = -1;
        /* Panel is already expanded; we'll resize it below. */
        [_controller contractPanelDropdown];
    }

    NSArray *descriptors = nil;
    CGFloat openX = 0;

    if (region == MenuBarRegionAmbrosia) {
        descriptors = [self _systemDescriptorsForAmbrosia];
        openX = _ambrosiaRect.origin.x;
    } else if (region == MenuBarRegionSession) {
        descriptors = [self _systemDescriptorsForSession];
        openX = _sessionRect.origin.x;
    } else if (region >= MenuBarRegionMenuItem) {
        NSInteger idx = region - MenuBarRegionMenuItem;
        if (idx < (NSInteger)_menuItemIndices.count) {
            NSUInteger activeIdx = [_menuItemIndices[(NSUInteger)idx] unsignedIntegerValue];
            if (activeIdx < _activeMenuItems.count) {
                NSDictionary *topItem = _activeMenuItems[activeIdx];
                descriptors = topItem[kMenuItemChildren];
                NSRect r = [[_menuRects objectAtIndex:(NSUInteger)idx] rectValue];
                openX = r.origin.x;
            }
        }
    }

    if (!descriptors.count) return;

    _openTag         = region;
    _openDescriptors = descriptors;
    _dropdownX       = openX;
    _hoveredIdx      = -1;

    CGFloat dropH = [self _dropdownTotalHeight];
    [_controller expandPanelByDropdownHeight:dropH];

    /* Enable mouse-moved events so hover tracking works */
    [self.window setAcceptsMouseMovedEvents:YES];

    [self setNeedsDisplay:YES];
}

- (void)_closeDropdown
{
    if (_openTag == MenuBarRegionNone) return;
    _openTag         = MenuBarRegionNone;
    _openDescriptors = nil;
    [_dropdownRects removeAllObjects];
    _hoveredIdx = -1;
    [_controller contractPanelDropdown];
    [self setNeedsDisplay:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Dropdown item activation

- (void)_activateDropdownItem:(NSDictionary *)item
{
    /* System-menu items carry a selector name */
    NSString *selName = item[kSysItemSel];
    if (selName.length) {
        SEL sel = NSSelectorFromString(selName);
        if ([self respondsToSelector:sel]) {
            /* performSelector with id return — cast suppresses ARC warning */
            IMP imp = [self methodForSelector:sel];
            ((void (*)(id, SEL))imp)(self, sel);
        }
        return;
    }

    /* App-menu items carry a kMenuItemIdentifier */
    NSString *identifier = item[kMenuItemIdentifier];
    if (identifier.length) {
        [_controller performMenuItemWithIdentifier:identifier];
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - System-menu descriptor builders

- (NSArray *)_systemDescriptorsForAmbrosia
{
    return @[
        @{ kSysItemTitle: @"About Ambrosia\u2026",       kSysItemSel: @"_doAbout" },
        @{ kSysItemSep: @YES },
        @{ kSysItemTitle: @"System Preferences\u2026",   kSysItemSel: @"_doPreferences" },
        @{ kSysItemSep: @YES },
        @{ kSysItemTitle: @"Log Out\u2026",              kSysItemSel: @"_doLogout" },
    ];
}

- (NSArray *)_systemDescriptorsForSession
{
    return @[
        @{ kSysItemTitle: @"Log Out\u2026",              kSysItemSel: @"_doLogout" },
    ];
}

/* ---------------------------------------------------------------------- */
#pragma mark - System-menu action targets (called via _activateDropdownItem:)

- (void)_doAbout       { [_controller showAbout]; }
- (void)_doPreferences { [_controller openSystemPreferences]; }
- (void)_doLogout      { [_controller logout]; }

/* ---------------------------------------------------------------------- */
#pragma mark - App-menu action handlers (kept for compatibility)

- (void)_doAppMenuAction:(NSMenuItem *)sender
{
    NSString *identifier = [sender representedObject];
    [_controller performMenuItemWithIdentifier:identifier];
}

@end
