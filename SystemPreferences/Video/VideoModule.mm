#import "VideoModule.h"
#import <AppKit/AppKit.h>
#import "DisplayBackend.hpp"
#import "DisplayBackendFactory.hpp"

#import <vector>
#import <memory>
#import <utility>
#import <string>
#import <cstdlib>
#import <algorithm>
#import <cmath>

static inline NSString* ns(const std::string& s) {
  return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
}

static inline NSString* modeString(const ModeInfo& mi) {
  double hz = mi.refresh_mHz / 1000.0;
  return [NSString stringWithFormat:@"%ux%u@%.0f", mi.width, mi.height, std::round(hz)];
}

struct OutputModel {
  OutputInfo info;
  std::string pendingMode;
  bool hasPendingPos{false};
  int pendingX{0}, pendingY{0};
  bool hasPendingScale{false};
  double pendingScale{1.0};
};

// ─────────────────────────────────────────────────────────────────────────────
// MonitorLayoutView — drag-to-arrange canvas
// ─────────────────────────────────────────────────────────────────────────────

struct MonDisplayRect {
  std::string name;
  int sx, sy, sw, sh;  // screen-space coords / size
};

@interface MonitorLayoutView : NSView {
  std::vector<MonDisplayRect> _mons;
  NSInteger _dragIdx;
  NSInteger _selectedIdx;
  NSPoint   _dragOffset;
}
- (void)reloadWithOutputs:(const std::vector<OutputModel>&)outputs;
- (NSInteger)monitorCount;
- (NSString *)nameAtIndex:(NSInteger)i;
- (int)screenXAtIndex:(NSInteger)i;
- (int)screenYAtIndex:(NSInteger)i;
- (NSString *)selectedMonitorName;
@end

@implementation MonitorLayoutView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _dragIdx = -1;
    _selectedIdx = -1;
  }
  return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque  { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)reloadWithOutputs:(const std::vector<OutputModel>&)outputs {
  std::string selectedName;
  if (_selectedIdx >= 0 && _selectedIdx < (NSInteger)_mons.size())
    selectedName = _mons[(size_t)_selectedIdx].name;

  _mons.clear();
  for (const auto& om : outputs) {
    int w = 0, h = 0;
    for (const auto& mi : om.info.modes) {
      if (mi.id == om.info.currentModeId) { w = (int)mi.width; h = (int)mi.height; break; }
    }
    if (w == 0 || h == 0) continue;
    MonDisplayRect r;
    double uiScale = om.hasPendingScale ? om.pendingScale : om.info.scale;
    if (uiScale <= 0.0) uiScale = 1.0;
    r.name = om.info.name;
    r.sx = om.info.x; r.sy = om.info.y;
    r.sw = std::max(1, (int)std::lround((double)w / uiScale));
    r.sh = std::max(1, (int)std::lround((double)h / uiScale));
    _mons.push_back(r);
  }
  _selectedIdx = -1;
  if (!selectedName.empty()) {
    for (NSInteger i = 0; i < (NSInteger)_mons.size(); i++) {
      if (_mons[(size_t)i].name == selectedName) {
        _selectedIdx = i;
        break;
      }
    }
  }
  [self setNeedsDisplay:YES];
}

- (CGFloat)currentScale {
  if (_mons.empty()) return 1.0;
  int maxX = 0, maxY = 0;
  for (const auto& m : _mons) {
    if (m.sx + m.sw > maxX) maxX = m.sx + m.sw;
    if (m.sy + m.sh > maxY) maxY = m.sy + m.sh;
  }
  if (maxX < 1) maxX = 1920;
  if (maxY < 1) maxY = 1080;
  NSRect b = [self bounds];
  CGFloat sx = (b.size.width  - 40.0) / maxX;
  CGFloat sy = (b.size.height - 40.0) / maxY;
  return fmin(sx, sy);
}

- (NSRect)canvasRectAtIndex:(NSInteger)i {
  const auto& m = _mons[(size_t)i];
  CGFloat s = [self currentScale];
  return NSMakeRect(20.0 + m.sx * s, 20.0 + m.sy * s,
                    m.sw * s,         m.sh * s);
}

