//
//  JRGSettings.m
//  JRG
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import "JRGSettings.h"

NSNotificationName const JRGSettingsDidChangeNotification = @"JRGSettingsDidChangeNotification";
NSString * const JRGCustomThemeName = @"Custom";

static NSString * const kStyle          = @"JRGDockStyle";       // "glass" or "bare"
static NSString * const kKeepOnTop      = @"JRGDockKeepOnTop";
static NSString * const kOffsetX        = @"JRGDockOffsetX";
static NSString * const kHistoryMinutes = @"JRGHistoryMinutes";
static NSString * const kStripSize      = @"JRGStripSize";
static NSString * const kMetrics        = @"JRGEnabledMetrics";  // array of BOOLs, one per JRGMetric
static NSString * const kDecimalUnits   = @"JRGDecimalUnits";
static NSString * const kNetworkBits    = @"JRGNetworkBits";
static NSString * const kShowInDock     = @"JRGShowInDock";
static NSString * const kTheme          = @"JRGTheme";
static NSString * const kCustomColors   = @"JRGCustomColors";    // array of "RRGGBB" strings, one per slot

NSString *JRGMetricName(JRGMetric m) {
    switch (m) {
        case JRGMetricCPU:         return @"CPU";
        case JRGMetricGPU:         return @"GPU";
        case JRGMetricMemory:      return @"MEMORY";
        case JRGMetricNetwork:     return @"NETWORK";
        case JRGMetricDisk:        return @"DISK";
        case JRGMetricTemperature: return @"TEMP";
        default:                   return @"";
    }
}

NSString *JRGColorSlotName(JRGColorSlot slot) {
    switch (slot) {
        case JRGColorCPU:         return @"CPU";
        case JRGColorGPU:         return @"GPU";
        case JRGColorMemory:      return @"Memory";
        case JRGColorNetDown:     return @"Net down";
        case JRGColorNetUp:       return @"Net up";
        case JRGColorDiskRead:    return @"Disk read";
        case JRGColorDiskWrite:   return @"Disk write";
        case JRGColorTemperature: return @"Temp";
        default:                  return @"";
    }
}

static NSColor *JRGColorFromHex(NSString *hex) {
    unsigned int v = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&v];
    return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}

static NSString *JRGHexFromColor(NSColor *color) {
    NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: [NSColor whiteColor];
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)round(c.redComponent * 255), (int)round(c.greenComponent * 255), (int)round(c.blueComponent * 255)];
}

/// Preset themes: one hex color per JRGColorSlot, in slot order.
static NSDictionary<NSString *, NSArray<NSString *> *> *JRGPresets(void) {
    static NSDictionary *presets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        presets = @{
            //                 CPU       GPU       Memory    NetDown   NetUp     DiskRead  DiskWrite Temp
            @"Midnight neon": @[@"00E0FF", @"8B6BFF", @"3D8BFF", @"00F0C8", @"A66BFF", @"2DE3A0", @"3D8BFF", @"FF6B9A"],
            @"Aurora":        @[@"7CFFB2", @"B388FF", @"4FD1FF", @"5CE1E6", @"F7A8FF", @"7CFFB2", @"4FD1FF", @"FFB86B"],
            @"Ember":         @[@"FF7A45", @"FF4D6D", @"FFB547", @"FFD166", @"F15BB5", @"FF9F45", @"FF4D6D", @"FF3B3B"],
            @"Ocean":         @[@"38BDF8", @"A5B4FC", @"60A5FA", @"2DD4BF", @"818CF8", @"22D3EE", @"60A5FA", @"F472B6"],
            @"Synthwave":     @[@"FF2E97", @"B026FF", @"00F5FF", @"00F5FF", @"FF2E97", @"FF9E00", @"B026FF", @"FF5E5E"],
            @"Mono":          @[@"E8ECFF", @"C7CCE8", @"D9DCF0", @"F2F4FF", @"9EA6CF", @"F2F4FF", @"9EA6CF", @"FFFFFF"],
        };
    });
    return presets;
}

