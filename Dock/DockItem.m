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

/*
 * Return the active icon theme name from GTK or GNUstep settings.
 * Checked in order: GTK-3 user config → GTK-4 user config →
 * GTK-3 system config → GNUstep NSGlobalDomain GSTheme.
 * Returns nil if none is found (caller falls back to "hicolor").
 */
/* Active GNUstep icon theme name from NSUserDefaults (GSTheme key). */
static NSString *GNUstepIconThemeName(void)
{
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:@"GSTheme"];
    return name.length ? name : nil;
}

/* Active GTK icon theme name, read from GTK-3/4 settings INI files. */
static NSString *GTKIconThemeName(void)
{
    NSArray<NSString *> *candidates = @[
        [@"~/.config/gtk-3.0/settings.ini" stringByExpandingTildeInPath],
        [@"~/.config/gtk-4.0/settings.ini" stringByExpandingTildeInPath],
        @"/etc/gtk-3.0/settings.ini",
        @"/etc/gtk-4.0/settings.ini",
    ];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *iniPath in candidates) {
        NSString *content = [NSString stringWithContentsOfFile:iniPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (!content) continue;
        for (NSString *raw in [content componentsSeparatedByString:@"\n"]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:ws];
            if (![line hasPrefix:@"gtk-icon-theme-name"]) continue;
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *val = [[line substringFromIndex:NSMaxRange(eq)]
                             stringByTrimmingCharactersInSet:ws];
            if (val.length >= 2 &&
                ([val hasPrefix:@"\""] || [val hasPrefix:@"'"])) {
                val = [val substringWithRange:NSMakeRange(1, val.length - 2)];
            }
            if (val.length) return val;
        }
    }
    return nil;
}

/*
 * Core icon search.  Looks for 'name' in freedesktop icon base directories,
 * trying only the file extensions in 'exts' (in order).
 *
 * Theme search order: preferredTheme (if non-nil) → hicolor → other themes.
 * Pass nil for preferredTheme to search hicolor first.
 *
 * An absolute path for 'name' short-circuits the search.
 */
