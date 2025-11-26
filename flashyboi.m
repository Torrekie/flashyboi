#import <Availability.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <signal.h>

// Private API declarations
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 160000
@interface CALayer ()
@property (nonatomic, assign) BOOL wantsExtendedDynamicRangeContent;
@end
#endif

@interface CADisplayMode : NSObject
@property (nonatomic, assign, readonly) NSUInteger preferredScale;
@end

@interface CAContext : NSObject
@property (nonatomic, assign) CGFloat level;
@property (nonatomic, strong) CALayer *layer;
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
@end

extern const CFStringRef kCAContextDisplayable;

@interface CADisplay : NSObject
@property (nonatomic, assign, readonly) CGRect bounds;
@property (nonatomic, strong) CADisplayMode *currentMode;
+ (instancetype)mainDisplay;
@end

static volatile sig_atomic_t g_shouldStop = 0;
static void handle_sigint(int signo) {
    (void)signo;
    g_shouldStop = 1;
}

static void print_usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s <interval-ms> [limit]\n"
            "  <interval-ms>  : strobe interval in milliseconds (integer > 0)\n"
            "  [limit]        : optional limit. If it ends with 's' (e.g. 10s) it is seconds timeout.\n"
            "                   Otherwise if integer (e.g. 100) it is number of flashes (times EDR becomes visible).\n"
            "Examples:\n"
            "  %s 100           # strobe every 100ms until Ctrl+C\n"
            "  %s 500 10s       # strobe every 500ms, exit after 10 seconds\n"
            "  %s 200 100       # strobe every 200ms, exit after EDR shown 100 times\n",
            prog, prog, prog, prog);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            print_usage(argv[0]);
            return 1;
        }

        char *endptr = NULL;
        long interval_ms = strtol(argv[1], &endptr, 10);
        if (endptr == argv[1] || interval_ms <= 0) {
            fprintf(stderr, "Invalid interval-ms: %s\n", argv[1]);
            print_usage(argv[0]);
            return 1;
        }

        BOOL use_time_limit = NO;
        double time_limit_seconds = 0.0;
        BOOL use_count_limit = NO;
        uint64_t count_limit = 0;

        if (argc >= 3) {
            const char *lim = argv[2];
            size_t L = strlen(lim);
            if (L == 0) {
                // ignore
            } else {
                char last = lim[L-1];
                if (last == 's' || last == 'S') {
                    // seconds
                    char buf[64] = {0};
                    if (L-1 >= sizeof(buf)) {
                        fprintf(stderr, "time value too long\n");
                        return 1;
                    }
                    memcpy(buf, lim, L-1);
                    char *end2 = NULL;
                    double secs = strtod(buf, &end2);
                    if (end2 == buf || secs <= 0) {
                        fprintf(stderr, "Invalid time limit: %s\n", lim);
                        return 1;
                    }
                    use_time_limit = YES;
                    time_limit_seconds = secs;
                } else {
                    // try integer count
                    char *end3 = NULL;
                    long long cnt = strtoll(lim, &end3, 10);
                    if (end3 == lim || cnt <= 0) {
                        fprintf(stderr, "Invalid count limit: %s\n", lim);
                        return 1;
                    }
                    use_count_limit = YES;
                    count_limit = (uint64_t)cnt;
                }
            }
        }

        struct sigaction act;
        memset(&act, 0, sizeof(act));
        act.sa_handler = handle_sigint;
        sigaction(SIGINT, &act, NULL);

        CAContext *ctx = [CAContext remoteContextWithOptions:@{ (__bridge NSString*)kCAContextDisplayable : (__bridge id)kCFBooleanTrue }];
        if (!ctx) {
            fprintf(stderr, "Failed to create remote CAContext, check if com.apple.QuartzCore.displayable-context signed.\n");
            return 1;
        }
        ctx.level = 5000.0;

        CALayer *rootLayer = [CALayer layer];
        CGRect screenBounds = [CADisplay mainDisplay].bounds;
        rootLayer.frame = screenBounds;

        CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (!sRGB) sRGB = CGColorSpaceCreateDeviceRGB();
        CGFloat blackComponents[4] = {0.0, 0.0, 0.0, 1.0};
        CGColorRef black = CGColorCreate(sRGB, blackComponents);
        rootLayer.backgroundColor = black;
        CGColorRelease(black);
        CGColorSpaceRelease(sRGB);

        ctx.layer = rootLayer;

        CAMetalLayer *edrLayer = [CAMetalLayer layer];
        edrLayer.frame = screenBounds;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "No Metal device available\n");
            return 1;
        }
        edrLayer.device = device;
        edrLayer.pixelFormat = MTLPixelFormatRGBA16Float;
        edrLayer.framebufferOnly = NO;
        edrLayer.wantsExtendedDynamicRangeContent = YES;

        CGColorSpaceRef edrCS = NULL;
        if (@available(iOS 12.3, *)) {
            edrCS = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
        } else {
            edrCS = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
        }
        if (edrCS) {
            edrLayer.colorspace = edrCS;
            CGColorSpaceRelease(edrCS);
        }

        edrLayer.hidden = YES;
        [rootLayer addSublayer:edrLayer];

        id<MTLCommandQueue> cmdQueue = [device newCommandQueue];
        if (!cmdQueue) {
            fprintf(stderr, "Failed to create Metal command queue\n");
            return 1;
        }

        dispatch_queue_t q = dispatch_get_main_queue();
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        if (!timer) {
            fprintf(stderr, "Failed to create timer\n");
            return 1;
        }

        uint64_t interval_ns = (uint64_t)interval_ms * NSEC_PER_MSEC;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, interval_ns), interval_ns, NSEC_PER_MSEC * 5);

        __weak CAMetalLayer *weakEDR = edrLayer;
        __block BOOL visible = NO;
        __block uint64_t shown_count = 0;
        __block CFAbsoluteTime start_time = CFAbsoluteTimeGetCurrent();

        dispatch_source_set_event_handler(timer, ^{
            if (g_shouldStop) {
                dispatch_source_cancel(timer);
                CFRunLoopStop(CFRunLoopGetMain());
                return;
            }
            if (use_time_limit) {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - start_time >= time_limit_seconds) {
                    dispatch_source_cancel(timer);
                    CFRunLoopStop(CFRunLoopGetMain());
                    return;
                }
            }

            CAMetalLayer *ml = weakEDR;
            if (!ml) {
                // nothing to do
                return;
            }

            visible = !visible;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ml.hidden = !visible;
            [CATransaction commit];

            if (visible) {
                shown_count++;
                // count limit check
                if (use_count_limit && shown_count >= count_limit) {
                    // We still show this one, then exit
                    // Render and then schedule stop after presenting
                }

                id<CAMetalDrawable> drawable = [ml nextDrawable];
                if (drawable) {
                    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = drawable.texture;
                    rp.colorAttachments[0].loadAction = MTLLoadActionClear;

                    double headroom = 2.0; // extra-bright
                    rp.colorAttachments[0].clearColor = MTLClearColorMake(headroom, headroom, headroom, 1.0);
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;

                    id<MTLCommandBuffer> cb = [cmdQueue commandBuffer];
                    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                    [enc endEncoding];
                    [cb presentDrawable:drawable];
                    [cb commit];
                } else {
                    // drawable unavailable this tick. it's fine, we tried
                }

                if (use_count_limit && shown_count >= count_limit) {
                    // schedule cancellation on the main queue to allow the present to occur
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 20), dispatch_get_main_queue(), ^{
                        if (!dispatch_source_testcancel(timer)) {
                            dispatch_source_cancel(timer);
                        }
                        CFRunLoopStop(CFRunLoopGetMain());
                    });
                    return;
                }
            } else {
                // nothing to render
            }
        });

        dispatch_source_set_cancel_handler(timer, ^{
            // nothing special to free; ARC will tear down Metal objects
        });

        dispatch_resume(timer);

        printf("EDR strobe running (interval %ld ms). Press Ctrl+C to stop.\n", interval_ms);
        if (use_time_limit) {
            printf("Time limit: %.3f seconds\n", time_limit_seconds);
        } else if (use_count_limit) {
            printf("Count limit: %llu flashes\n", (unsigned long long)count_limit);
        }

        CFRunLoopRun();

        if (timer && !dispatch_source_testcancel(timer)) {
            dispatch_source_cancel(timer);
        }
        ctx.layer = nil;

        printf("Exiting\n");
    }
    return 0;
}
