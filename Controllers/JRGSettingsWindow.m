//
//  JRGSettingsWindow.m
//  JRG
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import "JRGSettingsWindow.h"
#import "JRGSettings.h"
#import "XRGDockStrip.h"
#import <ServiceManagement/ServiceManagement.h>
#import <Sparkle/Sparkle.h>
#import "XRGAppDelegate.h"

static const CGFloat JRGSettingsWidth = 600;
static const CGFloat JRGSettingsPad = 22;
static const CGFloat JRGPreviewHeight = 48;

static NSColor *JRGMutedText(void)  { return [NSColor colorWithSRGBRed:0.56 green:0.60 blue:0.78 alpha:1]; }
static NSColor *JRGSoftText(void)   { return [NSColor colorWithSRGBRed:0.80 green:0.83 blue:0.95 alpha:1]; }

#pragma mark - Theme swatch

/// One clickable theme tile: color stripes with the theme name underneath.
@interface JRGThemeSwatch : NSView
@property (copy) NSString *themeName;
@property (copy) NSArray<NSColor *> *colors;   // nil draws an empty "Custom" placeholder
@property (nonatomic) BOOL selected;
@property (copy) void (^onClick)(JRGThemeSwatch *swatch);
@end

@implementation JRGThemeSwatch

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)setSelected:(BOOL)selected { _selected = selected; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event { if (self.onClick) self.onClick(self); }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]]; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    NSRect tile = NSInsetRect(b, 1.5, 1.5);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:9 yRadius:9];
    [[NSColor colorWithWhite:1 alpha:self.selected ? 0.10 : 0.04] setFill];
    [outline fill];
    [[NSColor colorWithWhite:1 alpha:self.selected ? 0.95 : 0.12] setStroke];
    outline.lineWidth = self.selected ? 1.5 : 1;
    [outline stroke];

    NSRect stripe = NSMakeRect(NSMinX(tile) + 7, NSMinY(tile) + 7, tile.size.width - 14, 20);
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:stripe xRadius:4 yRadius:4];
    if (self.colors.count) {
        [NSGraphicsContext saveGraphicsState];
        [clip addClip];
        NSArray *slots = @[@(JRGColorCPU), @(JRGColorGPU), @(JRGColorMemory), @(JRGColorNetDown), @(JRGColorNetUp), @(JRGColorTemperature)];
        CGFloat w = stripe.size.width / slots.count;
        for (NSUInteger i = 0; i < slots.count; i++) {
            NSInteger slot = [slots[i] integerValue];
            [(slot < (NSInteger)self.colors.count ? self.colors[slot] : [NSColor grayColor]) setFill];
            NSRectFill(NSMakeRect(NSMinX(stripe) + i * w, NSMinY(stripe), ceil(w), stripe.size.height));
        }
        [NSGraphicsContext restoreGraphicsState];
    } else {
        CGFloat dash[] = {3, 3};
        [clip setLineDash:dash count:2 phase:0];
        [[NSColor colorWithWhite:1 alpha:0.3] setStroke];
        [clip stroke];
    }

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:self.selected ? NSFontWeightSemibold : NSFontWeightRegular],
                            NSForegroundColorAttributeName: self.selected ? [NSColor whiteColor] : JRGSoftText(),
                            NSParagraphStyleAttributeName: ps};
    NSString *title = [self.themeName isEqualToString:@"Midnight neon"] ? @"Midnight" : self.themeName;
    [title drawInRect:NSMakeRect(NSMinX(tile) + 2, NSMaxY(stripe) + 5, tile.size.width - 4, 15) withAttributes:attrs];
}

@end

#pragma mark - Window controller

@interface JRGSettingsWindowController () <NSWindowDelegate>
@property NSView *previewBox;
@property NSView *preview;
@property NSArray<JRGThemeSwatch *> *swatches;
@property NSArray<NSColorWell *> *colorWells;
@property NSSegmentedControl *styleControl, *historyControl, *sizeControl, *unitsControl, *bitsControl;
@property NSArray<NSButton *> *metricBoxes;
@property NSSwitch *keepOnTopSwitch, *loginSwitch, *autoUpdateSwitch, *dockSwitch;
@property NSTextField *loginNote;
@end

@implementation JRGSettingsWindowController

