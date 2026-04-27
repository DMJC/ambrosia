#import "BluetoothModule.h"

#include <unistd.h>

/* ---------------------------------------------------------------------- */
#pragma mark - Layout constants

#define BT_W            540     /* total pane width  */
#define BT_H            420     /* total pane height */
#define BT_LIST_W       210     /* device list column width */
#define BT_LIST_H       300     /* device list height */
#define BT_LIST_X        20
#define BT_LIST_Y        80
#define BT_DETAIL_X     250
#define BT_DETAIL_Y      80
#define BT_ROW_H         22
#define BT_ROW_GAP        8
#define BT_LBL_W        100
#define BT_VAL_X        360
#define BT_VAL_W        160
#define BT_BTN_W         90
#define BT_BTN_H         26
#define BT_BTN_GAP        8
#define BT_SCAN_SECONDS  10     /* bluetoothctl scan duration in seconds */

/* ---------------------------------------------------------------------- */
#pragma mark - Device dictionary keys

static NSString * const kBTName      = @"name";
static NSString * const kBTAddress   = @"address";
static NSString * const kBTPaired    = @"paired";
static NSString * const kBTTrusted   = @"trusted";
static NSString * const kBTConnected = @"connected";

/* ---------------------------------------------------------------------- */
#pragma mark - Helpers

/* Strip ANSI escape sequences and carriage returns from bluetoothctl output. */
static NSString *StripANSI(NSString *s)
{
    if (!s.length) return @"";
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"\x1b\\[[0-9;]*[A-Za-z]|\r"
        options:0 error:nil];
    return [re stringByReplacingMatchesInString:s
                                        options:0
                                          range:NSMakeRange(0, s.length)
                                   withTemplate:@""];
}

/* Run a bluetoothctl command with arguments; return stdout as NSString. */
static NSString *RunBluetoothctl(NSArray<NSString *> *args)
{
    NSTask   *task = [[NSTask alloc] init];
    NSPipe   *pipe = [NSPipe pipe];
    task.launchPath     = @"/usr/bin/bluetoothctl";
    task.arguments      = args;
    task.standardOutput = pipe;
    task.standardError  = [NSPipe pipe];   /* suppress stderr */
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        [task release];
        return @"";
    }
    NSData   *data   = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding]
                        autorelease];
    [task release];
    return StripANSI(output ?: @"");
}

/* Run bluetoothctl in interactive (piped-stdin) mode.
 * `input` is written verbatim to stdin (include "quit\n" to exit cleanly).
 * Interactive mode waits for bluetoothd to fully enumerate devices before
 * executing commands, unlike CLI-argument mode which exits too early.   */
static NSString *RunBluetoothctlInteractive(NSString *input)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *inPipe  = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    task.launchPath     = @"/usr/bin/bluetoothctl";
    task.standardInput  = inPipe;
    task.standardOutput = outPipe;
    task.standardError  = [NSPipe pipe];
    @try {
        [task launch];
    } @catch (NSException *e) {
        [task release];
        return @"";
    }
    NSFileHandle *writer = [inPipe fileHandleForWriting];
    [writer writeData:[input dataUsingEncoding:NSUTF8StringEncoding]];
    [writer closeFile];
    [task waitUntilExit];
    NSData   *data   = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding]
                        autorelease];
    [task release];
    return StripANSI(output ?: @"");
}

/* Parse "devices" output: lines of the form "Device AA:BB:CC:DD:EE:FF Name".
 * Also handles "[NEW] Device ..." lines emitted during a scan. */
static NSArray<NSDictionary *> *ParseDeviceList(NSString *output)
{
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet   *seen   = [NSMutableSet set];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        /* Strip leading "[NEW] " tag that bluetoothctl emits during scanning. */
        if ([trimmed hasPrefix:@"[NEW] "])
            trimmed = [trimmed substringFromIndex:6];
        if (![trimmed hasPrefix:@"Device "]) continue;
        NSString *rest = [trimmed substringFromIndex:7];   /* strip "Device " */
        NSRange sp = [rest rangeOfString:@" "];
        NSString *addr = (sp.location != NSNotFound)
            ? [rest substringToIndex:sp.location] : rest;
        NSString *name = (sp.location != NSNotFound)
            ? [[rest substringFromIndex:sp.location + 1]
               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
            : addr;
        if (!addr.length || [seen containsObject:addr]) continue;
        [seen addObject:addr];
        [result addObject:@{
            kBTName:      name,
            kBTAddress:   addr,
            kBTPaired:    @NO,   /* actual value filled in by ParseDeviceInfo */
            kBTTrusted:   @NO,
            kBTConnected: @NO,
        }];
    }
    return result;
}

