// Probe injected into a COPY of the Debug MarkView app (own bundle id, own HOME). It keeps every window fully
// transparent and click-through for the window server, runs a script of steps on the main queue, and writes
// snapshots and measurements to MV_PROBE_OUT. Nothing here is shown on the screen.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <fcntl.h>
#import <sys/param.h>
#import <unistd.h>

static NSString *OutDir;
static FILE *LogF;
static NSArray<NSString *> *Script;
static NSUInteger Step;

static void L(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void L(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    fprintf(LogF, "%s\n", s.UTF8String);
    fflush(LogF);
}

static void hideWindow(NSWindow *w) {
    if (![w isKindOfClass:[NSWindow class]]) return;
    w.alphaValue = 0;
    w.ignoresMouseEvents = YES;
    w.hasShadow = NO;
}

static id (*origInitA)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL);
static id hookInitA(id self, SEL cmd, NSRect r, NSWindowStyleMask m, NSBackingStoreType b, BOOL d) {
    id w = origInitA(self, cmd, r, m, b, d);
    hideWindow(w);
    return w;
}
static id (*origInitB)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL, NSScreen *);
static id hookInitB(id self, SEL cmd, NSRect r, NSWindowStyleMask m, NSBackingStoreType b, BOOL d, NSScreen *s) {
    id w = origInitB(self, cmd, r, m, b, d, s);
    hideWindow(w);
    return w;
}

static int Pick = -1;
static NSString *PickTitle = nil;
/// `sheet on`: the steps act on the sheet attached to the window they would act on (a SwiftUI `.sheet` is a window of its own).
static BOOL OnSheet = NO;
static NSWindow *WindowBeforeSheet(void);
static NSWindow *MainWindow(void) {
    NSWindow *base = WindowBeforeSheet();
    return OnSheet && base.attachedSheet ? base.attachedSheet : base;
}
static NSWindow *WindowBeforeSheet(void) {
    if (PickTitle.length) {
        for (NSWindow *w in NSApp.windows) {
            if (w.isVisible && w.contentView && [w.title containsString:PickTitle]) return w;
        }
        return nil;
    }
    if (Pick >= 0) {
        NSMutableArray *eligible = [NSMutableArray array];
        for (NSWindow *w in NSApp.windows) {
            NSString *cn = NSStringFromClass([w class]);
            if (!w.isVisible || [cn containsString:@"Panel"] || [cn containsString:@"Popover"] || w.contentView == nil || [w.title containsString:@"Settings"]) continue;
            [eligible addObject:w];
        }
        if (eligible.count) return eligible[MIN((NSUInteger)Pick, eligible.count - 1)];
    }
    NSWindow *best = nil;
    CGFloat bestArea = 0;
    for (NSWindow *w in NSApp.windows) {
        NSString *cn = NSStringFromClass([w class]);
        if (!w.isVisible || [cn containsString:@"Panel"] || [cn containsString:@"Popover"] || w.contentView == nil) continue;
        if ([w.title containsString:@"Settings"]) continue;
        CGFloat area = w.frame.size.width * w.frame.size.height;
        if (area > bestArea) { best = w; bestArea = area; }
    }
    return best;
}

static NSView *FindView(NSView *root, NSString *needle) {
    if ([NSStringFromClass([root class]) containsString:needle]) return root;
    for (NSView *v in root.subviews) { NSView *f = FindView(v, needle); if (f) return f; }
    return nil;
}

