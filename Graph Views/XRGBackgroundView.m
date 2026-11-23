/* 
 * XRG (X Resource Graph):  A system resource grapher for Mac OS X.
 * Copyright (C) 2002-2022 Gaucho Software, LLC.
 * You can view the complete license in the LICENSE file in the root
 * of the source tree.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 *
 */

//
//  XRGBackgroundView.m
//

#import "XRGBackgroundView.h"
#import "XRGDockStrip.h"
#import "XRGGraphWindow.h"
#import "XRGGenericView.h"
#import "XRGAppDelegate.h"
#import "XRGPrefController.h"
#import <sys/sysctl.h>

// Draws the window title (hostname or custom title) in glass mode. It lives directly in
// the window's content view, unrotated, because the background view's bounds-rotation
// trick no longer renders under current SDKs.
@interface XRGTitleLabelView : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSDictionary *attributes;
@property (nonatomic) BOOL vertical;   // YES = text runs bottom-to-top in a narrow column
@end

@implementation XRGTitleLabelView

- (NSView *)hitTest:(NSPoint)point {
    return nil;   // let clicks and drags fall through to the window
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.text.length == 0) return;

    NSMutableDictionary *attrs = [self.attributes mutableCopy] ?: [NSMutableDictionary dictionary];
    attrs[NSForegroundColorAttributeName] = [NSColor colorWithWhite:1.0 alpha:0.7];
    NSFont *font = attrs[NSFontAttributeName] ?: [NSFont systemFontOfSize:11];
    CGFloat lineHeight = ceil(font.ascender - font.descender);

    NSRect b = self.bounds;
    if (self.vertical) {
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:b.size.width yBy:0];
        [t rotateByDegrees:90];
        [t concat];
        // In the rotated space, the label is b.height wide and b.width tall.
        NSRect r = NSMakeRect(0, floor((b.size.width - lineHeight) / 2.0) - 1, b.size.height, lineHeight);
        [self.text drawInRect:r withAttributes:attrs];
        [NSGraphicsContext restoreGraphicsState];
    }
    else {
        NSRect r = NSMakeRect(0, floor((b.size.height - lineHeight) / 2.0), b.size.width, lineHeight);
        [self.text drawInRect:r withAttributes:attrs];
    }
}

@end

@implementation XRGBackgroundView {
    XRGTitleLabelView *glassTitleLabel;
}

- (void)updateGlassTitleLabel {
    NSView *content = parentWindow.contentView;
    if (!content) return;

    if (!glassTitleLabel) {
        glassTitleLabel = [[XRGTitleLabelView alloc] initWithFrame:NSZeroRect];
        [content addSubview:glassTitleLabel];
    }

    CGFloat border = [parentWindow borderWidth];
    CGFloat titleSize = [appSettings textRectHeight];
    NSRect cb = content.bounds;
    BOOL vertical = [moduleManager graphOrientationVertical];

    // Horizontal strips keep the title in a narrow column on the left;
    // vertical stacks keep it in a row across the top.
    NSRect frame = vertical
        ? NSMakeRect(border, cb.size.height - border - titleSize, cb.size.width - 2 * border, titleSize)
        : NSMakeRect(border, border, titleSize, cb.size.height - 2 * border);

    NSString *title = [appSettings windowTitle];
    NSString *text = (title.length > 0) ? title : self.hostname;

    if (!NSEqualRects(glassTitleLabel.frame, frame)) glassTitleLabel.frame = frame;
    glassTitleLabel.vertical = !vertical;
    glassTitleLabel.attributes = [appSettings alignCenterAttributes];
    if (![glassTitleLabel.text isEqualToString:text]) {
        glassTitleLabel.text = text;
    }
    [glassTitleLabel setNeedsDisplay:YES];
}

- (void)awakeFromNib {
    [super awakeFromNib];
    
    parentWindow = (XRGGraphWindow *)[self window]; 
    
    appSettings = [parentWindow appSettings];
    moduleManager = [parentWindow moduleManager];
    
	self.hostname = @"JRG";
	[self getHostname];
	
    // Find out whether or not the App's UI is being displayed.
    uiIsHidden = [[NSUserDefaults standardUserDefaults] boolForKey:XRG_isDockIconHidden];
    if (!uiIsHidden) {
        [self showUI:nil];
    }
    
    isVertical = YES;
    inInner = inOuter = inHeader = NO;
    self.clickedMinimized = NO;
    lastWidth = [self frame].size.width;
    
    [self registerForDraggedTypes:@[NSFilenamesPboardType]];
    
    [parentWindow setBackgroundView: self];
}

