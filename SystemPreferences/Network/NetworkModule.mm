#import "NetworkModule.h"

static const CGFloat kConnectionRowHeight = 40.0;

@implementation NetworkModule

- (void)dealloc {
    [_connectionListView release];
    [_connectionTypes release];
    [_addButton release];
    [_removeButton release];
    [_statusField release];
    [_ipField release];
    [_maskField release];
    [_routerField release];
    [_dnsField release];
    [_searchField release];
    [_methodPopup release];
    [_showWiFiInMenuBarButton release];
    [super dealloc];
}

- (void)mainViewDidLoad {
    [super mainViewDidLoad];
    [self setupUI];
}

#pragma mark - Data

- (NSArray *)fetchConnectionTypes {
    NSMutableArray *connections = [NSMutableArray array];
    @try {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/bin/env"];
        [task setArguments:@[@"nmcli", @"-t", @"-f", @"DEVICE,TYPE,STATE", @"device", @"status"]];
        NSPipe *pipe = [NSPipe pipe];
        [task setStandardOutput:pipe];
        [task launch];
        [task waitUntilExit];

        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        NSArray *lines = [output componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line length] == 0) {
                continue;
            }
            NSArray *parts = [line componentsSeparatedByString:@":"];
            if ([parts count] < 3) {
                continue;
            }

            NSString *device = [parts objectAtIndex:0];
            NSString *type = [parts objectAtIndex:1];
            NSString *state = [[parts subarrayWithRange:NSMakeRange(2, [parts count] - 2)] componentsJoinedByString:@":"];
            if ([device length] == 0 || [device isEqualToString:@"--"]) {
                continue;
            }

            BOOL connected = ([state rangeOfString:@"connected" options:NSCaseInsensitiveSearch].location != NSNotFound);
            NSImage *icon = [self iconForConnectionType:type];
            if (!icon) {
                NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:@"Network" ofType:@"tiff"];
                icon = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
            }

            NSString *displayName = [NSString stringWithFormat:@"%@ (%@)", device, type];
            [connections addObject:@{
                @"name": displayName,
                @"device": device,
                @"type": type,
                @"icon": icon,
                @"connected": @(connected)
            }];
        }
    }
    @catch (NSException *exception) {
        // ignore and fall back to defaults
    }

    if ([connections count] == 0) {
        NSArray *fallback = @[@"ethernet", @"wifi", @"bond", @"ip-tunnel",
                              @"macsec", @"team", @"loopback", @"wifi-p2p", @"vlan", @"wireguard",
                              @"bridge", @"bluetooth", @"dsl", @"infiniband",
                              @"gsm", @"vpn"];
        for (NSString *type in fallback) {
            NSImage *icon = [self iconForConnectionType:type];
            if (!icon) {
                NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:@"Network" ofType:@"tiff"];
                icon = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
            }
            [connections addObject:@{
                @"name": type,
                @"type": type,
                @"icon": icon,
                @"connected": @NO
            }];
        }
    }

    return connections;
}

- (void)reloadConnectionList {
    self.connectionTypes = [self fetchConnectionTypes];
    NSInteger rowCount = [self.connectionTypes count];
    CGFloat tableHeight = kConnectionRowHeight * rowCount;
    if (tableHeight < 300)
        tableHeight = 300;
    [self.connectionListView setFrame:NSMakeRect(0, 0, 160, tableHeight)];
    [self.connectionListView reloadData];
}

- (NSImage *)iconForConnectionType:(NSString *)type {
    NSString *iconName = nil;
    if ([type caseInsensitiveCompare:@"ethernet"] == NSOrderedSame) {
        iconName = @"Ethernet";
    } else if ([type caseInsensitiveCompare:@"bluetooth"] == NSOrderedSame) {
        iconName = @"bluetooth";
    } else if ([type caseInsensitiveCompare:@"wifi"] == NSOrderedSame) {
	iconName = @"wireless";
    } else if ([type caseInsensitiveCompare:@"wireless"] == NSOrderedSame) {
	iconName = @"wireless";
    } else {
        iconName = @"Network";
    }

    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:iconName ofType:@"tiff"];
    return [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
}