- (void)drawRect:(NSRect)dirty {
  // Create fresh each draw — autoreleased objects in static C arrays get
  // freed after the first autorelease pool drain in non-ARC GNUstep builds.
  NSColor *palette[6] = {
    [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.80 alpha:1.0],
    [NSColor colorWithCalibratedRed:0.20 green:0.65 blue:0.30 alpha:1.0],
    [NSColor colorWithCalibratedRed:0.80 green:0.45 blue:0.10 alpha:1.0],
    [NSColor colorWithCalibratedRed:0.60 green:0.20 blue:0.70 alpha:1.0],
    [NSColor colorWithCalibratedRed:0.10 green:0.60 blue:0.65 alpha:1.0],
    [NSColor colorWithCalibratedRed:0.75 green:0.20 blue:0.20 alpha:1.0],
  };

  [[NSColor colorWithCalibratedWhite:0.15 alpha:1.0] setFill];
  NSRectFill([self bounds]);

  if (_mons.empty()) {
    NSDictionary *a = @{NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.5 alpha:1.0],
                        NSFontAttributeName: [NSFont systemFontOfSize:13.0]};
    NSString *msg = @"No displays detected";
    NSSize ts = [msg sizeWithAttributes:a];
    NSRect b = [self bounds];
    [msg drawAtPoint:NSMakePoint(NSMidX(b) - ts.width*0.5, NSMidY(b) - ts.height*0.5)
      withAttributes:a];
    return;
  }

  NSDictionary *labelAttrs = @{
    NSFontAttributeName:            [NSFont boldSystemFontOfSize:10.0],
    NSForegroundColorAttributeName: [NSColor whiteColor],
  };
  NSDictionary *subAttrs = @{
    NSFontAttributeName:            [NSFont systemFontOfSize:9.0],
    NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.85 alpha:1.0],
  };

  for (NSInteger i = 0; i < (NSInteger)_mons.size(); i++) {
    const auto& m = _mons[(size_t)i];
    NSRect r = [self canvasRectAtIndex:i];

    [palette[i % 6] setFill];
    NSRectFill(r);
    [[NSColor colorWithCalibratedWhite:0.65 alpha:1.0] setStroke];
    NSFrameRect(r);
    if (i == _selectedIdx) {
      [[NSColor whiteColor] setStroke];
      NSBezierPath *selected = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)];
      [selected setLineWidth:1.0];
      [selected stroke];
    }

    // Monitor name
    NSString *nameStr = [NSString stringWithUTF8String:m.name.c_str()];
    NSSize ns1 = [nameStr sizeWithAttributes:labelAttrs];
    [nameStr drawAtPoint:NSMakePoint(NSMidX(r) - ns1.width*0.5, NSMidY(r) - ns1.height - 1.0)
          withAttributes:labelAttrs];

    // Resolution + position
    NSString *infoStr = [NSString stringWithFormat:@"%dx%d  +%d+%d", m.sw, m.sh, m.sx, m.sy];
    NSSize ns2 = [infoStr sizeWithAttributes:subAttrs];
    [infoStr drawAtPoint:NSMakePoint(NSMidX(r) - ns2.width*0.5, NSMidY(r) + 2.0)
          withAttributes:subAttrs];
  }
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  _dragIdx = -1;
  _selectedIdx = -1;
  for (NSInteger i = (NSInteger)_mons.size() - 1; i >= 0; i--) {
    NSRect r = [self canvasRectAtIndex:i];
    if (NSPointInRect(p, r)) {
      _dragIdx = i;
      _selectedIdx = i;
      _dragOffset = NSMakePoint(p.x - r.origin.x, p.y - r.origin.y);
      break;
    }
  }
  [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
  if (_dragIdx < 0 || _dragIdx >= (NSInteger)_mons.size()) return;
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  CGFloat s = [self currentScale];
  if (s <= 0.0) return;

  static const int kSnapThreshold = 100;

  int newSX = (int)((p.x - _dragOffset.x - 20.0) / s);
  int newSY = (int)((p.y - _dragOffset.y - 20.0) / s);

  const MonDisplayRect &dragMon = _mons[(size_t)_dragIdx];
  int snappedSX = newSX;
  int snappedSY = newSY;
  int bestSnapDx = kSnapThreshold + 1;
  int bestSnapDy = kSnapThreshold + 1;

  for (NSInteger i = 0; i < (NSInteger)_mons.size(); i++) {
    if (i == _dragIdx) continue;

    const MonDisplayRect &other = _mons[(size_t)i];

    int otherLeft = other.sx;
    int otherRight = other.sx + other.sw;
    int otherTop = other.sy;
    int otherBottom = other.sy + other.sh;

    // Horizontal edge snaps: left-to-right and right-to-left.
    int dLeftToRight = std::abs(newSX - otherRight);
    if (dLeftToRight <= kSnapThreshold && dLeftToRight < bestSnapDx) {
      snappedSX = otherRight;
      bestSnapDx = dLeftToRight;
    }

    int dRightToLeft = std::abs((newSX + dragMon.sw) - otherLeft);
    if (dRightToLeft <= kSnapThreshold && dRightToLeft < bestSnapDx) {
      snappedSX = otherLeft - dragMon.sw;
      bestSnapDx = dRightToLeft;
    }

    // Vertical edge snaps: top-to-bottom and bottom-to-top.
    int dTopToBottom = std::abs(newSY - otherBottom);
    if (dTopToBottom <= kSnapThreshold && dTopToBottom < bestSnapDy) {
      snappedSY = otherBottom;
      bestSnapDy = dTopToBottom;
    }

    int dBottomToTop = std::abs((newSY + dragMon.sh) - otherTop);
    if (dBottomToTop <= kSnapThreshold && dBottomToTop < bestSnapDy) {
      snappedSY = otherTop - dragMon.sh;
      bestSnapDy = dBottomToTop;
    }
  }

  _mons[(size_t)_dragIdx].sx = MAX(0, snappedSX);
  _mons[(size_t)_dragIdx].sy = MAX(0, snappedSY);
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
  _dragIdx = -1;
}

