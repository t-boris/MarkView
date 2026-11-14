// Copy of tools/tests/app-probe/mvprobe.m with the steps the Cockpit end-to-end checks need (selectors, setting text,
// pressing buttons in sheets, waiting for a label or a file). Injected into a COPY of the Debug MarkView app (own bundle id, own
// HOME): every window is fully transparent and click-through for the window server, a script of steps runs on the main queue,
// and snapshots and measurements go to MV_PROBE_OUT. Nothing here is shown on the screen.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

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
static NSWindow *MainWindow(void) {
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
static BOOL FindAX(id el, NSWindow *w, NSString *name, int depth, int *count, CGPoint *centre) {
    if (depth > 14 || *count > 1500) return NO;
    NSArray *kids = [el respondsToSelector:@selector(accessibilityChildren)] ? [el accessibilityChildren] : nil;
    for (id k in kids) {
        (*count)++;
        // SwiftUI hands out attributed strings for some labels.
        id label = [k respondsToSelector:@selector(accessibilityLabel)] ? [k accessibilityLabel] : nil;
        id title = [k respondsToSelector:@selector(accessibilityTitle)] ? [k accessibilityTitle] : nil;
        if ([label isKindOfClass:NSAttributedString.class]) label = [label string];
        if ([title isKindOfClass:NSAttributedString.class]) title = [title string];
        if ([label isEqual:name] || [title isEqual:name]) {
            NSRect wf = [w convertRectFromScreen:[k accessibilityFrame]];
            *centre = CGPointMake(NSMidX(wf), w.contentView.bounds.size.height - NSMidY(wf));
            return YES;
        }
        if (FindAX(k, w, name, depth + 1, count, centre)) return YES;
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
    if (depth > 14 || *count > 400) return;
    NSArray *kids = nil;
    if ([el respondsToSelector:@selector(accessibilityChildren)]) kids = [el accessibilityChildren];
    for (id k in kids) {
        (*count)++;
        NSString *role = [k respondsToSelector:@selector(accessibilityRole)] ? [k accessibilityRole] : @"?";
        NSString *label = [k respondsToSelector:@selector(accessibilityLabel)] ? [k accessibilityLabel] : nil;
        NSString *title = [k respondsToSelector:@selector(accessibilityTitle)] ? [k accessibilityTitle] : nil;
        NSRect f = [k respondsToSelector:@selector(accessibilityFrame)] ? [k accessibilityFrame] : NSZeroRect;
        NSRect wf = [w convertRectFromScreen:f];
        CGFloat h = w.contentView.bounds.size.height;
        if (label.length || title.length || [role isEqualToString:@"AXButton"])
            L(@"ax %*s%@ label=%@ title=%@ x=%.0f y=%.0f w=%.0f h=%.0f", depth, "", role, label, title, wf.origin.x, h - wf.origin.y - wf.size.height, wf.size.width, wf.size.height);
        DumpAX(k, w, depth + 1, count);
    }
}


// ---- Selector based steps -----------------------------------------------------------------------------------------------
// Selectors: label:<exact label or title>, has:<substring of label, title or value>, role:<AXRole>[#n] (n-th of that role).

static NSString *Str(id v) {
    if ([v isKindOfClass:NSAttributedString.class]) return [v string];
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return nil;
}

static void Collect(id el, int depth, NSMutableArray *out) {
    if (depth > 40 || out.count > 8000) return;
    NSArray *kids = [el respondsToSelector:@selector(accessibilityChildren)] ? [el accessibilityChildren] : nil;
    for (id k in kids) {
        [out addObject:k];
        Collect(k, depth + 1, out);
    }
}

static NSArray *WindowElements(NSWindow *w) {
    if (!w) return @[];
    [NSApp accessibilitySetValue:@YES forAttribute:@"AXEnhancedUserInterface"];
    NSMutableArray *out = [NSMutableArray array];
    Collect(w.contentView, 0, out);
    return out;
}

static NSString *RoleOf(id k) { return [k respondsToSelector:@selector(accessibilityRole)] ? Str([k accessibilityRole]) : nil; }
static NSString *LabelOf(id k) { return [k respondsToSelector:@selector(accessibilityLabel)] ? Str([k accessibilityLabel]) : nil; }
static NSString *TitleOf(id k) { return [k respondsToSelector:@selector(accessibilityTitle)] ? Str([k accessibilityTitle]) : nil; }
static NSString *ValueOf(id k) { return [k respondsToSelector:@selector(accessibilityValue)] ? Str([k accessibilityValue]) : nil; }

static id Select(NSArray *elements, NSString *selector) {
    NSRange colon = [selector rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    NSString *kind = [selector substringToIndex:colon.location], *arg = [selector substringFromIndex:colon.location + 1];
    int index = 0;
    if ([kind isEqualToString:@"role"]) {
        NSRange hash = [arg rangeOfString:@"#"];
        if (hash.location != NSNotFound) { index = [[arg substringFromIndex:hash.location + 1] intValue]; arg = [arg substringToIndex:hash.location]; }
    }
    int seen = 0;
    for (id k in elements) {
        NSString *l = LabelOf(k), *t = TitleOf(k), *v = ValueOf(k), *r = RoleOf(k);
        BOOL hit = NO;
        if ([kind isEqualToString:@"label"]) hit = [l isEqualToString:arg] || [t isEqualToString:arg];
        else if ([kind isEqualToString:@"has"]) hit = [l containsString:arg] || [t containsString:arg] || [v containsString:arg];
        else if ([kind isEqualToString:@"role"]) hit = [r isEqualToString:arg];
        if (hit && seen++ == index) return k;
    }
    return nil;
}

/// Windows to search for a selector: the picked one, its sheet, then every other window (alerts and panels).
static NSArray<NSWindow *> *SearchWindows(NSWindow *picked) {
    NSMutableArray *a = [NSMutableArray array];
    if (picked.attachedSheet) [a addObject:picked.attachedSheet];
    if (picked) [a addObject:picked];
    for (NSWindow *x in NSApp.windows) if (![a containsObject:x] && x.contentView) [a addObject:x];
    return a;
}

static id FindAnywhere(NSWindow *picked, NSString *selector, NSWindow **foundIn) {
    for (NSWindow *x in SearchWindows(picked)) {
        id k = Select(WindowElements(x), selector);
        if (k) { if (foundIn) *foundIn = x; return k; }
    }
    return nil;
}

static void PressElement(id k, NSWindow *w) {
    NSRect wf = [w convertRectFromScreen:[k accessibilityFrame]];
    CGFloat x = NSMidX(wf), y = w.contentView.bounds.size.height - NSMidY(wf);
    MoveTo(w, x, y);
    ClickAt(w, x, y, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ClickAt(w, x, y, NO); });
}


static void CollectViews(NSView *root, Class cls, NSMutableArray *out) {
    if ([root isKindOfClass:cls]) [out addObject:root];
    for (NSView *v in root.subviews) CollectViews(v, cls, out);
}

static NSDate *WaitDeadline;

static void RunNext(void);

static void Later(NSTimeInterval s) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ RunNext(); });
}

