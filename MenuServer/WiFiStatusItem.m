#import "WiFiStatusItem.h"
#import <AppKit/AppKit.h>

static const NSTimeInterval kWiFiRefreshInterval = 30.0;

static NSString * const kWiFiName   = @"wifiName";
static NSString * const kWiFiActive = @"wifiActive";

static NSString * const kActionWiFiToggle     = @"wifi.toggle";
static NSString * const kActionWiFiConnect    = @"wifi.connect.";
static NSString * const kActionWiFiDisconnect = @"wifi.disconnect.";
static NSString * const kActionWiFiPrefs      = @"wifi.openprefs";

/* ---------------------------------------------------------------------- */

static NSString *RunNMCLI(NSArray<NSString *> *args)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.launchPath     = @"/usr/bin/nmcli";
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
    NSString *out  = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

/* Run nmcli for a mutating command; log exit code and any error output. */
static void RunNMCLICommand(NSArray<NSString *> *args, NSString *label)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.launchPath     = @"/usr/bin/nmcli";
    task.arguments      = args;
    task.standardOutput = outPipe;
    task.standardError  = errPipe;
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        NSLog(@"WiFiStatusItem: failed to launch nmcli for %@: %@", label, e);
        return;
    }
    int status = task.terminationStatus;
    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
    if (status != 0) {
        NSLog(@"WiFiStatusItem: nmcli %@ failed (exit %d).\n  stdout: %@\n  stderr: %@",
              label, status,
              [outStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]],
              [errStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    } else {
        NSLog(@"WiFiStatusItem: nmcli %@ succeeded.", label);
    }
}

/* Returns YES if the Wi-Fi radio is on. */
static BOOL FetchWiFiEnabled(void)
{
    NSString *out = RunNMCLI(@[@"radio", @"wifi"]);
    out = [out stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [out caseInsensitiveCompare:@"enabled"] == NSOrderedSame;
}

/* Returns array of {kWiFiName, kWiFiActive} sorted active-first then alpha. */
static NSArray<NSDictionary *> *FetchWiFiConnections(void)
{
    NSString *out = RunNMCLI(@[@"-t", @"-f", @"NAME,TYPE,ACTIVE", @"connection", @"show"]);
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        /* nmcli -t separates fields with ':'.  A connection name may itself
         * contain ':' so only split on the first two occurrences.           */
        NSRange r1 = [line rangeOfString:@":"];
        if (r1.location == NSNotFound) continue;
        NSString *name = [line substringToIndex:r1.location];
        NSString *rest = [line substringFromIndex:r1.location + 1];
        NSRange r2 = [rest rangeOfString:@":"];
        if (r2.location == NSNotFound) continue;
        NSString *type   = [rest substringToIndex:r2.location];
        NSString *active = [[rest substringFromIndex:r2.location + 1]
                            stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length == 0) continue;
        if ([type caseInsensitiveCompare:@"wifi"]             != NSOrderedSame &&
            [type caseInsensitiveCompare:@"802-11-wireless"]  != NSOrderedSame)
            continue;
        BOOL isActive = [active caseInsensitiveCompare:@"yes"] == NSOrderedSame;
        [result addObject:@{ kWiFiName: name, kWiFiActive: @(isActive) }];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL aa = [a[kWiFiActive] boolValue];
        BOOL ba = [b[kWiFiActive] boolValue];
        if (aa != ba) return aa ? NSOrderedAscending : NSOrderedDescending;
        return [a[kWiFiName] compare:b[kWiFiName] options:NSCaseInsensitiveSearch];
    }];
    return result;
}

/* ---------------------------------------------------------------------- */

@implementation WiFiStatusItem {
    NSArray<NSDictionary *> *_connections;
    BOOL                     _wifiEnabled;
    NSTimer                 *_timer;
    __weak id                _delegate;
}

@synthesize pluginDelegate = _delegate;

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _connections = @[];
    _wifiEnabled = YES;
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:kWiFiRefreshInterval
                                              target:self
                                            selector:@selector(_timerFired:)
                                            userInfo:nil
                                             repeats:YES];
    return self;
}

- (void)dealloc { [_timer invalidate]; }

/* ---------------------------------------------------------------------- */
#pragma mark - AmbrosiaStatusItemPlugin

- (NSString *)barLabel { return @"Wi-Fi"; }

