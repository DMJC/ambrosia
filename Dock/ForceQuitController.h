#ifndef FORCE_QUIT_CONTROLLER_H
#define FORCE_QUIT_CONTROLLER_H

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "DockItem.h"

/**
 * ForceQuitController presents a panel listing all running GNUstep applications.
 * The user can select an application and click "Kill" to send it SIGKILL,
 * or "Cancel" to dismiss the panel.
 *
 * Shown in response to the Ctrl+Super+Esc compositor keybinding, which posts
 * "AmbrosiaForceQuitRequest" via NSDistributedNotificationCenter.
 */
@interface ForceQuitController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

/** Replace the displayed app list with a fresh snapshot of running items. */
- (void)updateWithItems:(NSArray<DockItem *> *)items;

/** Bring the panel to the front, creating it the first time. */
- (void)showPanel;

@end

#endif /* FORCE_QUIT_CONTROLLER_H */