- (void)setFrame:(NSRect)frame {
	[super setFrame:frame];
	[parentWindow.moduleManager windowChangedToSize:self.frame.size];
}

- (void)offsetDrawingOrigin:(NSSize)offset {
    [self translateOriginToPoint: NSMakePoint(offset.width, offset.height)];
}

- (NSBezierPath *)outerPath {
    int borderWidth = [parentWindow borderWidth];

    return [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:borderWidth yRadius:borderWidth];
}

- (NSBezierPath *)innerPath {
    int borderWidth = [parentWindow borderWidth];
    NSRect tmpRect = [self bounds];
    tmpRect.origin.x += borderWidth;
    tmpRect.origin.y = tmpRect.size.height - borderWidth - [appSettings textRectHeight];
    tmpRect.size.width -= borderWidth * 2;
    tmpRect.size.height = [appSettings textRectHeight];

    return [NSBezierPath bezierPathWithRoundedRect:tmpRect xRadius:borderWidth yRadius:borderWidth];
}

- (void)drawRect:(NSRect)rect{
    // Rotate the coordinate system if necessary
    if (![moduleManager graphOrientationVertical] && isVertical) {
        // first update our size:
        NSRect f = [parentWindow frame];
        f.origin = [self frame].origin;
        [self setFrame:f];
        // switch from vertical to horizontal
        [self setBoundsRotation: 90];
        [self translateOriginToPoint: NSMakePoint(0, 0 - [self frame].size.width)];
        isVertical = NO;
        lastWidth = [self frame].size.width;
    }
    if ([moduleManager graphOrientationVertical] && !isVertical) {
        // first update our size:
        NSRect f = [parentWindow frame];
        f.origin = [self frame].origin;
        [self setFrame:f];
        // switch from horizontal to vertical
        [self translateOriginToPoint: NSMakePoint(0, lastWidth)];
        [self setBoundsRotation: 0];
        [self setAutoresizesSubviews:YES];
        isVertical = YES;
    }
    
    if (!isVertical) {
        if (lastWidth != [self frame].size.width) {
            [self translateOriginToPoint:NSMakePoint(0, 0 - ([self frame].size.width - lastWidth))];
            lastWidth = [self frame].size.width;
        }
    }
	
    NSGraphicsContext *gc = [NSGraphicsContext currentContext]; 
    
    if (!appSettings.glassAppearance) {
    // Draw the border
    [[appSettings borderColor] set];
    NSBezierPath *borderPath = [self outerPath];
    
    NSBezierPath *excludePath = [NSBezierPath bezierPath];
    for (XRGModule *module in parentWindow.moduleManager.displayList) {
        NSRect graphRect = module.reference.frame;
        graphRect = [self convertRect:module.reference.bounds fromView:module.reference];
        [excludePath appendBezierPath:[NSBezierPath bezierPathWithRect:graphRect]];
    }

    [borderPath appendBezierPath:[excludePath bezierPathByReversingPath]];
    [borderPath fill];

    // Draw the title background
    [[appSettings backgroundColor] set];
    [[self innerPath] fill];
    }
    
    // Draw the title
    int borderWidth = [parentWindow borderWidth];
    NSRect titleRect = NSMakeRect(borderWidth,
                                  [self bounds].size.height - borderWidth - [appSettings textRectHeight],
                                  [self bounds].size.width - 2 * borderWidth,
                                  [appSettings textRectHeight]);
    if (!appSettings.glassAppearance) NSRectFill(titleRect);
    
    [gc setShouldAntialias:YES];

    if (appSettings.glassAppearance) {
        [self updateGlassTitleLabel];
        return;
    }

    NSString *title = [appSettings windowTitle];
    if (!title || [title isEqualToString:@""]) {
		[self.hostname drawInRect:titleRect withAttributes:[appSettings alignCenterAttributes]];
    }
    else {
        [title drawInRect:titleRect withAttributes:[appSettings alignCenterAttributes]];
    }
    
    [gc setShouldAntialias:YES];
}