static void RunNext(void) {
    if (Step >= Script.count) { L(@"script finished"); return; }
    NSString *line = Script[Step++];
    NSArray<NSString *> *p = [line componentsSeparatedByString:@" "];
    NSString *cmd = p.firstObject;
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
    } else if ([cmd isEqualToString:@"clicklabel"]) {
        // `clicklabel End-to-End QA`: clicks the first element with that accessibility label or title, wherever the layout put it.
        NSString *name = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (w) {
            [NSApp accessibilitySetValue:@YES forAttribute:@"AXEnhancedUserInterface"];
            int n = 0; CGPoint c = CGPointZero;
            if (FindAX(w.contentView, w, name, 0, &n, &c)) {
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
    } else if ([cmd isEqualToString:@"dump"]) {
        // `dump <file>`: every accessibility element of the picked window and its sheet, one per line.
        NSString *path = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableString *text = [NSMutableString string];
        for (NSWindow *x in SearchWindows(w)) {
            [text appendFormat:@"== window %@ '%@' sheet=%d\n", NSStringFromClass([x class]), x.title, x.isSheet];
            for (id k in WindowElements(x)) {
                NSString *r = RoleOf(k), *l = LabelOf(k), *t = TitleOf(k), *v = ValueOf(k);
                BOOL input = [r isEqualToString:@"AXTextField"] || [r isEqualToString:@"AXTextArea"] || [r isEqualToString:@"AXPopUpButton"];
                if (!(l.length || t.length || v.length) && !input) continue;
                NSString *ph = [k respondsToSelector:@selector(accessibilityPlaceholderValue)] ? Str([k accessibilityPlaceholderValue]) : nil;
                [text appendFormat:@"%@ | label=%@ | title=%@ | value=%@%@\n", r, l, t, v, ph.length ? [NSString stringWithFormat:@" | placeholder=%@", ph] : @""];
            }
        }
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        L(@"dump %@ (%lu chars)", path.lastPathComponent, (unsigned long)text.length);
    } else if ([cmd isEqualToString:@"press"]) {
        // `press <selector>`: a real click on the first element the selector finds (the picked window, its sheet, any window).
        NSString *sel = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSWindow *in = nil;
        id k = FindAnywhere(w, sel, &in);
        if (k) {
            // The accessibility press works for a control that is scrolled out of view; a click needs it on the screen.
            BOOL pressed = [k respondsToSelector:@selector(accessibilityPerformPress)] && [k accessibilityPerformPress];
            L(@"press %@ ok via %@ (value before: %@)", sel, pressed ? @"AXPress" : @"click", ValueOf(k));
            if (!pressed) PressElement(k, in);
        } else L(@"press %@: NOT FOUND", sel);
        delay = 0.6;
    } else if ([cmd isEqualToString:@"value"]) {
        NSString *sel = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        id k = FindAnywhere(w, sel, NULL);
        L(@"value %@ = %@", sel, k ? (ValueOf(k) ?: @"(nil)") : @"NOT FOUND");
    } else if ([cmd isEqualToString:@"settext"]) {
        // `settext <selector> | <text>`: sets the value of a text field or text editor through accessibility, then reads it back.
        NSString *rest = [line substringFromIndex:8];
        NSRange bar = [rest rangeOfString:@" | "];
        NSString *sel = bar.location == NSNotFound ? rest : [rest substringToIndex:bar.location];
        NSString *text = bar.location == NSNotFound ? @"" : [rest substringFromIndex:bar.location + 3];
        id k = FindAnywhere(w, sel, NULL);
        if (!k) L(@"settext %@: NOT FOUND", sel);
        else {
            if ([k respondsToSelector:@selector(setAccessibilityValue:)]) [k setAccessibilityValue:text];
            else L(@"settext %@: element does not accept a value", sel);
            L(@"settext %@ -> read back '%@'", sel, ValueOf(k));
        }
        delay = 0.5;
    } else if ([cmd isEqualToString:@"typefocus"]) {
        // `typefocus <selector> | <text>`: click the element to focus it, then insert the text into the first responder.
        NSString *rest = [line substringFromIndex:10];
        NSRange bar = [rest rangeOfString:@" | "];
        NSString *sel = [rest substringToIndex:bar.location], *text = [rest substringFromIndex:bar.location + 3];
        NSWindow *in = nil;
        id k = FindAnywhere(w, sel, &in);
        if (!k) L(@"typefocus %@: NOT FOUND", sel);
        else {
            [in makeKeyWindow];
            PressElement(k, in);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                id r = in.firstResponder;
                L(@"typefocus %@: first responder %@", sel, NSStringFromClass([r class]));
                if ([r respondsToSelector:@selector(insertText:replacementRange:)])
                    [r insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
                else if ([r respondsToSelector:@selector(insertText:)]) [r insertText:text];
                L(@"typefocus %@ -> read back '%@'", sel, ValueOf(k));
            });
        }
        delay = 1.0;
    } else if ([cmd isEqualToString:@"waitfor"] || [cmd isEqualToString:@"waitgone"]) {
        // `waitfor <seconds> <selector>`: continues when the selector finds an element (waitgone: when it finds none), or after the time.
        BOOL gone = [cmd isEqualToString:@"waitgone"];
        NSRange sp = [[line substringFromIndex:cmd.length + 1] rangeOfString:@" "];
        NSString *rest = [line substringFromIndex:cmd.length + 1];
        NSTimeInterval secs = [[rest substringToIndex:sp.location] doubleValue];
        NSString *sel = [rest substringFromIndex:sp.location + 1];
        if (!WaitDeadline) WaitDeadline = [NSDate dateWithTimeIntervalSinceNow:secs];
        BOOL found = FindAnywhere(w, sel, NULL) != nil;
        if (found != gone) { L(@"%@ %@: satisfied (%.0fs left)", cmd, sel, [WaitDeadline timeIntervalSinceNow]); WaitDeadline = nil; }
        else if ([WaitDeadline timeIntervalSinceNow] < 0) { L(@"%@ %@: TIMEOUT", cmd, sel); WaitDeadline = nil; }
        else { Step--; delay = 0.5; }
    } else if ([cmd isEqualToString:@"waitfile"]) {
        // `waitfile <seconds> <path>`
        NSString *rest = [line substringFromIndex:9];
        NSRange sp = [rest rangeOfString:@" "];
        NSTimeInterval secs = [[rest substringToIndex:sp.location] doubleValue];
        NSString *path = [rest substringFromIndex:sp.location + 1];
        if (!WaitDeadline) WaitDeadline = [NSDate dateWithTimeIntervalSinceNow:secs];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) { L(@"waitfile %@: present", path.lastPathComponent); WaitDeadline = nil; }
        else if ([WaitDeadline timeIntervalSinceNow] < 0) { L(@"waitfile %@: TIMEOUT", path.lastPathComponent); WaitDeadline = nil; }
        else { Step--; delay = 0.5; }
    } else if ([cmd isEqualToString:@"popup"]) {
        // `popup <n> <item>`: picks item `item` (0-based) of the n-th pop-up button of the picked window (a SwiftUI Picker), as a click would.
        NSMutableArray *popups = [NSMutableArray array];
        if (w) CollectViews(w.contentView, [NSPopUpButton class], popups);
        int n = p[1].intValue, item = p[2].intValue;
        if (n < (int)popups.count) {
            NSPopUpButton *b = popups[n];
            L(@"popup %d items: %@", n, [b.itemTitles componentsJoinedByString:@" | "]);
            if (item < b.numberOfItems) {
                [b selectItemAtIndex:item];
                [NSApp sendAction:b.action to:b.target from:b];
                L(@"popup %d -> %@", n, b.titleOfSelectedItem);
            } else L(@"popup %d: no item %d", n, item);
        } else L(@"popup %d: NOT FOUND (%lu pop-ups)", n, (unsigned long)popups.count);
        delay = 0.6;
    } else if ([cmd isEqualToString:@"terminate"]) {
        // A normal quit, so the app stops its own children (the Cockpit's Temporal server and Postgres); `_exit` only if it hangs.
        L(@"terminate");
        // Not from this main-queue block: quitting runs a nested loop, and the app's own quit work (Tasks on the main actor) cannot
        // run while a main-queue block is still being drained. A run-loop timer calls it instead; a global queue is the safety net.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ L(@"terminate timed out"); _exit(0); });
        [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.2];
        return;
    } else if ([cmd isEqualToString:@"log"]) {
        L(@"-- %@", [line substringFromIndex:4]);
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
