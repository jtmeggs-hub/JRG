//
//  XRGDockStrip.m
//  JRG
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import "XRGDockStrip.h"
#import "JRGSettings.h"
#import "JRGSettingsWindow.h"
#import "XRGAppDelegate.h"
#import "XRGCPUMiner.h"
#import "XRGGPUMiner.h"
#import "XRGMemoryMiner.h"
#import "XRGNetMiner.h"
#import "XRGTemperatureMiner.h"
#import "XRGDataSet.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOBlockStorageDriver.h>

static const NSInteger JRGMaxHistorySamples = 30 * 60;   // 30 minutes at one sample per second
static const NSTimeInterval JRGSampleInterval = 1.0;

static BOOL JRGMetricIsDual(JRGMetric m) {
    return m == JRGMetricNetwork || m == JRGMetricDisk;
}

/// Primary and secondary colors for a metric, from the current theme.
static NSColor *JRGMetricColor(JRGMetric m, BOOL secondary) {
    JRGSettings *s = [JRGSettings shared];
    switch (m) {
        case JRGMetricCPU:         return [s colorForSlot:JRGColorCPU];
        case JRGMetricGPU:         return [s colorForSlot:JRGColorGPU];
        case JRGMetricMemory:      return [s colorForSlot:JRGColorMemory];
        case JRGMetricNetwork:     return [s colorForSlot:secondary ? JRGColorNetUp : JRGColorNetDown];
        case JRGMetricDisk:        return [s colorForSlot:secondary ? JRGColorDiskWrite : JRGColorDiskRead];
        case JRGMetricTemperature: return [s colorForSlot:JRGColorTemperature];
        default:                   return [NSColor whiteColor];
    }
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

/// The most recent `count` values in chronological order (oldest first).
static NSArray<NSNumber *> *JRGRecentValues(XRGDataSet *set, NSInteger count) {
    size_t n = set.numValues;
    if (n == 0) return @[];
    CGFloat *buf = malloc(n * sizeof(CGFloat));
    [set valuesInOrder:buf];
    size_t start = (count > 0 && (size_t)count < n) ? n - count : 0;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n - start];
    for (size_t i = start; i < n; i++) [out addObject:@(MAX(0, buf[i]))];
    free(buf);
    return out;
}

static CGFloat JRGPeakOf(NSArray<NSNumber *> *values) {
    CGFloat peak = 0;
    for (NSNumber *v in values) peak = MAX(peak, v.doubleValue);
    return peak;
}

/// Chart range for single-series metrics.
static void JRGChartRange(JRGMetric m, CGFloat *lo, CGFloat *hi) {
    switch (m) {
        case JRGMetricMemory:      *lo = 0;  *hi = 1;   break;
        case JRGMetricTemperature: *lo = 20; *hi = 110; break;
        default:                   *lo = 0;  *hi = 100; break;
    }
}

#pragma mark - Chart drawing

