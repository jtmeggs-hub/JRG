//
//  XRGDockStrip.m
//  JRG
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import "XRGDockStrip.h"
#import "XRGAppDelegate.h"
#import "XRGGraphWindow.h"
#import "XRGCPUMiner.h"
#import "XRGGPUMiner.h"
#import "XRGMemoryMiner.h"
#import "XRGNetMiner.h"
#import "XRGDataSet.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOBlockStorageDriver.h>

NSString * const JRGLayoutKey        = @"JRGLayout";
NSString * const JRGDockStyleKey     = @"JRGDockStyle";
NSString * const JRGDockKeepOnTopKey = @"JRGDockKeepOnTop";
NSString * const JRGDockOffsetXKey   = @"JRGDockOffsetX";

static const NSInteger JRGHistorySamples = 300;   // 5 minutes at one sample per second
static const NSTimeInterval JRGSampleInterval = 1.0;

typedef NS_ENUM(NSInteger, JRGMetric) {
    JRGMetricCPU = 0,
    JRGMetricGPU,
    JRGMetricMemory,
    JRGMetricNetwork,
    JRGMetricDisk,
    JRGMetricCount
};

static NSColor *JRGHex(UInt32 hex, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:alpha];
}

// Midnight neon palette: primary and secondary color per metric.
static NSColor *JRGMetricColor(JRGMetric m, BOOL secondary) {
    switch (m) {
        case JRGMetricCPU:     return secondary ? JRGHex(0x0094B8, 1) : JRGHex(0x00E0FF, 1);
        case JRGMetricGPU:     return secondary ? JRGHex(0xB18CFF, 1) : JRGHex(0x8B6BFF, 1);
        case JRGMetricMemory:  return secondary ? JRGHex(0x7FC8FF, 1) : JRGHex(0x3D8BFF, 1);
        case JRGMetricNetwork: return secondary ? JRGHex(0xA66BFF, 1) : JRGHex(0x00F0C8, 1);   // down mint, up violet
        case JRGMetricDisk:    return secondary ? JRGHex(0x3D8BFF, 1) : JRGHex(0x2DE3A0, 1);   // read green, write blue
        default:               return [NSColor whiteColor];
    }
}

static NSString *JRGMetricName(JRGMetric m) {
    switch (m) {
        case JRGMetricCPU:     return @"CPU";
        case JRGMetricGPU:     return @"GPU";
        case JRGMetricMemory:  return @"MEMORY";
        case JRGMetricNetwork: return @"NETWORK";
        case JRGMetricDisk:    return @"DISK";
        default:               return @"";
    }
}

static BOOL JRGMetricIsDual(JRGMetric m) {
    return m == JRGMetricNetwork || m == JRGMetricDisk;
}

/// Splits a byte count into a short number and a unit, e.g. 22548578304 -> ("21.0", "G").
static void JRGFormatBytes(double bytes, NSString **number, NSString **unit) {
    NSArray *units = @[@"B", @"K", @"M", @"G", @"T"];
    NSInteger u = 0;
    while (bytes >= 1000.0 && u < (NSInteger)units.count - 1) { bytes /= 1024.0; u++; }
    if (u == 0)            *number = [NSString stringWithFormat:@"%.0f", bytes];
    else if (bytes < 100)  *number = [NSString stringWithFormat:@"%.1f", bytes];
    else                   *number = [NSString stringWithFormat:@"%.0f", bytes];
    *unit = units[u];
}

static NSString *JRGBytesString(double bytes) {
    NSString *n, *u; JRGFormatBytes(bytes, &n, &u);
    return [n stringByAppendingString:u];
}

/// Reads total bytes read/written across all block storage devices.
static void JRGReadDiskCounters(UInt64 *readBytes, UInt64 *writeBytes) {
    *readBytes = 0; *writeBytes = 0;
    io_iterator_t drives = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &drives) != KERN_SUCCESS) return;

    io_registry_entry_t drive;
    while ((drive = IOIteratorNext(drives))) {
        CFTypeRef stats = IORegistryEntryCreateCFProperty(drive, CFSTR(kIOBlockStorageDriverStatisticsKey), kCFAllocatorDefault, kNilOptions);
        if (stats) {
            if (CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                UInt64 value = 0;
                CFNumberRef n = CFDictionaryGetValue((CFDictionaryRef)stats, CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey));
                if (n && CFNumberGetValue(n, kCFNumberSInt64Type, &value)) *readBytes += value;
                n = CFDictionaryGetValue((CFDictionaryRef)stats, CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey));
                if (n && CFNumberGetValue(n, kCFNumberSInt64Type, &value)) *writeBytes += value;
            }
            CFRelease(stats);
        }
        IOObjectRelease(drive);
    }
    IOObjectRelease(drives);
}

/// Values in chronological order (oldest first).
static NSArray<NSNumber *> *JRGOrderedValues(XRGDataSet *set) {
    size_t n = set.numValues;
    if (n == 0) return @[];
    CGFloat *buf = malloc(n * sizeof(CGFloat));
    [set valuesInOrder:buf];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (size_t i = 0; i < n; i++) [out addObject:@(MAX(0, buf[i]))];
    free(buf);
    return out;
}

