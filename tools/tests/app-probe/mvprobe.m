// Probe injected into a COPY of the Debug MarkView app (own bundle id, own HOME). It keeps every window fully
// transparent and click-through for the window server, runs a script of steps on the main queue, and writes
// snapshots and measurements to MV_PROBE_OUT. Nothing here is shown on the screen.
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
static NSWindow *MainWindow(void) {
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
        L(@"pick %d", Pick);
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ L(@"watchdog exit"); _exit(3); });
}