- (void)getHostname {
	// Run this in a background thread because it might take a little bit of time.
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSProcessInfo *proc = [NSProcessInfo processInfo];
		NSString *s = [proc hostName];
		NSRange r = [s rangeOfString:@"."];
		
		NSString *newHostname = @"JRG";
		if (r.location == NSNotFound) {
			if ([s length] > 0)	newHostname = s;
		}
		else {
			if (r.location != 0) newHostname = [s substringToIndex:r.location];
		}
		self.hostname = newHostname;

		dispatch_async(dispatch_get_main_queue(), ^{
			[self setNeedsDisplay:YES];
		});
	});

	@autoreleasepool {
	}
}

- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent *)theEvent {       
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent {       
    return YES;
}

- (BOOL)acceptsMouseMovedEvents {       
    return YES;
}

- (void)mouseDownAction:(NSEvent *)theEvent { 
    if ([appSettings windowLevel] == kCGDesktopWindowLevel) [NSApp preventWindowOrdering];
 	NSInteger originalWindowLevel = [parentWindow level];
	viewPointClicked = [self convertPoint:[theEvent locationInWindow] fromView:nil];

    // if it's a double click in the title bar, minimize the window
    if ([theEvent clickCount] == 2) { 
		NSRect frame    = [self bounds];
		int borderWidth = [parentWindow borderWidth];
		NSRect headerRect = NSMakeRect(frame.origin.x + borderWidth, frame.origin.y + frame.size.height - borderWidth - [appSettings textRectHeight], frame.size.width, [appSettings textRectHeight]);
        if (NSPointInRect(viewPointClicked, headerRect)) {
            if ([parentWindow minimized]) {
                self.clickedMinimized = NO;
                [self expandWindow];
            }
            else {
                if (self.clickedMinimized == NO) {
                    self.clickedMinimized = YES;
                    [self minimizeWindow];
                }
                else {
                    self.clickedMinimized = NO;
                    
                    // If the window was brought to the front when expanding, we need to put it back.
                    [parentWindow setLevel:originalWindowLevel];
                }
            }
        }
    }
}

- (void)mouseDragged:(NSEvent *)theEvent {
    [parentWindow mouseDragged:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent {
    [parentWindow mouseUp:theEvent];
}

- (void)minimizeWindow {
    if ([parentWindow minimized]) return;
    
    int i;
    NSRect windowFrame;
    
    // Figure out what the new rect should be and save the old rect.
    if ([moduleManager graphOrientationVertical]) {
        windowFrame = [parentWindow frame];
        unminimizedRect = windowFrame;
        
        if ([appSettings minimizeUpDown] == 0) { // minimize up
            windowFrame.origin.y = windowFrame.origin.y + windowFrame.size.height - ((2 * [parentWindow borderWidth]) + [appSettings textRectHeight]);
            windowFrame.size.height = (2 * [parentWindow borderWidth]) + [appSettings textRectHeight];
        }
        else { // minimize down
            windowFrame.size.height = (2 * [parentWindow borderWidth]) + [appSettings textRectHeight];
        }
        
        [parentWindow setMinimized:YES];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }
    else {
        windowFrame = [parentWindow frame];
        unminimizedRect = windowFrame;
        
        if ([appSettings minimizeUpDown] == 0) { // minimize left
            windowFrame.size.width = (2 * [parentWindow borderWidth]) + [appSettings textRectHeight];
        }
        else { // minimize right
            windowFrame.origin.x = windowFrame.origin.x + windowFrame.size.width - ((2 * [parentWindow borderWidth]) + [appSettings textRectHeight]);
            windowFrame.size.width = (2 * [parentWindow borderWidth]) + [appSettings textRectHeight];
        }
        
        [parentWindow setMinimized:YES];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }

    // Hide the modules.
    NSArray *a = [moduleManager displayList];
    for (i = 0; i < [a count]; i++) {
        XRGGenericView *ref = [a[i] reference];
        if (ref != nil) {
            [ref setHidden:YES];
        }
    }
    
    // Resize the window.
	[parentWindow setFrame:windowFrame display:YES animate:YES];
    
    // Put the window level back where it was.
    if ([appSettings foregroundWhenExpanding]) {
        if ([appSettings windowLevel] == 0)
        {
            [parentWindow setLevel:NSNormalWindowLevel];
        }
        else if ([appSettings windowLevel] == 1)
        {
            [parentWindow setLevel:NSFloatingWindowLevel];
        }
        else {
            [parentWindow setLevel:kCGDesktopWindowLevel];
        }
    }
	
	// Save in the preferences.
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:XRG_windowIsMinimized];
}

- (void)expandWindow {
    if (![parentWindow minimized]) return;

    int i;
    NSRect windowFrame;
    
    // Figure out what our new rect should be.
    if ([moduleManager graphOrientationVertical]) {
        windowFrame = [parentWindow frame];
		if ([appSettings minimizeUpDown] == 0) { // maximize down
			windowFrame.origin.y -= unminimizedRect.size.height - windowFrame.size.height;
		}
		else { // maximize up
			// windowFrame.origin.y is fine as-is
		}
        windowFrame.size.height = unminimizedRect.size.height;
        [parentWindow setMinimized:NO];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }
    else {
        windowFrame = [parentWindow frame];
		if ([appSettings minimizeUpDown] == 0) { // maximize right
			// windowFrame.origin.x is fine as-is
		}
		else { // maximize left
			windowFrame.origin.x -= unminimizedRect.size.width - windowFrame.size.width;
		}
        windowFrame.size.width = unminimizedRect.size.width;
        [parentWindow setMinimized:NO];
        [parentWindow setMinSize:[moduleManager getMinSize]];
    }
        
    if ([appSettings foregroundWhenExpanding] && [appSettings autoExpandGraph]) 
        [parentWindow setLevel:NSFloatingWindowLevel];

    // Finally, resize the window.
	[parentWindow setFrame:windowFrame display:YES animate:YES];
	
	// Show the modules again.
    NSArray *a = [moduleManager displayList];
    for (i = 0; i < [a count]; i++) {
        XRGGenericView *ref = [a[i] reference];
        if (ref != nil) {
            [ref setHidden:NO];
            [ref setNeedsDisplay:YES];
        }
    }
    	
	// Save in the preferences.
	[[NSUserDefaults standardUserDefaults] setBool:NO forKey:XRG_windowIsMinimized];
}

- (NSMenu *)menuForEvent:(NSEvent *)theEvent {
    NSMenu *myMenu = [[NSMenu alloc] initWithTitle:@"Background View"];
    NSMenuItem *tMI;

    tMI = [[NSMenuItem alloc] initWithTitle:@"About JRG" action:@selector(openAboutBox:) keyEquivalent:@""];
    [myMenu addItem:tMI];

    tMI = [[NSMenuItem alloc] initWithTitle:@"Preferences..." action:@selector(openPreferences:) keyEquivalent:@""];
    [myMenu addItem:tMI];

    tMI = [[NSMenuItem alloc] initWithTitle:@"JRG Help" action:@selector(openHelp:) keyEquivalent:@""];
    [myMenu addItem:tMI];

    [myMenu addItem:[NSMenuItem separatorItem]];
    tMI = [[NSMenuItem alloc] initWithTitle:@"Switch to Dock Strip" action:@selector(switchToDockStrip:) keyEquivalent:@""];
    tMI.target = [XRGDockStripController shared];
    [myMenu addItem:tMI];
    
    [myMenu addItem:[NSMenuItem separatorItem]];

    if (uiIsHidden) {
        tMI = [[NSMenuItem alloc] initWithTitle:@"Show JRG Dock Icon" action:@selector(showUI:) keyEquivalent:@""];
        [myMenu addItem:tMI];
    }
    else {
        tMI = [[NSMenuItem alloc] initWithTitle:@"Hide JRG Dock Icon (After Restart)" action:@selector(hideUI:) keyEquivalent:@""];
        [myMenu addItem:tMI];
    }

    [myMenu addItem:[NSMenuItem separatorItem]];
    
    tMI = [[NSMenuItem alloc] initWithTitle:@"Quit JRG" action:@selector(quit:) keyEquivalent:@""];
    [myMenu addItem:tMI];
    
    return myMenu;
}

- (void)openAboutBox:(NSEvent *)theEvent {
    [[NSApplication sharedApplication] orderFrontStandardAboutPanel:self];
}

- (void)openHelp:(NSEvent *)theEvent {
    [[NSApplication sharedApplication] showHelp:self];
}

- (void)openPreferences:(NSEvent *)theEvent {
    [[parentWindow controller] showPrefsWithPanel:@"General"];
}

- (void)hideUI:(NSEvent *)theEvent {
    uiIsHidden = YES;
    
    [[NSUserDefaults standardUserDefaults] setBool:uiIsHidden forKey:XRG_isDockIconHidden];
    
    NSRunInformationalAlertPanel(@"Hiding the XRG Dock Icon", @"Please re-launch XRG for changes to take effect.", @"OK", nil, nil);
}

- (void)showUI:(NSEvent *)theEvent {
    [NSApp setActivationPolicy: NSApplicationActivationPolicyRegular];
    uiIsHidden = NO;
    
    [[NSUserDefaults standardUserDefaults] setBool:uiIsHidden forKey:XRG_isDockIconHidden];
}

- (void)quit:(NSEvent *)theEvent {
    [[NSApplication sharedApplication] terminate:self];
} 

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender {
    NSPasteboard *pasteBoard;
    NSDragOperation sourceDragMask;

    sourceDragMask = [sender draggingSourceOperationMask];
    pasteBoard = [sender draggingPasteboard];

    if ( [[pasteBoard types] containsObject:NSFilenamesPboardType] ) {
        if (sourceDragMask & NSDragOperationCopy) {
            NSArray *files = [pasteBoard propertyListForType:NSFilenamesPboardType];
            if ([files count] == 1 && [files[0] hasSuffix:@".xtf"]) {
                return NSDragOperationCopy;
            }
            else {
                return NSDragOperationNone;
            }
        }
    }
    return NSDragOperationNone;
}    

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender {
    NSPasteboard *pasteBoard = [sender draggingPasteboard];
    
    if ([[pasteBoard types] containsObject:NSFilenamesPboardType]) {
        NSArray *files = [pasteBoard propertyListForType:NSFilenamesPboardType];
        
        // Check the same conditions as in draggingEntered:
        if ([files count] == 1 && [files[0] hasSuffix:@".xtf"]) {
            NSString *path;
            NSData *themeData;
            NSString *error;        
            NSPropertyListFormat format;
            NSDictionary *themeDictionary;
            
            /* if successful, open file under designated name */
            path = files[0];

            themeData = [NSData dataWithContentsOfFile:path];
            
            if ([themeData length] == 0) {
                NSRunInformationalAlertPanel(@"Error", @"The theme file dragged is not a valid theme file.", @"OK", nil, nil);
            }

            themeDictionary = [NSPropertyListSerialization propertyListFromData:themeData
                                                               mutabilityOption:NSPropertyListImmutable
                                                                         format:&format
                                                               errorDescription:&error];
                                                               
            if (!themeDictionary) {
                NSRunInformationalAlertPanel(@"Error", @"The theme file dragged is not a valid theme file.", @"OK", nil, nil);
				NSLog(@"%@", error);
            }
            else {
				[appSettings readXTFDictionary:themeDictionary];                
                [self setNeedsDisplay:YES];
            }
        }
    }
    	
	[[(XRGAppDelegate *)[NSApp delegate] prefController] setUpColorPanel];

    return YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
        self.trackingArea = nil;
    }

    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways)
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)mouseEntered:(NSEvent *)theEvent {
	//    NSLog(@"mouseEntered start\n");
	if (self.clickedMinimized && [appSettings autoExpandGraph]) {
		[self expandWindow];
	}
}

- (void)mouseExited:(NSEvent *)theEvent {
	//    NSLog(@"mouseEntered start\n");
	if (self.clickedMinimized && [appSettings autoExpandGraph]) {
		[self minimizeWindow];
	}
}

@end