static CGFloat JRGPeak(XRGDataSet *set) {
    CGFloat peak = 0;
    for (NSNumber *v in JRGOrderedValues(set)) peak = MAX(peak, v.doubleValue);
    return peak;
}

#pragma mark - Chart drawing

/// Draws a history chart into `rect` (in a flipped view). Samples are bucketed to the
/// pixel width, keeping each bucket's maximum so short spikes stay visible.
static void JRGDrawChart(NSArray<NSNumber *> *values, CGFloat maxValue, NSRect rect, NSColor *color, BOOL downward, CGFloat lineWidth) {
    if (values.count < 2 || rect.size.width < 2 || rect.size.height < 1) return;
    if (maxValue <= 0) maxValue = 1;

    NSInteger buckets = MAX(2, (NSInteger)floor(rect.size.width / 1.5));
    buckets = MIN(buckets, (NSInteger)values.count);
    CGFloat perBucket = (CGFloat)values.count / buckets;

    CGFloat baseY = downward ? NSMinY(rect) : NSMaxY(rect);
    CGFloat dir = downward ? 1 : -1;

    NSBezierPath *line = [NSBezierPath bezierPath];
    for (NSInteger b = 0; b < buckets; b++) {
        NSInteger start = (NSInteger)floor(b * perBucket);
        NSInteger end = MAX(start + 1, (NSInteger)floor((b + 1) * perBucket));
        CGFloat v = 0;
        for (NSInteger i = start; i < end && i < (NSInteger)values.count; i++) v = MAX(v, values[i].doubleValue);
        CGFloat frac = MIN(1, v / maxValue);
        NSPoint p = NSMakePoint(NSMinX(rect) + rect.size.width * b / (buckets - 1), baseY + dir * frac * rect.size.height);
        if (b == 0) [line moveToPoint:p]; else [line lineToPoint:p];
    }

    NSBezierPath *area = [line copy];
    [area lineToPoint:NSMakePoint(NSMaxX(rect), baseY)];
    [area lineToPoint:NSMakePoint(NSMinX(rect), baseY)];
    [area closePath];

    [NSGraphicsContext saveGraphicsState];
    [area addClip];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[color colorWithAlphaComponent:0.10]
                                                  endingColor:[color colorWithAlphaComponent:0.55]];
    // In a flipped view, angle 90 runs top to bottom visually reversed; pick so the fill is strongest near the line.
    [g drawInRect:rect angle:(downward ? 90 : -90)];
    [NSGraphicsContext restoreGraphicsState];

    [color setStroke];
    line.lineWidth = lineWidth;
    line.lineJoinStyle = NSLineJoinStyleRound;
    line.lineCapStyle = NSLineCapStyleRound;
    [line stroke];
}

#pragma mark - Layout

@interface JRGStripLayout : NSObject
@property CGFloat height, padding, gap, sectionGap, chartWidth, chartHeight;
@property NSFont *labelFont, *bigFont, *unitFont, *dualFont;
@property NSArray<NSValue *> *sectionRects;   // one per metric, in view coordinates
@property NSArray<NSNumber *> *blockWidths;    // width of the label/number block per metric
@property CGFloat totalWidth;
@end

@implementation JRGStripLayout

+ (instancetype)layoutForHeight:(CGFloat)h {
    JRGStripLayout *L = [[JRGStripLayout alloc] init];
    L.height = h;
    L.padding = round(h * 0.26);
    L.gap = round(h * 0.13);
    L.sectionGap = round(h * 0.36);
    L.chartWidth = round(h * 0.95);
    L.chartHeight = round(h * 0.46);
    L.labelFont = [NSFont systemFontOfSize:MAX(10, round(h * 0.155)) weight:NSFontWeightSemibold];
    L.bigFont = [NSFont monospacedDigitSystemFontOfSize:round(h * 0.36) weight:NSFontWeightMedium];
    L.unitFont = [NSFont systemFontOfSize:round(h * 0.2) weight:NSFontWeightRegular];
    L.dualFont = [NSFont monospacedDigitSystemFontOfSize:round(h * 0.23) weight:NSFontWeightMedium];

    NSDictionary *labelAttrs = @{NSFontAttributeName: L.labelFont, NSKernAttributeName: @(0.6)};
    NSDictionary *bigAttrs = @{NSFontAttributeName: L.bigFont};
    NSDictionary *unitAttrs = @{NSFontAttributeName: L.unitFont};
    NSDictionary *dualAttrs = @{NSFontAttributeName: L.dualFont};

    NSMutableArray *rects = [NSMutableArray array];
    NSMutableArray *blocks = [NSMutableArray array];
    CGFloat x = L.padding;
    for (JRGMetric m = 0; m < JRGMetricCount; m++) {
        CGFloat labelW = [JRGMetricName(m) sizeWithAttributes:labelAttrs].width;
        CGFloat numW;
        if (JRGMetricIsDual(m)) {
            numW = [@"↓ 999.9M" sizeWithAttributes:dualAttrs].width;
        } else {
            NSString *tmpl = (m == JRGMetricMemory) ? @"99.9" : @"100";
            NSString *unit = (m == JRGMetricMemory) ? @"G" : @"%";
            numW = [tmpl sizeWithAttributes:bigAttrs].width + [unit sizeWithAttributes:unitAttrs].width + 1;
        }
        CGFloat blockW = ceil(MAX(labelW, numW));
        CGFloat w = blockW + L.gap + L.chartWidth;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, h)]];
        [blocks addObject:@(blockW)];
        x += w + (m < JRGMetricCount - 1 ? L.sectionGap : 0);
    }
    L.sectionRects = rects;
    L.blockWidths = blocks;
    L.totalWidth = ceil(x + L.padding);
    return L;
}

