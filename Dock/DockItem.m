#import "DockItem.h"

/* Parse the [Desktop Entry] section of a freedesktop .desktop file. */
static NSDictionary<NSString *, NSString *> *ParseDesktopFile(NSString *path)
{
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (!content) return @{};

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    BOOL inEntry = NO;

    for (NSString *rawLine in [content componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        if ([line isEqualToString:@"[Desktop Entry]"]) { inEntry = YES; continue; }
        if ([line hasPrefix:@"["] && inEntry)           { break; }
        if (!inEntry) continue;

        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        result[[line substringToIndex:eq.location]] =
            [line substringFromIndex:NSMaxRange(eq)];
    }
    return result;
}

/* Strip freedesktop field codes (%u, %U, %f, %F, etc.) from an Exec= value. */
static NSString *StripExecFieldCodes(NSString *exec)
{
    NSMutableString *out = [NSMutableString stringWithCapacity:exec.length];
    NSUInteger i = 0, len = exec.length;
    while (i < len) {
        unichar c = [exec characterAtIndex:i];
        if (c == '%' && i + 1 < len) { i += 2; continue; }
        [out appendFormat:@"%C", c];
        i++;
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

/* Render an SVG file to an NSImage via rsvg-convert. */
static NSImage *LoadSVGImage(NSString *path, NSInteger size)
{
    NSTask *task        = [[NSTask alloc] init];
    task.launchPath     = @"/usr/bin/rsvg-convert";
    task.arguments      = @[@"-w", [NSString stringWithFormat:@"%ld", (long)size],
                             @"-h", [NSString stringWithFormat:@"%ld", (long)size],
                             path];
    NSPipe *outPipe     = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError  = [NSFileHandle fileHandleWithNullDevice];

    @try { [task launch]; }
    @catch (NSException *e) { return nil; }

    NSData *png = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];

    if (!png.length || task.terminationStatus != 0) return nil;
    return [[NSImage alloc] initWithData:png];
}

/* Load an image from a path, transparently handling SVG via rsvg-convert. */
static NSImage *LoadImageAtPath(NSString *path)
{
    if (!path.length) return nil;
    if ([path.pathExtension.lowercaseString isEqualToString:@"svg"])
        return LoadSVGImage(path, 128);
    return [[NSImage alloc] initWithContentsOfFile:path];
}

/* Resolve a freedesktop icon name to a full filesystem path. */
static NSString *FindIconPath(NSString *name)
{
    if (!name.length) return nil;
    if ([name hasPrefix:@"/"])
        return [[NSFileManager defaultManager] fileExistsAtPath:name] ? name : nil;

    NSArray<NSString *> *exts  = @[@"png", @"svg", @"xpm"];
    NSArray<NSString *> *sizes = @[@"48x48", @"32x32", @"64x64",
                                   @"128x128", @"256x256", @"scalable"];
    NSArray<NSString *> *cats  = @[@"apps", @"devices", @"mimetypes"];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *size in sizes) {
        for (NSString *cat in cats) {
            for (NSString *ext in exts) {
                NSString *p = [NSString stringWithFormat:
                    @"/usr/share/icons/hicolor/%@/%@/%@.%@", size, cat, name, ext];
                if ([fm fileExistsAtPath:p]) return p;
            }
        }
    }
    for (NSString *ext in exts) {
        NSString *p = [NSString stringWithFormat:@"/usr/share/pixmaps/%@.%@", name, ext];
        if ([fm fileExistsAtPath:p]) return p;
        p = [NSString stringWithFormat:@"/usr/share/icons/%@.%@", name, ext];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

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
    _execCommand       = [coder decodeObjectForKey:@"execCommand"];
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
    [coder encodeObject:_execCommand      forKey:@"execCommand"];
    [coder encodeInteger:_itemType        forKey:@"itemType"];
    [coder encodeBool:_keepInDock         forKey:@"keepInDock"];
}

- (id)copyWithZone:(NSZone *)zone
{
    DockItem *copy          = [[[self class] allocWithZone:zone] init];
    copy->_label            = [_label copy];
    copy->_bundleIdentifier = [_bundleIdentifier copy];
    copy->_launchPath       = [_launchPath copy];
    copy->_execCommand      = [_execCommand copy];
    copy->_icon             = _icon;
    copy->_itemType         = _itemType;
    copy->_isRunning        = _isRunning;
    copy->_keepInDock       = _keepInDock;
    copy->_pid              = _pid;
    return copy;
}

- (void)reloadIcon
{
    /* Recycler icon is drawn programmatically in DockView */
    if (_itemType == DockItemTypeRecycler) {
        _icon = nil;
        return;
    }

    /* Desktop file: parse icon, exec command, and name from the .desktop file */
    if (_itemType == DockItemTypeDesktop) {
        if (_launchPath) {
            NSDictionary *info = ParseDesktopFile(_launchPath);
            NSString *exec = info[@"Exec"];
            if (exec.length) _execCommand = StripExecFieldCodes(exec);
            if (!_label.length) _label = [info[@"Name"] copy];
            NSString *iconPath = FindIconPath(info[@"Icon"]);
            if (iconPath) _icon = LoadImageAtPath(iconPath);
        }
        if (!_icon) _icon = [NSImage imageNamed:@"NSApplicationIcon"];
        return;
    }

    /* Folder: use workspace generic folder icon */
    if (_itemType == DockItemTypeFolder) {
        if (_launchPath) {
            _icon = [[NSWorkspace sharedWorkspace] iconForFile:_launchPath];
        }
        if (!_icon) _icon = [NSImage imageNamed:@"NSFolder"];
        return;
    }

    /* App: try bundle icon, then workspace, then generic */
    if (!_launchPath) {
        _icon = [NSImage imageNamed:@"NSApplicationIcon"];
        return;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:_launchPath];
    if (bundle) {
        NSString *iconName = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"]
                          ?: [bundle objectForInfoDictionaryKey:@"NSIcon"];
        if (iconName) {
            NSString *iconPath = nil;
            if ([iconName pathExtension].length > 0) {
                /* Name includes extension — look up directly */
                iconPath = [bundle pathForResource:[iconName stringByDeletingPathExtension]
                                            ofType:[iconName pathExtension]];
            } else {
                /* No extension — try svg, icns, png, tiff in that order */
                for (NSString *ext in @[@"svg", @"icns", @"png", @"tiff"]) {
                    iconPath = [bundle pathForResource:iconName ofType:ext];
                    if (iconPath) break;
                }
            }
            if (iconPath) _icon = LoadImageAtPath(iconPath);
        }
    }
    if (!_icon)
        _icon = [[NSWorkspace sharedWorkspace] iconForFile:_launchPath];
    if (!_icon)
        _icon = [NSImage imageNamed:@"NSApplicationIcon"];
}

@end