- (NSInteger)monitorCount { return (NSInteger)_mons.size(); }

- (NSString *)nameAtIndex:(NSInteger)i {
  return [NSString stringWithUTF8String:_mons[(size_t)i].name.c_str()];
}

- (int)screenXAtIndex:(NSInteger)i { return _mons[(size_t)i].sx; }
- (int)screenYAtIndex:(NSInteger)i { return _mons[(size_t)i].sy; }
- (NSString *)selectedMonitorName {
  if (_selectedIdx < 0 || _selectedIdx >= (NSInteger)_mons.size()) return nil;
  return [NSString stringWithUTF8String:_mons[(size_t)_selectedIdx].name.c_str()];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// VideoModule
// ─────────────────────────────────────────────────────────────────────────────

@interface VideoModule () <NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate>
{
  std::unique_ptr<DisplayBackend> _backend;
  std::vector<OutputModel> _outputs;
  NSInteger _selectedOutputRow;
  NSTableView *_scaleTableView;
  MonitorLayoutView *_layoutView;
  NSTabView *_tabView;
  std::string _primaryOutputName;
}
@property (nonatomic, strong) NSTimer *revertTimer;
@end

@implementation VideoModule

- (NSString *)systemPreferencesPath {
  NSString *prefsDir = [NSHomeDirectory() stringByAppendingPathComponent:@"GNUstep/Defaults"];
  [[NSFileManager defaultManager] createDirectoryAtPath:prefsDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return [prefsDir stringByAppendingPathComponent:@"SystemPreferences.plist"];
}

- (void)saveScreenSettingsToPreferences {
  NSMutableArray *screens = [NSMutableArray arrayWithCapacity:_outputs.size()];

  for (const auto &entry : _outputs) {
    const ModeInfo *currentMode = nullptr;
    for (const auto &mode : entry.info.modes) {
      if (mode.id == entry.info.currentModeId) {
        currentMode = &mode;
        break;
      }
    }

    NSMutableDictionary *screen = [NSMutableDictionary dictionary];
    screen[@"name"] = ns(entry.info.name);
    screen[@"scale"] = @(entry.info.scale);
    screen[@"primary"] = @(entry.info.name == _primaryOutputName);
    screen[@"location"] = @{
      @"x": @(entry.info.x),
      @"y": @(entry.info.y)
    };

    if (currentMode) {
      screen[@"resolution"] = @{
        @"width": @(currentMode->width),
        @"height": @(currentMode->height),
        @"refreshHz": @(((double)currentMode->refresh_mHz) / 1000.0),
        @"modeId": ns(currentMode->id)
      };
    } else {
      screen[@"resolution"] = @{};
    }

    [screens addObject:screen];
  }

  NSString *prefsPath = [self systemPreferencesPath];
  NSMutableDictionary *prefs =
      [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath]
      ?: [NSMutableDictionary dictionary];
  prefs[@"Screens"] = screens;
  [prefs writeToFile:prefsPath atomically:YES];
}

- (void)refreshOutputsFromPreferences {
  NSString *prefsPath = [self systemPreferencesPath];
  NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
  if (!prefs) return;

  NSArray *screens = prefs[@"Screens"];
  if (![screens isKindOfClass:[NSArray class]]) return;
  _primaryOutputName.clear();

  for (NSDictionary *screen in screens) {
    if (![screen isKindOfClass:[NSDictionary class]]) continue;

    NSString *name = screen[@"name"];
    if (![name isKindOfClass:[NSString class]]) continue;

    NSDictionary *location = screen[@"location"];
    if (![location isKindOfClass:[NSDictionary class]])
      location = screen[@"Location"];
    NSNumber *scale = screen[@"scale"];
    if (![scale isKindOfClass:[NSNumber class]])
      scale = screen[@"Scale"];

    for (auto &entry : _outputs) {
      if (entry.info.name != std::string([name UTF8String])) continue;

      if ([location isKindOfClass:[NSDictionary class]]) {
        NSNumber *x = location[@"x"];
        NSNumber *y = location[@"y"];
        if ([x isKindOfClass:[NSNumber class]] && [y isKindOfClass:[NSNumber class]]) {
          entry.info.x = [x intValue];
          entry.info.y = [y intValue];
        }
      }

      if ([scale isKindOfClass:[NSNumber class]] && [scale doubleValue] > 0.0)
        entry.info.scale = [scale doubleValue];

      NSNumber *primary = screen[@"primary"];
      if (![primary isKindOfClass:[NSNumber class]])
        primary = screen[@"Primary"];
      if ([primary boolValue])
        _primaryOutputName = entry.info.name;

      break;
    }
  }
}

- (instancetype)initWithBundle:(NSBundle *)bundle {
  if ((self = [super initWithBundle:bundle]))
    _selectedOutputRow = -1;
  return self;
}

// ── Build "Resolution Settings" tab content ──────────────────────────────────

- (void)buildResolutionTabInto:(NSView *)tv {
  // Outputs list
  if (!self.deviceTableView) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 174, 180, 200)];
    self.deviceTableView = [[NSTableView alloc] initWithFrame:[sv bounds]];
    NSTableColumn *cName = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    cName.title = @"Display (Output)"; cName.width = 160;
    [self.deviceTableView addTableColumn:cName];
    self.deviceTableView.delegate   = (id)self;
    self.deviceTableView.dataSource = (id)self;
    [sv setDocumentView:self.deviceTableView];
    sv.hasVerticalScroller = YES;
    [tv addSubview:sv];
  }

  // Modes list
  if (!self.outputDeviceTableView) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(200, 174, 202, 200)];
    self.outputDeviceTableView = [[NSTableView alloc] initWithFrame:[sv bounds]];
    NSTableColumn *m = [[NSTableColumn alloc] initWithIdentifier:@"mode"];
    m.title = @"Resolution @Hz"; m.width = 100;
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"current"];
    c.title = @"Current"; c.width = 90;
    NSTableColumn *p = [[NSTableColumn alloc] initWithIdentifier:@"pending"];
    p.title = @"Pending"; p.width = 90;
    [self.outputDeviceTableView addTableColumn:m];
    self.outputDeviceTableView.delegate         = (id)self;
    self.outputDeviceTableView.dataSource       = (id)self;
    self.outputDeviceTableView.allowsEmptySelection = NO;
    [sv setDocumentView:self.outputDeviceTableView];
    sv.hasVerticalScroller = YES;
    [tv addSubview:sv];
  }

  // Scale presets list
  if (!_scaleTableView) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(410, 174, 90, 200)];
    _scaleTableView = [[NSTableView alloc] initWithFrame:[sv bounds]];
    NSTableColumn *s = [[NSTableColumn alloc] initWithIdentifier:@"scalePreset"];
    s.title = @"Scale"; s.width = 80;
    [_scaleTableView addTableColumn:s];
    _scaleTableView.delegate   = (id)self;
    _scaleTableView.dataSource = (id)self;
    _scaleTableView.allowsEmptySelection = NO;
    [sv setDocumentView:_scaleTableView];
    sv.hasVerticalScroller = YES;
    [tv addSubview:sv];
  }

  // Details table
  if (!self.inputDeviceTableView) {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 22, 696, 120)];
    self.inputDeviceTableView = [[NSTableView alloc] initWithFrame:[sv bounds]];
    NSTableColumn *d = [[NSTableColumn alloc] initWithIdentifier:@"detail"];
    d.title = @"Property"; d.width = 250;
    NSTableColumn *v = [[NSTableColumn alloc] initWithIdentifier:@"value"];
    v.title = @"Value"; v.width = 420;
    v.editable = YES;
    [self.inputDeviceTableView addTableColumn:d];
    [self.inputDeviceTableView addTableColumn:v];
    self.inputDeviceTableView.delegate   = (id)self;
    self.inputDeviceTableView.dataSource = (id)self;
    [sv setDocumentView:self.inputDeviceTableView];
    sv.hasVerticalScroller = YES;
    [tv addSubview:sv];
  }

  // Apply button
  if (!self.ApplyButton) {
    self.ApplyButton = [[NSButton alloc] initWithFrame:NSMakeRect(450, 8, 110, 28)];
    self.ApplyButton.title       = @"Apply";
    self.ApplyButton.bezelStyle  = NSRoundedBezelStyle;
    self.ApplyButton.target      = self;
    self.ApplyButton.action      = @selector(onApply:);
    [tv addSubview:self.ApplyButton];
  }
}