+ (instancetype)shared {
    static JRGSettingsWindowController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[JRGSettingsWindowController alloc] init]; });
    return shared;
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, JRGSettingsWidth, 600)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:YES];
    if (self = [super initWithWindow:w]) {
        NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"JRG";
        w.title = [name stringByAppendingString:@" Settings"];
        w.titlebarAppearsTransparent = YES;
        w.movableByWindowBackground = YES;
        w.releasedWhenClosed = NO;
        w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        w.delegate = self;
        [self buildContent];
        [w center];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:)
                                                     name:JRGSettingsDidChangeNotification object:nil];
    }
    return self;
}

- (void)showWindow:(id)sender {
    [self refreshControls];
    [self rebuildPreview];
    [super showWindow:sender];
    [self.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)windowWillClose:(NSNotification *)note {
    [[NSColorPanel sharedColorPanel] orderOut:nil];
    for (NSColorWell *well in self.colorWells) [well deactivate];
}

#pragma mark Building the window

- (NSTextField *)label:(NSString *)text size:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight {
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = [NSFont systemFontOfSize:size weight:weight];
    t.textColor = color;
    return t;
}

- (NSView *)sectionHeader:(NSString *)title {
    NSTextField *t = [self label:title.uppercaseString size:10.5 color:JRGMutedText() weight:NSFontWeightSemibold];
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:t.stringValue attributes:@{NSFontAttributeName: t.font, NSForegroundColorAttributeName: t.textColor, NSKernAttributeName: @(0.8)}];
    t.attributedStringValue = a;
    return t;
}

/// A settings row: label on the left, control on the right.
- (NSView *)row:(NSString *)title control:(NSView *)control {
    NSTextField *label = [self label:title size:13 color:[NSColor whiteColor] weight:NSFontWeightRegular];
    NSStackView *row = [NSStackView stackViewWithViews:@[label, control]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.distribution = NSStackViewDistributionEqualSpacing;
    row.alignment = NSLayoutAttributeCenterY;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:26].active = YES;
    return row;
}

- (NSView *)divider {
    NSBox *b = [[NSBox alloc] init];
    b.boxType = NSBoxCustom;
    b.borderWidth = 0;
    b.fillColor = [NSColor colorWithWhite:1 alpha:0.10];
    [b.heightAnchor constraintEqualToConstant:1].active = YES;
    return b;
}

- (NSSegmentedControl *)segments:(NSArray<NSString *> *)labels action:(SEL)action {
    NSSegmentedControl *s = [NSSegmentedControl segmentedControlWithLabels:labels trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:action];
    s.segmentStyle = NSSegmentStyleRounded;
    return s;
}

- (NSSwitch *)switchWithAction:(SEL)action {
    NSSwitch *s = [[NSSwitch alloc] init];
    s.target = self;
    s.action = action;
    s.controlSize = NSControlSizeSmall;
    return s;
}

