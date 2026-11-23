//
//  JRGSettings.h
//  JRG
//
//  Every user setting for the Dock strip, backed by NSUserDefaults. Changing a
//  setting posts JRGSettingsDidChangeNotification so the strip can redraw.
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, JRGMetric) {
    JRGMetricCPU = 0,
    JRGMetricGPU,
    JRGMetricMemory,
    JRGMetricNetwork,
    JRGMetricDisk,
    JRGMetricTemperature,
    JRGMetricCount
};

/// The color slots a theme fills. Network and Disk each get two (down/up, read/write).
typedef NS_ENUM(NSInteger, JRGColorSlot) {
    JRGColorCPU = 0,
    JRGColorGPU,
    JRGColorMemory,
    JRGColorNetDown,
    JRGColorNetUp,
    JRGColorDiskRead,
    JRGColorDiskWrite,
    JRGColorTemperature,
    JRGColorSlotCount
};

typedef NS_ENUM(NSInteger, JRGStripSize) {
    JRGStripSizeAuto = 0,
    JRGStripSizeCompact,
    JRGStripSizeLarge
};

extern NSNotificationName const JRGSettingsDidChangeNotification;
extern NSString * const JRGCustomThemeName;

NSString *JRGMetricName(JRGMetric m);
NSString *JRGColorSlotName(JRGColorSlot slot);

@interface JRGSettings : NSObject

+ (instancetype)shared;

// Strip
@property (nonatomic) BOOL glass;                 // NO = bare
@property (nonatomic) BOOL keepOnTop;
@property (nonatomic) CGFloat offsetX;            // strip's x offset from the Dock screen's left edge
@property (nonatomic) NSInteger historyMinutes;   // 1, 5, 15, or 30
@property (nonatomic) JRGStripSize stripSize;
- (BOOL)isMetricEnabled:(JRGMetric)m;
- (void)setMetric:(JRGMetric)m enabled:(BOOL)enabled;
- (NSArray<NSNumber *> *)enabledMetrics;          // in display order

// Display
@property (nonatomic) BOOL decimalUnits;          // YES = 1000-based, like macOS
@property (nonatomic) BOOL networkInBits;

// Theme
@property (nonatomic, copy) NSString *themeName;  // a preset name or JRGCustomThemeName
+ (NSArray<NSString *> *)presetThemeNames;
+ (NSArray<NSColor *> *)colorsForPreset:(NSString *)name;
- (NSColor *)colorForSlot:(JRGColorSlot)slot;
/// The saved Custom theme colors, or nil if none have been made yet.
- (NSArray<NSColor *> *)savedCustomColors;
/// Sets one color and switches the theme to Custom (seeded from the current colors).
- (void)setColor:(NSColor *)color forSlot:(JRGColorSlot)slot;

// Formatting that follows the unit settings.
- (NSString *)bytesString:(double)bytes;
- (void)formatBytes:(double)bytes number:(NSString **)number unit:(NSString **)unit;
- (NSString *)rateString:(double)bytesPerSecond network:(BOOL)network;   // "1.2M" or "9.6Mb"

@end
