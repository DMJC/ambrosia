/**
 * BluetoothStatusItem.h
 *
 * AmbrosiaStatusItemPlugin that shows a "BT" label in the menu bar and
 * lists trusted Bluetooth devices with their connection status in a dropdown.
 *
 * Connected devices are drawn with normal (black) text.
 * Disconnected devices are drawn with greyed text but remain clickable
 * so the user can connect them directly from the menu.
 */

#import <Foundation/Foundation.h>
#import "AmbrosiaStatusItemPlugin.h"

@interface BluetoothStatusItem : NSObject <AmbrosiaStatusItemPlugin>

/** Shared initialiser — sets up the refresh timer. */
- (instancetype)init;

@end