static void Snap(NSView *v, NSString *name) {
    NSRect b = v.bounds;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:b];
    [v cacheDisplayInRect:b toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[OutDir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    L(@"snap %@ %.0fx%.0f", name, b.size.width, b.size.height);
}

// The presentation layer tree of a view (what the render server shows now), drawn into a PNG.
static void PresentationFrame(NSView *v, NSString *name) {
    CALayer *layer = v.layer;
    if (!layer) { L(@"frame %@: no layer", name); return; }
    [CATransaction flush];
    CALayer *p = layer.presentationLayer ?: layer;
    size_t w = (size_t)v.bounds.size.width, h = (size_t)v.bounds.size.height;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, 0.08, 0.09, 0.12, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    [p renderInContext:ctx];
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[OutDir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    L(@"frame %@ %zux%zu", name, w, h);
}

static NSArray<NSValue *> *Positions(CALayer *root) {
    [CATransaction flush];
    NSMutableArray *a = [NSMutableArray array];
    for (CALayer *l in root.sublayers) {
        CALayer *p = l.presentationLayer;
        [a addObject:[NSValue valueWithPoint:p ? NSMakePoint(p.position.x, p.position.y) : NSMakePoint(-1e9, -1e9)]];
    }
    return a;
}

/// The centre (window content coordinates, top-left origin) of the first accessibility element whose label or title is `name`; NO when there is none.
static BOOL FindAX(id el, NSWindow *w, NSString *name, BOOL contains, int depth, int *count, CGPoint *centre) {
    if (depth > 14 || *count > 1500) return NO;
    NSArray *kids = [el respondsToSelector:@selector(accessibilityChildren)] ? [el accessibilityChildren] : nil;
    for (id k in kids) {
        (*count)++;
        // SwiftUI hands out attributed strings for some labels.
        id label = [k respondsToSelector:@selector(accessibilityLabel)] ? [k accessibilityLabel] : nil;
        id title = [k respondsToSelector:@selector(accessibilityTitle)] ? [k accessibilityTitle] : nil;
        if ([label isKindOfClass:NSAttributedString.class]) label = [label string];
        if ([title isKindOfClass:NSAttributedString.class]) title = [title string];
        BOOL hit = contains ? ([label isKindOfClass:NSString.class] && [(NSString *)label containsString:name]) || ([title isKindOfClass:NSString.class] && [(NSString *)title containsString:name])
                            : [label isEqual:name] || [title isEqual:name];
        if (hit) {
            NSRect wf = [w convertRectFromScreen:[k accessibilityFrame]];
            *centre = CGPointMake(NSMidX(wf), w.contentView.bounds.size.height - NSMidY(wf));
            return YES;
        }
        if (FindAX(k, w, name, contains, depth + 1, count, centre)) return YES;
    }
    return NO;
}

static NSArray<NSValue *> *MotionBefore;
static NSView *MotionView;

static void ClickAt(NSWindow *w, CGFloat x, CGFloat yTop, BOOL down) {
    NSView *cv = w.contentView;
    CGFloat y = cv.isFlipped ? yTop : cv.bounds.size.height - yTop;
    NSPoint p = [cv convertPoint:NSMakePoint(x, y) toView:nil];
    NSTimeInterval t = [NSProcessInfo processInfo].systemUptime;
    NSEvent *e = [NSEvent mouseEventWithType:down ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:t
                                windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:down ? 1 : 0];
    [w sendEvent:e];
}

static void MoveTo(NSWindow *w, CGFloat x, CGFloat yTop) {
    NSView *cv = w.contentView;
    CGFloat y = cv.isFlipped ? yTop : cv.bounds.size.height - yTop;
    NSPoint p = [cv convertPoint:NSMakePoint(x, y) toView:nil];
    NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:p modifierFlags:0 timestamp:[NSProcessInfo processInfo].systemUptime
                                windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0];
    [w sendEvent:e];
}

static void DumpAX(id el, NSWindow *w, int depth, int *count) {
    if (depth > 14 || *count > 1500) return;
    NSArray *kids = nil;
    if ([el respondsToSelector:@selector(accessibilityChildren)]) kids = [el accessibilityChildren];
    for (id k in kids) {
        (*count)++;
        NSString *role = [k respondsToSelector:@selector(accessibilityRole)] ? [k accessibilityRole] : @"?";
        id label = [k respondsToSelector:@selector(accessibilityLabel)] ? [k accessibilityLabel] : nil;
        id title = [k respondsToSelector:@selector(accessibilityTitle)] ? [k accessibilityTitle] : nil;
        if ([label isKindOfClass:NSAttributedString.class]) label = [label string];
        if ([title isKindOfClass:NSAttributedString.class]) title = [title string];
        NSRect f = [k respondsToSelector:@selector(accessibilityFrame)] ? [k accessibilityFrame] : NSZeroRect;
        NSRect wf = [w convertRectFromScreen:f];
        CGFloat h = w.contentView.bounds.size.height;
        BOOL enabled = [k respondsToSelector:@selector(isAccessibilityEnabled)] ? [k isAccessibilityEnabled] : YES;
        // A toolbar button that is the current one says so in its value ("current", "open").
        id value = [k respondsToSelector:@selector(accessibilityValue)] ? [k accessibilityValue] : nil;
        if ([value isKindOfClass:NSAttributedString.class]) value = [value string];
        if ([label length] || [title length] || [role isEqualToString:@"AXButton"])
            L(@"ax %*s%@ label=%@ title=%@ x=%.0f y=%.0f w=%.0f h=%.0f enabled=%d value=%@", depth, "", role, label, title, wf.origin.x, h - wf.origin.y - wf.size.height, wf.size.width, wf.size.height, enabled, [value isKindOfClass:NSString.class] ? value : @"");
        DumpAX(k, w, depth + 1, count);
    }
}

/// The main menu as the real app built it: one line per item with its path, key equivalent and enabled state.
static void DumpMenu(NSMenu *menu, NSString *path, int *count) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        NSString *name = [path stringByAppendingFormat:@"%@%@", path.length ? @" > " : @"", item.title];
        NSString *mods = [NSString stringWithFormat:@"%@%@%@%@",
                          (item.keyEquivalentModifierMask & NSEventModifierFlagControl) ? @"ctrl+" : @"",
                          (item.keyEquivalentModifierMask & NSEventModifierFlagOption) ? @"opt+" : @"",
                          (item.keyEquivalentModifierMask & NSEventModifierFlagShift) ? @"shift+" : @"",
                          (item.keyEquivalentModifierMask & NSEventModifierFlagCommand) ? @"cmd+" : @""];
        (*count)++;
        L(@"menu %@ key=%@%@ enabled=%d", name, item.keyEquivalent.length ? mods : @"", item.keyEquivalent, item.isEnabled);
        if (item.submenu) DumpMenu(item.submenu, name, count);
    }
}