// ── Build "Layout" tab content ────────────────────────────────────────────────

- (void)buildLayoutTabInto:(NSView *)tv {
  if (_layoutView) return;

  // Canvas fills most of the tab; buttons sit in a 36-px strip at the bottom.
  NSRect canvasFrame = NSMakeRect(8, 44, 700, 340);
  _layoutView = [[MonitorLayoutView alloc] initWithFrame:canvasFrame];
  _layoutView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [tv addSubview:_layoutView];

  NSButton *detectBtn = [[NSButton alloc] initWithFrame:NSMakeRect(8, 8, 150, 28)];
  detectBtn.title      = @"Detect Displays";
  detectBtn.bezelStyle = NSRoundedBezelStyle;
  detectBtn.target     = self;
  detectBtn.action     = @selector(onDetectDisplays:);
  [tv addSubview:detectBtn];

  NSButton *applyBtn = [[NSButton alloc] initWithFrame:NSMakeRect(420, 8, 142, 28)];
  applyBtn.title      = @"Apply Layout";
  applyBtn.bezelStyle = NSRoundedBezelStyle;
  applyBtn.target     = self;
  applyBtn.action     = @selector(onApplyLayout:);
  [tv addSubview:applyBtn];

  NSButton *primaryBtn = [[NSButton alloc] initWithFrame:NSMakeRect(220, 8, 130, 28)];
  primaryBtn.title      = @"Set as Primary";
  primaryBtn.bezelStyle = NSRoundedBezelStyle;
  primaryBtn.target     = self;
  primaryBtn.action     = @selector(onSetPrimary:);
  [tv addSubview:primaryBtn];
}