@end

#pragma mark - Strip view

@class XRGDockStripController;

@interface JRGStripView : NSView
@property (weak) XRGDockStripController *controller;
@property JRGStripLayout *layout;
@property BOOL bare;
@property NSInteger hoveredMetric;
@end

@interface XRGDockStripController ()
@property NSWindow *stripWindow;
@property JRGStripView *stripView;
@property NSView *glassView;
@property NSWindow *detailWindow;
@property NSView *detailView;
@property NSTimer *sampleTimer;
@property NSTimer *hoverTimer;
@property NSInteger pendingHoverMetric;
@property BOOL adjustingPosition;

@property XRGCPUMiner *cpuMiner;
@property XRGGPUMiner *gpuMiner;
@property XRGMemoryMiner *memoryMiner;
@property XRGNetMiner *netMiner;
@property UInt64 lastDiskRead, lastDiskWrite, diskReadSinceLaunch, diskWriteSinceLaunch;
@property NSDate *lastDiskSample;

// History: index 0 is the primary series, index 1 the secondary (network up, disk write).
@property NSArray<NSArray<XRGDataSet *> *> *history;
@property CGFloat cpuNow, gpuNow, vramUsed, vramTotal;
@property UInt64 memUsed, memTotal;
@property CGFloat netDown, netUp, diskRead, diskWrite;

- (NSMenu *)stripMenu;
- (void)hoverChangedTo:(NSInteger)metric;
- (void)drawMetric:(JRGMetric)m inRect:(NSRect)rect layout:(JRGStripLayout *)L bare:(BOOL)bare;
@end

@implementation JRGStripView

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
}

- (NSInteger)metricAtPoint:(NSPoint)p {
    for (NSInteger i = 0; i < (NSInteger)self.layout.sectionRects.count; i++) {
        if (NSPointInRect(p, [self.layout.sectionRects[i] rectValue])) return i;
    }
    return -1;
}

- (void)mouseMoved:(NSEvent *)event {
    [self.controller hoverChangedTo:[self metricAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]];
}

- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event  { [self.controller hoverChangedTo:-1]; }

- (NSMenu *)menuForEvent:(NSEvent *)event { return [self.controller stripMenu]; }

- (void)drawRect:(NSRect)dirtyRect {
    JRGStripLayout *L = self.layout;
    for (JRGMetric m = 0; m < JRGMetricCount; m++) {
        [self.controller drawMetric:m inRect:[L.sectionRects[m] rectValue] layout:L bare:self.bare];
    }
}

@end

#pragma mark - Detail view

@interface JRGDetailView : NSView
@property (weak) XRGDockStripController *controller;
@property NSInteger metric;
@property NSArray<NSArray<NSString *> *> *stats;   // label/value pairs
@end

#pragma mark - Controller

@implementation XRGDockStripController

+ (instancetype)shared {
    static XRGDockStripController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XRGDockStripController alloc] init]; });
    return shared;
}

+ (void)initialize {
    if (self == [XRGDockStripController class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            JRGLayoutKey: @"dock",
            JRGDockStyleKey: @"glass",
            JRGDockKeepOnTopKey: @YES,
            JRGDockOffsetXKey: @12,
        }];
    }
}

+ (BOOL)dockLayoutSelected {
    return [[[NSUserDefaults standardUserDefaults] stringForKey:JRGLayoutKey] isEqualToString:@"dock"];
}

- (instancetype)init {
    if (self = [super init]) {
        _pendingHoverMetric = -1;
        NSMutableArray *hist = [NSMutableArray array];
        for (JRGMetric m = 0; m < JRGMetricCount; m++) {
            XRGDataSet *a = [[XRGDataSet alloc] init]; [a resize:JRGHistorySamples]; [a setAllValues:0];
            XRGDataSet *b = [[XRGDataSet alloc] init]; [b resize:JRGHistorySamples]; [b setAllValues:0];
            [hist addObject:@[a, b]];
        }
        _history = hist;
    }
    return self;
}

- (BOOL)isGlass {
    return ![[[NSUserDefaults standardUserDefaults] stringForKey:JRGDockStyleKey] isEqualToString:@"bare"];
}

#pragma mark Showing and hiding

- (XRGGraphWindow *)classicWindow {
    return [(XRGAppDelegate *)[NSApp delegate] xrgGraphWindow];
}

- (void)showDockStrip {
    [[NSUserDefaults standardUserDefaults] setObject:@"dock" forKey:JRGLayoutKey];
    [self startSampling];
    [self buildWindowIfNeeded];
    [self applyStyle];
    [self positionStrip];
    [self.stripWindow orderFrontRegardless];
    [[self classicWindow] orderOut:nil];
}

- (void)showClassicLayout {
    [[NSUserDefaults standardUserDefaults] setObject:@"classic" forKey:JRGLayoutKey];
    [self hoverChangedTo:-1];
    [self.stripWindow orderOut:nil];
    [self.sampleTimer invalidate];
    self.sampleTimer = nil;
    [[self classicWindow] orderFrontRegardless];
}