- (void)buildContent {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, JRGSettingsWidth, 600)];

    // Background: frosted HUD material with a midnight tint.
    NSVisualEffectView *frost = [[NSVisualEffectView alloc] initWithFrame:root.bounds];
    frost.material = NSVisualEffectMaterialHUDWindow;
    frost.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    frost.state = NSVisualEffectStateActive;
    frost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:frost];
    NSBox *tint = [[NSBox alloc] initWithFrame:root.bounds];
    tint.boxType = NSBoxCustom;
    tint.borderWidth = 0;
    tint.fillColor = [NSColor colorWithSRGBRed:0.043 green:0.063 blue:0.15 alpha:0.62];
    tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:tint];

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor constant:40],
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:JRGSettingsPad],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-JRGSettingsPad],
        [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],
        [root.widthAnchor constraintEqualToConstant:JRGSettingsWidth],
    ]];
    CGFloat inner = JRGSettingsWidth - 2 * JRGSettingsPad;
    NSMutableArray<NSView *> *fullWidth = [NSMutableArray array];
    void (^add)(NSView *, CGFloat) = ^(NSView *v, CGFloat after) {
        [stack addArrangedSubview:v];
        [fullWidth addObject:v];
        if (after > 0) [stack setCustomSpacing:after afterView:v];
    };

    // Live preview of the strip.
    NSBox *box = [[NSBox alloc] init];
    box.boxType = NSBoxCustom;
    box.cornerRadius = 14;
    box.borderWidth = 1;
    box.borderColor = [NSColor colorWithWhite:1 alpha:0.14];
    box.fillColor = [NSColor colorWithWhite:1 alpha:0.06];
    box.contentViewMargins = NSZeroSize;
    [box.heightAnchor constraintEqualToConstant:JRGPreviewHeight + 22].active = YES;
    self.previewBox = box.contentView;
    add(box, 18);

    // Theme
    add([self sectionHeader:@"Theme"], 8);
    NSMutableArray *swatchViews = [NSMutableArray array];
    NSMutableArray *names = [[JRGSettings presetThemeNames] mutableCopy];
    [names addObject:JRGCustomThemeName];
    for (NSString *name in names) {
        JRGThemeSwatch *sw = [[JRGThemeSwatch alloc] init];
        sw.themeName = name;
        sw.colors = [name isEqualToString:JRGCustomThemeName] ? nil : [JRGSettings colorsForPreset:name];
        __weak typeof(self) weakSelf = self;
        sw.onClick = ^(JRGThemeSwatch *s) { [weakSelf pickTheme:s]; };
        [sw.heightAnchor constraintEqualToConstant:52].active = YES;
        [swatchViews addObject:sw];
    }
    self.swatches = swatchViews;
    NSStackView *swatchRow = [NSStackView stackViewWithViews:swatchViews];
    swatchRow.distribution = NSStackViewDistributionFillEqually;
    swatchRow.spacing = 7;
    add(swatchRow, 12);

    NSMutableArray *wells = [NSMutableArray array];
    NSMutableArray *wellColumns = [NSMutableArray array];
    for (JRGColorSlot slot = 0; slot < JRGColorSlotCount; slot++) {
        NSColorWell *well = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
        well.tag = slot;
        well.target = self;
        well.action = @selector(colorChanged:);
        [well.widthAnchor constraintEqualToConstant:44].active = YES;
        [well.heightAnchor constraintEqualToConstant:24].active = YES;
        [wells addObject:well];
        NSTextField *l = [self label:JRGColorSlotName(slot) size:10.5 color:JRGSoftText() weight:NSFontWeightRegular];
        NSStackView *col = [NSStackView stackViewWithViews:@[well, l]];
        col.orientation = NSUserInterfaceLayoutOrientationVertical;
        col.spacing = 4;
        [wellColumns addObject:col];
    }
    self.colorWells = wells;
    NSStackView *wellRow = [NSStackView stackViewWithViews:wellColumns];
    wellRow.distribution = NSStackViewDistributionEqualCentering;
    add(wellRow, 4);
    NSTextField *hint = [self label:@"Change any color to make your own Custom theme." size:11 color:JRGMutedText() weight:NSFontWeightRegular];
    [stack addArrangedSubview:hint];
    [stack setCustomSpacing:14 afterView:hint];
    add([self divider], 14);

    // Strip
    add([self sectionHeader:@"Strip"], 6);
    self.styleControl = [self segments:@[@"Glass", @"Bare"] action:@selector(styleChanged:)];
    add([self row:@"Style" control:self.styleControl], 0);

    NSMutableArray *boxes = [NSMutableArray array];
    for (JRGMetric m = 0; m < JRGMetricCount; m++) {
        NSString *title = (m == JRGMetricTemperature) ? @"Temp" : (m == JRGMetricMemory) ? @"Memory" : (m == JRGMetricNetwork) ? @"Network" : (m == JRGMetricDisk) ? @"Disk" : JRGMetricName(m);
        NSButton *b = [NSButton checkboxWithTitle:title target:self action:@selector(metricToggled:)];
        b.tag = m;
        [boxes addObject:b];
    }
    self.metricBoxes = boxes;
    NSStackView *boxRow = [NSStackView stackViewWithViews:boxes];
    boxRow.spacing = 12;
    add([self row:@"Metrics" control:boxRow], 0);

    self.historyControl = [self segments:@[@"1 min", @"5 min", @"15 min", @"30 min"] action:@selector(historyChanged:)];
    add([self row:@"History" control:self.historyControl], 0);
    self.sizeControl = [self segments:@[@"Auto", @"Compact", @"Large"] action:@selector(sizeChanged:)];
    add([self row:@"Size" control:self.sizeControl], 0);
    self.keepOnTopSwitch = [self switchWithAction:@selector(keepOnTopChanged:)];
    add([self row:@"Keep on top" control:self.keepOnTopSwitch], 0);
    NSButton *reset = [NSButton buttonWithTitle:@"Reset to Dock edge" target:[XRGDockStripController shared] action:@selector(resetPosition:)];
    reset.controlSize = NSControlSizeSmall;
    add([self row:@"Position (drag the strip to move it)" control:reset], 14);
    add([self divider], 14);

    // Display
    add([self sectionHeader:@"Display"], 6);
    self.unitsControl = [self segments:@[@"1000 (matches macOS)", @"1024"] action:@selector(unitsChanged:)];
    add([self row:@"Units" control:self.unitsControl], 0);
    self.bitsControl = [self segments:@[@"Bytes", @"Bits"] action:@selector(bitsChanged:)];
    add([self row:@"Network speed" control:self.bitsControl], 14);
    add([self divider], 14);

    // General
    add([self sectionHeader:@"General"], 6);
    self.dockSwitch = [self switchWithAction:@selector(dockChanged:)];
    add([self row:@"Show in Dock and menu bar" control:self.dockSwitch], 0);
    self.loginSwitch = [self switchWithAction:@selector(loginChanged:)];
    add([self row:@"Launch at login" control:self.loginSwitch], 0);
    self.loginNote = [self label:@"" size:11 color:JRGMutedText() weight:NSFontWeightRegular];
    self.loginNote.hidden = YES;
    [stack addArrangedSubview:self.loginNote];
    [stack setCustomSpacing:16 afterView:self.loginNote];

    SPUUpdater *updater = [self updater];
    self.autoUpdateSwitch = [self switchWithAction:@selector(autoUpdateChanged:)];
    self.autoUpdateSwitch.enabled = (updater != nil);
    add([self row:@"Check for updates automatically" control:self.autoUpdateSwitch], 0);

    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    NSString *versionText = updater ? [NSString stringWithFormat:@"JRG %@ (%@)", version, build]
                                    : [NSString stringWithFormat:@"JRG %@ (development build, updates are off)", version];
    NSButton *checkNow = [NSButton buttonWithTitle:@"Check now" target:NSApp.delegate action:@selector(checkForUpdates:)];
    checkNow.controlSize = NSControlSizeSmall;
    checkNow.enabled = (updater != nil);
    NSView *versionRow = [self row:versionText control:checkNow];
    ((NSTextField *)versionRow.subviews.firstObject).textColor = JRGSoftText();
    add(versionRow, 16);

    NSTextField *credit = [self label:@"Based on XRG by Gaucho Software (Mike Piatek-Jimenez)  ·  Free software under the GNU GPL v2"
                                 size:11 color:JRGMutedText() weight:NSFontWeightRegular];
    [stack addArrangedSubview:credit];

    for (NSView *v in fullWidth) [v.widthAnchor constraintEqualToConstant:inner].active = YES;

    self.window.contentView = root;
    [root layoutSubtreeIfNeeded];
    [self.window setContentSize:root.fittingSize];
}