// ── Root UI builder ───────────────────────────────────────────────────────────

- (void)buildUIInto:(NSView *)content {
  if (_tabView) return;

  _tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 720, 420)];
  _tabView.delegate = (id)self;
  _tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:_tabView];

  // Use a fixed content size — contentRect returns NSZeroRect before the tab
  // view is placed in a window, which causes subviews to be clipped invisible.
  NSRect contentFrame = NSMakeRect(0, 0, 716, 392);

  // --- Resolution Settings tab ---
  NSTabViewItem *resItem = [[NSTabViewItem alloc] initWithIdentifier:@"resolution"];
  resItem.label = @"Resolution Settings";
  NSView *resView = [[NSView alloc] initWithFrame:contentFrame];
  resView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  resItem.view = resView;
  [_tabView addTabViewItem:resItem];
  [self buildResolutionTabInto:resView];

  // --- Layout tab ---
  NSTabViewItem *layItem = [[NSTabViewItem alloc] initWithIdentifier:@"layout"];
  layItem.label = @"Layout";
  NSView *layView = [[NSView alloc] initWithFrame:contentFrame];
  layView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  layItem.view = layView;
  [_tabView addTabViewItem:layItem];
  [self buildLayoutTabInto:layView];
}

// ── NSPreferencePane overrides ────────────────────────────────────────────────

