#import "MenuBarView.h"
#import "MenuBarController.h"
#import "MenuServerProtocol.h"

/* ---- Appearance constants ---- */
static const CGFloat kBarPad        = 6.0;   /* outer left / right margin       */
static const CGFloat kItemPad       = 6.0;   /* horizontal padding inside items */
static const CGFloat kItemGap       = 2.0;   /* gap between adjacent items       */
static const CGFloat kSepWidth      = 1.0;   /* vertical separator width         */
static const CGFloat kSepInset      = 4.0;   /* vertical inset for separators    */
static const CGFloat kFontSize      = 11.5;
static const CGFloat kBoldFontSize  = 12.0;
static const CGFloat kHighlightAlpha = 0.25; /* button-press background alpha    */

/* ---- Hit-region tags ---- */
typedef NS_ENUM(NSInteger, MenuBarRegion) {
    MenuBarRegionNone     = -1,
    MenuBarRegionAmbrosia =  0,
    MenuBarRegionSession  =  1,
    MenuBarRegionMenuItem =  100, /* items >= 100, index = tag - 100 */
};

/* ---- Helpers ---- */
static NSColor *BarBackgroundColor(void)
{
    /* Dark navy-grey, similar to a classic dark desktop bar. */
    return [NSColor colorWithCalibratedRed:0.10
                                     green:0.10
                                      blue:0.16
                                     alpha:1.0];
}

static NSColor *BarHighlightColor(void)
{
    return [NSColor colorWithCalibratedWhite:1.0 alpha:kHighlightAlpha];
}

static NSColor *BarSeparatorColor(void)
{
    return [NSColor colorWithCalibratedWhite:0.40 alpha:0.8];
}

static NSDictionary *NormalTextAttrs(void)
{
    return @{
        NSForegroundColorAttributeName:
            [NSColor colorWithCalibratedWhite:0.92 alpha:1.0],
        NSFontAttributeName:
            [NSFont systemFontOfSize:kFontSize],
    };
}

static NSDictionary *BoldTextAttrs(void)
{
    return @{
        NSForegroundColorAttributeName:
            [NSColor colorWithCalibratedWhite:1.0 alpha:1.0],
        NSFontAttributeName:
            [NSFont boldSystemFontOfSize:kBoldFontSize],
    };
}

static NSDictionary *DimTextAttrs(void)
{
    return @{
        NSForegroundColorAttributeName:
            [NSColor colorWithCalibratedWhite:0.65 alpha:1.0],
        NSFontAttributeName:
            [NSFont systemFontOfSize:kFontSize],
    };
}

/* Centre a string vertically in a rect. */
static NSRect CentreStringRect(NSString *str, NSDictionary *attrs, NSRect bounds)
{
    NSSize sz = [str sizeWithAttributes:attrs];
    CGFloat y = bounds.origin.y + (bounds.size.height - sz.height) * 0.5;
    return NSMakeRect(bounds.origin.x, y, sz.width, sz.height);
}

/* ---------------------------------------------------------------------- */

@implementation MenuBarView {
    /* ---- State ---- */
    NSString  *_activeAppName;
    NSArray   *_activeMenuItems;  /* NSArray<NSDictionary*> */
    NSString  *_clockString;
    NSTimer   *_clockTimer;

    /* ---- Pre-computed hit-test rects (view coordinates) ---- */
    NSRect     _ambrosiaRect;     /* Ambrosia system-menu button    */
    NSRect     _appNameRect;      /* app-name label (non-clickable) */
    NSMutableArray *_menuRects;   /* one NSValue(NSRect) per clickable top-level item */
    NSMutableArray *_menuItemIndices; /* NSNumber: index into _activeMenuItems for each rect */
    NSRect     _clockRect;
    NSRect     _sessionRect;

    /* ---- Pressed-button tracking ---- */
    NSInteger  _pressedRegion;    /* MenuBarRegion; -1 = none */
}