- (NSImage *)dotImageForState:(BOOL)connected {
    static NSImage *greenDot = nil;
    static NSImage *redDot = nil;
    if (!greenDot) {
        NSImage *g = [[[NSImage alloc] initWithSize:NSMakeSize(8, 8)] autorelease];
        [g lockFocus];
        [[NSColor greenColor] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 8, 8)] fill];
        [g unlockFocus];
        greenDot = [g retain];

        NSImage *r = [[[NSImage alloc] initWithSize:NSMakeSize(8, 8)] autorelease];
        [r lockFocus];
        [[NSColor redColor] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, 8, 8)] fill];
        [r unlockFocus];
        redDot = [r retain];
    }
    return connected ? greenDot : redDot;
}

- (NSString *)maskFromPrefix:(NSInteger)prefix {
    uint32_t mask = prefix == 0 ? 0 : 0xffffffff << (32 - prefix);
    return [NSString stringWithFormat:@"%d.%d.%d.%d",
            (mask >> 24) & 0xFF,
            (mask >> 16) & 0xFF,
            (mask >> 8) & 0xFF,
            mask & 0xFF];
}

- (NSDictionary *)detailsForConnection:(NSDictionary *)connection {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSString *device = [connection objectForKey:@"device"];
    BOOL connectedFromList = [[connection objectForKey:@"connected"] boolValue];

    @try {
        if ([device length] > 0) {
            NSTask *detail = [[NSTask alloc] init];
            [detail setLaunchPath:@"/usr/bin/env"];
            [detail setArguments:@[@"nmcli", @"-t", @"-f",
                                   @"GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP4.DOMAIN",
                                   @"device", @"show", device]];
            NSPipe *dpipe = [NSPipe pipe];
            [detail setStandardOutput:dpipe];
            [detail launch];
            [detail waitUntilExit];
            NSData *ddata = [[dpipe fileHandleForReading] readDataToEndOfFile];
            NSString *dout = [[[NSString alloc] initWithData:ddata encoding:NSUTF8StringEncoding] autorelease];
            NSArray *dl = [dout componentsSeparatedByString:@"\n"];
            BOOL connected = connectedFromList;
            for (NSString *l in dl) {
                if ([l hasPrefix:@"GENERAL.STATE:"]) {
                    connected = ([l rangeOfString:@"connected" options:NSCaseInsensitiveSearch].location != NSNotFound);
                } else if ([l hasPrefix:@"IP4.ADDRESS"]) {
                    NSString *val = [[l componentsSeparatedByString:@":"] lastObject];
                    NSRange slash = [val rangeOfString:@"/"];
                    if (slash.location != NSNotFound) {
                        NSString *ip = [val substringToIndex:slash.location];
                        NSInteger prefix = [[val substringFromIndex:slash.location + 1] integerValue];
                        [info setObject:ip forKey:@"ip"];
                        [info setObject:[self maskFromPrefix:prefix] forKey:@"mask"];
                    } else {
                        [info setObject:val forKey:@"ip"];
                    }
                } else if ([l hasPrefix:@"IP4.GATEWAY:"]) {
                    [info setObject:[[l componentsSeparatedByString:@":"] lastObject] forKey:@"router"];
                } else if ([l hasPrefix:@"IP4.DNS"]) {
                    NSString *dns = [info objectForKey:@"dns"];
                    NSString *val = [[l componentsSeparatedByString:@":"] lastObject];
                    if (dns) {
                        dns = [dns stringByAppendingFormat:@",%@", val];
                        [info setObject:dns forKey:@"dns"];
                    } else {
                        [info setObject:val forKey:@"dns"];
                    }
                } else if ([l hasPrefix:@"IP4.DOMAIN"]) {
                    NSString *domains = [info objectForKey:@"search"];
                    NSString *val = [[l componentsSeparatedByString:@":"] lastObject];
                    if (domains) {
                        domains = [domains stringByAppendingFormat:@",%@", val];
                        [info setObject:domains forKey:@"search"];
                    } else {
                        [info setObject:val forKey:@"search"];
                    }
                }
            }
            [info setObject:(connected ? @"Connected" : @"Disconnected") forKey:@"status"];

            NSTask *methodTask = [[NSTask alloc] init];
            [methodTask setLaunchPath:@"/usr/bin/env"];
            [methodTask setArguments:@[@"nmcli", @"-t", @"-f",
                                       @"DEVICE,IP4.METHOD,IP4.ADDRESS",
                                       @"connection", @"show", @"--active"]];
            NSPipe *mpipe = [NSPipe pipe];
            [methodTask setStandardOutput:mpipe];
            [methodTask launch];
            [methodTask waitUntilExit];
            NSData *mdata = [[mpipe fileHandleForReading] readDataToEndOfFile];
            NSString *mout = [[[NSString alloc] initWithData:mdata encoding:NSUTF8StringEncoding] autorelease];
            NSArray *mlines = [mout componentsSeparatedByString:@"\n"];
            for (NSString *ml in mlines) {
                NSArray *mparts = [ml componentsSeparatedByString:@":"];
                if ([mparts count] >= 2 && [[mparts objectAtIndex:0] isEqualToString:device]) {
                    NSString *method = [mparts objectAtIndex:1];
                    NSString *addr = ([mparts count] > 2) ? [mparts objectAtIndex:2] : @"";
                    if ([method isEqualToString:@"manual"]) {
                        [info setObject:@"manual" forKey:@"method"];
                    } else if ([addr length] > 0) {
                        [info setObject:@"auto-manual" forKey:@"method"];
                    } else {
                        [info setObject:@"auto" forKey:@"method"];
                    }
                    break;
                }
            }
        }

        if (![info objectForKey:@"status"]) {
            [info setObject:(connectedFromList ? @"Connected" : @"Disconnected") forKey:@"status"];
        }
    }
    @catch (NSException *exception) {
        if (![info objectForKey:@"status"]) {
            [info setObject:(connectedFromList ? @"Connected" : @"Disconnected") forKey:@"status"];
        }
    }

    return info;
}

