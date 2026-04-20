#import "WiFiStatusItem.h"
#import <AppKit/AppKit.h>

static const NSTimeInterval kWiFiRefreshInterval = 30.0;

static NSString * const kWiFiName   = @"wifiName";
static NSString * const kWiFiActive = @"wifiActive";

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
    NSTimer                 *_timer;
    __weak id                _delegate;
}

@synthesize pluginDelegate = _delegate;

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _connections = @[];
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
    [items addObject:@{ kMenuItemTitle: @"Wi-Fi", kMenuItemEnabled: @NO }];
    [items addObject:@{ kMenuItemSeparator: @YES }];

    if (_connections.count == 0) {
        [items addObject:@{ kMenuItemTitle:   @"No configured Wi-Fi networks",
                            kMenuItemEnabled: @NO }];
    } else {
        for (NSDictionary *c in _connections) {
            BOOL     active  = [c[kWiFiActive] boolValue];
            NSString *name   = c[kWiFiName];
            /* U+2713 = ✓ check mark; three non-breaking spaces align inactive items */
            NSString *prefix = active ? @"\u2713 " : @"   ";
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
        kMenuItemTitle:      @"Open Network Preferences\u2026",
        kMenuItemIdentifier: kActionWiFiPrefs,
        kMenuItemEnabled:    @YES,
    }];
    return items;
}

- (void)refresh
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *conns = FetchWiFiConnections();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_connections = conns;
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

- (void)_connectNetwork:(NSString *)name
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunNMCLI(@[@"connection", @"up", name]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self refresh];
        });
    });
}

- (void)_disconnectNetwork:(NSString *)name
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RunNMCLI(@[@"connection", @"down", name]);
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