#pragma mark Preview

/// Recreates the preview, shrinking it if the current metrics would overflow the box.
- (void)rebuildPreview {
    [self.preview removeFromSuperview];
    XRGDockStripController *strip = [XRGDockStripController shared];
    CGFloat maxW = JRGSettingsWidth - 2 * JRGSettingsPad - 24;
    CGFloat h = JRGPreviewHeight;
    CGFloat w = [strip stripWidthForHeight:h];
    if (w > maxW) h = floor(h * maxW / w);
    NSView *p = [strip makePreviewViewWithHeight:h];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [self.previewBox addSubview:p];
    [NSLayoutConstraint activateConstraints:@[
        [p.centerXAnchor constraintEqualToAnchor:self.previewBox.centerXAnchor],
        [p.centerYAnchor constraintEqualToAnchor:self.previewBox.centerYAnchor],
    ]];
    self.preview = p;
}

#pragma mark Syncing controls

- (void)settingsChanged:(NSNotification *)note {
    if (!self.window.isVisible) return;
    [self refreshControls];
    [self rebuildPreview];
}

- (void)refreshControls {
    JRGSettings *s = [JRGSettings shared];
    NSString *theme = s.themeName;
    for (JRGThemeSwatch *sw in self.swatches) {
        if ([sw.themeName isEqualToString:JRGCustomThemeName]) {
            sw.colors = [s savedCustomColors];
        }
        sw.selected = [sw.themeName isEqualToString:theme];
    }
    for (NSColorWell *well in self.colorWells) {
        if (!well.isActive) well.color = [s colorForSlot:well.tag];
    }
    self.styleControl.selectedSegment = s.glass ? 0 : 1;
    for (NSButton *b in self.metricBoxes) b.state = [s isMetricEnabled:b.tag] ? NSControlStateValueOn : NSControlStateValueOff;
    NSArray *minutes = @[@1, @5, @15, @30];
    self.historyControl.selectedSegment = MAX(0, (NSInteger)[minutes indexOfObject:@(s.historyMinutes)]);
    self.sizeControl.selectedSegment = s.stripSize;
    self.dockSwitch.state = s.showInDock ? NSControlStateValueOn : NSControlStateValueOff;
    self.keepOnTopSwitch.state = s.keepOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    self.unitsControl.selectedSegment = s.decimalUnits ? 0 : 1;
    self.bitsControl.selectedSegment = s.networkInBits ? 1 : 0;
    self.autoUpdateSwitch.state = [self updater].automaticallyChecksForUpdates ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshLoginState];
}