/* Parse "info <addr>" output to obtain Paired, Trusted and Connected fields. */
static void ParseDeviceInfo(NSString *output, BOOL *outPaired, BOOL *outTrusted, BOOL *outConnected)
{
    *outPaired    = NO;
    *outTrusted   = NO;
    *outConnected = NO;
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"Paired: yes"])    *outPaired    = YES;
        if ([t hasPrefix:@"Trusted: yes"])   *outTrusted   = YES;
        if ([t hasPrefix:@"Connected: yes"]) *outConnected = YES;
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Flipped container view

@interface BTFlippedView : NSView
@end
@implementation BTFlippedView
- (BOOL)isFlipped { return YES; }
@end

/* ---------------------------------------------------------------------- */
#pragma mark - BluetoothModule

@implementation BluetoothModule

/* ---------------------------------------------------------------------- */
#pragma mark - NSPreferencePane lifecycle

- (NSView *)loadMainView
{
    NSView *container = [[BTFlippedView alloc]
                         initWithFrame:NSMakeRect(0, 0, BT_W, BT_H)];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [self setMainView:container];
    [self _buildUI:container];
    [self mainViewDidLoad];
    return [container autorelease];
}

- (void)mainViewDidLoad
{
    self.devices = [NSMutableArray array];
    self.deviceListView.dataSource = self;
    self.deviceListView.delegate   = self;
    [self _reloadPairedDevices];
}

- (void)willSelect
{
    [self _reloadPairedDevices];
}

- (void)dealloc
{
    [_devices release];
    [_deviceListView release];
    [_scanButton release];
    [_trustButton release];
    [_untrustButton release];
    [_connectButton release];
    [_disconnectButton release];
    [_statusField release];
    [_detailNameField release];
    [_detailAddressField release];
    [_detailPairedField release];
    [_detailTrustedField release];
    [_detailConnectedField release];
    [super dealloc];
}

/* ---------------------------------------------------------------------- */
#pragma mark - UI construction

static NSTextField *BTMakeLabel(NSString *text)
{
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.stringValue     = text;
    f.editable        = NO;
    f.bordered        = NO;
    f.drawsBackground = NO;
    f.selectable      = NO;
    return [f autorelease];
}

static NSTextField *BTMakeValue(void)
{
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSZeroRect];
    f.editable        = NO;
    f.bordered        = NO;
    f.drawsBackground = NO;
    f.selectable      = YES;
    return [f autorelease];
}

static NSButton *BTMakeButton(NSString *title, id target, SEL action)
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    [b setButtonType:NSMomentaryPushInButton];
    b.bezelStyle = NSRoundedBezelStyle;
    b.title      = title;
    [b setTarget:target];
    [b setAction:action];
    return [b autorelease];
}

