#ifndef NETWORKMODULE_H
#define NETWORKMODULE_H

#import <Cocoa/Cocoa.h>
#import <PreferencePanes/PreferencePanes.h>

@interface NetworkModule : NSPreferencePane <NSTableViewDelegate, NSTableViewDataSource>
@property (nonatomic, retain) NSArray<NSDictionary *> *connectionTypes;
@property (nonatomic, retain) NSTableView *connectionListView;
@property (nonatomic, retain) NSButton *addButton;
@property (nonatomic, retain) NSButton *removeButton;
@property (nonatomic, retain) NSTextField *statusField;
@property (nonatomic, retain) NSTextField *ipField;
@property (nonatomic, retain) NSTextField *maskField;
@property (nonatomic, retain) NSTextField *routerField;
@property (nonatomic, retain) NSTextField *dnsField;
@property (nonatomic, retain) NSTextField *searchField;
@property (nonatomic, retain) NSPopUpButton *methodPopup;
@property (nonatomic, retain) NSButton *showWiFiInMenuBarButton;
@end
#endif //NETWORKMODULE_H