/// Draws a history chart into `rect` (in a flipped view). Samples are bucketed to the
/// pixel width, keeping each bucket's maximum so short spikes stay visible.
static void JRGDrawChart(NSArray<NSNumber *> *values, CGFloat minValue, CGFloat maxValue, NSRect rect, NSColor *color, BOOL downward, CGFloat lineWidth) {
    if (values.count < 2 || rect.size.width < 2 || rect.size.height < 1) return;
    if (maxValue <= minValue) maxValue = minValue + 1;

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
        CGFloat frac = MIN(1, MAX(0, (v - minValue) / (maxValue - minValue)));
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
@property NSArray<NSNumber *> *metrics;         // metric shown in each section, left to right
@property NSArray<NSValue *> *sectionRects;     // one per section, in view coordinates
@property NSArray<NSNumber *> *blockWidths;     // width of the label/number block per section
@property CGFloat totalWidth;
@end

@implementation JRGStripLayout

+ (instancetype)layoutForHeight:(CGFloat)h {
    JRGSettings *settings = [JRGSettings shared];
    JRGStripLayout *L = [[JRGStripLayout alloc] init];
    L.height = h;
    L.padding = round(h * 0.26);
    L.gap = round(h * 0.13);
    L.sectionGap = round(h * 0.36);
    L.chartWidth = round(h * 0.95);
    L.chartHeight = round(h * 0.46);
    L.labelFont = [NSFont systemFontOfSize:MAX(9, round(h * 0.155)) weight:NSFontWeightSemibold];
    L.bigFont = [NSFont monospacedDigitSystemFontOfSize:round(h * 0.36) weight:NSFontWeightMedium];
    L.unitFont = [NSFont systemFontOfSize:round(h * 0.2) weight:NSFontWeightRegular];
    L.dualFont = [NSFont monospacedDigitSystemFontOfSize:round(h * 0.23) weight:NSFontWeightMedium];
    L.metrics = [settings enabledMetrics];

    NSDictionary *labelAttrs = @{NSFontAttributeName: L.labelFont, NSKernAttributeName: @(0.6)};
    NSDictionary *bigAttrs = @{NSFontAttributeName: L.bigFont};
    NSDictionary *unitAttrs = @{NSFontAttributeName: L.unitFont};
    NSDictionary *dualAttrs = @{NSFontAttributeName: L.dualFont};

    NSMutableArray *rects = [NSMutableArray array];
    NSMutableArray *blocks = [NSMutableArray array];
    CGFloat x = L.padding;
    for (NSUInteger i = 0; i < L.metrics.count; i++) {
        JRGMetric m = L.metrics[i].integerValue;
        CGFloat labelW = [JRGMetricName(m) sizeWithAttributes:labelAttrs].width;
        CGFloat numW;
        if (JRGMetricIsDual(m)) {
            NSString *tmpl = (m == JRGMetricNetwork && settings.networkInBits) ? @"↓ 999.9Mb" : @"↓ 999.9M";
            numW = [tmpl sizeWithAttributes:dualAttrs].width;
        } else {
            NSString *tmpl = (m == JRGMetricMemory) ? @"99.9" : @"100";
            NSString *unit = (m == JRGMetricMemory) ? @"G" : (m == JRGMetricTemperature) ? @"°C" : @"%";
            numW = [tmpl sizeWithAttributes:bigAttrs].width + [unit sizeWithAttributes:unitAttrs].width + 1;
        }
        CGFloat blockW = ceil(MAX(labelW, numW));
        CGFloat w = blockW + L.gap + L.chartWidth;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, h)]];
        [blocks addObject:@(blockW)];
        x += w + (i + 1 < L.metrics.count ? L.sectionGap : 0);
    }
    L.sectionRects = rects;
    L.blockWidths = blocks;
    L.totalWidth = ceil(x + L.padding);
    return L;
}

@end

#pragma mark - Strip view

@interface JRGStripView : NSView
@property (weak) XRGDockStripController *controller;
@property (nonatomic) JRGStripLayout *layout;
@property BOOL bare;
@property BOOL interactive;   // NO for the preview in Settings
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
@property NSHashTable<JRGStripView *> *previewViews;

@property XRGCPUMiner *cpuMiner;
@property XRGGPUMiner *gpuMiner;
@property XRGMemoryMiner *memoryMiner;
@property XRGNetMiner *netMiner;
@property UInt64 lastDiskRead, lastDiskWrite, diskReadSinceLaunch, diskWriteSinceLaunch;
@property NSDate *lastDiskSample;
@property BOOL seeded;

// History: index 0 is the primary series, index 1 the secondary (network up, disk write).
@property NSArray<NSArray<XRGDataSet *> *> *history;
@property CGFloat cpuNow, gpuNow, vramUsed, vramTotal, tempNow;
@property UInt64 memUsed, memTotal;
@property CGFloat netDown, netUp, diskRead, diskWrite;
@property NSArray<NSArray *> *hottestSensors;   // (label, °C) pairs, hottest first

