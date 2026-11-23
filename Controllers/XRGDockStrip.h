//
//  XRGDockStrip.h
//  JRG
//
//  A minimal, Dock-height layout: one row of metrics (CPU, GPU, Memory,
//  Network, Disk), each a big live number with a small 5-minute history
//  chart beside it. Sits next to the Dock, in a glass strip or bare on the
//  desktop. Hovering a metric shows a detail panel.
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import <Cocoa/Cocoa.h>

extern NSString * const JRGDockStyleKey;       // @"glass" or @"bare"
extern NSString * const JRGDockKeepOnTopKey;   // BOOL
extern NSString * const JRGDockOffsetXKey;     // CGFloat, strip's x offset from the screen's left edge

@interface XRGDockStripController : NSObject

+ (instancetype)shared;

/// Builds (if needed) and shows the strip next to the Dock.
- (void)showDockStrip;

/// Opens the Settings window.
- (IBAction)showSettings:(id)sender;

@end
