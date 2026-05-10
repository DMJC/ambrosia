#import "MenuBarView.h"
#import "MenuBarController.h"
#import "MenuServerProtocol.h"
#import "TrayManager.h"
#import <GNUstepGUI/GSTheme.h>

/* ---- Bar geometry ---- */
static const CGFloat kBarHeight      = 24.0;

/* ---- Bar appearance ---- */
static const CGFloat kBarPad         = 6.0;
static const CGFloat kItemPad        = 6.0;
static const CGFloat kItemGap        = 2.0;
static const CGFloat kSepWidth       = 1.0;
static const CGFloat kSepInset       = 4.0;
static const CGFloat kHighlightAlpha = 0.25;

/* ---- Dropdown geometry ---- */
static const CGFloat kDropItemH      = 22.0;   /* normal item row height          */
static const CGFloat kDropSepH       = 8.0;    /* separator row height            */
static const CGFloat kDropSliderH    = 130.0;  /* vertical slider row height      */
static const CGFloat kDropPadX       = 14.0;   /* horizontal text inset           */
static const CGFloat kDropMinW       = 180.0;  /* minimum dropdown panel width    */
static const CGFloat kDropExtraBot   = 4.0;    /* extra padding below last item   */

/* ---- Tray icon geometry ---- */
static const CGFloat kTrayIconSize = 16.0;   /* render size for tray icons  */
static const CGFloat kTrayIconPad  =  4.0;   /* left/right padding per icon */
static const CGFloat kTraySepW     =  6.0;   /* gap between tray and status items */

/* ---- Hit-region tags ---- */
typedef NS_ENUM(NSInteger, MenuBarRegion) {
    MenuBarRegionNone        = -1,
    MenuBarRegionAmbrosia    =  0,
    MenuBarRegionSession     =  1,
    MenuBarRegionTrayItem    =  200,  /* tray icons 200…249; index = tag − 200 */
    MenuBarRegionStatusItem  =  50,   /* plugins 50…99;  index = tag − 50  */
    MenuBarRegionMenuItem    =  100,  /* items >= 100;   index = tag − 100  */
};

/* ---- NSDictionary keys for system-menu item descriptors ---- */
static NSString * const kSysItemTitle    = @"sysTitle";
static NSString * const kSysItemSel     = @"sysSel";     /* NSString selector name */
static NSString * const kSysItemSep     = @"sysSep";     /* @YES = separator row  */

/* ---- Colour helpers — sourced from the active GNUstep theme ---- */
static NSColor *BarBg(void)
{
    return [[GSTheme theme] menuBarBackgroundColor];
}
static NSColor *DropBg(void)
{
    return [[GSTheme theme] menuBackgroundColor];
}
static NSColor *DropBorder(void)
{
    return [[GSTheme theme] menuBorderColor];
}
static NSColor *BarHighlight(void)
{
    return [[NSColor selectedMenuItemColor]
            colorWithAlphaComponent:kHighlightAlpha];
}
static NSColor *DropHighlight(void)
{
    return [NSColor selectedMenuItemColor];
}
static NSColor *BarSep(void)
{
    return [[GSTheme theme] menuSeparatorColor];
}

/* ---- Font helpers ---- */
static NSFont *MenuFont(void)
{
    return [NSFont menuFontOfSize:0];
}
static NSFont *MenuFontBold(void)
{
    NSFont *base = [NSFont menuFontOfSize:0];
    NSFont *bold = [[NSFontManager sharedFontManager]
                    convertFont:base toHaveTrait:NSBoldFontMask];
    return bold ? bold : base;
}

