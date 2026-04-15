#import "BluetoothStatusItem.h"
#import <AppKit/AppKit.h>

/* Refresh interval in seconds */
static const NSTimeInterval kRefreshInterval = 30.0;

/* Device dictionary keys (internal) */
static NSString * const kBTDevName      = @"btName";
static NSString * const kBTDevAddress   = @"btAddress";
static NSString * const kBTDevConnected = @"btConnected";
static NSString * const kBTDevPaired    = @"btPaired";
static NSString * const kBTDevTrusted   = @"btTrusted";

/* Action identifiers embedded in dropdown item kMenuItemIdentifier */
static NSString * const kActionConnect    = @"bt.connect.";    /* + address */
static NSString * const kActionDisconnect = @"bt.disconnect."; /* + address */

/* ---------------------------------------------------------------------- */
#pragma mark - Helpers

/** Strip ANSI escape sequences and carriage returns from bluetoothctl output. */
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

/** Run bluetoothctl with arguments; return stdout (for single-device queries). */
static NSString *BTCtl(NSArray<NSString *> *args)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.launchPath     = @"/usr/bin/bluetoothctl";
    task.arguments      = args;
    task.standardOutput = pipe;
    task.standardError  = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return @"";
    }
    NSData   *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *out  = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    return StripANSI(out ?: @"");
}

/** Run bluetoothctl in interactive (piped-stdin) mode.
 *  Interactive mode waits for bluetoothd to finish enumerating devices
 *  before executing commands, so offline paired/trusted devices appear. */
static NSString *BTCtlInteractive(NSString *input)
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
        return @"";
    }
    NSFileHandle *writer = [inPipe fileHandleForWriting];
    [writer writeData:[input dataUsingEncoding:NSUTF8StringEncoding]];
    [writer closeFile];
    [task waitUntilExit];
    NSData   *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *out  = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    return StripANSI(out ?: @"");
}

/** Parse "devices" output into an array of {name, address} dicts.
 *  Handles both "Device ADDR Name" and "[NEW] Device ADDR Name" lines. */
static NSArray<NSDictionary *> *ParseDeviceList(NSString *output)
{
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet   *seen   = [NSMutableSet set];
    for (NSString *raw in [output componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"[NEW] "])
            line = [line substringFromIndex:6];
        if (![line hasPrefix:@"Device "]) continue;
        NSString *rest = [line substringFromIndex:7];
        NSRange sp = [rest rangeOfString:@" "];
        NSString *addr = (sp.location != NSNotFound)
            ? [rest substringToIndex:sp.location] : rest;
        NSString *name = (sp.location != NSNotFound)
            ? [[rest substringFromIndex:sp.location + 1]
               stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceCharacterSet]]
            : addr;
        if (!addr.length || [seen containsObject:addr]) continue;
        [seen addObject:addr];
        [result addObject:@{ kBTDevName: name, kBTDevAddress: addr }];
    }
    return result;
}

/** Parse "info <addr>" output for paired, trusted, and connected flags. */
static void ParseDeviceInfo(NSString *output,
                             BOOL *outPaired,
                             BOOL *outTrusted,
                             BOOL *outConnected)
{
    *outPaired = *outTrusted = *outConnected = NO;
    for (NSString *raw in [output componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"Paired: yes"])    *outPaired    = YES;
        if ([line hasPrefix:@"Trusted: yes"])   *outTrusted   = YES;
        if ([line hasPrefix:@"Connected: yes"]) *outConnected = YES;
    }
}

/* ---------------------------------------------------------------------- */

@implementation BluetoothStatusItem {
    NSArray<NSDictionary *> *_devices;   /* latest fetched device list */
    NSTimer                 *_timer;
    __weak id                _delegate;
}

@synthesize pluginDelegate = _delegate;

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    _devices = @[];

    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                              target:self
                                            selector:@selector(_timerFired:)
                                            userInfo:nil
                                             repeats:YES];
    return self;
}

- (void)dealloc
{
    [_timer invalidate];
}

/* ---------------------------------------------------------------------- */
#pragma mark - AmbrosiaStatusItemPlugin

- (NSString *)barLabel
{
    return @"BT";
}

