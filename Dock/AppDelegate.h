#ifndef APP_DELEGATE_H
#define APP_DELEGATE_H

#import <AppKit/AppKit.h>
#import "DockController.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) DockController *dockController;

@end

#endif /* APP_DELEGATE_H */
