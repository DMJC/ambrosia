#ifndef AMBROSIA_SESSION_H
#define AMBROSIA_SESSION_H

#import <Foundation/Foundation.h>
#include <wayland-server-core.h>
#include <sys/types.h>

@class AmbrosiaSession;

/**
 * A single process managed by the session.
 * The session owns all instances; do not create these directly.
 */
@interface AmbrosiaSessionProcess : NSObject

@property (nonatomic, copy)   NSString *name;
/** Absolute path to the executable or .app bundle */
@property (nonatomic, copy)   NSString *execPath;
/** Additional arguments (argv[1..]) */
@property (nonatomic, copy)   NSArray<NSString *> *arguments;
/** Seconds to wait before restarting after an unexpected exit (default 2) */
@property (nonatomic)         NSInteger restartDelaySecs;
/** Current child PID; 0 when not running */
@property (nonatomic)         pid_t pid;
/** YES for processes added from the user session plist (vs. core infrastructure) */
@property (nonatomic)         BOOL userManaged;
/** When YES the process will not be restarted after it exits */
@property (nonatomic)         BOOL disabled;

@property (nonatomic, weak)   AmbrosiaSession *session;

- (BOOL)launch;
- (void)terminate;

@end

/* -------------------------------------------------------------------------- */

/**
 * AmbrosiaSession — supervises a set of essential desktop processes.
 *
 * Integrates with the wlroots wl_event_loop:
 *  • Catches SIGCHLD via wl_event_loop_add_signal.
 *  • Uses per-process wl_event_loop timers for delayed restarts.
 *
 * Default managed processes:
 *  1. AmbrosiaDock   — the dock application
 *  2. GFinder.app    — the GNUstep file manager
 */
@interface AmbrosiaSession : NSObject

@property (nonatomic, readonly) NSArray<AmbrosiaSessionProcess *> *processes;

- (instancetype)initWithEventLoop:(struct wl_event_loop *)loop;

/**
 * Add a process to be supervised.
 * @param name        Human-readable label (used in log messages).
 * @param execPath    Path to the executable or .app bundle.
 * @param arguments   Extra argv entries (may be nil).
 */
- (AmbrosiaSessionProcess *)addProcessNamed:(NSString *)name
                                   execPath:(NSString *)execPath
                                  arguments:(nullable NSArray<NSString *> *)arguments;

/** Launch all managed processes and begin supervision. */
- (void)start;

/** Terminate all managed processes and stop supervision. */
- (void)stop;

/** Called from the C SIGCHLD handler — do not call directly. */
- (void)handleSIGCHLD;

/** Called from the C timer handler for @p process — do not call directly. */
- (void)restartProcess:(AmbrosiaSessionProcess *)process;

/**
 * Synchronise the set of user-managed processes with @p items, an array of
 * dictionaries each containing:
 *   "name"    (NSString) — human-readable label
 *   "path"    (NSString) — path to the executable or .app bundle
 *   "enabled" (NSNumber/BOOL) — whether the process should auto-start
 *
 * Processes no longer present in @p items, or whose "enabled" flag is NO, are
 * terminated.  New enabled entries are launched immediately.  Core processes
 * (MenuServer, AmbrosiaDock) are never touched by this method.
 *
 * Safe to call from the wl_event_loop thread.
 */
- (void)syncUserApps:(NSArray<NSDictionary *> *)items;

@end

/**
 * Convenience constructor: creates a session managing the core Ambrosia
 * infrastructure (MenuServer, AmbrosiaDock) plus any apps enabled in
 * ~/Library/Preferences/org.gnustep.AmbrosiaSession.plist.
 */
AmbrosiaSession *AmbrosiaSessionCreateDefault(struct wl_event_loop *loop);

#endif /* AMBROSIA_SESSION_H */
