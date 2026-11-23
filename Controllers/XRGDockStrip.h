//
//  XRGDockStrip.h
//  JRG
//
//  A minimal, Dock-height layout: one row of metrics, each a big live number
//  with a small history chart beside it. Sits next to the Dock, in a glass
//  strip or bare on the desktop. Hovering a metric shows a detail panel.
//  All of its options live in JRGSettings.
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import <Cocoa/Cocoa.h>

@interface XRGDockStripController : NSObject

+ (instancetype)shared;

/// Builds (if needed) and shows the strip next to the Dock.
- (void)showDockStrip;

/// Opens the Settings window.
- (IBAction)showSettings:(id)sender;

/// Moves the strip back to the left edge of the Dock screen.
- (IBAction)resetPosition:(id)sender;

/// Width of the strip at a given height with the current settings.
- (CGFloat)stripWidthForHeight:(CGFloat)height;

/// A live, non-interactive copy of the strip at the given height (for the Settings preview).
- (NSView *)makePreviewViewWithHeight:(CGFloat)height;

@end