/* ---------------------------------------------------------------------- */
#pragma mark - Initialisation

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _menuRects        = [NSMutableArray array];
    _menuItemIndices  = [NSMutableArray array];
    _pressedRegion    = MenuBarRegionNone;

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
#pragma mark - Public API

- (void)setActiveAppName:(NSString *)appName menuItems:(NSArray *)menuItems
{
    _activeAppName  = [appName copy];
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
    /* Only redraw the clock region to avoid full-bar flicker */
    [self setNeedsDisplayInRect:_clockRect];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Drawing

- (BOOL)isFlipped { return NO; }   /* Keep GNUstep bottom-left origin */

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = self.bounds;
    CGFloat W = bounds.size.width;
    CGFloat H = bounds.size.height;

    /* ---- Background ---- */
    [BarBackgroundColor() set];
    NSRectFill(bounds);

    /* ---- Layout state ---- */
    CGFloat leftX  = kBarPad;
    CGFloat rightX = W - kBarPad;

    /* Reset hit rects */
    [_menuRects removeAllObjects];
    [_menuItemIndices removeAllObjects];

    /* ---- RIGHT SIDE: session button + clock ---- */
    /* Session button: "⏻" (U+23FB POWER SYMBOL) */
    NSString *sessionStr = @"\u23FB";
    NSSize sessionSz = [sessionStr sizeWithAttributes:NormalTextAttrs()];
    CGFloat sessionW = sessionSz.width + kItemPad * 2;
    _sessionRect = NSMakeRect(rightX - sessionW, 0, sessionW, H);
    [self _drawButtonRect:_sessionRect
                   label:sessionStr
                    attrs:NormalTextAttrs()
               isPressed:(_pressedRegion == MenuBarRegionSession)];
    rightX -= sessionW + kItemGap;

    /* Vertical separator */
    [self _drawVerticalSeparatorAtX:rightX];
    rightX -= kSepWidth + kItemGap;

    /* Clock */
    NSString *clock = _clockString ?: @"--:--:--";
    NSSize clockSz  = [clock sizeWithAttributes:NormalTextAttrs()];
    CGFloat clockW  = clockSz.width + kItemPad * 2;
    _clockRect = NSMakeRect(rightX - clockW, 0, clockW, H);
    /* Clock is non-interactive: draw label only */
    [self _drawLabelInRect:_clockRect label:clock attrs:NormalTextAttrs()];
    rightX -= clockW + kItemGap;

    /* ---- LEFT SIDE: Ambrosia button ---- */
    NSString *ambrosiaStr  = @"  Ambrosia  ";
    NSSize    ambrosiaSz   = [ambrosiaStr sizeWithAttributes:BoldTextAttrs()];
    CGFloat   ambrosiaW    = ambrosiaSz.width;
    _ambrosiaRect = NSMakeRect(leftX, 0, ambrosiaW, H);
    [self _drawButtonRect:_ambrosiaRect
                   label:ambrosiaStr
                    attrs:BoldTextAttrs()
               isPressed:(_pressedRegion == MenuBarRegionAmbrosia)];
    leftX += ambrosiaW + kItemGap;

    /* Vertical separator after Ambrosia */
    [self _drawVerticalSeparatorAtX:leftX];
    leftX += kSepWidth + kItemGap;

    /* ---- App name (non-clickable, capped to 200 px) ---- */
    if (_activeAppName.length) {
        NSString *nameStr = _activeAppName;
        NSSize    nameSz  = [nameStr sizeWithAttributes:BoldTextAttrs()];
        CGFloat   nameW   = MIN(nameSz.width + kItemPad * 2, 200.0);
        _appNameRect = NSMakeRect(leftX, 0, nameW, H);
        [self _drawLabelInRect:_appNameRect label:nameStr attrs:BoldTextAttrs()];
        leftX += nameW + kItemGap;

        /* Separator after app name (only if we have menu items) */
        if (_activeMenuItems.count) {
            [self _drawVerticalSeparatorAtX:leftX];
            leftX += kSepWidth + kItemGap;
        }
    } else {
        _appNameRect = NSZeroRect;
    }

    /* ---- Top-level menu items (from DO-registered app) ---- */
    NSUInteger activeItemIndex = 0;
    for (NSDictionary *item in _activeMenuItems) {
        if ([item[kMenuItemSeparator] boolValue]) { activeItemIndex++; continue; }

        NSString *title  = item[kMenuItemTitle] ?: @"";
        NSSize    titleSz = [title sizeWithAttributes:NormalTextAttrs()];
        CGFloat   itemW   = titleSz.width + kItemPad * 2 + 8; /* +8 for arrow ▾ */

        /* Stop if we would overlap the clock/session area */
        if (leftX + itemW + kBarPad > rightX) break;

        NSInteger menuIdx = (NSInteger)_menuRects.count;
        NSRect itemRect = NSMakeRect(leftX, 0, itemW, H);
        [_menuRects addObject:[NSValue valueWithRect:itemRect]];
        /* Record the actual _activeMenuItems index so _showAppMenuAtIndex:
         * always gets the right descriptor even when separators are present. */
        [_menuItemIndices addObject:@(activeItemIndex)];

        BOOL isPressed = (_pressedRegion == MenuBarRegionMenuItem + menuIdx);
        [self _drawButtonRect:itemRect
                        label:[title stringByAppendingString:@" \u25BE"] /* ▾ */
                        attrs:NormalTextAttrs()
                    isPressed:isPressed];

        leftX += itemW + kItemGap;
        activeItemIndex++;
    }

    /* ---- Bottom border highlight (1 px, subtle) ---- */
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.4] set];
    NSRectFill(NSMakeRect(0, 0, W, 1.0));

    (void)dirtyRect;
}

