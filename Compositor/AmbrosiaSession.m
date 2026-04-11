#import "AmbrosiaSession.h"

#include <wlr/util/log.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

/* --------------------------------------------------------------------------
 * Helpers
 * -------------------------------------------------------------------------- */

/**
 * Search a set of candidate paths and return the first that exists.
 * Returns nil if none found.
 */
static NSString *findExecutable(NSArray<NSString *> *candidates)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

/**
 * Given an .app bundle path, return the executable inside it, e.g.
 *   /usr/GNUstep/Local/Applications/GFinder.app
 *   → /usr/GNUstep/Local/Applications/GFinder.app/GFinder
 */
static NSString *executableForAppBundle(NSString *bundlePath)
{
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (bundle) {
        NSString *exec = bundle.executablePath;
        if (exec) return exec;
    }
    /* Fallback: conventional layout AppName.app/AppName */
    NSString *name = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
    return [bundlePath stringByAppendingPathComponent:name];
}

/* --------------------------------------------------------------------------
 * C-level wl_event_loop callbacks
 * -------------------------------------------------------------------------- */

static int session_sigchld_handler(int signal_number, void *data)
{
    AmbrosiaSession *session = (__bridge AmbrosiaSession *)data;
    [session handleSIGCHLD];
    return 0;
}

/* Timer context: one per managed process */
struct ambrosia_restart_ctx {
    struct wl_event_source *timer;
    void                   *objc_process; /* __bridge AmbrosiaSessionProcess* */
    void                   *objc_session; /* __bridge AmbrosiaSession* */
};

static int session_restart_timer(void *data)
{
    struct ambrosia_restart_ctx *ctx = data;
    AmbrosiaSession        *session  = (__bridge AmbrosiaSession *)ctx->objc_session;
    AmbrosiaSessionProcess *process  = (__bridge AmbrosiaSessionProcess *)ctx->objc_process;
    [session restartProcess:process];
    return 0;
}

/* --------------------------------------------------------------------------
 * AmbrosiaSessionProcess
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaSessionProcess {
    struct ambrosia_restart_ctx *_restartCtx;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _restartDelaySecs = 2;
    _pid = 0;
    return self;
}

- (void)dealloc
{
    [self terminate];
    if (_restartCtx) {
        if (_restartCtx->timer) wl_event_source_remove(_restartCtx->timer);
        free(_restartCtx);
        _restartCtx = NULL;
    }
}

- (BOOL)launch
{
    if (_pid > 0) return YES; /* Already running */

    /* Resolve actual executable path */
    NSString *exec = _execPath;
    if ([exec hasSuffix:@".app"]) {
        exec = executableForAppBundle(exec);
    }

    if (!exec || ![[NSFileManager defaultManager] fileExistsAtPath:exec]) {
        wlr_log(WLR_ERROR, "session: cannot find executable for '%s' (path: %s)",
                [_name UTF8String], [exec UTF8String] ?: "(nil)");
        return NO;
    }

    /* Build argv */
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:exec];
    if (_arguments) [args addObjectsFromArray:_arguments];

    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i] = (char *)[args[i] UTF8String];
    }
    argv[args.count] = NULL;

    pid_t pid = fork();
    if (pid < 0) {
        wlr_log(WLR_ERROR, "session: fork failed for '%s': %s",
                [_name UTF8String], strerror(errno));
        free(argv);
        return NO;
    }
    if (pid == 0) {
        /* Child: clear DISPLAY so GNUstep apps use WAYLAND_DISPLAY
         * (pointing to this compositor's socket) rather than falling
         * back to Xwayland on a host compositor.                      */
        unsetenv("DISPLAY");
        execv(argv[0], argv);
        _exit(127);
    }

    free(argv);
    _pid = pid;
    wlr_log(WLR_INFO, "session: launched '%s' pid=%d", [_name UTF8String], pid);
    return YES;
}

- (void)terminate
{
    if (_pid <= 0) return;
    kill(_pid, SIGTERM);
    /* Reap synchronously so we don't leave a zombie */
    waitpid(_pid, NULL, 0);
    wlr_log(WLR_INFO, "session: terminated '%s' pid=%d", [_name UTF8String], _pid);
    _pid = 0;
}

/**
 * Arm the restart timer on the wl_event_loop.
 * Called by the session after SIGCHLD confirms this process exited.
 */
- (void)armRestartTimerOnLoop:(struct wl_event_loop *)loop
{
    if (!_restartCtx) {
        _restartCtx = calloc(1, sizeof(struct ambrosia_restart_ctx));
        _restartCtx->objc_process = (__bridge void *)self;
        _restartCtx->objc_session = (__bridge void *)_session;
        _restartCtx->timer = wl_event_loop_add_timer(loop,
                                                     session_restart_timer,
                                                     _restartCtx);
    }
    int ms = (int)(_restartDelaySecs * 1000);
    wl_event_source_timer_update(_restartCtx->timer, ms);
    wlr_log(WLR_INFO, "session: will restart '%s' in %lds",
            [_name UTF8String], (long)_restartDelaySecs);
}

@end

/* --------------------------------------------------------------------------
 * AmbrosiaSession
 * -------------------------------------------------------------------------- */

@implementation AmbrosiaSession {
    struct wl_event_loop       *_loop;
    struct wl_event_source     *_sigchldSource;
    NSMutableArray<AmbrosiaSessionProcess *> *_processes;
}

@synthesize processes = _processes;

- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop
{
    self = [super init];
    if (!self) return nil;

    _loop      = loop;
    _processes = [NSMutableArray array];

    /* Register SIGCHLD handler on the Wayland event loop */
    _sigchldSource = wl_event_loop_add_signal(loop, SIGCHLD,
                                              session_sigchld_handler,
                                              (__bridge void *)self);
    return self;
}

- (void)dealloc
{
    if (_sigchldSource) {
        wl_event_source_remove(_sigchldSource);
        _sigchldSource = NULL;
    }
}

- (AmbrosiaSessionProcess *)addProcessNamed:(NSString *)name
                                   execPath:(NSString *)execPath
                                  arguments:(NSArray<NSString *> *)arguments
{
    AmbrosiaSessionProcess *proc = [[AmbrosiaSessionProcess alloc] init];
    proc.name      = name;
    proc.execPath  = execPath;
    proc.arguments = arguments;
    proc.session   = self;
    [_processes addObject:proc];
    return proc;
}

- (void)start
{
    for (AmbrosiaSessionProcess *proc in _processes) {
        [proc launch];
    }
}

- (void)stop
{
    for (AmbrosiaSessionProcess *proc in _processes) {
        [proc terminate];
    }
}

- (void)handleSIGCHLD
{
    int status;
    pid_t pid;

    /* Reap all terminated children */
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        BOOL normal = WIFEXITED(status);
        int  code   = normal ? WEXITSTATUS(status) : WTERMSIG(status);

        for (AmbrosiaSessionProcess *proc in _processes) {
            if (proc.pid != pid) continue;

            proc.pid = 0;
            wlr_log(WLR_INFO,
                    "session: '%s' (pid %d) exited (%s %d) — scheduling restart",
                    [proc.name UTF8String], pid,
                    normal ? "exit" : "signal", code);

            [proc armRestartTimerOnLoop:_loop];
            break;
        }
    }
}

- (void)restartProcess:(AmbrosiaSessionProcess *)process
{
    wlr_log(WLR_INFO, "session: restarting '%s'", [process.name UTF8String]);
    [process launch];
}

@end

/* --------------------------------------------------------------------------
 * Convenience: build the default Ambrosia session
 * -------------------------------------------------------------------------- */

/**
 * Returns candidate executable paths for a given app name, checking
 * the GNUstep domain hierarchy, /usr/local, and PATH.
 */
static NSArray<NSString *> *candidatePaths(NSString *appBundleName,
                                           NSString *binaryName)
{
    NSMutableArray *paths = [NSMutableArray array];

    /* GNUstep domain paths */
    NSArray *gnustepDirs = @[
        @"/usr/GNUstep/Local/Applications",
        @"/usr/GNUstep/System/Applications",
        @"/usr/local/GNUstep/Local/Applications",
        [NSHomeDirectory() stringByAppendingPathComponent:@"GNUstep/Applications"],
    ];
    for (NSString *dir in gnustepDirs) {
        /* .app bundle */
        [paths addObject:[dir stringByAppendingPathComponent:appBundleName]];
        /* direct binary next to compositor */
        [paths addObject:[dir stringByAppendingPathComponent:binaryName]];
    }

    /* Binary in same directory as the compositor */
    NSString *selfDir = [[NSBundle mainBundle].executablePath
                         stringByDeletingLastPathComponent];
    [paths addObject:[selfDir stringByAppendingPathComponent:binaryName]];
    [paths addObject:[selfDir stringByAppendingPathComponent:appBundleName]];

    /* Plain PATH lookup */
    [paths addObject:binaryName];

    return paths;
}

AmbrosiaSession *AmbrosiaSessionCreateDefault(struct wl_event_loop *loop)
{
    AmbrosiaSession *session = [[AmbrosiaSession alloc] initWithEventLoop:loop];

    /* Force gnustep-back to use the Wayland display server.  Without this,
     * gnustep-back defaults to its X11 backend, causing apps to crash when
     * DISPLAY is unset or to connect to Xwayland on the host compositor
     * instead of our own WAYLAND_DISPLAY socket.                           */
    NSArray<NSString *> *gnustepWaylandArgs = @[@"-GSBackend", @"back"];

    /* ---- MenuServer ---- */
    NSString *menuServerExec = findExecutable(candidatePaths(@"MenuServer.app",
                                                             @"MenuServer"));
    if (!menuServerExec) menuServerExec = @"MenuServer";

    AmbrosiaSessionProcess *menuServer =
        [session addProcessNamed:@"MenuServer"
                        execPath:menuServerExec
                       arguments:gnustepWaylandArgs];
    menuServer.restartDelaySecs = 2;

    /* ---- AmbrosiaDock ---- */
    NSString *dockExec = findExecutable(candidatePaths(@"AmbrosiaDock.app",
                                                       @"AmbrosiaDock"));
    if (!dockExec) dockExec = @"AmbrosiaDock"; /* fallback: hope it is in PATH */

    AmbrosiaSessionProcess *dock =
        [session addProcessNamed:@"AmbrosiaDock"
                        execPath:dockExec
                       arguments:gnustepWaylandArgs];
    dock.restartDelaySecs = 2;

    /* ---- GFinder ---- */
    NSString *finderExec = findExecutable(candidatePaths(@"GFinder.app",
                                                         @"GFinder"));
    if (!finderExec) finderExec = @"GFinder";

    AmbrosiaSessionProcess *finder =
        [session addProcessNamed:@"GFinder"
                        execPath:finderExec
                       arguments:gnustepWaylandArgs];
    finder.restartDelaySecs = 3; /* slightly longer delay for the file manager */

    return session;
}