/* ---- Text attribute helpers ---- */
static NSDictionary *NormalAttrs(void)
{
    return @{
        NSForegroundColorAttributeName: [NSColor controlTextColor],
        NSFontAttributeName: MenuFont(),
    };
}
static NSDictionary *BoldAttrs(void)
{
    return @{
        NSForegroundColorAttributeName: [NSColor controlTextColor],
        NSFontAttributeName: MenuFontBold(),
    };
}
static NSDictionary *DisabledAttrs(void)
{
    return @{
        NSForegroundColorAttributeName: [NSColor disabledControlTextColor],
        NSFontAttributeName: MenuFont(),
    };
}
static NSDictionary *DropItemAttrs(BOOL highlighted)
{
    NSColor *fg = highlighted
        ? [NSColor selectedMenuItemTextColor]
        : [NSColor controlTextColor];
    return @{
        NSForegroundColorAttributeName: fg,
        NSFontAttributeName: MenuFont(),
    };
}
static NSDictionary *GrayedItemAttrs(BOOL highlighted)
{
    /* Like DisabledAttrs but the item is still clickable. */
    NSColor *fg = highlighted
        ? [NSColor selectedMenuItemTextColor]
        : [NSColor disabledControlTextColor];
    return @{
        NSForegroundColorAttributeName: fg,
        NSFontAttributeName: MenuFont(),
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
    NSMutableArray     *_pluginRects;      /* NSValue(NSRect) per status plugin button */
    NSMutableArray     *_trayRects;        /* NSValue(NSRect) per tray icon */
    NSRect              _clockRect;
    NSRect              _sessionRect;      /* kept for compat; always NSZeroRect */
    NSInteger           _pressedRegion;    /* MenuBarRegion; -1 = none */

    /* ---- Inline dropdown state ---- */
    NSInteger           _openTag;          /* which header is open (MenuBarRegion); -1 = none */
    NSArray            *_openDescriptors;  /* items for open dropdown; NSDictionary array */
    /* When the open dropdown belongs to a plugin, store the plugin index. */
    NSInteger           _openPluginIdx;    /* -1 if not a plugin dropdown */
    NSMutableArray     *_dropdownRects;    /* NSValue(NSRect) per dropdown row (view coords) */
    CGFloat             _dropdownX;        /* left edge of open dropdown */
    CGFloat             _dropdownW;        /* width of open dropdown */
    NSInteger           _hoveredIdx;       /* hovered item index (-1 = none) */

    /* ---- Vertical slider drag state ---- */
    NSInteger           _draggingSliderRowIdx;    /* row index in _dropdownRects; -1 = none */
    NSInteger           _draggingSliderPluginIdx; /* plugin index owning the slider; -1 = none */
}

@synthesize statusPlugins = _statusPlugins;
@synthesize trayItems     = _trayItems;

/* ---------------------------------------------------------------------- */
#pragma mark - Initialisation

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _menuRects              = [NSMutableArray array];
    _menuItemIndices        = [NSMutableArray array];
    _pluginRects            = [NSMutableArray array];
    _trayRects              = [NSMutableArray array];
    _dropdownRects          = [NSMutableArray array];
    _pressedRegion          = MenuBarRegionNone;
    _openTag                = MenuBarRegionNone;
    _openPluginIdx          = -1;
    _hoveredIdx             = -1;
    _draggingSliderRowIdx    = -1;
    _draggingSliderPluginIdx = -1;
    _sessionRect            = NSZeroRect;

    [self _updateClockString];
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                   target:self
                                                 selector:@selector(_tickClock:)
                                                 userInfo:nil
                                                  repeats:YES];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(_themeDidChange:)
               name:GSThemeDidActivateNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(_themeDidChange:)
               name:NSSystemColorsDidChangeNotification
             object:nil];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
#pragma mark - Tray items

- (void)setTrayItems:(NSArray<TrayItem *> *)trayItems
{
    _trayItems = [trayItems copy];
    [self setNeedsDisplay:YES];
}

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
#pragma mark - AmbrosiaStatusItemPluginDelegate