- (NSView *)mainView {
  NSView *v = [super mainView];
  if (!v) {
    v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 420)];
    [super setMainView:v];
    [self buildUIInto:v];
    [self openDisplayAndLoad];
  }
  return v;
}

- (void)mainViewDidLoad {
  NSView *content = [self mainView];
  if (!content) {
    content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 720, 420)];
    [self setMainView:content];
  }
  [self buildUIInto:content];
  [self openDisplayAndLoad];
}

// ── Load display data ─────────────────────────────────────────────────────────

- (void)openDisplayAndLoad {
  bool isWayland = getenv("WAYLAND_DISPLAY") != nullptr;
  NSLog(@"VideoModule: openDisplayAndLoad using %@ backend", isWayland ? @"Wayland" : @"X11");
  _backend = isWayland ? MakeWaylandBackend() : MakeX11Backend();
  _outputs.clear();
  _selectedOutputRow = -1;
  if (_backend) {
    for (auto &out : _backend->listOutputs()) {
      OutputModel m;
      m.info = out;
      m.pendingMode.clear();
      _outputs.push_back(std::move(m));
    }
  }
  [self.deviceTableView reloadData];
  [self.outputDeviceTableView reloadData];
  [_scaleTableView reloadData];
  [self.inputDeviceTableView reloadData];
  if (!_outputs.empty()) {
    _selectedOutputRow = 0;
    [self.deviceTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                      byExtendingSelection:NO];
  }
  if (_layoutView)
    [_layoutView reloadWithOutputs:_outputs];
}

// ── Revert / Apply (Resolution Settings) ─────────────────────────────────────

- (void)startRevertTimer {
  [self.revertTimer invalidate];
  self.revertTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                      target:self
                                                    selector:@selector(onRevert:)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)onRevert:(NSTimer *)t {
  if (!_backend) return;
  for (auto &e : _outputs) {
    if (!e.pendingMode.empty() && e.pendingMode != e.info.currentModeId) {
      _backend->revert(e.info.name);
      e.pendingMode.clear();
    }
  }
  [self.outputDeviceTableView reloadData];
  [self.inputDeviceTableView reloadData];
}

- (IBAction)onApply:(id)sender {
  NSLog(@"VideoModule: onApply");
  if (!_backend) return;

  // Apply pending mode changes
  for (auto &e : _outputs) {
    if (!e.pendingMode.empty() && e.pendingMode != e.info.currentModeId) {
      if (_backend->setMode(e.info.name, e.pendingMode))
        e.info.currentModeId = e.pendingMode;
      e.pendingMode.clear();
    }
    if (e.hasPendingScale && std::fabs(e.pendingScale - e.info.scale) > 0.0001) {
      if (_backend->setScale(e.info.name, e.pendingScale))
        e.info.scale = e.pendingScale;
      e.hasPendingScale = false;
    }
  }

  // Apply pending position changes (edited in the property table)
  std::vector<std::pair<std::string, std::pair<int,int>>> placements;
  for (const auto &e : _outputs)
    if (e.hasPendingPos)
      placements.push_back({e.info.name, {e.pendingX, e.pendingY}});

  if (!placements.empty() && _backend->applyPositions(placements)) {
    for (auto &e : _outputs) {
      if (e.hasPendingPos) {
        e.info.x = e.pendingX;
        e.info.y = e.pendingY;
        e.hasPendingPos = false;
      }
    }
    if (_layoutView) [_layoutView reloadWithOutputs:_outputs];
  }

  [self.revertTimer invalidate];
  self.revertTimer = nil;
  [self.deviceTableView reloadData];
  [self.outputDeviceTableView reloadData];
  [_scaleTableView reloadData];
  [self.inputDeviceTableView reloadData];
  [self saveScreenSettingsToPreferences];
}

