/**
 * WiFiStatusItem.h
 *
 * AmbrosiaStatusItemPlugin that shows a "Wi-Fi" label in the menu bar and
 * lists configured wireless networks in a dropdown.
 *
 * The active network is shown with a check mark (✓).
 * Inactive configured networks are greyed but remain clickable so the user
 * can connect to them directly.  An "Open Network Preferences…" item at the
 * bottom launches SystemPreferences.app.
 *
 * Display is controlled by the ShowWiFiMenu key in
 * ~/GNUstep/Defaults/AmbrosiaMenuBar.plist, which the Network module in
 * SystemPreferences writes when the user toggles the menu-bar checkbox.
 */

#import <Foundation/Foundation.h>
#import "AmbrosiaStatusItemPlugin.h"

@interface WiFiStatusItem : NSObject <AmbrosiaStatusItemPlugin>
- (instancetype)init;
@end
