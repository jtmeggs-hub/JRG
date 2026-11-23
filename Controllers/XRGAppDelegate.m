/*
 * JRG, based on XRG (X Resource Graph) by Gaucho Software, LLC.
 * Copyright (C) 2002-2022 Gaucho Software, LLC. Changes (C) 2026 Jordan Meggs.
 * Licensed under the GNU General Public License, version 2 or later.
 * See the LICENSE file in the root of the source tree.
 */

#import "XRGAppDelegate.h"
#import "XRGDockStrip.h"
#import "JRGSettings.h"
#import <Sparkle/Sparkle.h>

@implementation XRGAppDelegate {
    SPUStandardUpdaterController *_updaterController;
}

- (SPUStandardUpdaterController *)updaterController { return _updaterController; }

+ (BOOL)isDevelopmentBuild {
    return [[NSBundle mainBundle].bundleIdentifier hasSuffix:@"-dev"];
}

- (IBAction)checkForUpdates:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [_updaterController checkForUpdates:sender];
}

- (NSString *)appName {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"JRG";
}

/// JRG has no nib, so the menu is built here. It's never shown (JRG lives outside the
/// menu bar), but its key equivalents still work while a JRG window is key.
- (void)buildMainMenu {
    NSString *name = [self appName];
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:name];
    [appMenu addItemWithTitle:[@"About " stringByAppendingString:name] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","].target = self;
    [appMenu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates:) keyEquivalent:@""].target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(terminate:) keyEquivalent:@"q"];
    [main addItemWithTitle:name action:nil keyEquivalent:@""].submenu = appMenu;

    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [main addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu = edit;

    NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
    [window addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [main addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu = window;

    [NSApp setMainMenu:main];
}

/// Regular app (Dock icon, menu bar, Command-Tab) or background app, per Settings.
- (void)applyActivationPolicy {
    BOOL dock = [JRGSettings shared].showInDock;
    NSApplicationActivationPolicy want = dock ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory;
    if (NSApp.activationPolicy == want) return;
    [NSApp setActivationPolicy:want];
    if (dock) [NSApp activateIgnoringOtherApps:YES];   // so the menu bar shows up right away
}

- (void)settingsChanged:(NSNotification *)note {
    [self applyActivationPolicy];
}

- (void)applicationWillFinishLaunching:(NSNotification *)note {
    [self buildMainMenu];
    [NSApp setActivationPolicy:[JRGSettings shared].showInDock ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:)
                                                 name:JRGSettingsDidChangeNotification object:nil];
    if (![XRGAppDelegate isDevelopmentBuild]) {
        // Checks the GitHub appcast once a day (SUScheduledCheckInterval) and offers new releases.
        _updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [[XRGDockStripController shared] showDockStrip];
}

// Opening JRG again while it's running (Finder, Spotlight) brings up Settings,
// since the strip itself has no window to bring forward.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self showSettings:nil];
    return NO;
}

- (IBAction)showSettings:(id)sender {
    [[XRGDockStripController shared] showSettings:sender];
}

@end