- (IBAction)switchToDockStrip:(id)sender { [self showDockStrip]; }
- (IBAction)switchToClassic:(id)sender   { [self showClassicLayout]; }

- (void)buildWindowIfNeeded {
    if (self.stripWindow) return;

    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 64)
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered defer:NO];
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    w.hasShadow = NO;
    w.movableByWindowBackground = YES;
    w.releasedWhenClosed = NO;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    w.delegate = (id<NSWindowDelegate>)self;

    NSView *container = [[NSView alloc] initWithFrame:w.contentView.bounds];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    w.contentView = container;

    JRGStripView *v = [[JRGStripView alloc] initWithFrame:container.bounds];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    v.controller = self;
    v.hoveredMetric = -1;
    [container addSubview:v];

    self.stripWindow = w;
    self.stripView = v;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];
}

- (void)applyStyle {
    BOOL glass = [self isGlass];
    [self.glassView removeFromSuperview];
    self.glassView = nil;

    if (glass) {
        NSView *container = self.stripWindow.contentView;
        CGFloat radius = round(self.stripWindow.frame.size.height * 0.3);
        NSView *g;
        if (@available(macOS 26.0, *)) {
            NSGlassEffectView *gv = [[NSGlassEffectView alloc] initWithFrame:container.bounds];
            gv.cornerRadius = radius;
            gv.contentView = [[NSView alloc] initWithFrame:container.bounds];
            g = gv;
        } else {
            NSVisualEffectView *ve = [[NSVisualEffectView alloc] initWithFrame:container.bounds];
            ve.material = NSVisualEffectMaterialHUDWindow;
            ve.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            ve.state = NSVisualEffectStateActive;
            ve.wantsLayer = YES;
            ve.layer.cornerRadius = radius;
            ve.layer.masksToBounds = YES;
            g = ve;
        }
        g.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [container addSubview:g positioned:NSWindowBelow relativeTo:nil];
        self.glassView = g;
    }

    self.stripView.bare = !glass;
    BOOL onTop = [[NSUserDefaults standardUserDefaults] boolForKey:JRGDockKeepOnTopKey];
    self.stripWindow.level = onTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
    self.stripView.needsDisplay = YES;
}

#pragma mark Positioning next to the Dock

/// The screen whose bottom edge holds the Dock (its visible frame starts above the screen's bottom).
- (NSScreen *)dockScreen {
    for (NSScreen *s in [NSScreen screens]) {
        if (NSMinY(s.visibleFrame) - NSMinY(s.frame) > 1) return s;
    }
    return [NSScreen mainScreen];
}

- (NSRect)targetFrame {
    NSScreen *screen = [self dockScreen];
    NSRect sf = screen.frame;
    CGFloat band = NSMinY(screen.visibleFrame) - NSMinY(sf);
    if (band < 30) band = 76;   // Dock hidden or on the side: use a Dock-like band at the bottom.

    CGFloat h = MIN(84, MAX(46, round(band - 14)));
    JRGStripLayout *L = [JRGStripLayout layoutForHeight:h];
    CGFloat w = L.totalWidth;

    CGFloat offset = [[NSUserDefaults standardUserDefaults] doubleForKey:JRGDockOffsetXKey];
    CGFloat x = NSMinX(sf) + MIN(MAX(0, offset), sf.size.width - w);
    CGFloat y = NSMinY(sf) + round((band - h) / 2.0);
    return NSMakeRect(x, y, w, h);
}

- (void)positionStrip {
    if (!self.stripWindow) return;
    NSRect target = [self targetFrame];
    if (!self.stripView.layout || self.stripView.layout.height != target.size.height) {
        self.stripView.layout = [JRGStripLayout layoutForHeight:target.size.height];
    }
    if (!NSEqualRects(self.stripWindow.frame, target)) {
        self.adjustingPosition = YES;
        [self.stripWindow setFrame:target display:YES];
        self.adjustingPosition = NO;
        if ([self.glassView respondsToSelector:@selector(setCornerRadius:)]) {
            [(id)self.glassView setCornerRadius:round(target.size.height * 0.3)];
        } else {
            self.glassView.layer.cornerRadius = round(target.size.height * 0.3);
        }
    }
}

- (void)screensChanged:(NSNotification *)note {
    [self positionStrip];
}

// Dragging moves the strip sideways only; it stays in the Dock's band.
- (void)windowDidMove:(NSNotification *)note {
    if (self.adjustingPosition || note.object != self.stripWindow) return;
    NSRect sf = [self dockScreen].frame;
    CGFloat offset = NSMinX(self.stripWindow.frame) - NSMinX(sf);
    [[NSUserDefaults standardUserDefaults] setDouble:round(offset) forKey:JRGDockOffsetXKey];
    [self positionStrip];
}

#pragma mark Sampling

