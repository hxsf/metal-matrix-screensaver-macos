#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>

@interface LegacyPreviewController : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) ScreenSaverView *saverView;
@property(nonatomic, copy) NSString *outputPath;
@property(nonatomic) NSTimeInterval startedAt;
@property(nonatomic) NSTimeInterval captureDelay;
@end

@implementation LegacyPreviewController

- (instancetype)initWithOutputPath:(NSString *)outputPath captureDelay:(NSTimeInterval)captureDelay {
    self = [super init];
    if (self) {
        _outputPath = [outputPath copy];
        _captureDelay = captureDelay;
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    NSString *bundlePath = [[[NSFileManager defaultManager] currentDirectoryPath]
        stringByAppendingPathComponent:@"GLMatrix.saver"];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (!bundle || ![bundle load]) {
        NSLog(@"Failed to load legacy saver bundle at %@", bundlePath);
        [NSApp terminate:self];
        return;
    }

    Class principalClass = [bundle principalClass];
    if (![principalClass isSubclassOfClass:[ScreenSaverView class]]) {
        NSLog(@"Principal class %@ is not a ScreenSaverView", principalClass);
        [NSApp terminate:self];
        return;
    }

    NSArray<NSString *> *moduleNames = @[
        @"com.nwwnetwork.MatrixSaver",
        @"matrixsaver",
        @"MatrixSaver"
    ];
    for (NSString *moduleName in moduleNames) {
        ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:moduleName];
        [defaults setInteger:30000 forKey:@"delay"];
        [defaults setInteger:100 forKey:@"density"];
        [defaults setFloat:1.0f forKey:@"speed"];
        [defaults setObject:@"matrix" forKey:@"mode"];
        [defaults setBool:YES forKey:@"fog"];
        [defaults setBool:YES forKey:@"waves"];
        [defaults setBool:NO forKey:@"rotate"];
        [defaults setBool:YES forKey:@"tex"];
        [defaults setBool:NO forKey:@"wire"];
        [defaults setBool:NO forKey:@"showfps"];
        [defaults synchronize];
    }

    NSRect frame = NSMakeRect(0, 0, 632, 408);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.backgroundColor = [NSColor blackColor];
    [self.window center];

    self.saverView = [[principalClass alloc] initWithFrame:frame isPreview:NO];
    self.saverView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.saverView.animationTimeInterval = 1.0 / 30.0;
    self.window.contentView = self.saverView;

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.saverView startAnimation];
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];

    [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                     target:self
                                   selector:@selector(tick:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    [self.saverView animateOneFrame];

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.startedAt;
    if (elapsed < self.captureDelay) {
        return;
    }

    [timer invalidate];
    [self saveWindowImage];
    [self.saverView stopAnimation];
    [NSApp terminate:self];
}

- (void)saveWindowImage {
    CGWindowID windowID = (CGWindowID)self.window.windowNumber;
    CGImageRef image = CGWindowListCreateImage(CGRectNull,
                                               kCGWindowListOptionIncludingWindow,
                                               windowID,
                                               kCGWindowImageBoundsIgnoreFraming);
    if (!image) {
        NSLog(@"Failed to capture legacy preview window");
        return;
    }

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    BOOL ok = [png writeToFile:self.outputPath atomically:YES];
    NSLog(@"%@ %@", ok ? @"Wrote" : @"Failed to write", self.outputPath);
    CGImageRelease(image);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *outputPath = argc > 1
            ? [NSString stringWithUTF8String:argv[1]]
            : [[[NSFileManager defaultManager] currentDirectoryPath]
                stringByAppendingPathComponent:@"dist/legacy-glmatrix-preview.png"];
        NSTimeInterval delay = argc > 2 ? atof(argv[2]) : 8.0;

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        LegacyPreviewController *controller = [[LegacyPreviewController alloc]
            initWithOutputPath:outputPath
                  captureDelay:delay];
        app.delegate = (id<NSApplicationDelegate>)controller;
        [app run];
    }
    return 0;
}