// ── Apply Layout ──────────────────────────────────────────────────────────────

- (IBAction)onApplyLayout:(id)sender {
  NSLog(@"VideoModule: onApplyLayout");
  if (!_backend || !_layoutView) return;

  // Collect all new positions
  std::vector<std::pair<std::string, std::pair<int,int>>> placements;
  NSInteger count = [_layoutView monitorCount];
  for (NSInteger i = 0; i < count; i++) {
    NSString *name = [_layoutView nameAtIndex:i];
    int x = [_layoutView screenXAtIndex:i];
    int y = [_layoutView screenYAtIndex:i];
    placements.push_back({ std::string([name UTF8String]), { x, y } });
  }

  // Apply all at once — backend handles screen resize ordering
  if (_backend->applyPositions(placements)) {
    for (const auto& p : placements) {
      for (auto &om : _outputs) {
        if (om.info.name == p.first) { om.info.x = p.second.first; om.info.y = p.second.second; break; }
      }
    }
    [self saveScreenSettingsToPreferences];
  }

  [_layoutView reloadWithOutputs:_outputs];
}

- (IBAction)onDetectDisplays:(id)sender {
  [self openDisplayAndLoad];
}

- (IBAction)onSetPrimary:(id)sender {
  if (!_layoutView) return;
  NSString *name = [_layoutView selectedMonitorName];
  if (![name length]) return;
  _primaryOutputName = std::string([name UTF8String]);
  [self saveScreenSettingsToPreferences];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item {
  if (tabView != _tabView) return;
  if (![[item identifier] isEqual:@"layout"]) return;
  [self refreshOutputsFromPreferences];
  if (_layoutView) [_layoutView reloadWithOutputs:_outputs];
}

// ── NSTableView Data Source / Delegate ───────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
  if (tv == self.deviceTableView) return (NSInteger)_outputs.size();
  if (tv == self.outputDeviceTableView) {
    if (_selectedOutputRow < 0 || _selectedOutputRow >= (NSInteger)_outputs.size()) return 0;
    return (NSInteger)_outputs[(size_t)_selectedOutputRow].info.modes.size();
  }
  if (tv == _scaleTableView) return 5;
  if (tv == self.inputDeviceTableView) return 3;
  return 0;
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  if (tv == self.deviceTableView) {
    const auto &e = _outputs[(size_t)row].info;
    if ([col.identifier isEqual:@"name"]) return ns(e.name);
  } else if (tv == self.outputDeviceTableView) {
    if (_selectedOutputRow < 0 || _selectedOutputRow >= (NSInteger)_outputs.size()) return @"";
    const auto &e = _outputs[(size_t)_selectedOutputRow];
    if (row < 0 || row >= (NSInteger)e.info.modes.size()) return @"";
    const ModeInfo &mi = e.info.modes[(size_t)row];
    if ([col.identifier isEqual:@"mode"])    return modeString(mi);
    if ([col.identifier isEqual:@"current"]) return (mi.id == e.info.currentModeId) ? @"●" : @"";
    if ([col.identifier isEqual:@"pending"]) return (mi.id == e.pendingMode) ? @"●" : @"";
  } else if (tv == _scaleTableView) {
    static const double kScalePresets[] = {1.0, 1.5, 2.0, 2.5, 3.0};
    if ([col.identifier isEqual:@"scalePreset"])
      return [NSString stringWithFormat:@"%.1f", kScalePresets[row]];
  } else if (tv == self.inputDeviceTableView) {
    if (_selectedOutputRow < 0 || _selectedOutputRow >= (NSInteger)_outputs.size()) return @"";
    const auto &e = _outputs[(size_t)_selectedOutputRow];
    if ([col.identifier isEqual:@"detail"]) {
      if (row == 0) return @"Current Mode";
      if (row == 1) return @"Position";
      if (row == 2) return @"Scale";
    }
    if ([col.identifier isEqual:@"value"]) {
      if (row == 0) {
        for (const auto &mi : e.info.modes)
          if (mi.id == e.info.currentModeId) return modeString(mi);
        return @"—";
      }
      if (row == 1) {
        int px = e.hasPendingPos ? e.pendingX : e.info.x;
        int py = e.hasPendingPos ? e.pendingY : e.info.y;
        return [NSString stringWithFormat:@"%d, %d", px, py];
      }
      if (row == 2) {
        double scale = e.hasPendingScale ? e.pendingScale : e.info.scale;
        return [NSString stringWithFormat:@"%.2f", scale];
      }
    }
  }
  return @"";
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
  NSTableView *tv = note.object;
  if (tv == self.deviceTableView) {
    _selectedOutputRow = tv.selectedRow;
    [self.outputDeviceTableView reloadData];
    [_scaleTableView reloadData];
    [self.inputDeviceTableView reloadData];
  } else if (tv == self.outputDeviceTableView) {
    if (_selectedOutputRow < 0 || _selectedOutputRow >= (NSInteger)_outputs.size()) return;
    auto &e = _outputs[(size_t)_selectedOutputRow];
    NSInteger row = tv.selectedRow;
    if (row < 0 || row >= (NSInteger)e.info.modes.size()) return;
    e.pendingMode = e.info.modes[(size_t)row].id;
    [self.outputDeviceTableView reloadData];
    [self.inputDeviceTableView reloadData];
    [self startRevertTimer];
  } else if (tv == _scaleTableView) {
    if (_selectedOutputRow < 0 || _selectedOutputRow >= (NSInteger)_outputs.size()) return;
    NSInteger selected = tv.selectedRow;
    if (selected < 0 || selected > 4) return;
    static const double kScalePresets[] = {1.0, 1.5, 2.0, 2.5, 3.0};
    auto &e = _outputs[(size_t)_selectedOutputRow];
    e.hasPendingScale = true;
    e.pendingScale = kScalePresets[selected];
    [self.inputDeviceTableView reloadData];
  }
}