- (void)startSampling {
    if (self.sampleTimer) return;

    if (!self.cpuMiner) {
        self.cpuMiner = [[XRGCPUMiner alloc] init];
        [self.cpuMiner setDataSize:2];
        self.cpuMiner.uptime = YES;
        self.cpuMiner.loadAverage = YES;
        self.gpuMiner = [[XRGGPUMiner alloc] init];
        [self.gpuMiner setDataSize:2];
        self.memoryMiner = [[XRGMemoryMiner alloc] init];
        [self.memoryMiner setDataSize:2];
        self.netMiner = [[XRGNetMiner alloc] init];
        [self.netMiner setDataSize:2];
        [self.netMiner getLatestNetInfo];
        [self.cpuMiner graphUpdate:nil];

        UInt64 r, w; JRGReadDiskCounters(&r, &w);
        self.lastDiskRead = r; self.lastDiskWrite = w; self.lastDiskSample = [NSDate date];
        self.memTotal = [NSProcessInfo processInfo].physicalMemory;
    }

    self.sampleTimer = [NSTimer timerWithTimeInterval:JRGSampleInterval target:self selector:@selector(sample:) userInfo:nil repeats:YES];
    self.sampleTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:self.sampleTimer forMode:NSRunLoopCommonModes];
}

- (void)sample:(NSTimer *)timer {
    // CPU: average across all cores, 0-100%.
    [self.cpuMiner graphUpdate:nil];
    CGFloat total = 0;
    NSInteger n = self.cpuMiner.numberOfCPUs;
    for (NSInteger i = 0; i < n; i++) {
        total += [self.cpuMiner.userValues[i] currentValue] + [self.cpuMiner.systemValues[i] currentValue] + [self.cpuMiner.niceValues[i] currentValue];
    }
    self.cpuNow = n > 0 ? MIN(100, total / n) : 0;

    // GPU: first GPU's utilization and memory.
    [self.gpuMiner getLatestGraphicsInfo];
    NSArray<XRGDataSet *> *util = self.gpuMiner.utilizationDataSets;
    self.gpuNow = util.count ? MIN(100, MAX(0, [util[0] currentValue])) : 0;
    NSArray<XRGDataSet *> *tv = self.gpuMiner.totalVRAMDataSets, *fv = self.gpuMiner.freeVRAMDataSets;
    if (tv.count && fv.count) {
        self.vramTotal = [tv[0] currentValue];
        self.vramUsed = MAX(0, self.vramTotal - [fv[0] currentValue]);
    }

    // Memory: active + wired.
    [self.memoryMiner getLatestMemoryInfo];
    self.memUsed = self.memoryMiner.activeBytes + self.memoryMiner.wiredBytes;

    // Network: bytes per second.
    [self.netMiner getLatestNetInfo];
    self.netDown = MAX(0, self.netMiner.currentRX);
    self.netUp = MAX(0, self.netMiner.currentTX);

    // Disk: bytes per second since the last sample.
    UInt64 r, w; JRGReadDiskCounters(&r, &w);
    NSTimeInterval dt = MAX(0.2, -[self.lastDiskSample timeIntervalSinceNow]);
    UInt64 dr = r >= self.lastDiskRead ? r - self.lastDiskRead : 0;
    UInt64 dw = w >= self.lastDiskWrite ? w - self.lastDiskWrite : 0;
    self.diskRead = dr / dt; self.diskWrite = dw / dt;
    self.diskReadSinceLaunch += dr; self.diskWriteSinceLaunch += dw;
    self.lastDiskRead = r; self.lastDiskWrite = w; self.lastDiskSample = [NSDate date];

    // On the first sample, fill the history with it so charts start as a flat line
    // at the current level instead of climbing up from zero.
    static BOOL seeded = NO;
    if (!seeded) {
        seeded = YES;
        [self.history[JRGMetricCPU][0] setAllValues:self.cpuNow];
        [self.history[JRGMetricGPU][0] setAllValues:self.gpuNow];
        [self.history[JRGMetricMemory][0] setAllValues:self.memTotal ? (CGFloat)self.memUsed / self.memTotal : 0];
    }

    [self.history[JRGMetricCPU][0] setNextValue:self.cpuNow];
    [self.history[JRGMetricGPU][0] setNextValue:self.gpuNow];
    [self.history[JRGMetricMemory][0] setNextValue:self.memTotal ? (CGFloat)self.memUsed / self.memTotal : 0];
    [self.history[JRGMetricNetwork][0] setNextValue:self.netDown];
    [self.history[JRGMetricNetwork][1] setNextValue:self.netUp];
    [self.history[JRGMetricDisk][0] setNextValue:self.diskRead];
    [self.history[JRGMetricDisk][1] setNextValue:self.diskWrite];

    [self positionStrip];   // follows Dock size and display changes
    self.stripView.needsDisplay = YES;
    if (self.detailWindow.isVisible) [self refreshDetail];
}

#pragma mark Drawing a metric