- (NSMenu *)stripMenu;
- (void)hoverChangedTo:(NSInteger)metric;
- (NSArray<NSNumber *> *)valuesFor:(JRGMetric)m series:(NSInteger)series;
- (void)drawMetric:(JRGMetric)m inRect:(NSRect)rect blockWidth:(CGFloat)blockW layout:(JRGStripLayout *)L bare:(BOOL)bare;
@end

@implementation JRGStripView

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return self.interactive; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (NSSize)intrinsicContentSize {
    return self.layout ? NSMakeSize(self.layout.totalWidth, self.layout.height) : NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

- (void)setLayout:(JRGStripLayout *)layout {
    _layout = layout;
    [self invalidateIntrinsicContentSize];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    if (!self.interactive) return;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
}

/// The metric under the point, or -1.
- (NSInteger)metricAtPoint:(NSPoint)p {
    for (NSUInteger i = 0; i < self.layout.sectionRects.count; i++) {
        if (NSPointInRect(p, [self.layout.sectionRects[i] rectValue])) return self.layout.metrics[i].integerValue;
    }
    return -1;
}

- (NSRect)rectForMetric:(NSInteger)metric {
    NSUInteger i = [self.layout.metrics indexOfObject:@(metric)];
    return i == NSNotFound ? NSZeroRect : [self.layout.sectionRects[i] rectValue];
}

- (void)mouseMoved:(NSEvent *)event {
    [self.controller hoverChangedTo:[self metricAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]];
}

- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event  { [self.controller hoverChangedTo:-1]; }

- (NSMenu *)menuForEvent:(NSEvent *)event { return self.interactive ? [self.controller stripMenu] : nil; }

- (void)drawRect:(NSRect)dirtyRect {
    JRGStripLayout *L = self.layout;
    for (NSUInteger i = 0; i < L.metrics.count; i++) {
        [self.controller drawMetric:L.metrics[i].integerValue inRect:[L.sectionRects[i] rectValue]
                         blockWidth:[L.blockWidths[i] doubleValue] layout:L bare:self.bare];
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

- (instancetype)init {
    if (self = [super init]) {
        _pendingHoverMetric = -1;
        _previewViews = [NSHashTable weakObjectsHashTable];
        NSMutableArray *hist = [NSMutableArray array];
        for (JRGMetric m = 0; m < JRGMetricCount; m++) {
            XRGDataSet *a = [[XRGDataSet alloc] init]; [a resize:JRGMaxHistorySamples]; [a setAllValues:0];
            XRGDataSet *b = [[XRGDataSet alloc] init]; [b resize:JRGMaxHistorySamples]; [b setAllValues:0];
            [hist addObject:@[a, b]];
        }
        _history = hist;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:)
                                                     name:JRGSettingsDidChangeNotification object:nil];
    }
    return self;
}

- (NSInteger)visibleSamples {
    return [JRGSettings shared].historyMinutes * 60;
}

- (NSArray<NSNumber *> *)valuesFor:(JRGMetric)m series:(NSInteger)series {
    return JRGRecentValues(self.history[m][series], [self visibleSamples]);
}

#pragma mark Showing

- (void)showDockStrip {
    [self startSampling];
    [self buildWindowIfNeeded];
    [self applyStyle];
    [self positionStrip];
    [self.stripWindow orderFrontRegardless];
}

- (IBAction)showSettings:(id)sender {
    [[JRGSettingsWindowController shared] showWindow:sender];
}

- (void)settingsChanged:(NSNotification *)note {
    [self hoverChangedTo:-1];
    self.stripView.layout = nil;   // rebuilt by positionStrip for the new metrics/units/size
    [self applyStyle];
    [self positionStrip];
    for (JRGStripView *v in self.previewViews) {
        v.layout = [JRGStripLayout layoutForHeight:v.layout.height];
        v.bare = ![JRGSettings shared].glass;
        v.needsDisplay = YES;
    }
}

- (CGFloat)stripWidthForHeight:(CGFloat)height {
    return [JRGStripLayout layoutForHeight:height].totalWidth;
}

- (NSView *)makePreviewViewWithHeight:(CGFloat)height {
    [self startSampling];
    JRGStripView *v = [[JRGStripView alloc] initWithFrame:NSZeroRect];
    v.controller = self;
    v.interactive = NO;
    v.bare = ![JRGSettings shared].glass;
    v.layout = [JRGStripLayout layoutForHeight:height];
    [self.previewViews addObject:v];
    return v;
}

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
    v.interactive = YES;
    [container addSubview:v];

    self.stripWindow = w;
    self.stripView = v;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];
}

