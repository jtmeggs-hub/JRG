/*
 * JRG, based on XRG (X Resource Graph) by Gaucho Software, LLC.
 * Copyright (C) 2002-2022 Gaucho Software, LLC. Changes (C) 2026 Jordan Meggs.
 * Licensed under the GNU General Public License, version 2 or later.
 * See the LICENSE file in the root of the source tree.
 */

#import <Cocoa/Cocoa.h>

@class SPUStandardUpdaterController;

@interface XRGAppDelegate : NSObject <NSApplicationDelegate>

/// Sparkle's updater. nil in development builds, which shouldn't replace themselves
/// with a release.
@property (readonly) SPUStandardUpdaterController *updaterController;

- (IBAction)checkForUpdates:(id)sender;

- (IBAction)showSettings:(id)sender;

@end