- (void)drawMetric:(JRGMetric)m inRect:(NSRect)rect layout:(JRGStripLayout *)L bare:(BOOL)bare {
    CGFloat h = L.height;
    CGFloat blockW = [L.blockWidths[m] doubleValue];
    NSColor *c1 = JRGMetricColor(m, NO), *c2 = JRGMetricColor(m, YES);

    NSShadow *shadow = nil;
    if (bare) {
        shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.75];
        shadow.shadowBlurRadius = 3;
        shadow.shadowOffset = NSMakeSize(0, -1);
    }
    NSMutableDictionary *labelAttrs = [@{NSFontAttributeName: L.labelFont, NSForegroundColorAttributeName: c1, NSKernAttributeName: @(0.6)} mutableCopy];
    NSMutableDictionary *bigAttrs   = [@{NSFontAttributeName: L.bigFont, NSForegroundColorAttributeName: [NSColor whiteColor]} mutableCopy];
    NSMutableDictionary *unitAttrs  = [@{NSFontAttributeName: L.unitFont, NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.65]} mutableCopy];
    NSMutableDictionary *dualAttrs  = [@{NSFontAttributeName: L.dualFont, NSForegroundColorAttributeName: [NSColor whiteColor]} mutableCopy];
    if (shadow) { labelAttrs[NSShadowAttributeName] = bigAttrs[NSShadowAttributeName] = unitAttrs[NSShadowAttributeName] = dualAttrs[NSShadowAttributeName] = shadow; }

    // Text block, vertically centered: label on top, number(s) beneath.
    CGFloat labelH = ceil(L.labelFont.ascender - L.labelFont.descender);
    CGFloat textH;
    if (JRGMetricIsDual(m)) textH = labelH + 2 * ceil(L.dualFont.ascender - L.dualFont.descender);
    else                    textH = labelH + ceil(L.bigFont.ascender - L.bigFont.descender) - 2;
    CGFloat top = round((h - textH) / 2.0);

    [JRGMetricName(m) drawAtPoint:NSMakePoint(NSMinX(rect), top) withAttributes:labelAttrs];
    CGFloat y = top + labelH - 1;

    if (JRGMetricIsDual(m)) {
        CGFloat a = (m == JRGMetricNetwork) ? self.netDown : self.diskRead;
        CGFloat b = (m == JRGMetricNetwork) ? self.netUp : self.diskWrite;
        NSString *aGlyph = (m == JRGMetricNetwork) ? @"↓" : @"R";
        NSString *bGlyph = (m == JRGMetricNetwork) ? @"↑" : @"W";
        CGFloat lineH = ceil(L.dualFont.ascender - L.dualFont.descender);
        NSArray *rows = @[@[aGlyph, @(a), c1], @[bGlyph, @(b), c2]];
        for (NSArray *row in rows) {
            NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
            NSMutableDictionary *glyphAttrs = [dualAttrs mutableCopy];
            glyphAttrs[NSForegroundColorAttributeName] = row[2];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:[row[0] stringByAppendingString:@" "] attributes:glyphAttrs]];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:JRGBytesString([row[1] doubleValue]) attributes:dualAttrs]];
            [s drawAtPoint:NSMakePoint(NSMinX(rect), y)];
            y += lineH;
        }
    } else {
        NSString *num, *unit;
        if (m == JRGMetricMemory) { JRGFormatBytes(self.memUsed, &num, &unit); }
        else { num = [NSString stringWithFormat:@"%.0f", (m == JRGMetricCPU) ? self.cpuNow : self.gpuNow]; unit = @"%"; }
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:num attributes:bigAttrs];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:unit attributes:unitAttrs]];
        [s drawAtPoint:NSMakePoint(NSMinX(rect), y - round(L.bigFont.pointSize * 0.06))];
    }

    // History chart beside the numbers.
    NSRect chart = NSMakeRect(NSMinX(rect) + blockW + L.gap, round((h - L.chartHeight) / 2.0), L.chartWidth, L.chartHeight);
    CGFloat lw = bare ? 1.8 : 1.5;
    NSArray *v1 = JRGOrderedValues(self.history[m][0]);
    if (JRGMetricIsDual(m)) {
        NSArray *v2 = JRGOrderedValues(self.history[m][1]);
        CGFloat peak = MAX(10 * 1024, MAX(JRGPeak(self.history[m][0]), JRGPeak(self.history[m][1])));
        NSRect upper = NSMakeRect(chart.origin.x, chart.origin.y, chart.size.width, floor(chart.size.height / 2) - 0.5);
        NSRect lower = NSMakeRect(chart.origin.x, NSMaxY(upper) + 1, chart.size.width, upper.size.height);
        JRGDrawChart(v1, peak, upper, c1, NO, lw);
        JRGDrawChart(v2, peak, lower, c2, YES, lw);
        [[NSColor colorWithWhite:1 alpha:0.22] setFill];
        NSRectFillUsingOperation(NSMakeRect(chart.origin.x, NSMaxY(upper), chart.size.width, 0.5), NSCompositingOperationSourceOver);
    } else {
        CGFloat max = (m == JRGMetricMemory) ? 1.0 : 100.0;
        JRGDrawChart(v1, max, chart, c1, NO, lw);
    }
}

#pragma mark Hover detail

- (void)hoverChangedTo:(NSInteger)metric {
    if (metric == self.pendingHoverMetric) return;
    self.pendingHoverMetric = metric;
    [self.hoverTimer invalidate];

    if (metric < 0) {
        [self.detailWindow orderOut:nil];
        return;
    }
    if (self.detailWindow.isVisible) {   // already showing: switch immediately
        [self showDetailFor:metric];
        return;
    }
    self.hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *t) {
        [self showDetailFor:metric];
    }];
}

