/**
 * VolumeStatusItem.h
 *
 * AmbrosiaStatusItemPlugin that shows a "Vol N%" label in the menu bar and
 * provides a vertical volume slider in a dropdown for the default PulseAudio
 * output sink.
 *
 * Volume is read/written via pactl (get-sink-volume / set-sink-volume).
 * The dropdown slider height is kDropSliderH (defined in MenuBarView.m) to
 * give enough vertical travel for comfortable mouse dragging.
 *
 * Display is controlled by the ShowVolumeMenu key in
 * ~/GNUstep/Defaults/AmbrosiaMenuBar.plist, which the Audio module in
 * SystemPreferences writes when the user toggles the menu-bar checkbox.
 */

#import <Foundation/Foundation.h>
#import "AmbrosiaStatusItemPlugin.h"

@interface VolumeStatusItem : NSObject <AmbrosiaStatusItemPlugin>
- (instancetype)init;
@end