// Allow editing only the Position value cell
- (BOOL)tableView:(NSTableView *)tv shouldEditTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  return (tv == self.inputDeviceTableView &&
          [col.identifier isEqual:@"value"] &&
          (row == 1 || row == 2));
}

// Receive edited Position value ("x, y")
- (void)tableView:(NSTableView *)tv setObjectValue:(id)obj
   forTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  if (tv != self.inputDeviceTableView) return;
  if (![col.identifier isEqual:@"value"] || (row != 1 && row != 2)) return;
  if (_selectedOutputRow < 0 || _selectedOutputRow >= (NSInteger)_outputs.size()) return;

  auto &e = _outputs[(size_t)_selectedOutputRow];
  if (row == 1) {
    const char *s = [[obj description] UTF8String];
    int x = 0, y = 0;
    if (sscanf(s, "%d , %d", &x, &y) == 2 ||
        sscanf(s, "%d, %d",  &x, &y) == 2 ||
        sscanf(s, "%d,%d",   &x, &y) == 2 ||
        sscanf(s, "%dx%d",   &x, &y) == 2) {
      e.hasPendingPos = true;
      e.pendingX = x;
      e.pendingY = y;
      [self.inputDeviceTableView reloadData];
    }
    return;
  }

  if (row == 2) {
    double scale = [[obj description] doubleValue];
    if (scale >= 0.25 && scale <= 4.0) {
      e.hasPendingScale = true;
      e.pendingScale = scale;
      [self.inputDeviceTableView reloadData];
    }
  }
}

- (void)dealloc { [super dealloc]; }

@end
