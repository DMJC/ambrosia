#ifndef BLUETOOTHMODULE_H
#define BLUETOOTHMODULE_H

#import <Cocoa/Cocoa.h>
#import <PreferencePanes/PreferencePanes.h>

/*
 * BluetoothModule — SystemPreferences pane for Bluetooth management.
 *
 * Uses libbluetooth (BlueZ HCI) for device discovery and bluetoothctl
 * for pairing, trust management, and connection control.
 *
 * UI layout:
 *   Left  – scrollable table listing known/discovered devices
 *           (name, address, paired/trusted, connected state)
 *   Right – detail panel with Trust / Untrust / Connect / Disconnect
 *           buttons for the selected device
 *   Bottom – Scan button + status label
 */
@interface BluetoothModule : NSPreferencePane
    <NSTableViewDelegate, NSTableViewDataSource>

/* Device list (array of NSDictionary, keys: name, address, paired, trusted, connected) */
@property (nonatomic, retain) NSMutableArray<NSDictionary *> *devices;

/* Table view showing the device list */
@property (nonatomic, retain) NSTableView   *deviceListView;

/* Action buttons */
@property (nonatomic, retain) NSButton      *scanButton;
@property (nonatomic, retain) NSButton      *trustButton;
@property (nonatomic, retain) NSButton      *untrustButton;
@property (nonatomic, retain) NSButton      *connectButton;
@property (nonatomic, retain) NSButton      *disconnectButton;

/* Status / progress label */
@property (nonatomic, retain) NSTextField   *statusField;

/* Detail labels (right-hand panel) */
@property (nonatomic, retain) NSTextField   *detailNameField;
@property (nonatomic, retain) NSTextField   *detailAddressField;
@property (nonatomic, retain) NSTextField   *detailPairedField;
@property (nonatomic, retain) NSTextField   *detailTrustedField;
@property (nonatomic, retain) NSTextField   *detailConnectedField;

/* YES while an HCI scan is in progress */
@property (nonatomic, assign) BOOL scanning;

/* Actions */
- (IBAction)scanForDevices:(id)sender;
- (IBAction)trustDevice:(id)sender;
- (IBAction)untrustDevice:(id)sender;
- (IBAction)connectDevice:(id)sender;
- (IBAction)disconnectDevice:(id)sender;

@end

#endif /* BLUETOOTHMODULE_H */