- (NSArray<NSDictionary *> *)dropdownItems
{
    if (!_devices.count) {
        return @[
            @{ kMenuItemTitle:   @"No paired or trusted devices",
               kMenuItemEnabled: @NO },
        ];
    }

    NSMutableArray *items = [NSMutableArray array];

    [items addObject:@{ kMenuItemTitle:   @"Bluetooth Devices",
                        kMenuItemEnabled: @NO }];
    [items addObject:@{ kMenuItemSeparator: @YES }];

    for (NSDictionary *dev in _devices) {
        BOOL connected = [dev[kBTDevConnected] boolValue];
        NSString *name = dev[kBTDevName];
        NSString *addr = dev[kBTDevAddress];

        NSString *actionID = connected
            ? [kActionDisconnect stringByAppendingString:addr]
            : [kActionConnect    stringByAppendingString:addr];

        /* Connected devices use normal (black) text; paired/trusted but
         * disconnected devices are greyed out but remain clickable.    */
        [items addObject:@{
            kMenuItemTitle:      name,
            kMenuItemIdentifier: actionID,
            kMenuItemEnabled:    @YES,
            kMenuItemGrayed:     @(!connected),
        }];
    }

    [items addObject:@{ kMenuItemSeparator: @YES }];
    [items addObject:@{
        kMenuItemTitle:      @"Open Bluetooth Settings\u2026",
        kMenuItemIdentifier: @"bt.openprefs",
        kMenuItemEnabled:    @YES,
    }];

    return items;
}

- (void)refresh
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        /* Use interactive mode so bluetoothd has time to enumerate the full
         * device cache — CLI-argument mode exits before offline devices load. */
        NSString *devOut = BTCtlInteractive(@"devices\nquit\n");
        NSArray  *all    = ParseDeviceList(devOut);

        NSMutableArray *enriched = [NSMutableArray array];
        for (NSDictionary *dev in all) {
            NSString *info = BTCtl(@[@"info", dev[kBTDevAddress]]);
            BOOL paired = NO, trusted = NO, connected = NO;
            ParseDeviceInfo(info, &paired, &trusted, &connected);

            /* Only show devices the user has explicitly paired or trusted. */
            if (!paired && !trusted && !connected) continue;

            [enriched addObject:@{
                kBTDevName:      dev[kBTDevName],
                kBTDevAddress:   dev[kBTDevAddress],
                kBTDevPaired:    @(paired),
                kBTDevTrusted:   @(trusted),
                kBTDevConnected: @(connected),
            }];
        }

        /* Sort: connected devices first, then alphabetically by name. */
        [enriched sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                           NSDictionary *b) {
            BOOL ac = [a[kBTDevConnected] boolValue];
            BOOL bc = [b[kBTDevConnected] boolValue];
            if (ac != bc) return ac ? NSOrderedAscending : NSOrderedDescending;
            return [a[kBTDevName] compare:b[kBTDevName]
                                  options:NSCaseInsensitiveSearch];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            _devices = [enriched copy];
            id<AmbrosiaStatusItemPluginDelegate> d =
                (id<AmbrosiaStatusItemPluginDelegate>)_delegate;
            if ([d respondsToSelector:@selector(statusItemPluginDidUpdate:)])
                [d statusItemPluginDidUpdate:self];
        });
    });
}

- (void)activateItem:(NSDictionary *)item
{
    NSString *ident = item[kMenuItemIdentifier];
    if (!ident.length) return;

    if ([ident isEqualToString:@"bt.openprefs"]) {
        [self _openBluetoothPrefs];
        return;
    }

    if ([ident hasPrefix:kActionConnect]) {
        NSString *addr = [ident substringFromIndex:kActionConnect.length];
        [self _connectDevice:addr];
        return;
    }

    if ([ident hasPrefix:kActionDisconnect]) {
        NSString *addr = [ident substringFromIndex:kActionDisconnect.length];
        [self _disconnectDevice:addr];
        return;
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private

- (void)_timerFired:(NSTimer *)t
{
    [self refresh];
}

- (void)_connectDevice:(NSString *)address
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BTCtl(@[@"connect", address]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self refresh];
        });
    });
}

- (void)_disconnectDevice:(NSString *)address
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BTCtl(@[@"disconnect", address]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self refresh];
        });
    });
}

- (void)_openBluetoothPrefs
{
    NSArray<NSString *> *candidates = @[
        @"/usr/GNUstep/Local/Applications/SystemPreferences.app",
        @"/usr/GNUstep/System/Applications/SystemPreferences.app",
        @"/usr/local/GNUstep/Local/Applications/SystemPreferences.app",
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"GNUstep/Applications/SystemPreferences.app"],
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSWorkspace sharedWorkspace] launchApplication:path];
            return;
        }
    }
}

@end
