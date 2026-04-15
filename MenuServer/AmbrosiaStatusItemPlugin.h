/**
 * AmbrosiaStatusItemPlugin.h
 *
 * Protocol adopted by objects that want to contribute a right-side status
 * item to the Ambrosia menu bar.
 *
 * Each plugin is owned by MenuBarController, which passes it to MenuBarView
 * for rendering.  Plugins are drawn right-to-left between the clock and the
 * session button.
 *
 * Item descriptors follow the MenuServerProtocol.h NSDictionary format;
 * the additional kMenuItemGrayed key is supported for greyed-but-clickable
 * entries (e.g. disconnected Bluetooth devices).
 */

#import <Foundation/Foundation.h>
#import "MenuServerProtocol.h"

@protocol AmbrosiaStatusItemPlugin <NSObject>

/**
 * Short text label shown in the menu bar (e.g. "BT").
 * A nil or empty return hides the plugin from the bar.
 */
@property (nonatomic, readonly) NSString *barLabel;

/**
 * Returns the dropdown item descriptors shown when the user clicks the
 * plugin's bar label.  Uses the MenuServerProtocol NSDictionary format plus
 * the kMenuItemGrayed extension key.
 * Return nil or an empty array to disable the dropdown.
 */
@property (nonatomic, readonly) NSArray<NSDictionary *> *dropdownItems;

/**
 * Called on a background queue approximately every 30 seconds, and also
 * once immediately after the plugin is created.  Implementations should
 * refresh their internal state and call back to the delegate when done.
 * Must be safe to call from any thread.
 */
- (void)refresh;

/**
 * Called on the main queue when the user selects a dropdown item.
 *
 * @param item  The full item descriptor dictionary (same object returned
 *              from -dropdownItems).
 */
- (void)activateItem:(NSDictionary *)item;

/**
 * Delegate set by MenuBarController so the plugin can request a bar redraw
 * after -refresh completes.
 */
@property (nonatomic, weak) id pluginDelegate;

@end

/**
 * Informal protocol for the plugin delegate (implemented by MenuBarView).
 */
@protocol AmbrosiaStatusItemPluginDelegate <NSObject>
- (void)statusItemPluginDidUpdate:(id<AmbrosiaStatusItemPlugin>)plugin;
@end