- (void)statusItemPluginDidUpdate:(id<AmbrosiaStatusItemPlugin>)plugin
{
    /* Redraw the bar so the plugin's label (and open dropdown) refresh. */
    [self setNeedsDisplay:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Theme changes

- (void)_themeDidChange:(NSNotification *)note
{
    [self setNeedsDisplay:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Clock

- (void)_updateClockString
{
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"EEE h:mm a"];
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
    [_pluginRects removeAllObjects];
    [_trayRects removeAllObjects];

    CGFloat leftX  = kBarPad;
    CGFloat rightX = W - kBarPad;

    /* ---- RIGHT SIDE ---- */
    /* Session/logout button removed; logout is accessible via the Ambrosia menu. */
    _sessionRect = NSZeroRect;

    NSString *clock = _clockString ?: @"--:--:--";
    NSSize clockSz  = [clock sizeWithAttributes:NormalAttrs()];
    CGFloat clockW  = clockSz.width + kItemPad * 2;
    _clockRect = NSMakeRect(rightX - clockW, 0, clockW, kBarHeight);
    [self _drawLabelInRect:_clockRect label:clock attrs:NormalAttrs()];
    rightX -= clockW + kItemGap;

    /* ---- RIGHT SIDE: status item plugins (right-to-left) ---- */
    NSArray<id<AmbrosiaStatusItemPlugin>> *plugins = _statusPlugins;
    for (NSInteger pi = (NSInteger)plugins.count - 1; pi >= 0; pi--) {
        id<AmbrosiaStatusItemPlugin> plugin = plugins[(NSUInteger)pi];
        NSString *label = plugin.barLabel;
        if (!label.length) continue;

        NSSize   lblSz  = [label sizeWithAttributes:NormalAttrs()];
        CGFloat  itemW  = lblSz.width + kItemPad * 2;
        NSRect   pRect  = NSMakeRect(rightX - itemW, 0, itemW, kBarHeight);

        /* Pad _pluginRects so index pi maps to the right slot. */
        while ((NSInteger)_pluginRects.count <= pi)
            [_pluginRects addObject:[NSValue valueWithRect:NSZeroRect]];
        _pluginRects[(NSUInteger)pi] = [NSValue valueWithRect:pRect];

        NSInteger tag = MenuBarRegionStatusItem + pi;
        [self _drawBarButton:pRect
                       label:label
                       attrs:NormalAttrs()
                   isPressed:(_pressedRegion == tag)
                      isOpen:(_openTag == tag)];
        rightX -= itemW + kItemGap;
    }

    /* ---- RIGHT SIDE: tray icons (right-to-left, left of status plugins) ---- */
    NSArray<TrayItem *> *trayItems = _trayItems;
    if (trayItems.count > 0) {
        /* Vertical icon origin so a kTrayIconSize icon is centred in the bar */
        CGFloat iconY = (kBarHeight - kTrayIconSize) * 0.5;
        CGFloat iconSlotW = kTrayIconSize + kTrayIconPad * 2;

        /* Separator between tray area and status plugins */
        [self _drawBarSepAtX:rightX - kTraySepW * 0.5];
        rightX -= kTraySepW;

        /* Draw right-to-left */
        for (NSInteger ti = (NSInteger)trayItems.count - 1; ti >= 0; ti--) {
            TrayItem *item = trayItems[(NSUInteger)ti];
            NSRect slotRect = NSMakeRect(rightX - iconSlotW, 0, iconSlotW, kBarHeight);

            /* Pad _trayRects so index ti maps to the right slot */
            while ((NSInteger)_trayRects.count <= ti)
                [_trayRects addObject:[NSValue valueWithRect:NSZeroRect]];
            _trayRects[(NSUInteger)ti] = [NSValue valueWithRect:slotRect];

            NSInteger tag = MenuBarRegionTrayItem + ti;
            BOOL isPressed = (_pressedRegion == tag);
            if (isPressed) {
                [BarHighlight() set];
                NSRectFillUsingOperation(slotRect, NSCompositeSourceOver);
            }

            NSImage *icon = item.icon;
            if (icon) {
                NSRect iconRect = NSMakeRect(rightX - iconSlotW + kTrayIconPad,
                                            iconY,
                                            kTrayIconSize, kTrayIconSize);
                [icon drawInRect:iconRect
                        fromRect:NSZeroRect
                       operation:NSCompositeSourceOver
                        fraction:1.0];
            } else {
                /* Placeholder dot while icon is loading */
                NSString *dot = @"●";
                NSSize dotSz  = [dot sizeWithAttributes:NormalAttrs()];
                CGFloat dotX  = slotRect.origin.x + (iconSlotW - dotSz.width) * 0.5;
                CGFloat dotY  = (kBarHeight - dotSz.height) * 0.5;
                [dot drawAtPoint:NSMakePoint(dotX, dotY) withAttributes:NormalAttrs()];
            }
            rightX -= iconSlotW;
        }
    }

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
    BOOL isFirstMenuItem = YES;
    for (NSDictionary *item in _activeMenuItems) {
        if ([item[kMenuItemSeparator] boolValue]) { activeItemIndex++; continue; }

        NSDictionary *attrs = isFirstMenuItem ? BoldAttrs() : NormalAttrs();
        NSString *title   = item[kMenuItemTitle] ?: @"";
        NSSize    titleSz = [title sizeWithAttributes:attrs];
        CGFloat   itemW   = titleSz.width + kItemPad * 2 + 8;

        if (leftX + itemW + kBarPad > rightX) break;

        NSInteger menuIdx = (NSInteger)_menuRects.count;
        NSRect itemRect = NSMakeRect(leftX, 0, itemW, kBarHeight);
        [_menuRects addObject:[NSValue valueWithRect:itemRect]];
        [_menuItemIndices addObject:@(activeItemIndex)];

        BOOL isPressed = (_pressedRegion == MenuBarRegionMenuItem + menuIdx);
        BOOL isOpen    = (_openTag       == MenuBarRegionMenuItem + menuIdx);
        [self _drawBarButton:itemRect
                       label:title
                       attrs:attrs
                   isPressed:isPressed
                      isOpen:isOpen];
        isFirstMenuItem = NO;

        leftX += itemW + kItemGap;
        activeItemIndex++;
    }

    /* Bottom border */
    [[[GSTheme theme] menuBarBorderColor] set];
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
        BOOL isSep    = [item[kSysItemSep] boolValue] || [item[kMenuItemSeparator] boolValue];
        BOOL isSlider = !isSep && [item[kMenuItemSlider] boolValue];

        if (isSep) {
            CGFloat rowH = kDropSepH;
            NSRect rowRect = NSMakeRect(_dropdownX, y, _dropdownW, rowH);
            [_dropdownRects addObject:[NSValue valueWithRect:rowRect]];

            CGFloat lineY = y + rowH * 0.5;
            [[[GSTheme theme] menuSeparatorColor] set];
            NSBezierPath *line = [NSBezierPath bezierPath];
            [line moveToPoint:NSMakePoint(_dropdownX + kDropPadX,             lineY + 0.5)];
            [line lineToPoint:NSMakePoint(_dropdownX + _dropdownW - kDropPadX, lineY + 0.5)];
            [line setLineWidth:1.0];
            [line stroke];

            y += rowH;

        } else if (isSlider) {
            /* ---- Vertical volume slider ---- */
            CGFloat rowH = kDropSliderH;
            NSRect rowRect = NSMakeRect(_dropdownX, y, _dropdownW, rowH);
            [_dropdownRects addObject:[NSValue valueWithRect:rowRect]];

            CGFloat value    = [item[kMenuItemSliderValue] doubleValue];
            CGFloat trackW   = 8.0;
            CGFloat padY     = 18.0;  /* space reserved for percentage label at top */
            CGFloat trackX   = _dropdownX + (_dropdownW - trackW) * 0.5;
            CGFloat trackTop = y + padY;
            CGFloat trackBot = y + rowH - 10.0;
            CGFloat trackH   = trackBot - trackTop;

            /* Track background */
            NSRect trackBg = NSMakeRect(trackX, trackTop, trackW, trackH);
            [[NSColor colorWithWhite:0.75 alpha:1.0] set];
            [[NSBezierPath bezierPathWithRoundedRect:trackBg xRadius:4 yRadius:4] fill];

            /* Filled portion (bottom up) */
            CGFloat fillH = trackH * (value / 100.0);
            NSRect  fillR = NSMakeRect(trackX, trackBot - fillH, trackW, fillH);
            [[NSColor selectedMenuItemColor] set];
            [[NSBezierPath bezierPathWithRoundedRect:fillR xRadius:4 yRadius:4] fill];

            /* Thumb */
            CGFloat thumbD = 16.0;
            CGFloat thumbX = trackX + (trackW - thumbD) * 0.5;
            CGFloat thumbY = trackBot - fillH - thumbD * 0.5;
            NSRect  thumbR = NSMakeRect(thumbX, thumbY, thumbD, thumbD);
            [[NSColor selectedMenuItemColor] set];
            [[NSBezierPath bezierPathWithOvalInRect:thumbR] fill];
            [[NSColor whiteColor] set];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(thumbR, 4, 4)] fill];

            /* Percentage label centred above the track */
            NSString     *pct  = [NSString stringWithFormat:@"%.0f%%", value];
            NSDictionary *pctA = NormalAttrs();
            NSSize        pctSz = [pct sizeWithAttributes:pctA];
            [pct drawAtPoint:NSMakePoint(_dropdownX + (_dropdownW - pctSz.width) * 0.5,
                                         y + 2.0)
              withAttributes:pctA];

            y += rowH;

        } else {
            BOOL enabled = item[kMenuItemEnabled]
                           ? [item[kMenuItemEnabled] boolValue] : YES;
            BOOL grayed  = [item[kMenuItemGrayed] boolValue];
            BOOL hovered = (_hoveredIdx == (NSInteger)idx);
            CGFloat rowH = kDropItemH;
            NSRect rowRect = NSMakeRect(_dropdownX, y, _dropdownW, rowH);
            [_dropdownRects addObject:[NSValue valueWithRect:rowRect]];

            if (hovered) {
                [DropHighlight() set];
                NSRectFill(rowRect);
            }

            NSString *title = item[kSysItemTitle] ?: item[kMenuItemTitle] ?: @"";
            NSDictionary *attrs;
            if (!enabled)
                attrs = DisabledAttrs();
            else if (grayed)
                attrs = GrayedItemAttrs(hovered);
            else
                attrs = DropItemAttrs(hovered);
            NSSize sz = [title sizeWithAttributes:attrs];
            CGFloat textY = y + (rowH - sz.height) * 0.5;
            [title drawAtPoint:NSMakePoint(_dropdownX + kDropPadX, textY)
                withAttributes:attrs];

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
        BOOL isSep    = [item[kSysItemSep] boolValue] || [item[kMenuItemSeparator] boolValue];
        BOOL isSlider = !isSep && [item[kMenuItemSlider] boolValue];
        if (isSep)         h += kDropSepH;
        else if (isSlider) h += kDropSliderH;
        else               h += kDropItemH;
    }
    return h + kDropExtraBot;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Mouse handling

- (void)rightMouseDown:(NSEvent *)event
{
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
    if (pt.y < 0 || pt.y > kBarHeight) return;

    for (NSUInteger i = 0; i < _trayRects.count; i++) {
        NSRect r = [_trayRects[i] rectValue];
        if (r.size.width == 0) continue;
        if (NSPointInRect(pt, r)) {
            [self _openTrayMenuForItemIndex:(NSInteger)i clickPoint:pt];
            return;
        }
    }
}

/**
 * Fetch the dbusmenu layout for tray item at index |ti| and show it in the
 * MenuServer's own dropdown.  Falls back to the SNI ContextMenu(x,y) call
 * when the item has no dbusmenu object path.
 */
- (void)_openTrayMenuForItemIndex:(NSInteger)ti clickPoint:(NSPoint)pt
{
    NSArray<TrayItem *> *items = _trayItems;
    if (ti < 0 || ti >= (NSInteger)items.count) return;
    TrayItem *trayItem = items[(NSUInteger)ti];
    void             *conn      = _controller.trayManager.dbusConnection;
    dispatch_queue_t  dbusQueue = _controller.trayManager.dbusQueue;

    __weak typeof(self) weakSelf = self;
    [trayItem fetchMenuItemsWithConnection:conn
                                 dbusQueue:dbusQueue
                                completion:^(NSArray<NSDictionary *> *menuItems) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (menuItems.count == 0) {
            /* No dbusmenu — ask the app to show its own menu */
            NSPoint screenPt =
                [strongSelf.window convertBaseToScreen:
                 [strongSelf convertPoint:pt toView:nil]];
            [trayItem contextMenuAtX:(int)screenPt.x
                                   y:(int)screenPt.y
                          connection:conn];
            return;
        }

        /* Close any currently open dropdown first */
        if (strongSelf->_openTag != MenuBarRegionNone)
            [strongSelf _closeDropdown];

        /* Align dropdown to the left edge of the tray icon slot */
        NSRect slot = NSZeroRect;
        if (ti < (NSInteger)strongSelf->_trayRects.count)
            slot = [strongSelf->_trayRects[(NSUInteger)ti] rectValue];

        strongSelf->_openTag         = MenuBarRegionTrayItem + ti;
        strongSelf->_openDescriptors = menuItems;
        strongSelf->_dropdownX       = slot.origin.x;
        strongSelf->_openPluginIdx   = -1;
        strongSelf->_hoveredIdx      = -1;

        CGFloat dropH = [strongSelf _dropdownTotalHeight];
        [strongSelf->_controller expandPanelByDropdownHeight:dropH];
        [strongSelf.window setAcceptsMouseMovedEvents:YES];
        [strongSelf setNeedsDisplay:YES];
    }];
}

/** Find the TrayItem whose bus name matches, or nil. */
- (nullable TrayItem *)_trayItemForBusName:(NSString *)busName
{
    for (TrayItem *it in _trayItems) {
        if ([it.busName isEqualToString:busName]) return it;
    }
    return nil;
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];

    /* ---- Click inside an open dropdown ---- */
    if (_openTag != MenuBarRegionNone) {
        NSInteger hitIdx = [self _dropdownIndexForPoint:pt];
        if (hitIdx >= 0) {
            NSDictionary *item = _openDescriptors[(NSUInteger)hitIdx];
            BOOL isSep    = [item[kSysItemSep] boolValue] || [item[kMenuItemSeparator] boolValue];
            BOOL isSlider = !isSep && [item[kMenuItemSlider] boolValue];
            BOOL enabled  = item[kMenuItemEnabled]
                            ? [item[kMenuItemEnabled] boolValue] : YES;

            if (isSlider) {
                /* Start tracking a slider drag — do NOT close the dropdown. */
                _draggingSliderRowIdx    = hitIdx;
                _draggingSliderPluginIdx = _openPluginIdx;
                [self _updateSliderFromPoint:pt];
                return;
            }

            if (!isSep && enabled) {
                /* Close (and contract the panel) BEFORE activating the item.
                 * Some actions (e.g. logout) call [NSAlert runModal] which is
                 * blocking; if the dropdown is still open the panel stays
                 * expanded and mouse-moved events continue to fire against
                 * stale dropdown state while the alert is on screen.
                 *
                 * Use a short delay (not only dispatch_async) so the full
                 * click sequence is drained, including button-UP. Otherwise
                 * button-UP can land on the just-opened alert and immediately
                 * trigger the default button, closing the alert before the
                 * user can interact with it.
                 *
                 * Capture _openPluginIdx NOW — _closeDropdown resets it to -1,
                 * so the deferred block would never route to the plugin.      */
                NSInteger capturedPluginIdx = _openPluginIdx;
                [self _closeDropdown];
                NSDictionary *deferred = item;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.18 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self _activateDropdownItem:deferred pluginIdx:capturedPluginIdx];
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

- (void)mouseDragged:(NSEvent *)event
{
    if (_draggingSliderRowIdx < 0) return;
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
    [self _updateSliderFromPoint:pt];
}

- (void)mouseUp:(NSEvent *)event
{
    if (_draggingSliderRowIdx < 0) return;
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
    [self _updateSliderFromPoint:pt];
    _draggingSliderRowIdx    = -1;
    _draggingSliderPluginIdx = -1;
}

/**
 * Recalculate the slider value from the mouse position during a drag,
 * update _openDescriptors, and notify the owning plugin.
 *
 * The vertical slider maps: track top → 100%, track bottom → 0%.
 */
- (void)_updateSliderFromPoint:(NSPoint)pt
{
    if (_draggingSliderRowIdx < 0 ||
        _draggingSliderRowIdx >= (NSInteger)_dropdownRects.count) return;

    NSRect sliderRowRect =
        [_dropdownRects[(NSUInteger)_draggingSliderRowIdx] rectValue];

    CGFloat padY     = 18.0;   /* must match kDropSliderH layout in _drawDropdown */
    CGFloat trackTop = sliderRowRect.origin.y + padY;
    CGFloat trackBot = sliderRowRect.origin.y + sliderRowRect.size.height - 10.0;
    CGFloat trackH   = trackBot - trackTop;

    if (trackH <= 0) return;
    CGFloat t        = 1.0 - MAX(0.0, MIN(1.0, (pt.y - trackTop) / trackH));
    CGFloat newValue = t * 100.0;

    /* Rebuild _openDescriptors with the updated slider value. */
    NSMutableArray *mutable = [_openDescriptors mutableCopy];
    NSMutableDictionary *sliderItem =
        [mutable[(NSUInteger)_draggingSliderRowIdx] mutableCopy];
    sliderItem[kMenuItemSliderValue] = @(newValue);
    mutable[(NSUInteger)_draggingSliderRowIdx] = sliderItem;
    _openDescriptors = [mutable copy];

    /* Notify the owning plugin so it applies the volume change. */
    NSArray<id<AmbrosiaStatusItemPlugin>> *plugins = _statusPlugins;
    NSInteger pi = _draggingSliderPluginIdx;
    if (pi >= 0 && pi < (NSInteger)plugins.count)
        [plugins[(NSUInteger)pi] activateItem:sliderItem];

    [self setNeedsDisplay:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Hit testing

- (NSInteger)_barRegionForPoint:(NSPoint)pt
{
    /* Only test within the bar strip */
    if (pt.y < 0 || pt.y > kBarHeight) return MenuBarRegionNone;

    if (NSPointInRect(pt, _ambrosiaRect)) return MenuBarRegionAmbrosia;
    if (NSPointInRect(pt, _sessionRect))  return MenuBarRegionSession;
    for (NSUInteger i = 0; i < _trayRects.count; i++) {
        NSRect r = [_trayRects[i] rectValue];
        if (r.size.width == 0) continue;
        if (NSPointInRect(pt, r)) return MenuBarRegionTrayItem + (NSInteger)i;
    }
    for (NSUInteger i = 0; i < _pluginRects.count; i++) {
        NSRect r = [_pluginRects[i] rectValue];
        if (r.size.width == 0 && r.size.height == 0) continue;
        if (NSPointInRect(pt, r)) return MenuBarRegionStatusItem + (NSInteger)i;
    }
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
        _openPluginIdx   = -1;
        [_dropdownRects removeAllObjects];
        _hoveredIdx = -1;
        /* Panel is already expanded; we'll resize it below. */
        [_controller contractPanelDropdown];
    }

    /* Tray items forward clicks directly to the SNI item; no dropdown. */
    if (region >= MenuBarRegionTrayItem) {
        NSInteger ti = region - MenuBarRegionTrayItem;
        NSArray<TrayItem *> *items = _trayItems;
        if (ti < (NSInteger)items.count) {
            TrayItem *item = items[(NSUInteger)ti];
            NSRect   slot  = [_trayRects[(NSUInteger)ti] rectValue];
            NSPoint  barPt = NSMakePoint(NSMidX(slot), NSMidY(slot));
            NSPoint  scPt  = [self.window convertBaseToScreen:
                              [self convertPoint:barPt toView:nil]];
            [item activateAtX:(int)scPt.x
                            y:(int)scPt.y
                   connection:_controller.trayManager.dbusConnection];
        }
        return;
    }

    NSArray *descriptors = nil;
    CGFloat openX = 0;
    _openPluginIdx = -1;

    if (region == MenuBarRegionAmbrosia) {
        descriptors = [self _systemDescriptorsForAmbrosia];
        openX = _ambrosiaRect.origin.x;
    } else if (region == MenuBarRegionSession) {
        descriptors = [self _systemDescriptorsForSession];
        openX = _sessionRect.origin.x;
    } else if (region >= MenuBarRegionStatusItem &&
               region < MenuBarRegionMenuItem) {
        NSInteger pi = region - MenuBarRegionStatusItem;
        NSArray<id<AmbrosiaStatusItemPlugin>> *plugins = _statusPlugins;
        if (pi < (NSInteger)plugins.count) {
            id<AmbrosiaStatusItemPlugin> plugin = plugins[(NSUInteger)pi];
            descriptors = plugin.dropdownItems;
            if (pi < (NSInteger)_pluginRects.count)
                openX = [_pluginRects[(NSUInteger)pi] rectValue].origin.x;
            _openPluginIdx = pi;
        }
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
    _openPluginIdx   = -1;
    [_dropdownRects removeAllObjects];
    _hoveredIdx = -1;
    [_controller contractPanelDropdown];
    [self setNeedsDisplay:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Dropdown item activation

- (void)_activateDropdownItem:(NSDictionary *)item pluginIdx:(NSInteger)pluginIdx
{
    /* Plugin items: route to the plugin that owned this dropdown. */
    if (pluginIdx >= 0) {
        NSArray<id<AmbrosiaStatusItemPlugin>> *plugins = _statusPlugins;
        if (pluginIdx < (NSInteger)plugins.count) {
            id<AmbrosiaStatusItemPlugin> plugin = plugins[(NSUInteger)pluginIdx];
            [plugin activateItem:item];
        }
        return;
    }

    /* dbusmenu tray items carry a bus name and integer item id.
     * Trigger via com.canonical.dbusmenu Event() instead of a notification. */
    NSString *trayBusName = item[@"_trayBusName"];
    if (trayBusName.length) {
        NSNumber *menuItemId = item[@"_dbusMenuId"];
        if (menuItemId) {
            TrayItem *trayItem = [self _trayItemForBusName:trayBusName];
            if (trayItem) {
                [trayItem triggerMenuItemId:(int32_t)[menuItemId intValue]
                                connection:_controller.trayManager.dbusConnection
                                 dbusQueue:_controller.trayManager.dbusQueue];
            }
        }
        return;
    }

    /* System-menu items carry a selector name */
    NSString *selName = item[kSysItemSel];
    if (selName.length) {
        SEL sel = NSSelectorFromString(selName);
        if ([self respondsToSelector:sel]) {
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
        @{ kSysItemTitle: @"Open Terminal",              kSysItemSel: @"_doTerminal" },
        @{ kSysItemTitle: @"Files",                      kSysItemSel: @"_doGFinder" },
        @{ kSysItemSep: @YES },
        @{ kSysItemTitle: @"Log Out\u2026",              kSysItemSel: @"_doLogout" },
        @{ kSysItemTitle: @"Shut Down\u2026",            kSysItemSel: @"_doShutdown" },
        @{ kSysItemTitle: @"Restart\u2026",              kSysItemSel: @"_doReboot" },
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
- (void)_doTerminal    { [_controller openTerminal]; }
- (void)_doGFinder     { [_controller openGFinder]; }
- (void)_doLogout      { [_controller logout]; }
- (void)_doShutdown    { [_controller shutdown]; }
- (void)_doReboot      { [_controller reboot]; }

/* ---------------------------------------------------------------------- */
#pragma mark - App-menu action handlers (kept for compatibility)

- (void)_doAppMenuAction:(NSMenuItem *)sender
{
    NSString *identifier = [sender representedObject];
    [_controller performMenuItemWithIdentifier:identifier];
}

@end