- (NSArray<NSDictionary *> *)dropdownItems
{
    NSMutableArray *items = [NSMutableArray array];

    /* Header row: clickable to toggle the Wi-Fi radio on/off.
     * A check mark prefix (U+2713) indicates the radio is on. */
    NSString *headerPrefix = _wifiEnabled ? @"✓ " : @"   ";
    [items addObject:@{
        kMenuItemTitle:      [headerPrefix stringByAppendingString:@"Wi-Fi"],
        kMenuItemIdentifier: kActionWiFiToggle,
        kMenuItemEnabled:    @YES,
        kMenuItemGrayed:     @(!_wifiEnabled),
    }];
    [items addObject:@{ kMenuItemSeparator: @YES }];

    if (!_wifiEnabled) {
        [items addObject:@{ kMenuItemTitle:   @"Wi-Fi is turned off",
                            kMenuItemEnabled: @NO }];
    } else if (_connections.count == 0) {
        [items addObject:@{ kMenuItemTitle:   @"No configured Wi-Fi networks",
                            kMenuItemEnabled: @NO }];
    } else {
        for (NSDictionary *c in _connections) {
            BOOL     active  = [c[kWiFiActive] boolValue];
            NSString *name   = c[kWiFiName];
            /* U+2713 = check mark; three spaces align inactive items */
            NSString *prefix = active ? @"✓ " : @"   ";
            NSString *title  = [prefix stringByAppendingString:name];
            NSString *action = active
                ? [kActionWiFiDisconnect stringByAppendingString:name]
                : [kActionWiFiConnect    stringByAppendingString:name];
            [items addObject:@{
                kMenuItemTitle:      title,
                kMenuItemIdentifier: action,
                kMenuItemEnabled:    @YES,
                kMenuItemGrayed:     @(!active),
            }];
        }
    }

    [items addObject:@{ kMenuItemSeparator: @YES }];
    [items addObject:@{
        kMenuItemTitle:      @"Open Network Preferences…",
        kMenuItemIdentifier: kActionWiFiPrefs,
        kMenuItemEnabled:    @YES,
    }];
    return items;
}

- (void)refresh
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL       enabled = FetchWiFiEnabled();
        NSArray   *conns   = enabled ? FetchWiFiConnections() : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_wifiEnabled  = enabled;
            self->_connections  = conns;
            id<AmbrosiaStatusItemPluginDelegate> d =
                (id<AmbrosiaStatusItemPluginDelegate>)self->_delegate;
            if ([d respondsToSelector:@selector(statusItemPluginDidUpdate:)])
                [d statusItemPluginDidUpdate:self];
        });
    });
}

- (void)activateItem:(NSDictionary *)item
{
    NSString *ident = item[kMenuItemIdentifier];
    if (!ident.length) return;

    if ([ident isEqualToString:kActionWiFiToggle]) {
        [self _toggleWiFi];
        return;
    }
    if ([ident isEqualToString:kActionWiFiPrefs]) {
        [self _openNetworkPrefs];
        return;
    }
    if ([ident hasPrefix:kActionWiFiConnect]) {
        NSString *name = [ident substringFromIndex:kActionWiFiConnect.length];
        [self _connectNetwork:name];
        return;
    }
    if ([ident hasPrefix:kActionWiFiDisconnect]) {
        NSString *name = [ident substringFromIndex:kActionWiFiDisconnect.length];
        [self _disconnectNetwork:name];
        return;
    }
}

/* ---------------------------------------------------------------------- */
#pragma mark - Private

- (void)_timerFired:(NSTimer *)t { [self refresh]; }

- (void)_toggleWiFi
{
    BOOL turnOn = !_wifiEnabled;
    NSLog(@"WiFiStatusItem: turning Wi-Fi %@", turnOn ? @"on" : @"off");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunNMCLICommand(@[@"radio", @"wifi", turnOn ? @"on" : @"off"],
                        turnOn ? @"radio wifi on" : @"radio wifi off");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self refresh];
        });
    });
}

- (void)_connectNetwork:(NSString *)name
{
    NSLog(@"WiFiStatusItem: connecting to '%@'", name);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunNMCLICommand(@[@"connection", @"up", @"id", name],
                        [@"connection up id " stringByAppendingString:name]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self refresh];
        });
    });
}

- (void)_disconnectNetwork:(NSString *)name
{
    NSLog(@"WiFiStatusItem: disconnecting '%@'", name);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunNMCLICommand(@[@"connection", @"down", @"id", name],
                        [@"connection down id " stringByAppendingString:name]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self refresh];
        });
    });
}

- (void)_openNetworkPrefs
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
