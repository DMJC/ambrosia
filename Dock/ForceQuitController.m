#import "ForceQuitController.h"

#include <signal.h>

/* Snapshot of one running app — stores only what we need so the panel stays
 * correct even if the DockController updates its item list concurrently.   */
@interface FQAppEntry : NSObject
@property (nonatomic, copy) NSString  *label;
@property (nonatomic)       NSInteger  pid;
@end
@implementation FQAppEntry
@end

/* ---------------------------------------------------------------------- */

@implementation ForceQuitController {
    NSPanel                    *_panel;
    NSTableView                *_tableView;
    NSButton                   *_killButton;
    NSMutableArray<FQAppEntry *> *_entries;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _entries = [NSMutableArray array];
    return self;
}

/* ---------------------------------------------------------------------- */
#pragma mark - Public API

- (void)updateWithItems:(NSArray<DockItem *> *)items
{
    [_entries removeAllObjects];
    for (DockItem *item in items) {
        FQAppEntry *e = [[FQAppEntry alloc] init];
        e.label = item.label ?: @"Unknown";
        e.pid   = item.pid;
        [_entries addObject:e];
    }
    [_tableView reloadData];
    [self _updateKillButton];
}

- (void)showPanel
{
    if (!_panel)
        [self _buildPanel];

    /* Refresh kill-button state in case the selection was cleared. */
    [self _updateKillButton];

    NSScreen *screen = [NSScreen mainScreen];
    if (screen) {
        NSRect sf   = screen.frame;
        NSRect pf   = _panel.frame;
        NSPoint origin = NSMakePoint(
            sf.origin.x + floor((sf.size.width  - pf.size.width)  * 0.5),
            sf.origin.y + floor((sf.size.height - pf.size.height) * 0.5));
        [_panel setFrameOrigin:origin];
    }

    [_panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Panel construction

- (void)_buildPanel
{
    const CGFloat W = 360, H = 300;

    _panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _panel.title          = @"Force Quit Applications";
    _panel.releasedWhenClosed = NO;
    _panel.level          = NSFloatingWindowLevel;

    NSView *content = _panel.contentView;

    /* --- heading label --- */
    NSTextField *heading = [[NSTextField alloc]
        initWithFrame:NSMakeRect(16, H - 44, W - 32, 22)];
    heading.stringValue = @"Select an application to force-quit:";
    heading.editable    = NO;
    heading.bordered    = NO;
    heading.drawsBackground = NO;
    [content addSubview:heading];

    /* --- scroll view + table --- */
    NSScrollView *scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(16, 60, W - 32, H - 110)];
    scroll.hasVerticalScroller   = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers    = YES;
    scroll.borderType            = NSBezelBorder;

    _tableView = [[NSTableView alloc]
        initWithFrame:NSMakeRect(0, 0, scroll.contentSize.width,
                                       scroll.contentSize.height)];
    NSTableColumn *col = [[NSTableColumn alloc]
        initWithIdentifier:@"AppName"];
    col.title  = @"Application";
    col.width  = scroll.contentSize.width - 4;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:col];

    _tableView.dataSource       = self;
    _tableView.delegate         = self;
    _tableView.allowsEmptySelection = YES;
    _tableView.allowsMultipleSelection = NO;
    _tableView.usesAlternatingRowBackgroundColors = YES;

    scroll.documentView = _tableView;
    [content addSubview:scroll];

    /* --- buttons --- */
    _killButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(16, 16, 100, 32)];
    _killButton.title  = @"Kill";
    _killButton.target = self;
    _killButton.action = @selector(_killSelected:);
    _killButton.bezelStyle = NSRoundedBezelStyle;
    [content addSubview:_killButton];

    NSButton *cancelButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(W - 116, 16, 100, 32)];
    cancelButton.title  = @"Cancel";
    cancelButton.target = self;
    cancelButton.action = @selector(_cancel:);
    cancelButton.bezelStyle = NSRoundedBezelStyle;
    [content addSubview:cancelButton];

    [self _updateKillButton];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Button actions

- (void)_killSelected:(id)sender
{
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_entries.count) return;

    FQAppEntry *entry = _entries[(NSUInteger)row];
    if (entry.pid > 0) {
        kill((pid_t)entry.pid, SIGKILL);
        [_entries removeObjectAtIndex:(NSUInteger)row];
        [_tableView reloadData];
        [self _updateKillButton];
    }
}

- (void)_cancel:(id)sender
{
    [_panel orderOut:nil];
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)_entries.count;
}

- (id)tableView:(NSTableView *)tv
    objectValueForTableColumn:(NSTableColumn *)col
                          row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)_entries.count) return @"";
    return _entries[(NSUInteger)row].label;
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)note
{
    [self _updateKillButton];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Helpers

- (void)_updateKillButton
{
    _killButton.enabled = (_tableView.selectedRow >= 0
                           && _tableView.selectedRow < (NSInteger)_entries.count);
}

@end