/* ---- Drawing helpers ---- */

- (void)_drawButtonRect:(NSRect)rect
                  label:(NSString *)label
                  attrs:(NSDictionary *)attrs
              isPressed:(BOOL)pressed
{
    if (pressed) {
        [BarHighlightColor() set];
        NSRectFillUsingOperation(rect, NSCompositeSourceOver);
    }
    [self _drawLabelInRect:rect label:label attrs:attrs];
}

- (void)_drawLabelInRect:(NSRect)rect
                   label:(NSString *)label
                   attrs:(NSDictionary *)attrs
{
    NSRect textRect = CentreStringRect(label, attrs, rect);
    /* Clamp to the button rect so long titles don't bleed */
    textRect.size.width = MIN(textRect.size.width, rect.size.width);
    [label drawInRect:textRect withAttributes:attrs];
}

- (void)_drawVerticalSeparatorAtX:(CGFloat)x
{
    CGFloat H = self.bounds.size.height;
    [BarSeparatorColor() set];
    NSBezierPath *line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(x + 0.5, kSepInset)];
    [line lineToPoint:NSMakePoint(x + 0.5, H - kSepInset)];
    [line setLineWidth:kSepWidth];
    [line stroke];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Mouse events

- (void)mouseDown:(NSEvent *)event
{
    NSPoint   pt     = [self convertPoint:[event locationInWindow] fromView:nil];
    NSInteger region = [self _regionForPoint:pt];
    if (region == MenuBarRegionNone) return;

    /* Highlight the item immediately for visual feedback. */
    _pressedRegion = region;
    [self setNeedsDisplay:YES];

    /* All interactive regions display a pop-up menu.
     * -popUpContextMenu:withEvent:forView: expects a mouseDown event and runs
     * its own internal tracking loop until the mouse button is released.
     * Calling it here (on mouseDown) means the menu tracks the mouse drag and
     * fires the selected action on mouseUp — exactly standard menu-bar
     * behaviour.  The call blocks until the menu is dismissed.               */
    [self _activateRegion:region event:event];

    /* Menu dismissed — clear the highlight. */
    _pressedRegion = MenuBarRegionNone;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event
{
    /* All menu interactions are handled inside mouseDown's blocking
     * popUpContextMenu: call.  Just clear any residual highlight state.     */
    _pressedRegion = MenuBarRegionNone;
    [self setNeedsDisplay:YES];
}

- (NSInteger)_regionForPoint:(NSPoint)pt
{
    if (NSPointInRect(pt, _ambrosiaRect)) return MenuBarRegionAmbrosia;
    if (NSPointInRect(pt, _sessionRect))  return MenuBarRegionSession;
    for (NSUInteger i = 0; i < _menuRects.count; i++) {
        NSRect r = [[_menuRects objectAtIndex:i] rectValue];
        if (NSPointInRect(pt, r)) return MenuBarRegionMenuItem + (NSInteger)i;
    }
    return MenuBarRegionNone;
}

- (void)_activateRegion:(NSInteger)region event:(NSEvent *)event
{
    if (region == MenuBarRegionAmbrosia) {
        [self _showAmbrosiaMenuWithEvent:event];
    } else if (region == MenuBarRegionSession) {
        [self _showSessionMenuWithEvent:event];
    } else if (region >= MenuBarRegionMenuItem) {
        NSInteger idx = region - MenuBarRegionMenuItem;
        [self _showAppMenuAtIndex:idx withEvent:event];
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Pop-up menus

- (void)_showAmbrosiaMenuWithEvent:(NSEvent *)event
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Ambrosia"];

    NSMenuItem *about = (NSMenuItem *)[menu addItemWithTitle:@"About Ambrosia…"
                                                      action:@selector(_doAbout:)
                                               keyEquivalent:@""];
    about.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = (NSMenuItem *)[menu addItemWithTitle:@"System Preferences…"
                                                      action:@selector(_doPreferences:)
                                               keyEquivalent:@","];
    prefs.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *logout = (NSMenuItem *)[menu addItemWithTitle:@"Log Out…"
                                                       action:@selector(_doLogout:)
                                                keyEquivalent:@""];
    logout.target = self;

    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)_showSessionMenuWithEvent:(NSEvent *)event
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Session"];

    NSMenuItem *logout = (NSMenuItem *)[menu addItemWithTitle:@"Log Out…"
                                                       action:@selector(_doLogout:)
                                                keyEquivalent:@""];
    logout.target = self;

    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)_showAppMenuAtIndex:(NSInteger)index withEvent:(NSEvent *)event
{
    if (index < 0 || index >= (NSInteger)_menuItemIndices.count) return;

    /* Translate rect-index → _activeMenuItems index (separators are skipped
     * when building _menuRects, so the two arrays are not 1-to-1).         */
    NSUInteger activeIdx = [_menuItemIndices[(NSUInteger)index] unsignedIntegerValue];
    if (activeIdx >= _activeMenuItems.count) return;

    NSDictionary *topItem  = _activeMenuItems[activeIdx];
    NSArray      *children = topItem[kMenuItemChildren];
    if (!children.count) return;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:topItem[kMenuItemTitle] ?: @""];

    for (NSDictionary *child in children) {
        if ([child[kMenuItemSeparator] boolValue]) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }

        NSString *title    = child[kMenuItemTitle]   ?: @"(untitled)";
        NSString *keyEquiv = child[kMenuItemKeyEquiv] ?: @"";
        BOOL      enabled  = child[kMenuItemEnabled]
                             ? [child[kMenuItemEnabled] boolValue]
                             : YES;

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(_doAppMenuAction:)
                                               keyEquivalent:keyEquiv];
        item.enabled            = enabled;
        item.representedObject  = child[kMenuItemIdentifier];
        item.target             = self;
        [menu addItem:item];
    }

    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Menu action handlers

- (void)_doAbout:(id)sender       { [_controller showAbout]; }
- (void)_doPreferences:(id)sender { [_controller openSystemPreferences]; }
- (void)_doLogout:(id)sender      { [_controller logout]; }

- (void)_doAppMenuAction:(NSMenuItem *)sender
{
    NSString *identifier = [sender representedObject];
    [_controller performMenuItemWithIdentifier:identifier];
}

@end