#pragma mark - UI Setup

- (void)setupUI {
    NSView *contentView = [self mainView];
    self.mainView.frame = NSMakeRect(0, 0, 400, 360);

    NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 40, 160, 300)] autorelease];
    NSTableView *tableView = [[[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 160, 300)] autorelease];
    [tableView setRowHeight:kConnectionRowHeight];
    NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:@"TypeColumn"] autorelease];
    [column setWidth:160];
    [tableView addTableColumn:column];
    [tableView setHeaderView:nil];
    tableView.delegate = self;
    tableView.dataSource = self;
    self.connectionListView = tableView;
    [scrollView setDocumentView:tableView];
    [scrollView setHasVerticalScroller:YES];
    [contentView addSubview:scrollView];
    [self reloadConnectionList];
    [self.connectionListView noteNumberOfRowsChanged];

    self.addButton = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 10, 20, 20)] autorelease];
    [self.addButton setTitle:@"+"];
    [self.addButton setTarget:self];
    [self.addButton setAction:@selector(addConnection:)];
    [contentView addSubview:self.addButton];

    self.removeButton = [[[NSButton alloc] initWithFrame:NSMakeRect(50, 10, 20, 20)] autorelease];
    [self.removeButton setTitle:@"-"];
    [self.removeButton setTarget:self];
    [self.removeButton setAction:@selector(removeConnection:)];
    [contentView addSubview:self.removeButton];

    // Show Wi-Fi status in menu bar checkbox
    self.showWiFiInMenuBarButton = [[[NSButton alloc]
        initWithFrame:NSMakeRect(80, 10, 300, 20)] autorelease];
    [self.showWiFiInMenuBarButton setTitle:@"Show Wi-Fi status in menu bar"];
    [self.showWiFiInMenuBarButton setButtonType:NSSwitchButton];
    [self.showWiFiInMenuBarButton setTarget:self];
    [self.showWiFiInMenuBarButton setAction:@selector(showWiFiInMenuBarChanged:)];
    [contentView addSubview:self.showWiFiInMenuBarButton];

    // Restore saved state for the checkbox
    {
        NSString *prefsPath = [NSHomeDirectory() stringByAppendingPathComponent:
                               @"GNUstep/Defaults/AmbrosiaMenuBar.plist"];
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
        BOOL show = [prefs[@"ShowWiFiMenu"] boolValue];
        [self.showWiFiInMenuBarButton
            setState:(show ? NSControlStateValueOn : NSControlStateValueOff)];
    }

    CGFloat labelX = 200.0;
    CGFloat valueX = 300.0;
    CGFloat startY = 350.0;

    NSTextField *(^makeLabel)(NSString *, CGFloat) = ^NSTextField *(NSString *text, CGFloat y) {
        NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(labelX, y, 100, 20)] autorelease];
        [label setBezeled:NO];
        [label setDrawsBackground:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setStringValue:text];
        [label setBordered:NO];
        [contentView addSubview:label];
        return label;
    };

    NSTextField *(^makeValueField)(CGFloat) = ^NSTextField *(CGFloat y) {
        NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(valueX, y, 140, 20)] autorelease];
        [field setEditable:NO];
        [field setBezeled:NO];
        [field setDrawsBackground:NO];
        [field setSelectable:NO];
        [field setBordered:NO];

        [contentView addSubview:field];
        return field;
    };

    makeLabel(@"Status:", startY - 30);
    self.statusField = makeValueField(startY - 30);

    makeLabel(@"Configure IPv4:", startY - 60);
    self.methodPopup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(valueX, startY - 60, 140, 26)] autorelease];
    [self.methodPopup addItemsWithTitles:@[@"Manually", @"Using DHCP", @"Using DHCP with manual address"]];
    [self.methodPopup setTarget:self];
    [self.methodPopup setAction:@selector(methodChanged:)];
    [contentView addSubview:self.methodPopup];

    makeLabel(@"IP Address:", startY - 90);
    self.ipField = makeValueField(startY - 90);

    makeLabel(@"Subnet Mask:", startY - 120);
    self.maskField = makeValueField(startY - 120);

    makeLabel(@"Router:", startY - 150);
    self.routerField = makeValueField(startY - 150);

    makeLabel(@"DNS Server:", startY - 180);
    self.dnsField = makeValueField(startY - 180);

    makeLabel(@"Search Domains:", startY - 210);
    self.searchField = makeValueField(startY - 210);
    [self updateFieldEditability];