- (void)_buildUI:(NSView *)container
{
    /* ---- Section heading ---- */
    NSTextField *heading = BTMakeLabel(@"Bluetooth Devices");
    heading.font  = [NSFont boldSystemFontOfSize:13];
    heading.frame = NSMakeRect(BT_LIST_X, 16, 300, 22);
    [container addSubview:heading];

    /* ---- Device list (left panel) ---- */
    NSTableView  *tv  = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSScrollView *sv  = [[NSScrollView alloc]
                         initWithFrame:NSMakeRect(BT_LIST_X, BT_LIST_Y,
                                                  BT_LIST_W, BT_LIST_H)];

    NSTableColumn *nameCol = [[[NSTableColumn alloc]
                                initWithIdentifier:@"name"] autorelease];
    nameCol.title = @"Name";
    nameCol.width = 130;
    [tv addTableColumn:nameCol];

    NSTableColumn *statusCol = [[[NSTableColumn alloc]
                                  initWithIdentifier:@"status"] autorelease];
    statusCol.title = @"Status";
    statusCol.width = 70;
    [tv addTableColumn:statusCol];

    tv.rowHeight              = 18;
    tv.usesAlternatingRowBackgroundColors = YES;
    sv.documentView           = tv;
    sv.hasVerticalScroller    = YES;
    sv.hasHorizontalScroller  = NO;
    [container addSubview:sv];
    self.deviceListView = tv;
    [tv release];
    [sv release];

    /* ---- Scan button ---- */
    self.scanButton = BTMakeButton(@"Scan", self, @selector(scanForDevices:));
    self.scanButton.frame = NSMakeRect(BT_LIST_X,
                                       BT_LIST_Y + BT_LIST_H + BT_ROW_GAP,
                                       BT_BTN_W, BT_BTN_H);
    [container addSubview:self.scanButton];

    /* ---- Status label ---- */
    self.statusField = BTMakeLabel(@"");
    self.statusField.frame = NSMakeRect(BT_LIST_X + BT_BTN_W + BT_BTN_GAP,
                                        BT_LIST_Y + BT_LIST_H + BT_ROW_GAP + 4,
                                        BT_LIST_W - BT_BTN_W - BT_BTN_GAP,
                                        BT_BTN_H - 8);
    [container addSubview:self.statusField];

    /* ---- Detail panel (right side) ---- */
    CGFloat y = BT_DETAIL_Y;
    CGFloat lblX = BT_DETAIL_X;

    NSTextField *detailHeading = BTMakeLabel(@"Device Info");
    detailHeading.font  = [NSFont boldSystemFontOfSize:11];
    detailHeading.frame = NSMakeRect(lblX, y - 24, 200, 18);
    [container addSubview:detailHeading];

    NSTextField *(^addRow)(NSString *, CGFloat *) =
        ^NSTextField *(NSString *labelText, CGFloat *yPtr) {
            NSTextField *lbl = BTMakeLabel(labelText);
            lbl.frame = NSMakeRect(lblX, *yPtr, BT_LBL_W, BT_ROW_H);
            [container addSubview:lbl];
            NSTextField *val = BTMakeValue();
            val.frame = NSMakeRect(BT_VAL_X, *yPtr, BT_VAL_W, BT_ROW_H);
            [container addSubview:val];
            *yPtr += BT_ROW_H + BT_ROW_GAP;
            return val;
        };

    self.detailNameField      = addRow(@"Name:",      &y);
    self.detailAddressField   = addRow(@"Address:",   &y);
    self.detailPairedField    = addRow(@"Paired:",    &y);
    self.detailTrustedField   = addRow(@"Trusted:",   &y);
    self.detailConnectedField = addRow(@"Connected:", &y);

    y += BT_ROW_GAP * 2;

    /* ---- Action buttons (right panel) ---- */
    CGFloat bx = lblX;

    self.trustButton = BTMakeButton(@"Trust",
                                    self, @selector(trustDevice:));
    self.trustButton.frame = NSMakeRect(bx, y, BT_BTN_W, BT_BTN_H);
    [container addSubview:self.trustButton];
    bx += BT_BTN_W + BT_BTN_GAP;

    self.untrustButton = BTMakeButton(@"Untrust",
                                      self, @selector(untrustDevice:));
    self.untrustButton.frame = NSMakeRect(bx, y, BT_BTN_W, BT_BTN_H);
    [container addSubview:self.untrustButton];

    y += BT_BTN_H + BT_BTN_GAP;
    bx = lblX;

    self.connectButton = BTMakeButton(@"Connect",
                                      self, @selector(connectDevice:));
    self.connectButton.frame = NSMakeRect(bx, y, BT_BTN_W, BT_BTN_H);
    [container addSubview:self.connectButton];
    bx += BT_BTN_W + BT_BTN_GAP;

    self.disconnectButton = BTMakeButton(@"Disconnect",
                                         self, @selector(disconnectDevice:));
    self.disconnectButton.frame = NSMakeRect(bx, y, BT_BTN_W + 10, BT_BTN_H);
    [container addSubview:self.disconnectButton];

    [self _updateButtonStates];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Data loading

/* Reload from bluetoothctl on a background queue, update UI on main.
 * Uses "devices" (not "paired-devices") to include trusted-only devices. */
- (void)_reloadPairedDevices
{
    self.statusField.stringValue = @"Loading\u2026";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *devOut     = RunBluetoothctlInteractive(@"devices\nquit\n");
        NSArray  *discovered = ParseDeviceList(devOut);

        /* Enrich each entry with paired, trust, and connection state. */
        NSMutableArray *enriched = [NSMutableArray array];
        for (NSDictionary *dev in discovered) {
            NSString *addr    = dev[kBTAddress];
            NSString *infoOut = RunBluetoothctl(@[@"info", addr]);
            BOOL paired = NO, trusted = NO, connected = NO;
            ParseDeviceInfo(infoOut, &paired, &trusted, &connected);
            [enriched addObject:@{
                kBTName:      dev[kBTName],
                kBTAddress:   addr,
                kBTPaired:    @(paired),
                kBTTrusted:   @(trusted),
                kBTConnected: @(connected),
            }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.devices = enriched;
            [self.deviceListView reloadData];
            self.statusField.stringValue =
                [NSString stringWithFormat:@"%lu device(s)",
                 (unsigned long)enriched.count];
            [self _updateButtonStates];
        });
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Scan via bluetoothctl

- (IBAction)scanForDevices:(id)sender
{
    if (self.scanning) return;
    self.scanning = YES;
    self.scanButton.enabled = NO;
    self.statusField.stringValue = @"Scanning\u2026";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self _runHCIScan];
    });
}