- (void)applyStyle {
    if (!self.stripWindow) return;
    JRGSettings *s = [JRGSettings shared];
    BOOL glass = s.glass;
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
    self.stripWindow.level = s.keepOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
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

    CGFloat h;
    switch ([JRGSettings shared].stripSize) {
        case JRGStripSizeCompact: h = MIN(60, MAX(40, round(band - 26))); break;
        case JRGStripSizeLarge:   h = MIN(100, MAX(50, round(band - 6))); break;
        default:                  h = MIN(84, MAX(46, round(band - 14))); break;
    }
    CGFloat w = (self.stripView.layout && self.stripView.layout.height == h) ? self.stripView.layout.totalWidth
                                                                              : [JRGStripLayout layoutForHeight:h].totalWidth;

    CGFloat offset = [JRGSettings shared].offsetX;
    CGFloat x = NSMinX(sf) + MIN(MAX(0, offset), sf.size.width - w);
    CGFloat y = NSMinY(sf) + round((band - h) / 2.0);
    return NSMakeRect(x, y, w, h);
}

- (void)positionStrip {
    if (!self.stripWindow) return;
    NSRect target = [self targetFrame];
    if (!self.stripView.layout || self.stripView.layout.height != target.size.height) {
        self.stripView.layout = [JRGStripLayout layoutForHeight:target.size.height];
        target.size.width = self.stripView.layout.totalWidth;
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
    // Only a drag with the mouse counts. macOS also moves windows itself (display sleep,
    // resolution or arrangement changes); saving those would lose the spot you picked.
    if (([NSEvent pressedMouseButtons] & 1) == 0) {
        [self positionStrip];
        return;
    }
    NSRect sf = [self dockScreen].frame;
    [JRGSettings shared].offsetX = NSMinX(self.stripWindow.frame) - NSMinX(sf);
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

/// Reads the temperature sensors (the miner itself refreshes every 5 calls) and keeps the hottest.
- (void)sampleTemperature {
    XRGTemperatureMiner *tm = [XRGTemperatureMiner shared];
    [tm updateCurrentTemperatures:NO];
    NSMutableArray *readings = [NSMutableArray array];
    for (NSString *key in [tm locationKeysIncludingUnknown:NO]) {
        XRGSensorData *sensor = [tm sensorForLocation:key];
        if (!sensor || !sensor.isEnabled || [tm isFanSensor:sensor] || ![sensor.units hasSuffix:@"C"]) continue;
        if (sensor.currentValue <= 0 || sensor.currentValue > 150) continue;
        [readings addObject:@[[sensor label] ?: key, @(sensor.currentValue)]];
    }
    [readings sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[1] compare:a[1]]; }];
    if (readings.count) {
        self.hottestSensors = readings;
        self.tempNow = [readings[0][1] doubleValue];
    }
}