@implementation JRGSettings {
    NSArray<NSColor *> *_colorCache;
}

+ (instancetype)shared {
    static JRGSettings *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[JRGSettings alloc] init]; });
    return shared;
}

+ (void)initialize {
    if (self != [JRGSettings class]) return;
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kStyle: @"glass",
        kKeepOnTop: @YES,
        kOffsetX: @12,
        kHistoryMinutes: @5,
        kStripSize: @(JRGStripSizeAuto),
        kMetrics: @[@YES, @YES, @YES, @YES, @YES, @NO],
        kDecimalUnits: @YES,
        kNetworkBits: @NO,
        kShowInDock: @YES,
        kTheme: @"Midnight neon",
    }];
}

- (NSUserDefaults *)d { return [NSUserDefaults standardUserDefaults]; }

- (void)changed {
    _colorCache = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:JRGSettingsDidChangeNotification object:self];
}

#pragma mark Strip

- (BOOL)glass { return ![[self.d stringForKey:kStyle] isEqualToString:@"bare"]; }
- (void)setGlass:(BOOL)glass { [self.d setObject:glass ? @"glass" : @"bare" forKey:kStyle]; [self changed]; }

- (BOOL)keepOnTop { return [self.d boolForKey:kKeepOnTop]; }
- (void)setKeepOnTop:(BOOL)v { [self.d setBool:v forKey:kKeepOnTop]; [self changed]; }

- (CGFloat)offsetX { return [self.d doubleForKey:kOffsetX]; }
- (void)setOffsetX:(CGFloat)v { [self.d setDouble:round(v) forKey:kOffsetX]; }   // no notification: the strip moved itself

- (NSInteger)historyMinutes {
    NSInteger m = [self.d integerForKey:kHistoryMinutes];
    return (m == 1 || m == 5 || m == 15 || m == 30) ? m : 5;
}
- (void)setHistoryMinutes:(NSInteger)v { [self.d setInteger:v forKey:kHistoryMinutes]; [self changed]; }

- (JRGStripSize)stripSize { return (JRGStripSize)MIN(MAX(0, [self.d integerForKey:kStripSize]), 2); }
- (void)setStripSize:(JRGStripSize)v { [self.d setInteger:v forKey:kStripSize]; [self changed]; }

- (BOOL)isMetricEnabled:(JRGMetric)m {
    NSArray *a = [self.d arrayForKey:kMetrics];
    return m < (NSInteger)a.count ? [a[m] boolValue] : (m != JRGMetricTemperature);
}

- (void)setMetric:(JRGMetric)m enabled:(BOOL)enabled {
    NSMutableArray *a = [NSMutableArray array];
    for (JRGMetric i = 0; i < JRGMetricCount; i++) [a addObject:@(i == m ? enabled : [self isMetricEnabled:i])];
    // Keep at least one metric on, or the strip would vanish.
    if (![a containsObject:@YES]) return;
    [self.d setObject:a forKey:kMetrics];
    [self changed];
}

- (NSArray<NSNumber *> *)enabledMetrics {
    NSMutableArray *out = [NSMutableArray array];
    for (JRGMetric m = 0; m < JRGMetricCount; m++) if ([self isMetricEnabled:m]) [out addObject:@(m)];
    if (out.count == 0) [out addObject:@(JRGMetricCPU)];
    return out;
}

#pragma mark App

- (BOOL)showInDock { return [self.d boolForKey:kShowInDock]; }
- (void)setShowInDock:(BOOL)v { [self.d setBool:v forKey:kShowInDock]; [self changed]; }

#pragma mark Display

- (BOOL)decimalUnits { return [self.d boolForKey:kDecimalUnits]; }
- (void)setDecimalUnits:(BOOL)v { [self.d setBool:v forKey:kDecimalUnits]; [self changed]; }