- (void)buildDetailWindowIfNeeded {
    if (self.detailWindow) return;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 280, 178) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    w.hasShadow = YES;
    w.ignoresMouseEvents = YES;
    w.releasedWhenClosed = NO;
    w.level = NSPopUpMenuWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;

    NSView *container = [[NSView alloc] initWithFrame:w.contentView.bounds];
    w.contentView = container;
    NSView *g;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *gv = [[NSGlassEffectView alloc] initWithFrame:container.bounds];
        gv.cornerRadius = 16;
        gv.tintColor = [NSColor colorWithSRGBRed:0.04 green:0.06 blue:0.16 alpha:0.55];
        gv.contentView = [[NSView alloc] initWithFrame:container.bounds];
        g = gv;
    } else {
        NSVisualEffectView *ve = [[NSVisualEffectView alloc] initWithFrame:container.bounds];
        ve.material = NSVisualEffectMaterialHUDWindow;
        ve.state = NSVisualEffectStateActive;
        ve.wantsLayer = YES; ve.layer.cornerRadius = 16; ve.layer.masksToBounds = YES;
        g = ve;
    }
    g.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:g];

    JRGDetailView *dv = [[JRGDetailView alloc] initWithFrame:container.bounds];
    dv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    dv.controller = self;
    [container addSubview:dv];

    self.detailWindow = w;
    self.detailView = dv;
}

- (void)showDetailFor:(NSInteger)metric {
    [self buildDetailWindowIfNeeded];
    ((JRGDetailView *)self.detailView).metric = metric;
    [self refreshDetail];

    NSRect section = [self.stripView.layout.sectionRects[metric] rectValue];
    NSRect strip = self.stripWindow.frame;
    NSRect sf = [self dockScreen].frame;
    NSSize size = self.detailWindow.frame.size;
    CGFloat x = NSMinX(strip) + NSMidX(section) - size.width / 2;
    x = MIN(MAX(NSMinX(sf) + 8, x), NSMaxX(sf) - size.width - 8);
    CGFloat y = NSMaxY(strip) + 10;
    [self.detailWindow setFrameOrigin:NSMakePoint(round(x), round(y))];
    [self.detailWindow orderFrontRegardless];
}

static NSString *JRGPercent(CGFloat v) { return [NSString stringWithFormat:@"%.0f%%", v]; }