- (void)sample:(NSTimer *)timer {
    JRGSettings *settings = [JRGSettings shared];

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

    // Temperature only costs anything while it's shown.
    if ([settings isMetricEnabled:JRGMetricTemperature]) [self sampleTemperature];

    CGFloat memFrac = self.memTotal ? (CGFloat)self.memUsed / self.memTotal : 0;

    // On the first sample, fill the history with it so charts start as a flat line
    // at the current level instead of climbing up from zero.
    if (!self.seeded) {
        self.seeded = YES;
        [self.history[JRGMetricCPU][0] setAllValues:self.cpuNow];
        [self.history[JRGMetricGPU][0] setAllValues:self.gpuNow];
        [self.history[JRGMetricMemory][0] setAllValues:memFrac];
    }
    if (self.tempNow > 0 && [self.history[JRGMetricTemperature][0] max] <= 0) {
        [self.history[JRGMetricTemperature][0] setAllValues:self.tempNow];
    }

    [self.history[JRGMetricCPU][0] setNextValue:self.cpuNow];
    [self.history[JRGMetricGPU][0] setNextValue:self.gpuNow];
    [self.history[JRGMetricMemory][0] setNextValue:memFrac];
    [self.history[JRGMetricNetwork][0] setNextValue:self.netDown];
    [self.history[JRGMetricNetwork][1] setNextValue:self.netUp];
    [self.history[JRGMetricDisk][0] setNextValue:self.diskRead];
    [self.history[JRGMetricDisk][1] setNextValue:self.diskWrite];
    [self.history[JRGMetricTemperature][0] setNextValue:self.tempNow];

    [self positionStrip];   // follows Dock size and display changes
    self.stripView.needsDisplay = YES;
    for (JRGStripView *v in self.previewViews) v.needsDisplay = YES;
    if (self.detailWindow.isVisible) [self refreshDetail];
}

#pragma mark Drawing a metric