#pragma mark Actions

- (void)pickTheme:(JRGThemeSwatch *)swatch {
    if ([swatch.themeName isEqualToString:JRGCustomThemeName] && !swatch.colors) {
        NSBeep();   // nothing custom saved yet: change a color below to create one
        return;
    }
    [JRGSettings shared].themeName = swatch.themeName;
}

- (void)colorChanged:(NSColorWell *)well {
    [[JRGSettings shared] setColor:well.color forSlot:well.tag];
}

- (void)styleChanged:(NSSegmentedControl *)c   { [JRGSettings shared].glass = (c.selectedSegment == 0); }
- (void)historyChanged:(NSSegmentedControl *)c { [JRGSettings shared].historyMinutes = [@[@1, @5, @15, @30][c.selectedSegment] integerValue]; }
- (void)sizeChanged:(NSSegmentedControl *)c    { [JRGSettings shared].stripSize = c.selectedSegment; }
- (void)dockChanged:(NSSwitch *)s {
    [JRGSettings shared].showInDock = (s.state == NSControlStateValueOn);
    // Switching to a background app deactivates JRG; keep Settings in front.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    });
}

- (void)keepOnTopChanged:(NSSwitch *)s         { [JRGSettings shared].keepOnTop = (s.state == NSControlStateValueOn); }
- (void)unitsChanged:(NSSegmentedControl *)c   { [JRGSettings shared].decimalUnits = (c.selectedSegment == 0); }
- (void)bitsChanged:(NSSegmentedControl *)c    { [JRGSettings shared].networkInBits = (c.selectedSegment == 1); }

- (void)metricToggled:(NSButton *)b {
    JRGSettings *s = [JRGSettings shared];
    BOOL on = (b.state == NSControlStateValueOn);
    if (!on && s.enabledMetrics.count <= 1) {   // keep at least one metric on
        b.state = NSControlStateValueOn;
        NSBeep();
        return;
    }
    [s setMetric:b.tag enabled:on];
}

#pragma mark Updates

- (SPUUpdater *)updater {
    return [(XRGAppDelegate *)NSApp.delegate updaterController].updater;
}

- (void)autoUpdateChanged:(NSSwitch *)sw {
    [self updater].automaticallyChecksForUpdates = (sw.state == NSControlStateValueOn);
}

#pragma mark Launch at login

- (void)refreshLoginState {
    SMAppService *service = [SMAppService mainAppService];
    switch (service.status) {
        case SMAppServiceStatusEnabled:
            self.loginSwitch.state = NSControlStateValueOn;
            self.loginNote.stringValue = @"";
            break;
        case SMAppServiceStatusRequiresApproval:
            self.loginSwitch.state = NSControlStateValueOn;
            self.loginNote.stringValue = @"Waiting for approval in System Settings › General › Login Items.";
            break;
        default:
            self.loginSwitch.state = NSControlStateValueOff;
            self.loginNote.stringValue = @"";
            break;
    }
    self.loginNote.hidden = (self.loginNote.stringValue.length == 0);
    [self fitWindow];
}

- (void)fitWindow {
    NSView *root = self.window.contentView;
    [root layoutSubtreeIfNeeded];
    NSSize fit = root.fittingSize;
    NSRect f = self.window.frame;
    CGFloat dh = fit.height - root.frame.size.height;
    if (fabs(dh) < 0.5) return;
    f.size.height += dh;
    f.origin.y -= dh;   // keep the top edge in place
    [self.window setFrame:f display:YES];
}

- (void)loginChanged:(NSSwitch *)sw {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;
    BOOL ok = (sw.state == NSControlStateValueOn) ? [service registerAndReturnError:&error]
                                                  : [service unregisterAndReturnError:&error];
    [self refreshLoginState];
    if (!ok && error) {
        self.loginNote.stringValue = [NSString stringWithFormat:@"Couldn't change the login item: %@", error.localizedDescription];
        self.loginNote.hidden = NO;
    }
    if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
}

@end