- (void)refreshDetail {
    JRGDetailView *dv = (JRGDetailView *)self.detailView;
    JRGMetric m = dv.metric;
    NSMutableArray *stats = [NSMutableArray array];
    switch (m) {
        case JRGMetricCPU: {
            [stats addObject:@[@"Usage", JRGPercent(self.cpuNow)]];
            [stats addObject:@[@"5-min peak", JRGPercent(JRGPeak(self.history[m][0]))]];
            [stats addObject:@[@"Load avg", [NSString stringWithFormat:@"%.2f", self.cpuMiner.currentLoadAverage]]];
            [stats addObject:@[@"Cores", [NSString stringWithFormat:@"%ld", (long)self.cpuMiner.numberOfCPUs]]];
            [stats addObject:@[@"Uptime", [NSString stringWithFormat:@"%ldd %ldh %ldm", (long)self.cpuMiner.uptimeDays, (long)self.cpuMiner.uptimeHours, (long)self.cpuMiner.uptimeMinutes]]];
            break;
        }
        case JRGMetricGPU: {
            [stats addObject:@[@"Usage", JRGPercent(self.gpuNow)]];
            [stats addObject:@[@"5-min peak", JRGPercent(JRGPeak(self.history[m][0]))]];
            [stats addObject:@[@"GPU memory", JRGBytesString(self.vramUsed)]];
            [stats addObject:@[@"Available", JRGBytesString(self.vramTotal)]];
            break;
        }
        case JRGMetricMemory: {
            [stats addObject:@[@"Used", JRGBytesString(self.memUsed)]];
            [stats addObject:@[@"Installed", JRGBytesString(self.memTotal)]];
            [stats addObject:@[@"Active", JRGBytesString(self.memoryMiner.activeBytes)]];
            [stats addObject:@[@"Wired", JRGBytesString(self.memoryMiner.wiredBytes)]];
            [stats addObject:@[@"Inactive", JRGBytesString(self.memoryMiner.inactiveBytes)]];
            [stats addObject:@[@"Free", JRGBytesString(self.memoryMiner.freeBytes)]];
            [stats addObject:@[@"Swap", JRGBytesString(self.memoryMiner.usedSwap)]];
            break;
        }
        case JRGMetricNetwork: {
            [stats addObject:@[@"Down", [JRGBytesString(self.netDown) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Up", [JRGBytesString(self.netUp) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Peak down", [JRGBytesString(JRGPeak(self.history[m][0])) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Peak up", [JRGBytesString(JRGPeak(self.history[m][1])) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Since boot", JRGBytesString(self.netMiner.totalBytesSinceBoot)]];
            break;
        }
        case JRGMetricDisk: {
            [stats addObject:@[@"Read", [JRGBytesString(self.diskRead) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Write", [JRGBytesString(self.diskWrite) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Peak read", [JRGBytesString(JRGPeak(self.history[m][0])) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Peak write", [JRGBytesString(JRGPeak(self.history[m][1])) stringByAppendingString:@"/s"]]];
            [stats addObject:@[@"Read total", JRGBytesString(self.diskReadSinceLaunch)]];
            [stats addObject:@[@"Write total", JRGBytesString(self.diskWriteSinceLaunch)]];
            break;
        }
        default: break;
    }
    dv.stats = stats;

    // Size the panel to its content: header, chart, then two columns of stats.
    NSInteger rows = (stats.count + 1) / 2;
    CGFloat height = 14 + 16 + 8 + 70 + 10 + rows * 17 + 12;
    NSRect f = self.detailWindow.frame;
    if (fabs(f.size.height - height) > 0.5) {
        f.size.height = height;
        [self.detailWindow setFrame:f display:NO];
    }
    dv.needsDisplay = YES;
}

#pragma mark Menu

- (NSMenu *)stripMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"JRG"];
    BOOL glass = [self isGlass];

    NSMenuItem *glassItem = [menu addItemWithTitle:@"Glass" action:@selector(setGlassStyle:) keyEquivalent:@""];
    glassItem.target = self; glassItem.state = glass ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *bareItem = [menu addItemWithTitle:@"Bare" action:@selector(setBareStyle:) keyEquivalent:@""];
    bareItem.target = self; bareItem.state = glass ? NSControlStateValueOff : NSControlStateValueOn;
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *top = [menu addItemWithTitle:@"Keep on Top" action:@selector(toggleKeepOnTop:) keyEquivalent:@""];
    top.target = self;
    top.state = [[NSUserDefaults standardUserDefaults] boolForKey:JRGDockKeepOnTopKey] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *reset = [menu addItemWithTitle:@"Move Back to Left Edge" action:@selector(resetPosition:) keyEquivalent:@""];
    reset.target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *classic = [menu addItemWithTitle:@"Switch to Classic Layout" action:@selector(switchToClassic:) keyEquivalent:@""];
    classic.target = self;
    [menu addItemWithTitle:@"Preferences…" action:@selector(showPrefs:) keyEquivalent:@""].target = [NSApp delegate];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit JRG" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    return menu;
}

- (IBAction)setGlassStyle:(id)sender {
    [[NSUserDefaults standardUserDefaults] setObject:@"glass" forKey:JRGDockStyleKey];
    [self applyStyle];
}

- (IBAction)setBareStyle:(id)sender {
    [[NSUserDefaults standardUserDefaults] setObject:@"bare" forKey:JRGDockStyleKey];
    [self applyStyle];
}

- (IBAction)toggleKeepOnTop:(id)sender {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:![d boolForKey:JRGDockKeepOnTopKey] forKey:JRGDockKeepOnTopKey];
    [self applyStyle];
}

- (IBAction)resetPosition:(id)sender {
    [[NSUserDefaults standardUserDefaults] setDouble:12 forKey:JRGDockOffsetXKey];
    [self positionStrip];
}

@end

#pragma mark - Detail view drawing

@implementation JRGDetailView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    XRGDockStripController *c = self.controller;
    JRGMetric m = self.metric;
    NSColor *c1 = JRGMetricColor(m, NO), *c2 = JRGMetricColor(m, YES);
    CGFloat pad = 14, w = self.bounds.size.width;

    NSDictionary *head = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: c1, NSKernAttributeName: @(0.6)};
    NSDictionary *meta = @{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.55]};
    [JRGMetricName(m) drawAtPoint:NSMakePoint(pad, 14) withAttributes:head];
    NSString *span = @"Last 5 minutes";
    CGFloat spanW = [span sizeWithAttributes:meta].width;
    [span drawAtPoint:NSMakePoint(w - pad - spanW, 14) withAttributes:meta];

    NSRect chart = NSMakeRect(pad, 38, w - 2 * pad, 70);
    [[NSColor colorWithWhite:1 alpha:0.06] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:chart xRadius:6 yRadius:6] fill];
    NSRect inner = NSInsetRect(chart, 4, 5);
    NSArray *v1 = JRGOrderedValues(c.history[m][0]);
    if (JRGMetricIsDual(m)) {
        NSArray *v2 = JRGOrderedValues(c.history[m][1]);
        CGFloat peak = MAX(10 * 1024, MAX(JRGPeak(c.history[m][0]), JRGPeak(c.history[m][1])));
        NSRect upper = NSMakeRect(inner.origin.x, inner.origin.y, inner.size.width, floor(inner.size.height / 2) - 0.5);
        NSRect lower = NSMakeRect(inner.origin.x, NSMaxY(upper) + 1, inner.size.width, upper.size.height);
        JRGDrawChart(v1, peak, upper, c1, NO, 1.5);
        JRGDrawChart(v2, peak, lower, c2, YES, 1.5);
    } else {
        JRGDrawChart(v1, (m == JRGMetricMemory) ? 1.0 : 100.0, inner, c1, NO, 1.5);
    }

    NSDictionary *lab = @{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.6]};
    NSDictionary *val = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor whiteColor]};
    CGFloat colW = (w - 2 * pad - 16) / 2;
    for (NSUInteger i = 0; i < self.stats.count; i++) {
        CGFloat x = pad + (i % 2) * (colW + 16);
        CGFloat y = NSMaxY(chart) + 10 + (i / 2) * 17;
        [self.stats[i][0] drawAtPoint:NSMakePoint(x, y) withAttributes:lab];
        NSString *v = self.stats[i][1];
        CGFloat vw = [v sizeWithAttributes:val].width;
        [v drawAtPoint:NSMakePoint(x + colW - vw, y) withAttributes:val];
    }
}

@end