- (BOOL)networkInBits { return [self.d boolForKey:kNetworkBits]; }
- (void)setNetworkInBits:(BOOL)v { [self.d setBool:v forKey:kNetworkBits]; [self changed]; }

#pragma mark Theme

+ (NSArray<NSString *> *)presetThemeNames {
    return @[@"Midnight neon", @"Aurora", @"Ember", @"Ocean", @"Synthwave", @"Mono"];
}

+ (NSArray<NSColor *> *)colorsForPreset:(NSString *)name {
    NSArray *hexes = JRGPresets()[name] ?: JRGPresets()[@"Midnight neon"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *h in hexes) [out addObject:JRGColorFromHex(h)];
    return out;
}

- (NSString *)themeName {
    NSString *t = [self.d stringForKey:kTheme];
    if ([t isEqualToString:JRGCustomThemeName] && [self.d arrayForKey:kCustomColors].count == JRGColorSlotCount) return t;
    return JRGPresets()[t] ? t : @"Midnight neon";
}

- (void)setThemeName:(NSString *)name {
    [self.d setObject:name forKey:kTheme];
    [self changed];
}

- (NSArray<NSColor *> *)currentColors {
    if (_colorCache) return _colorCache;
    NSString *t = self.themeName;
    if ([t isEqualToString:JRGCustomThemeName]) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *h in [self.d arrayForKey:kCustomColors]) [out addObject:JRGColorFromHex(h)];
        _colorCache = out;
    } else {
        _colorCache = [JRGSettings colorsForPreset:t];
    }
    return _colorCache;
}

- (NSArray<NSColor *> *)savedCustomColors {
    NSArray *hexes = [self.d arrayForKey:kCustomColors];
    if (hexes.count != JRGColorSlotCount) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *h in hexes) [out addObject:JRGColorFromHex(h)];
    return out;
}

- (NSColor *)colorForSlot:(JRGColorSlot)slot {
    NSArray *c = [self currentColors];
    return slot < (NSInteger)c.count ? c[slot] : [NSColor whiteColor];
}

- (void)setColor:(NSColor *)color forSlot:(JRGColorSlot)slot {
    NSMutableArray *hexes = [NSMutableArray array];
    for (NSColor *c in [self currentColors]) [hexes addObject:JRGHexFromColor(c)];
    if (slot >= (NSInteger)hexes.count) return;
    hexes[slot] = JRGHexFromColor(color);
    [self.d setObject:hexes forKey:kCustomColors];
    [self.d setObject:JRGCustomThemeName forKey:kTheme];
    [self changed];
}

#pragma mark Formatting

- (void)formatValue:(double)value units:(NSArray<NSString *> *)units number:(NSString **)number unit:(NSString **)unit {
    double base = self.decimalUnits ? 1000.0 : 1024.0;
    NSInteger u = 0;
    while (value >= 1000.0 && u < (NSInteger)units.count - 1) { value /= base; u++; }
    if (u == 0)            *number = [NSString stringWithFormat:@"%.0f", value];
    else if (value < 100)  *number = [NSString stringWithFormat:@"%.1f", value];
    else                   *number = [NSString stringWithFormat:@"%.0f", value];
    *unit = units[u];
}

- (void)formatBytes:(double)bytes number:(NSString **)number unit:(NSString **)unit {
    [self formatValue:MAX(0, bytes) units:@[@"B", @"K", @"M", @"G", @"T"] number:number unit:unit];
}

- (NSString *)bytesString:(double)bytes {
    NSString *n, *u; [self formatBytes:bytes number:&n unit:&u];
    return [n stringByAppendingString:u];
}

- (NSString *)rateString:(double)bytesPerSecond network:(BOOL)network {
    if (network && self.networkInBits) {
        NSString *n, *u;
        [self formatValue:MAX(0, bytesPerSecond) * 8 units:@[@"b", @"Kb", @"Mb", @"Gb", @"Tb"] number:&n unit:&u];
        return [n stringByAppendingString:u];
    }
    return [self bytesString:bytesPerSecond];
}

@end