- (void)drawMetric:(JRGMetric)m inRect:(NSRect)rect blockWidth:(CGFloat)blockW layout:(JRGStripLayout *)L bare:(BOOL)bare {
    JRGSettings *settings = [JRGSettings shared];
    CGFloat h = L.height;
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
        BOOL net = (m == JRGMetricNetwork);
        CGFloat a = net ? self.netDown : self.diskRead;
        CGFloat b = net ? self.netUp : self.diskWrite;
        CGFloat lineH = ceil(L.dualFont.ascender - L.dualFont.descender);
        NSArray *rows = @[@[net ? @"↓" : @"R", @(a), c1], @[net ? @"↑" : @"W", @(b), c2]];
        for (NSArray *row in rows) {
            NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
            NSMutableDictionary *glyphAttrs = [dualAttrs mutableCopy];
            glyphAttrs[NSForegroundColorAttributeName] = row[2];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:[row[0] stringByAppendingString:@" "] attributes:glyphAttrs]];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:[settings rateString:[row[1] doubleValue] network:net] attributes:dualAttrs]];
            [s drawAtPoint:NSMakePoint(NSMinX(rect), y)];
            y += lineH;
        }
    } else {
        NSString *num, *unit;
        if (m == JRGMetricMemory) { [settings formatBytes:self.memUsed number:&num unit:&unit]; }
        else if (m == JRGMetricTemperature) { num = self.tempNow > 0 ? [NSString stringWithFormat:@"%.0f", self.tempNow] : @"–"; unit = @"°C"; }
        else { num = [NSString stringWithFormat:@"%.0f", (m == JRGMetricCPU) ? self.cpuNow : self.gpuNow]; unit = @"%"; }
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:num attributes:bigAttrs];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:unit attributes:unitAttrs]];
        [s drawAtPoint:NSMakePoint(NSMinX(rect), y - round(L.bigFont.pointSize * 0.06))];
    }

    // History chart beside the numbers.
    NSRect chart = NSMakeRect(NSMinX(rect) + blockW + L.gap, round((h - L.chartHeight) / 2.0), L.chartWidth, L.chartHeight);
    CGFloat lw = bare ? 1.8 : 1.5;
    NSArray *v1 = [self valuesFor:m series:0];
    if (JRGMetricIsDual(m)) {
        NSArray *v2 = [self valuesFor:m series:1];
        CGFloat peak = MAX(10 * 1024, MAX(JRGPeakOf(v1), JRGPeakOf(v2)));
        NSRect upper = NSMakeRect(chart.origin.x, chart.origin.y, chart.size.width, floor(chart.size.height / 2) - 0.5);
        NSRect lower = NSMakeRect(chart.origin.x, NSMaxY(upper) + 1, chart.size.width, upper.size.height);
        JRGDrawChart(v1, 0, peak, upper, c1, NO, lw);
        JRGDrawChart(v2, 0, peak, lower, c2, YES, lw);
        [[NSColor colorWithWhite:1 alpha:0.22] setFill];
        NSRectFillUsingOperation(NSMakeRect(chart.origin.x, NSMaxY(upper), chart.size.width, 0.5), NSCompositingOperationSourceOver);
    } else {
        CGFloat lo, hi; JRGChartRange(m, &lo, &hi);
        JRGDrawChart(v1, lo, hi, chart, c1, NO, lw);
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

    NSRect section = [self.stripView rectForMetric:metric];
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
static NSString *JRGDegrees(CGFloat v) { return [NSString stringWithFormat:@"%.0f°C", v]; }

- (void)refreshDetail {
    JRGSettings *s = [JRGSettings shared];
    JRGDetailView *dv = (JRGDetailView *)self.detailView;
    JRGMetric m = dv.metric;
    NSString *peakLabel = [NSString stringWithFormat:@"%ld-min peak", (long)s.historyMinutes];
    NSArray *v1 = [self valuesFor:m series:0], *v2 = [self valuesFor:m series:1];
    NSString *(^rate)(double, BOOL) = ^NSString *(double v, BOOL net) { return [[s rateString:v network:net] stringByAppendingString:@"/s"]; };
    NSMutableArray *stats = [NSMutableArray array];
    switch (m) {
        case JRGMetricCPU: {
            [stats addObject:@[@"Usage", JRGPercent(self.cpuNow)]];
            [stats addObject:@[peakLabel, JRGPercent(JRGPeakOf(v1))]];
            [stats addObject:@[@"Load avg", [NSString stringWithFormat:@"%.2f", self.cpuMiner.currentLoadAverage]]];
            [stats addObject:@[@"Cores", [NSString stringWithFormat:@"%ld", (long)self.cpuMiner.numberOfCPUs]]];
            [stats addObject:@[@"Uptime", [NSString stringWithFormat:@"%ldd %ldh %ldm", (long)self.cpuMiner.uptimeDays, (long)self.cpuMiner.uptimeHours, (long)self.cpuMiner.uptimeMinutes]]];
            break;
        }
        case JRGMetricGPU: {
            [stats addObject:@[@"Usage", JRGPercent(self.gpuNow)]];
            [stats addObject:@[peakLabel, JRGPercent(JRGPeakOf(v1))]];
            [stats addObject:@[@"GPU memory", [s bytesString:self.vramUsed]]];
            [stats addObject:@[@"Available", [s bytesString:self.vramTotal]]];
            break;
        }
        case JRGMetricMemory: {
            [stats addObject:@[@"Used", [s bytesString:self.memUsed]]];
            [stats addObject:@[@"Installed", [s bytesString:self.memTotal]]];
            [stats addObject:@[@"Active", [s bytesString:self.memoryMiner.activeBytes]]];
            [stats addObject:@[@"Wired", [s bytesString:self.memoryMiner.wiredBytes]]];
            [stats addObject:@[@"Inactive", [s bytesString:self.memoryMiner.inactiveBytes]]];
            [stats addObject:@[@"Free", [s bytesString:self.memoryMiner.freeBytes]]];
            [stats addObject:@[@"Swap", [s bytesString:self.memoryMiner.usedSwap]]];
            break;
        }
        case JRGMetricNetwork: {
            [stats addObject:@[@"Down", rate(self.netDown, YES)]];
            [stats addObject:@[@"Up", rate(self.netUp, YES)]];
            [stats addObject:@[@"Peak down", rate(JRGPeakOf(v1), YES)]];
            [stats addObject:@[@"Peak up", rate(JRGPeakOf(v2), YES)]];
            [stats addObject:@[@"Since boot", [s bytesString:self.netMiner.totalBytesSinceBoot]]];
            break;
        }
        case JRGMetricDisk: {
            [stats addObject:@[@"Read", rate(self.diskRead, NO)]];
            [stats addObject:@[@"Write", rate(self.diskWrite, NO)]];
            [stats addObject:@[@"Peak read", rate(JRGPeakOf(v1), NO)]];
            [stats addObject:@[@"Peak write", rate(JRGPeakOf(v2), NO)]];
            [stats addObject:@[@"Read total", [s bytesString:self.diskReadSinceLaunch]]];
            [stats addObject:@[@"Write total", [s bytesString:self.diskWriteSinceLaunch]]];
            break;
        }
        case JRGMetricTemperature: {
            [stats addObject:@[@"Hottest", self.tempNow > 0 ? JRGDegrees(self.tempNow) : @"–"]];
            [stats addObject:@[peakLabel, JRGDegrees(JRGPeakOf(v1))]];
            NSUInteger shown = 0;
            for (NSArray *reading in self.hottestSensors) {
                if (shown++ >= 6) break;
                NSString *label = reading[0];
                if (label.length > 14) label = [[label substringToIndex:13] stringByAppendingString:@"…"];
                [stats addObject:@[label, JRGDegrees([reading[1] doubleValue])]];
            }
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
    JRGSettings *s = [JRGSettings shared];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"JRG"];

    NSMenuItem *glassItem = [menu addItemWithTitle:@"Glass" action:@selector(setGlassStyle:) keyEquivalent:@""];
    glassItem.target = self; glassItem.state = s.glass ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *bareItem = [menu addItemWithTitle:@"Bare" action:@selector(setBareStyle:) keyEquivalent:@""];
    bareItem.target = self; bareItem.state = s.glass ? NSControlStateValueOff : NSControlStateValueOn;
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *top = [menu addItemWithTitle:@"Keep on Top" action:@selector(toggleKeepOnTop:) keyEquivalent:@""];
    top.target = self;
    top.state = s.keepOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItemWithTitle:@"Move Back to Left Edge" action:@selector(resetPosition:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@""].target = self;
    if ([(XRGAppDelegate *)NSApp.delegate updaterController]) {
        [menu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""].target = NSApp.delegate;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit JRG" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    return menu;
}

- (IBAction)setGlassStyle:(id)sender  { [JRGSettings shared].glass = YES; }
- (IBAction)setBareStyle:(id)sender   { [JRGSettings shared].glass = NO; }
- (IBAction)toggleKeepOnTop:(id)sender { [JRGSettings shared].keepOnTop = ![JRGSettings shared].keepOnTop; }

- (IBAction)resetPosition:(id)sender {
    [JRGSettings shared].offsetX = 12;
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
    NSString *title = (m == JRGMetricTemperature) ? @"TEMPERATURE" : JRGMetricName(m);
    [title drawAtPoint:NSMakePoint(pad, 14) withAttributes:head];
    NSInteger minutes = [JRGSettings shared].historyMinutes;
    NSString *span = minutes == 1 ? @"Last minute" : [NSString stringWithFormat:@"Last %ld minutes", (long)minutes];
    CGFloat spanW = [span sizeWithAttributes:meta].width;
    [span drawAtPoint:NSMakePoint(w - pad - spanW, 14) withAttributes:meta];

    NSRect chart = NSMakeRect(pad, 38, w - 2 * pad, 70);
    [[NSColor colorWithWhite:1 alpha:0.06] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:chart xRadius:6 yRadius:6] fill];
    NSRect inner = NSInsetRect(chart, 4, 5);
    NSArray *v1 = [c valuesFor:m series:0];
    if (JRGMetricIsDual(m)) {
        NSArray *v2 = [c valuesFor:m series:1];
        CGFloat peak = MAX(10 * 1024, MAX(JRGPeakOf(v1), JRGPeakOf(v2)));
        NSRect upper = NSMakeRect(inner.origin.x, inner.origin.y, inner.size.width, floor(inner.size.height / 2) - 0.5);
        NSRect lower = NSMakeRect(inner.origin.x, NSMaxY(upper) + 1, inner.size.width, upper.size.height);
        JRGDrawChart(v1, 0, peak, upper, c1, NO, 1.5);
        JRGDrawChart(v2, 0, peak, lower, c2, YES, 1.5);
    } else {
        CGFloat lo, hi; JRGChartRange(m, &lo, &hi);
        JRGDrawChart(v1, lo, hi, inner, c1, NO, 1.5);
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