/// The pop-up buttons of the window, in view order. A toolbar `Menu` is one: SwiftUI fills its NSMenu only when it opens.
static void CollectPopUps(NSView *v, NSMutableArray<NSPopUpButton *> *found) {
    if ([v isKindOfClass:NSPopUpButton.class]) [found addObject:(NSPopUpButton *)v];
    for (NSView *k in v.subviews) CollectPopUps(k, found);
}

/// Chooses `title` in the first toolbar menu that offers it, without opening the menu: the menu's delegate is told it is about to open, as it is
/// just before the menu is shown, SwiftUI fills the menu a moment later, and the item's action runs as a click on it would run it. Nothing
/// appears on the screen and no tracking loop starts.
static void ChooseInToolbarMenu(NSWindow *w, NSString *title) {
    NSMutableArray<NSPopUpButton *> *popUps = [NSMutableArray array];
    CollectPopUps(w.contentView, popUps);
    for (NSPopUpButton *button in popUps) {
        id delegate = button.menu.delegate;
        SEL willShow = NSSelectorFromString(@"popUpButtonCell:willShowMenu:");
        if ([delegate respondsToSelector:willShow]) ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, willShow, button.cell, button.menu);
        if ([delegate respondsToSelector:@selector(menuWillOpen:)]) [delegate menuWillOpen:button.menu];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (NSPopUpButton *button in popUps) {
            NSMenu *menu = button.menu;
            for (NSMenuItem *item in menu.itemArray) {
                if (![item.title isEqualToString:title]) continue;
                if (!item.isEnabled) { L(@"menuchoose %@: disabled", title); return; }
                [menu performActionForItemAtIndex:[menu indexOfItem:item]];
                L(@"menuchoose %@: chosen", title);
                return;
            }
        }
        L(@"menuchoose %@: no toolbar menu offers it (%lu pop-up buttons)", title, (unsigned long)popUps.count);
    });
}

static void RunNext(void);

static void Later(NSTimeInterval s) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ RunNext(); });
}

/// How many arguments each step reads after its name. A step with fewer is a script error: it is reported and the probe exits, because an
/// exception in the probed app is a crash with a system dialog on the screen of whoever runs the probe.
static NSDictionary<NSString *, NSNumber *> *StepArguments(void) {
    return @{ @"wait": @1, @"pick": @1, @"picktitle": @1, @"size": @2, @"snap": @1, @"frame": @1, @"motion": @1, @"menuchoose": @1,
             @"move": @2, @"click": @2, @"hit": @2, @"clicklabel": @1, @"clickcontains": @1, @"cmdkey": @1, @"drag": @4, @"openurl": @1, @"sheet": @1, @"fds": @1 };
}

