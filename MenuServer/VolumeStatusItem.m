#import "VolumeStatusItem.h"
#import <AppKit/AppKit.h>

static const NSTimeInterval kVolumeRefreshInterval = 10.0;

/* ---------------------------------------------------------------------- */

static CGFloat FetchVolume(void)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.launchPath     = @"/usr/bin/pactl";
    task.arguments      = @[@"get-sink-volume", @"@DEFAULT_SINK@"];
    task.standardOutput = pipe;
    task.standardError  = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return 50.0;
    }
    NSData   *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *out  = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!out.length) return 50.0;

    /* pactl output: "Volume: front-left: 65536 / 100% / 0.00 dB, ..." */
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"(\\d+)%" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:out
                                             options:0
                                               range:NSMakeRange(0, out.length)];
    if (m) return [[out substringWithRange:[m rangeAtIndex:1]] doubleValue];
    return 50.0;
}

static void ApplyVolume(CGFloat percent)
{
    NSString *arg = [NSString stringWithFormat:@"%.0f%%",
                     MAX(0.0, MIN(100.0, percent))];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath    = @"/usr/bin/pactl";
    task.arguments     = @[@"set-sink-volume", @"@DEFAULT_SINK@", arg];
    task.standardError = [NSPipe pipe];
    @try { [task launch]; [task waitUntilExit]; } @catch (...) {}
}

/* ---------------------------------------------------------------------- */

@implementation VolumeStatusItem {
    CGFloat  _volume;   /* 0..100 */
    NSTimer *_timer;
    __weak id _delegate;
}

@synthesize pluginDelegate = _delegate;

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _volume = 50.0;
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:kVolumeRefreshInterval
                                              target:self
                                            selector:@selector(_timerFired:)
                                            userInfo:nil
                                             repeats:YES];
    return self;
}

- (void)dealloc { [_timer invalidate]; }

/* ---------------------------------------------------------------------- */
#pragma mark - AmbrosiaStatusItemPlugin

- (NSString *)barLabel
{
    return [NSString stringWithFormat:@"Vol %.0f%%", _volume];
}

- (NSArray<NSDictionary *> *)dropdownItems
{
    return @[
        @{ kMenuItemTitle:   @"Output Volume", kMenuItemEnabled: @NO },
        @{ kMenuItemSeparator: @YES },
        /* Vertical slider row — rendered specially by MenuBarView. */
        @{ kMenuItemSlider:      @YES,
           kMenuItemSliderValue: @(_volume) },
    ];
}

- (void)refresh
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CGFloat v = FetchVolume();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_volume = v;
            id<AmbrosiaStatusItemPluginDelegate> d =
                (id<AmbrosiaStatusItemPluginDelegate>)self->_delegate;
            if ([d respondsToSelector:@selector(statusItemPluginDidUpdate:)])
                [d statusItemPluginDidUpdate:self];
        });
    });
}

- (void)activateItem:(NSDictionary *)item
{
    /* Called by MenuBarView whenever the slider value changes during drag. */
    NSNumber *val = item[kMenuItemSliderValue];
    if (!val) return;
    _volume = val.doubleValue;
    /* Apply asynchronously so the UI stays responsive during dragging. */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ApplyVolume(self->_volume);
    });
    id<AmbrosiaStatusItemPluginDelegate> d =
        (id<AmbrosiaStatusItemPluginDelegate>)_delegate;
    if ([d respondsToSelector:@selector(statusItemPluginDidUpdate:)])
        [d statusItemPluginDidUpdate:self];
}

/* ---------------------------------------------------------------------- */

- (void)_timerFired:(NSTimer *)t { [self refresh]; }

@end