- (void)_runHCIScan
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    /* Open an interactive bluetoothctl session.  Interactive mode keeps the
     * DBus connection alive so bluetoothd can push [NEW] Device events and
     * the subsequent "devices" query returns the full cache.             */
    NSTask *task = [[NSTask alloc] init];
    NSPipe *inPipe  = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    task.launchPath     = @"/usr/bin/bluetoothctl";
    task.standardInput  = inPipe;
    task.standardOutput = outPipe;
    task.standardError  = [NSPipe pipe];
    @try {
        [task launch];
    } @catch (NSException *e) {
        [task release];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusField.stringValue = @"Could not launch bluetoothctl.";
            self.scanning = NO;
            self.scanButton.enabled = YES;
        });
        [pool release];
        return;
    }

    NSFileHandle *writer = [inPipe fileHandleForWriting];

    /* Start discovery. */
    [writer writeData:[@"scan on\n" dataUsingEncoding:NSUTF8StringEncoding]];

    /* Wait for the configured scan duration. */
    sleep(BT_SCAN_SECONDS);

    /* Stop scan and request the full device list, then quit. */
    [writer writeData:[@"scan off\ndevices\nquit\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [writer closeFile];

    /* Give bluetoothctl time to print results and exit cleanly (≤3 s). */
    sleep(3);
    if ([task isRunning])
        [task terminate];
    [task waitUntilExit];

    NSData   *data   = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = StripANSI([[[NSString alloc] initWithData:data
                                                        encoding:NSUTF8StringEncoding]
                                   autorelease] ?: @"");
    NSArray  *found  = ParseDeviceList(output);
    [task release];

    dispatch_async(dispatch_get_main_queue(), ^{
        /* Merge newly discovered devices into the list. */
        NSMutableSet *knownAddrs = [NSMutableSet set];
        for (NSDictionary *d in self.devices)
            [knownAddrs addObject:d[kBTAddress]];
        for (NSDictionary *d in found) {
            if (![knownAddrs containsObject:d[kBTAddress]])
                [self.devices addObject:d];
        }
        [self.deviceListView reloadData];
        self.statusField.stringValue =
            [NSString stringWithFormat:@"%lu device(s)",
             (unsigned long)self.devices.count];
        self.scanning = NO;
        self.scanButton.enabled = YES;
        [self _updateButtonStates];
    });

    [pool release];
}

/* ---------------------------------------------------------------------- */
#pragma mark - Actions

- (IBAction)trustDevice:(id)sender
{
    NSDictionary *dev = [self _selectedDevice];
    if (!dev) return;
    NSString *addr = dev[kBTAddress];
    self.statusField.stringValue = [NSString stringWithFormat:@"Trusting %@\u2026",
                                    dev[kBTName]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunBluetoothctl(@[@"trust", addr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _reloadPairedDevices];
        });
    });
}