//    makeLabel(@"Router:", startY - 240);
//    self.routerField = makeValueField(startY - 240);

}

#pragma mark - Editing

- (void)updateFieldEditability {
    BOOL manual = ([self.methodPopup indexOfSelectedItem] == 0);
    NSArray *fields = @[ self.ipField, self.maskField, self.routerField, self.dnsField, self.searchField ];
    for (NSTextField *field in fields) {
        [field setEditable:manual];
        [field setBezeled:manual];
        [field setSelectable:manual];
        [field setBordered:manual];
        [field setDrawsBackground:manual];
    }
}

- (void)methodChanged:(id)sender {
    [self updateFieldEditability];
}

#pragma mark - Actions

- (void)addConnection:(id)sender {
    NSLog(@"Add Connection Pressed");
}

- (void)removeConnection:(id)sender {
    NSInteger row = [self.connectionListView selectedRow];
    if (row >= 0) {
        NSLog(@"Remove Connection at row %ld", (long)row);
    }
}

- (void)showWiFiInMenuBarChanged:(NSButton *)sender {
    NSString *prefsDir  = [NSHomeDirectory() stringByAppendingPathComponent:@"GNUstep/Defaults"];
    NSString *prefsPath = [prefsDir stringByAppendingPathComponent:@"AmbrosiaMenuBar.plist"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSMutableDictionary *prefs =
        [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath]
        ?: [NSMutableDictionary dictionary];
    prefs[@"ShowWiFiMenu"] = @(sender.state == NSControlStateValueOn);
    [prefs writeToFile:prefsPath atomically:YES];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"AmbrosiaMenuBarPrefsChanged"
                      object:nil
                    userInfo:nil
          deliverImmediately:YES];
}

