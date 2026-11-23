//
//  JRGSettingsWindow.h
//  JRG
//
//  The Settings window: a live strip preview, themes and custom colors, strip
//  options, display units, launch at login, and updates. Built in code.
//
//  Licensed under the GNU GPL v2, like the rest of XRG/JRG.
//

#import <Cocoa/Cocoa.h>

@interface JRGSettingsWindowController : NSWindowController

+ (instancetype)shared;

@end
