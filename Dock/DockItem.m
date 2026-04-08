#import "DockItem.h"

@implementation DockItem

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;
    _itemType   = DockItemTypeApp;
    _keepInDock = YES;
    _isRunning  = NO;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (!self) return nil;
    _label             = [coder decodeObjectForKey:@"label"];
    _bundleIdentifier  = [coder decodeObjectForKey:@"bundleIdentifier"];
    _launchPath        = [coder decodeObjectForKey:@"launchPath"];
    _itemType          = [coder decodeIntegerForKey:@"itemType"];
    _keepInDock        = [coder decodeBoolForKey:@"keepInDock"];
    [self reloadIcon];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_label            forKey:@"label"];
    [coder encodeObject:_bundleIdentifier forKey:@"bundleIdentifier"];
    [coder encodeObject:_launchPath       forKey:@"launchPath"];
    [coder encodeInteger:_itemType        forKey:@"itemType"];
    [coder encodeBool:_keepInDock         forKey:@"keepInDock"];
}

- (id)copyWithZone:(NSZone *)zone
{
    DockItem *copy         = [[[self class] allocWithZone:zone] init];
    copy->_label           = [_label copy];
    copy->_bundleIdentifier = [_bundleIdentifier copy];
    copy->_launchPath      = [_launchPath copy];
    copy->_icon            = _icon;
    copy->_itemType        = _itemType;
    copy->_isRunning       = _isRunning;
    copy->_keepInDock      = _keepInDock;
    return copy;
}

- (void)reloadIcon
{
    if (!_launchPath) {
        _icon = [NSImage imageNamed:@"NSApplicationIcon"];
        return;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:_launchPath];
    if (bundle) {
        NSString *iconName = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
        if (iconName) {
            NSString *ext = [iconName pathExtension];
            if (ext.length == 0) iconName = [iconName stringByAppendingPathExtension:@"icns"];
            NSString *iconPath = [bundle pathForResource:[iconName stringByDeletingPathExtension]
                                                  ofType:[iconName pathExtension]];
            if (iconPath) {
                _icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
            }
        }
    }
    if (!_icon) {
        _icon = [[NSWorkspace sharedWorkspace] iconForFile:_launchPath];
    }
    if (!_icon) {
        _icon = [NSImage imageNamed:@"NSApplicationIcon"];
    }
}

@end