- (IBAction)untrustDevice:(id)sender
{
    NSDictionary *dev = [self _selectedDevice];
    if (!dev) return;
    NSString *addr = dev[kBTAddress];
    self.statusField.stringValue = [NSString stringWithFormat:@"Untrusting %@\u2026",
                                    dev[kBTName]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunBluetoothctl(@[@"untrust", addr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _reloadPairedDevices];
        });
    });
}

- (IBAction)connectDevice:(id)sender
{
    NSDictionary *dev = [self _selectedDevice];
    if (!dev) return;
    NSString *addr = dev[kBTAddress];
    self.statusField.stringValue = [NSString stringWithFormat:@"Connecting %@\u2026",
                                    dev[kBTName]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunBluetoothctl(@[@"connect", addr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _reloadPairedDevices];
        });
    });
}

- (IBAction)disconnectDevice:(id)sender
{
    NSDictionary *dev = [self _selectedDevice];
    if (!dev) return;
    NSString *addr = dev[kBTAddress];
    self.statusField.stringValue = [NSString stringWithFormat:@"Disconnecting %@\u2026",
                                    dev[kBTName]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunBluetoothctl(@[@"disconnect", addr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _reloadPairedDevices];
        });
    });
}

/* ---------------------------------------------------------------------- */
#pragma mark - Helpers

- (NSDictionary *)_selectedDevice
{
    NSInteger row = self.deviceListView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.devices.count) return nil;
    return self.devices[(NSUInteger)row];
}

- (void)_updateButtonStates
{
    NSDictionary *dev = [self _selectedDevice];
    BOOL hasDev       = (dev != nil);
    BOOL connected    = [dev[kBTConnected] boolValue];
    BOOL trusted      = [dev[kBTTrusted]   boolValue];

    self.trustButton.enabled      = hasDev && !trusted;
    self.untrustButton.enabled    = hasDev && trusted;
    self.connectButton.enabled    = hasDev && !connected;
    self.disconnectButton.enabled = hasDev && connected;
}

- (void)_refreshDetailPanel
{
    NSDictionary *dev = [self _selectedDevice];
    if (!dev) {
        self.detailNameField.stringValue      = @"";
        self.detailAddressField.stringValue   = @"";
        self.detailPairedField.stringValue    = @"";
        self.detailTrustedField.stringValue   = @"";
        self.detailConnectedField.stringValue = @"";
        return;
    }
    self.detailNameField.stringValue      = dev[kBTName]      ?: @"";
    self.detailAddressField.stringValue   = dev[kBTAddress]   ?: @"";
    self.detailPairedField.stringValue    = [dev[kBTPaired]    boolValue] ? @"Yes" : @"No";
    self.detailTrustedField.stringValue   = [dev[kBTTrusted]   boolValue] ? @"Yes" : @"No";
    self.detailConnectedField.stringValue = [dev[kBTConnected] boolValue] ? @"Yes" : @"No";
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return (NSInteger)self.devices.count;
}

- (id)tableView:(NSTableView *)tv
objectValueForTableColumn:(NSTableColumn *)col
            row:(NSInteger)row
{
    NSDictionary *dev = self.devices[(NSUInteger)row];
    if ([col.identifier isEqualToString:@"name"])
        return dev[kBTName] ?: dev[kBTAddress];
    if ([col.identifier isEqualToString:@"status"]) {
        if ([dev[kBTConnected] boolValue]) return @"Connected";
        if ([dev[kBTPaired]    boolValue]) return @"Paired";
        return @"Discovered";
    }
    return @"";
}

/* ---------------------------------------------------------------------- */
#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)note
{
    [self _refreshDetailPanel];
    [self _updateButtonStates];
}

@end
