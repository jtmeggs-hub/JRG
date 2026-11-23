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

extern NSString * const JRGLayoutKey;          // @"classic" or @"dock"
extern NSString * const JRGDockStyleKey;       // @"glass" or @"bare"
extern NSString * const JRGDockKeepOnTopKey;   // BOOL
extern NSString * const JRGDockOffsetXKey;     // CGFloat, strip's x offset from the screen's left edge

@interface XRGDockStripController : NSObject

+ (instancetype)shared;

/// YES when the Dock strip layout is selected (the default).
+ (BOOL)dockLayoutSelected;

/// Shows the strip and hides the classic window, or the reverse.
- (void)showDockStrip;
- (void)showClassicLayout;

/// Menu actions (also used from the classic window's right-click menu).
- (IBAction)switchToDockStrip:(id)sender;
- (IBAction)switchToClassic:(id)sender;

@end
