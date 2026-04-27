// build: see GNUmakefile below
// Requires: GNUstep (Foundation/AppKit), Xlib, Xrandr
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <X11/Xlib.h>
#import <X11/extensions/Xrandr.h>

@interface OutputEntry : NSObject
@property (nonatomic) RROutput output;
@property (nonatomic) RRCrtc crtc;
@property (nonatomic) RRMode originalMode;
@property (nonatomic) int originalX;
@property (nonatomic) int originalY;
@property (nonatomic) Rotation originalRotation;
@property (nonatomic, strong) NSString *name;

@property (nonatomic, strong) NSComboBox *combo;
@property (nonatomic, strong) NSTextField *label;

// Mode list mapping UI rows -> RRMode ids
@property (nonatomic, strong) NSArray<NSNumber*> *modeIds;
// Remember last “applied” mode so Apply can commit it
@property (nonatomic) RRMode pendingMode;
@end
@implementation OutputEntry @end

@interface AppController : NSObject <NSApplicationDelegate, NSComboBoxDelegate>
@property (nonatomic) Display *dpy;
@property (nonatomic) Window root;
@property (nonatomic) int screen;
@property (nonatomic) XRRScreenResources *res;

@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSButton *applyButton;
@property (nonatomic, strong) NSTextField *hint;

@property (nonatomic, strong) NSMutableArray<OutputEntry*> *entries;

@property (nonatomic, strong) NSTimer *revertTimer;
@end

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.entries = [NSMutableArray array];

    // Open X display and RandR resources
    self.dpy = XOpenDisplay(NULL);
    if (!self.dpy) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Cannot open X display";
        [a runModal];
        [NSApp terminate:nil];
        return;
    }
    self.screen = DefaultScreen(self.dpy);
    self.root   = RootWindow(self.dpy, self.screen);

    int rrMajor, rrMinor;
    if (!XRRQueryVersion(self.dpy, &rrMajor, &rrMinor)) {
        [self showError:@"XRandR not available"]; return;
    }
    if (rrMajor < 1 || (rrMajor == 1 && rrMinor < 3)) {
        [self showError:@"XRandR 1.3+ required"]; return;
    }
    self.res = XRRGetScreenResourcesCurrent(self.dpy, self.root);
    if (!self.res) { [self showError:@"Failed to get screen resources"]; return; }

    // Build UI
    [self buildWindow];
    [self populateFromRandR];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)showError:(NSString*)msg {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = msg;
    [a runModal];
    [NSApp terminate:nil];
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(200, 200, 520, 120);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSTitledWindowMask|NSClosableWindowMask|NSMiniaturizableWindowMask)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"RandR Screen Selector"];

    NSView *content = [self.window contentView];

    self.applyButton = [[NSButton alloc] initWithFrame:NSMakeRect(400, 20, 100, 30)];
    [self.applyButton setTitle:@"Apply"];
    [self.applyButton setButtonType:NSMomentaryPushInButton];
    [self.applyButton setBezelStyle:NSRoundedBezelStyle];
    [self.applyButton setTarget:self];
    [self.applyButton setAction:@selector(applyPermanent:)];
    [content addSubview:self.applyButton];

    self.hint = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 20, 360, 30)];
    [self.hint setBezeled:NO];
    [self.hint setEditable:NO];
    [self.hint setDrawsBackground:NO];
    [self.hint setStringValue:@"Pick a resolution (auto-reverts in 10s unless Apply)."];
    [content addSubview:self.hint];
}

- (void)resizeWindowForRows:(NSUInteger)rows {
    CGFloat rowHeight = 28.0;
    CGFloat padding = 60.0; // top+bottom etc
    CGFloat height = padding + rows * (rowHeight + 8.0);
    NSRect f = [self.window frame];
    f.size.height = MAX(120, height);
    [self.window setFrame:f display:YES];
}

- (NSString *)stringForMode:(XRRModeInfo)mi {
    // rate = dotClock / (hTotal * vTotal)
    double hz = 0.0;
    if (mi.hTotal && mi.vTotal) {
        hz = (double)mi.dotClock / ((double)mi.hTotal * (double)mi.vTotal);
    }
    return [NSString stringWithFormat:@"%ux%u@%.0f", mi.width, mi.height, round(hz)];
}

- (XRRModeInfo)modeInfoForId:(RRMode)mode {
    for (int i = 0; i < self.res->nmode; i++) {
        if (self.res->modes[i].id == mode) return self.res->modes[i];
    }
    // Return a zeroed struct if not found
    XRRModeInfo zero; memset(&zero, 0, sizeof(zero)); return zero;
}