#pragma mark - TableView Data Source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return [self.connectionTypes count];
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return kConnectionRowHeight;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSDictionary *info = [self.connectionTypes objectAtIndex:row];
    CGFloat width = [tableColumn width];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"TypeCell" owner:self];
    if (!cell) {
        cell = [[[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, width, kConnectionRowHeight)] autorelease];
        cell.identifier = @"TypeCell";

	NSImageView *imageView = [[[NSImageView alloc] initWithFrame:NSMakeRect(2, 8, 24, 24)] autorelease];
        [imageView setImageScaling:NSImageScaleProportionallyDown];
        [imageView setTag:1];
        cell.imageView = imageView;
        [cell addSubview:imageView];

        NSTextField *nameField = [[[NSTextField alloc] initWithFrame:NSMakeRect(32, 22, width - 34, 16)] autorelease];
        [nameField setBezeled:NO];
        [nameField setBordered:NO];
        [nameField setEditable:NO];
        [nameField setDrawsBackground:NO];
        [nameField setTag:2];
        cell.textField = nameField;
        [cell addSubview:nameField];

        NSImageView *dotView = [[[NSImageView alloc] initWithFrame:NSMakeRect(32, 6, 8, 8)] autorelease];
        [dotView setTag:3];
        [cell addSubview:dotView];

        NSTextField *statusField = [[[NSTextField alloc] initWithFrame:NSMakeRect(44, 2, width - 46, 16)] autorelease];
        [statusField setBordered:NO];
        [statusField setBezeled:NO];
        [statusField setEditable:NO];
        [statusField setBackgroundColor:[NSColor clearColor]];
        [statusField setTag:4];
        [cell addSubview:statusField];
    }
    NSImageView *imageView = [cell viewWithTag:1];
    NSTextField *nameField = [cell viewWithTag:2];
    NSImageView *dotView = [cell viewWithTag:3];
    NSTextField *statusField = [cell viewWithTag:4];

    [imageView setImage:[info objectForKey:@"icon"]];
    [nameField setStringValue:[info objectForKey:@"name"]];
    BOOL connected = [[info objectForKey:@"connected"] boolValue];
    [dotView setImage:[self dotImageForState:connected]];
    [statusField setStringValue:(connected ? @"Connected" : @"Disconnected")];

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = [self.connectionListView selectedRow];
    if (row < 0 || row >= [self.connectionTypes count]) {
        return;
    }
    NSDictionary *selectedConnection = [self.connectionTypes objectAtIndex:row];
    NSDictionary *details = [self detailsForConnection:selectedConnection];
    self.statusField.stringValue = [details objectForKey:@"status"] ?: @"";
    self.ipField.stringValue = [details objectForKey:@"ip"] ?: @"";
    self.maskField.stringValue = [details objectForKey:@"mask"] ?: @"";
    self.routerField.stringValue = [details objectForKey:@"router"] ?: @"";
    self.dnsField.stringValue = [details objectForKey:@"dns"] ?: @"";
    self.searchField.stringValue = [details objectForKey:@"search"] ?: @"";

}

@end