static void RunNext(void) {
    if (Step >= Script.count) { L(@"script finished"); return; }
    NSString *line = Script[Step++];
    NSArray<NSString *> *p = [line componentsSeparatedByString:@" "];
    NSString *cmd = p.firstObject;
    NSNumber *needed = StepArguments()[cmd];
    if (needed && (NSInteger)p.count - 1 < needed.integerValue) {
        L(@"script error at step %lu: '%@' needs %@ argument(s), the line is '%@'; the probe stops", (unsigned long)Step, cmd, needed, line);
        _exit(2);
    }
    NSTimeInterval delay = 0.05;
    for (NSWindow *w in NSApp.windows) hideWindow(w);
    NSWindow *w = MainWindow();
    if ([cmd isEqualToString:@"wait"]) {
        delay = p[1].doubleValue;
    } else if ([cmd isEqualToString:@"pick"]) {
        Pick = p[1].intValue;
        PickTitle = nil;
        L(@"pick %d", Pick);
    } else if ([cmd isEqualToString:@"picktitle"]) {
        PickTitle = [[line substringFromIndex:10] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        L(@"picktitle %@", PickTitle);
    } else if ([cmd isEqualToString:@"sheet"]) {
        // `sheet on` / `sheet off`: the steps that follow act on the picked window's attached sheet (snap, ax, clicklabel to dismiss it) or on the window again.
        OnSheet = [p[1] isEqualToString:@"on"];
        L(@"sheet %@: %@", p[1], w.attachedSheet ? NSStringFromClass([w.attachedSheet class]) : @"no sheet attached");
    } else if ([cmd isEqualToString:@"key"]) {
        if (w) { [w makeKeyWindow]; L(@"key: keyWindow=%d NSApp.keyWindow=%@ main=%d", w.isKeyWindow, NSApp.keyWindow ? @"set" : @"nil", w.isMainWindow); }
    } else if ([cmd isEqualToString:@"size"]) {
        if (w) { [w setContentSize:NSMakeSize(p[1].doubleValue, p[2].doubleValue)]; [w setFrameOrigin:NSMakePoint(40, 40)]; L(@"size now %@", NSStringFromRect(w.contentView.bounds)); }
    } else if ([cmd isEqualToString:@"snap"]) {
        if (w) Snap(w.contentView, p[1]); else L(@"snap %@: no window", p[1]);
    } else if ([cmd isEqualToString:@"frame"]) {
        NSView *b = w ? FindView(w.contentView, @"BackdropHostView") : nil;
        if (b) PresentationFrame(b, p[1]); else L(@"frame %@: no BackdropHostView", p[1]);
    } else if ([cmd isEqualToString:@"motion"]) {
        NSView *b = w ? FindView(w.contentView, @"BackdropHostView") : nil;
        if (!b) L(@"motion: no BackdropHostView");
        else if ([p[1] isEqualToString:@"begin"]) { MotionView = b; MotionBefore = Positions(b.layer); L(@"motion begin %lu layers", (unsigned long)MotionBefore.count); }
        else if (MotionView) {
            NSArray<NSValue *> *after = Positions(MotionView.layer);
            int moved = 0;
            for (NSUInteger i = 0; i < MIN(after.count, MotionBefore.count); i++) {
                NSPoint a = MotionBefore[i].pointValue, c = after[i].pointValue;
                if (fabs(a.x - c.x) > 0.5 || fabs(a.y - c.y) > 0.5) moved++;
            }
            L(@"motion end: %d of %lu layers moved; backdrop view size %@ hitTest(center)=%@", moved, (unsigned long)after.count, NSStringFromSize(MotionView.bounds.size),
              [MotionView hitTest:NSMakePoint(NSMidX(MotionView.frame), NSMidY(MotionView.frame))] ? @"NOT nil" : @"nil");
        }
    } else if ([cmd isEqualToString:@"ax"]) {
        if (w) {
            [NSApp accessibilitySetValue:@YES forAttribute:@"AXEnhancedUserInterface"];
            int n = 0;
            DumpAX(w.contentView, w, 0, &n);
            L(@"ax total %d", n);
        }
    } else if ([cmd isEqualToString:@"menu"]) {
        int n = 0;
        DumpMenu(NSApp.mainMenu, @"", &n);
        L(@"menu total %d", n);
    } else if ([cmd isEqualToString:@"menuchoose"]) {
        // `menuchoose Review`: chooses that item in the toolbar menu of the picked window that offers it (a SwiftUI `Menu` button).
        NSString *title = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (w) ChooseInToolbarMenu(w, title); else L(@"menuchoose %@: no window", title);
        delay = 1.2;
    } else if ([cmd isEqualToString:@"move"]) {
        if (w) MoveTo(w, p[1].doubleValue, p[2].doubleValue);
    } else if ([cmd isEqualToString:@"click"]) {
        CGFloat x = p[1].doubleValue, y = p[2].doubleValue;
        if (w) {
            MoveTo(w, x, y);
            ClickAt(w, x, y, YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ClickAt(w, x, y, NO); });
        }
        delay = 0.2;
    } else if ([cmd isEqualToString:@"hit"]) {
        // `hit x y`: the view AppKit's hit test finds at that point and its superview chain.
        if (w) {
            NSView *cv = w.contentView;
            NSPoint pt = [cv convertPoint:NSMakePoint(p[1].doubleValue, cv.isFlipped ? p[2].doubleValue : cv.bounds.size.height - p[2].doubleValue) toView:nil];
            NSView *v = [w.contentView.superview hitTest:[w.contentView.superview convertPoint:pt fromView:nil]];
            NSMutableArray *chain = [NSMutableArray array];
            for (NSView *x = v; x && chain.count < 8; x = x.superview) [chain addObject:NSStringFromClass([x class])];
            L(@"hit %@,%@ -> %@", p[1], p[2], [chain componentsJoinedByString:@" < "]);
        }
    } else if ([cmd isEqualToString:@"clicklabel"] || [cmd isEqualToString:@"clickcontains"]) {
        // `clicklabel End-to-End QA`: clicks the first element with that accessibility label or title, wherever the layout put it.
        // `clickcontains BUG-124`: the same for the first element whose label or title contains the text (a row whose label is its texts put together).
        BOOL contains = [cmd isEqualToString:@"clickcontains"];
        NSString *name = [[line substringFromIndex:cmd.length + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (w) {
            [NSApp accessibilitySetValue:@YES forAttribute:@"AXEnhancedUserInterface"];
            int n = 0; CGPoint c = CGPointZero;
            if (FindAX(w.contentView, w, name, contains, 0, &n, &c)) {
                L(@"clicklabel %@ at %.0f,%.0f", name, c.x, c.y);
                MoveTo(w, c.x, c.y);
                ClickAt(w, c.x, c.y, YES);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ClickAt(w, c.x, c.y, NO); });
            } else L(@"clicklabel %@: not found", name);
        }
        delay = 0.5;
    } else if ([cmd isEqualToString:@"cmdkey"]) {
        // `cmdkey 8` presses ⌘8 in the picked window (menu and .keyboardShortcut equivalents).
        if (w && p.count > 1) {
            NSString *c = p[1];
            NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
                                         timestamp:[NSProcessInfo processInfo].systemUptime windowNumber:w.windowNumber context:nil
                                        characters:c charactersIgnoringModifiers:c isARepeat:NO keyCode:0];
            // The main menu owns the key equivalents of `.keyboardShortcut` commands; an accessory-policy app does not route a key event to it by itself.
            if (![NSApp.mainMenu performKeyEquivalent:e]) [NSApp sendEvent:e];
        }
        delay = 0.3;
    } else if ([cmd isEqualToString:@"drag"]) {
        // `drag x1 y1 x2 y2`: mouse down at the first point, five drags towards the second, mouse up (window content coordinates, top-left origin).
        if (w && p.count > 4) {
            CGFloat x1 = p[1].doubleValue, y1 = p[2].doubleValue, x2 = p[3].doubleValue, y2 = p[4].doubleValue;
            NSView *cv = w.contentView;
            NSPoint (^pt)(CGFloat, CGFloat) = ^NSPoint(CGFloat x, CGFloat yTop) {
                return [cv convertPoint:NSMakePoint(x, cv.isFlipped ? yTop : cv.bounds.size.height - yTop) toView:nil];
            };
            void (^send)(NSEventType, CGFloat, CGFloat, CGFloat) = ^(NSEventType type, CGFloat x, CGFloat y, CGFloat pressure) {
                NSEvent *e = [NSEvent mouseEventWithType:type location:pt(x, y) modifierFlags:0 timestamp:[NSProcessInfo processInfo].systemUptime
                                            windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:pressure];
                [w sendEvent:e];
            };
            // The events are spread over the run loop: a SwiftUI drag gesture only sees them when each is delivered in its own turn.
            MoveTo(w, x1, y1);
            send(NSEventTypeLeftMouseDown, x1, y1, 1);
            for (int i = 1; i <= 5; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * i * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    send(NSEventTypeLeftMouseDragged, x1 + (x2 - x1) * i / 5, y1 + (y2 - y1) * i / 5, 1);
                });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ send(NSEventTypeLeftMouseUp, x2, y2, 0); });
        }
        delay = 0.8;
    } else if ([cmd isEqualToString:@"windows"]) {
        for (NSWindow *x in NSApp.windows)
            L(@"window %@ title='%@' visible=%d alpha=%.1f sheet=%d frame=%@ attachedSheet=%@", NSStringFromClass([x class]), x.title, x.isVisible, x.alphaValue, x.isSheet,
              NSStringFromRect(x.frame), x.attachedSheet ? NSStringFromClass([x.attachedSheet class]) : @"-");
        L(@"modalWindow=%@ activationPolicy=%ld active=%d", NSApp.modalWindow ? NSStringFromClass([NSApp.modalWindow class]) : @"-", (long)NSApp.activationPolicy, NSApp.isActive);
    } else if ([cmd isEqualToString:@"openurl"]) {
        NSString *path = [[line substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        id d = NSApp.delegate;
        SEL sel = NSSelectorFromString(@"application:openURLs:");
        if ([d respondsToSelector:sel]) {
            L(@"openurl %@", path);
            [d application:NSApp openURLs:@[[NSURL fileURLWithPath:path]]];
        } else L(@"openurl: delegate %@ does not respond", NSStringFromClass([d class]));
    } else if ([cmd isEqualToString:@"close"]) {
        if (w) { L(@"close '%@'", w.title); [w performClose:nil]; } else L(@"close: no window");
        // The probe's app gets no events of its own, so the last one (which names this window) would stay NSApp.currentEvent and
        // keep the closed window alive: one empty event replaces it.
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0
                                         windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
    } else if ([cmd isEqualToString:@"fds"]) {
        NSString *part = [[line substringFromIndex:4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        int count = 0, limit = getdtablesize();
        char path[MAXPATHLEN];
        for (int fd = 0; fd < limit; fd++)
            if (fcntl(fd, F_GETPATH, path) == 0 && strstr(path, part.UTF8String)) { count++; L(@"  fd %d %s", fd, path); }
        L(@"fds '%@': %d open", part, count);
    } else if ([cmd isEqualToString:@"abortmodal"]) {
        if (NSApp.modalWindow) { L(@"aborting modal %@", NSStringFromClass([NSApp.modalWindow class])); [NSApp abortModal]; }
    } else if ([cmd isEqualToString:@"quit"]) {
        L(@"quit");
        _exit(0);
    } else {
        L(@"unknown step: %@", line);
    }
    Later(delay);
}

__attribute__((constructor)) static void Init(void) {
    const char *script = getenv("MV_PROBE_SCRIPT");
    const char *out = getenv("MV_PROBE_OUT");
    if (!script || !out) return;
    // Child processes of the app (the indexer, MCP servers) inherit the environment: only the GUI process is probed.
    for (NSString *a in [NSProcessInfo processInfo].arguments) if ([a hasPrefix:@"--"]) return;
    // So do the applications it launches (the QA native player starts an application of its own, through Launch Services, with this environment):
    // their windows must stay visible to the player's pictures and they must not run the script.
    if (strcmp(getprogname(), "MarkView") != 0) return;
    OutDir = [NSString stringWithUTF8String:out];
    [[NSFileManager defaultManager] createDirectoryAtPath:OutDir withIntermediateDirectories:YES attributes:nil error:nil];
    LogF = fopen([[OutDir stringByAppendingPathComponent:@"log.txt"] UTF8String], "w");
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:script] encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *l in [text componentsSeparatedByString:@"\n"]) if (l.length && ![l hasPrefix:@"#"]) [lines addObject:l];
    Script = lines;

    Method mA = class_getInstanceMethod([NSWindow class], @selector(initWithContentRect:styleMask:backing:defer:));
    origInitA = (void *)method_getImplementation(mA);
    method_setImplementation(mA, (IMP)hookInitA);
    Method mB = class_getInstanceMethod([NSWindow class], @selector(initWithContentRect:styleMask:backing:defer:screen:));
    origInitB = (void *)method_getImplementation(mB);
    method_setImplementation(mB, (IMP)hookInitB);

    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        L(@"launched, %lu steps", (unsigned long)Script.count);
        Later(1.0);
    }];
    // Whatever happens, the probe never outlives its script by more than a minute.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (getenv("MV_PROBE_SECONDS") ? atoi(getenv("MV_PROBE_SECONDS")) : 90) * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ L(@"watchdog exit"); _exit(3); });
}