- (void)populateFromRandR {
    NSView *content = [self.window contentView];
    CGFloat y = [self.window frame].size.height - 60;

    for (int oi = 0; oi < self.res->noutput; oi++) {
        RROutput out = self.res->outputs[oi];
        XRROutputInfo *oiInfo = XRRGetOutputInfo(self.dpy, self.res, out);
        if (!oiInfo) continue;
        if (oiInfo->connection != RR_Connected || oiInfo->crtc == 0 || oiInfo->nmode == 0) {
            XRRFreeOutputInfo(oiInfo);
            continue; // only show connected with modes
        }

        XRRCrtcInfo *ci = XRRGetCrtcInfo(self.dpy, self.res, oiInfo->crtc);
        if (!ci) { XRRFreeOutputInfo(oiInfo); continue; }

        OutputEntry *e = [OutputEntry new];
        e.output = out;
        e.crtc   = oiInfo->crtc;
        e.originalMode = ci->mode;
        e.originalX = ci->x;
        e.originalY = ci->y;
        e.originalRotation = ci->rotation;
        e.name = [[NSString alloc] initWithBytes:oiInfo->name length:oiInfo->nameLen encoding:NSUTF8StringEncoding];

        // UI: label + combo
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 200, 24)];
        [label setBezeled:NO]; [label setEditable:NO]; [label setDrawsBackground:NO];
        [label setStringValue:[NSString stringWithFormat:@"%@:", e.name]];
        e.label = label;
        [content addSubview:label];

        NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(220, y-2, 260, 28)];
        combo.usesDataSource = NO;
        combo.delegate = (id<NSComboBoxDelegate>)self;
        e.combo = combo;

        NSMutableArray<NSNumber*> *ids = [NSMutableArray array];
        for (int m = 0; m < oiInfo->nmode; m++) {
            RRMode mid = oiInfo->modes[m];
            XRRModeInfo mi = [self modeInfoForId:mid];
            if (mi.id == 0) continue;
            [combo addItemWithObjectValue:[self stringForMode:mi]];
            [ids addObject:@(mid)];
        }
        e.modeIds = ids;

        // Set current mode selection if possible
        if (e.originalMode != 0) {
            NSUInteger idx = [ids indexOfObject:@(e.originalMode)];
            if (idx != NSNotFound) [combo selectItemAtIndex:idx];
        }
        [combo setTarget:self];
        [combo setAction:@selector(modePicked:)];
        [content addSubview:combo];

        [self.entries addObject:e];

        y -= 36.0;

        XRRFreeCrtcInfo(ci);
        XRRFreeOutputInfo(oiInfo);
    }

    [self resizeWindowForRows:self.entries.count];
}

#pragma mark - Actions

- (void)modePicked:(NSComboBox *)sender {
    // Find which entry’s combo fired
    OutputEntry *entry = nil;
    for (OutputEntry *e in self.entries) if (e.combo == sender) { entry = e; break; }
    if (!entry) return;

    NSInteger idx = [sender indexOfSelectedItem];
    if (idx < 0 || idx >= (NSInteger)entry.modeIds.count) return;

    RRMode newMode = (RRMode)entry.modeIds[idx].unsignedLongValue;
    if (newMode == 0) return;

    if (![self applyMode:newMode forEntry:entry]) {
        NSBeep();
        return;
    }

    entry.pendingMode = newMode;

    // (Re)start the 10s revert timer
    [self.revertTimer invalidate];
    self.revertTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                        target:self
                                                      selector:@selector(revertAll:)
                                                      userInfo:nil
                                                       repeats:NO];
    [self.hint setStringValue:@"Temporary change applied. Reverting in 10s unless you click Apply."];
}

- (BOOL)applyMode:(RRMode)newMode forEntry:(OutputEntry *)e {
    // Fetch CRTC info to keep pos/rotation and outputs list
    XRRCrtcInfo *ci = XRRGetCrtcInfo(self.dpy, self.res, e.crtc);
    if (!ci) return NO;

    // Use the same outputs array (the CRTC may drive multiple outputs—rare but possible)
    Status st = XRRSetCrtcConfig(self.dpy,
                                 self.res,
                                 e.crtc,
                                 CurrentTime,
                                 ci->x, ci->y,
                                 newMode,
                                 ci->rotation,
                                 ci->outputs,
                                 ci->noutput);
    XSync(self.dpy, False);
    XRRFreeCrtcInfo(ci);

    return (st == Success);
}

- (void)revertAll:(NSTimer *)t {
    for (OutputEntry *e in self.entries) {
        if (e.pendingMode != 0 && e.pendingMode != e.originalMode) {
            // Revert to original
            XRRCrtcInfo *ci = XRRGetCrtcInfo(self.dpy, self.res, e.crtc);
            if (ci) {
                XRRSetCrtcConfig(self.dpy, self.res, e.crtc, CurrentTime,
                                 e.originalX, e.originalY,
                                 e.originalMode, e.originalRotation,
                                 ci->outputs, ci->noutput);
                XSync(self.dpy, False);
                XRRFreeCrtcInfo(ci);
            }
            e.pendingMode = 0;
            // Reset UI selection back to original
            NSUInteger idx = [e.modeIds indexOfObject:@(e.originalMode)];
            if (idx != NSNotFound) [e.combo selectItemAtIndex:idx];
        }
    }
    [self.hint setStringValue:@"Reverted to original settings."];
}

- (void)applyPermanent:(id)sender {
    // Accept all pending modes as new "original"
    for (OutputEntry *e in self.entries) {
        if (e.pendingMode != 0 && e.pendingMode != e.originalMode) {
            // Update original baseline to the new mode
            e.originalMode = e.pendingMode;
            // Also capture current CRTC geometry/rotation (could have changed)
            XRRCrtcInfo *ci = XRRGetCrtcInfo(self.dpy, self.res, e.crtc);
            if (ci) {
                e.originalX = ci->x; e.originalY = ci->y; e.originalRotation = ci->rotation;
                XRRFreeCrtcInfo(ci);
            }
            e.pendingMode = 0;
        }
    }
    [self.revertTimer invalidate];
    self.revertTimer = nil;
    [self.hint setStringValue:@"Changes applied."];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)dealloc {
    if (self.res) XRRFreeScreenResources(self.res);
    if (self.dpy) XCloseDisplay(self.dpy);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppController *controller = [AppController new];
        [app setDelegate:controller];
        [app run];
    }
    return 0;
}