static NSString *FindIconPathWithExtensions(NSString *name,
                                            NSArray<NSString *> *exts,
                                            NSString *preferredTheme)
{
    if (!name.length) return nil;
    if ([name hasPrefix:@"/"]) {
        return [[NSFileManager defaultManager] fileExistsAtPath:name] ? name : nil;
    }

    NSArray<NSString *> *sizes = @[@"scalable", @"48x48", @"64x64",
                                   @"128x128", @"256x256", @"32x32"];
    NSArray<NSString *> *cats  = @[@"apps", @"devices", @"mimetypes"];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *userBase = [@"~/.local/share/icons" stringByExpandingTildeInPath];
    NSArray<NSString *> *baseDirs = @[userBase, @"/usr/share/icons"];

    for (NSString *base in baseDirs) {
        /* Build theme order: preferred → hicolor → others. */
        NSMutableArray<NSString *> *themes = [NSMutableArray array];
        if (preferredTheme.length) [themes addObject:preferredTheme];
        [themes addObject:@"hicolor"];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:base error:nil]) {
            if ([entry isEqualToString:preferredTheme]) continue;
            if ([entry isEqualToString:@"hicolor"])     continue;
            BOOL isDir = NO;
            NSString *full = [base stringByAppendingPathComponent:entry];
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir)
                [themes addObject:entry];
        }

        for (NSString *theme in themes) {
            NSString *themeDir = [base stringByAppendingPathComponent:theme];
            for (NSString *size in sizes) {
                for (NSString *cat in cats) {
                    for (NSString *ext in exts) {
                        NSString *p = [[[[themeDir
                            stringByAppendingPathComponent:size]
                            stringByAppendingPathComponent:cat]
                            stringByAppendingPathComponent:name]
                            stringByAppendingPathExtension:ext];
                        if ([fm fileExistsAtPath:p]) return p;
                    }
                }
            }
        }

        for (NSString *ext in exts) {
            NSString *p = [[base stringByAppendingPathComponent:name]
                           stringByAppendingPathExtension:ext];
            if ([fm fileExistsAtPath:p]) return p;
        }
    }

    for (NSString *ext in exts) {
        NSString *p = [NSString stringWithFormat:@"/usr/share/pixmaps/%@.%@", name, ext];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

/*
 * GNUstep library base directories searched for themes, in priority order.
 * Mirrors the GNUstep path convention: user → Local → System.
 */
static NSArray<NSString *> *GNUstepThemeBaseDirs(void)
{
    return @[
        [@"~/GNUstep/Library/Themes"         stringByExpandingTildeInPath],
        @"/usr/GNUstep/Local/Library/Themes",
        @"/usr/GNUstep/System/Library/Themes",
        @"/usr/local/GNUstep/Local/Library/Themes",
        @"/usr/local/GNUstep/System/Library/Themes",
    ];
}

/*
 * GNUstep themes store per-app icon overrides at:
 *   ThemeImages/<bundleIdentifier>/<iconBaseName>.<ext>
 *
 * Look for 'iconBase' (no extension) inside that per-bundle sub-directory.
 * Returns the first matching path, or nil.
 */
static NSString *FindGNUstepThemeAppIcon(NSString *bundleId, NSString *iconBase,
                                          NSArray<NSString *> *exts)
{
    if (!bundleId.length || !iconBase.length) return nil;
    NSString *themeName = GNUstepIconThemeName();
    if (!themeName.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *themeBundleName = [themeName stringByAppendingPathExtension:@"theme"];
    for (NSString *base in GNUstepThemeBaseDirs()) {
        NSString *iconDir = [[[[base
            stringByAppendingPathComponent:themeBundleName]
            stringByAppendingPathComponent:@"Resources"]
            stringByAppendingPathComponent:@"ThemeImages"]
            stringByAppendingPathComponent:bundleId];
        for (NSString *ext in exts) {
            NSString *p = [[iconDir stringByAppendingPathComponent:iconBase]
                           stringByAppendingPathExtension:ext];
            if ([fm fileExistsAtPath:p]) return p;
        }
    }
    return nil;
}

/* Flat name search in ThemeImages/ (no per-bundle sub-directory), then hicolor. */
static NSString *FindGNUstepThemeSVGPath(NSString *name)
{
    return FindIconPathWithExtensions(name, @[@"svg"], GNUstepIconThemeName());
}

static NSString *FindGNUstepThemeRasterPath(NSString *name)
{
    return FindIconPathWithExtensions(name, @[@"png", @"xpm"], GNUstepIconThemeName());
}

/* Any icon in the active GTK theme, SVG preferred, hicolor fallback.
 * Used for freedesktop .desktop items. */
static NSString *FindGTKThemeIconPath(NSString *name)
{
    return FindIconPathWithExtensions(name, @[@"svg", @"png", @"xpm"], GTKIconThemeName());
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
            NSString *iconPath = FindGTKThemeIconPath(info[@"Icon"]);
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

    /* App icons — priority order:
     *   1. SVG from the current system icon theme
     *   2. SVG from the application bundle
     *   3. Raster (PNG/XPM) from the system icon theme
     *   4. TIFF/PNG/ICNS from the application bundle
     *   5. NSWorkspace / generic fallback                                    */
    if (!_launchPath) {
        _icon = [NSImage imageNamed:@"NSApplicationIcon"];
        return;
    }

    NSString *appBaseName = [[_launchPath lastPathComponent] stringByDeletingPathExtension];

    /* Resolve the bundle icon name once; used for both theme and bundle lookups. */
    NSBundle *bundle   = [NSBundle bundleWithPath:_launchPath];
    NSString *iconName = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"]
                      ?: [bundle objectForInfoDictionaryKey:@"NSIcon"]
                      ?: [bundle objectForInfoDictionaryKey:@"ApplicationIcon"];
    NSString *iconBase = [iconName stringByDeletingPathExtension];

    /* 1. SVG from the GNUstep system theme.
     *    Primary:  ThemeImages/<bundleId>/<iconBase>.svg  (per-app theme override)
     *    Fallback: freedesktop icon dirs under the GNUstep theme name / hicolor  */
    NSString *themeSVGPath = nil;
    if (_bundleIdentifier.length && iconBase.length)
        themeSVGPath = FindGNUstepThemeAppIcon(_bundleIdentifier, iconBase, @[@"svg"]);
    if (!themeSVGPath)
        themeSVGPath = FindGNUstepThemeSVGPath(appBaseName);
    if (!themeSVGPath && _bundleIdentifier.length)
        themeSVGPath = FindGNUstepThemeSVGPath(_bundleIdentifier);
    if (themeSVGPath)
        _icon = LoadSVGImage(themeSVGPath, 128);

    /* 2. SVG from the application bundle. */
    if (!_icon && iconBase.length) {
        NSString *svgPath = [bundle pathForResource:iconBase ofType:@"svg"]
                         ?: [bundle pathForResource:iconName ofType:@"svg"];
        if (svgPath) _icon = LoadSVGImage(svgPath, 128);
    }

    /* 3. Raster from the GNUstep system theme.
     *    Primary:  ThemeImages/<bundleId>/<iconBase>.{png,tiff,...}
     *    Fallback: freedesktop icon dirs under the GNUstep theme name / hicolor  */
    if (!_icon) {
        NSString *rasterPath = nil;
        if (_bundleIdentifier.length && iconBase.length)
            rasterPath = FindGNUstepThemeAppIcon(_bundleIdentifier, iconBase,
                                                  @[@"png", @"xpm", @"tiff", @"tif"]);
        if (!rasterPath)
            rasterPath = FindGNUstepThemeRasterPath(appBaseName);
        if (!rasterPath && _bundleIdentifier.length)
            rasterPath = FindGNUstepThemeRasterPath(_bundleIdentifier);
        if (rasterPath) _icon = LoadImageAtPath(rasterPath);
    }

    /* 4. TIFF/PNG/ICNS from the application bundle. */
    if (!_icon && iconName.length) {
        NSString *iconPath = nil;
        if ([iconName pathExtension].length > 0) {
            iconPath = [bundle pathForResource:iconBase ofType:[iconName pathExtension]];
        } else {
            for (NSString *ext in @[@"tiff", @"png", @"icns"]) {
                iconPath = [bundle pathForResource:iconName ofType:ext];
                if (iconPath) break;
            }
        }
        if (iconPath) _icon = LoadImageAtPath(iconPath);
    }

    /* 5. NSWorkspace / generic fallback. */
    if (!_icon)
        _icon = [[NSWorkspace sharedWorkspace] iconForFile:_launchPath];
    if (!_icon)
        _icon = [NSImage imageNamed:@"NSApplicationIcon"];
}

@end
