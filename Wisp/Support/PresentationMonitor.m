#import "PresentationMonitor.h"

// macOS has no public host virtual-monitor constructor. Isolate this optional
// CoreGraphics ABI here and check the selectors before attaching any display.
// Interface reference: Chromium ui/display/mac/test/virtual_display_mac_util.mm.
@interface WispDisplayDescriptor : NSObject
@property(copy) NSString *name;
@property(strong) dispatch_queue_t queue;
@property uint32_t maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface WispDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)rate;
@end
@interface WispDisplaySettings : NSObject
@property(copy) NSArray *modes;
@end
@interface WispVirtualMonitor : NSObject
- (instancetype)initWithDescriptor:(WispDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(WispDisplaySettings *)settings;
@property(readonly) CGDirectDisplayID displayID;
@end

@implementation PresentationMonitor {
    WispVirtualMonitor *_monitor;
}
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height {
    self = [super init];
    if (!self) return nil;
    Class descriptorType = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeType = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsType = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayType = NSClassFromString(@"CGVirtualDisplay");
    if (![modeType instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)] ||
        ![settingsType instancesRespondToSelector:@selector(setModes:)] ||
        ![displayType instancesRespondToSelector:@selector(initWithDescriptor:)] ||
        ![displayType instancesRespondToSelector:@selector(applySettings:)] ||
        ![displayType instancesRespondToSelector:@selector(displayID)]) return nil;

    WispDisplayDescriptor *descriptor = [[descriptorType alloc] init];
    for (NSString *setter in @[@"setName:", @"setQueue:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
                               @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setSizeInMillimeters:",
                               @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:"]) {
        if (![descriptor respondsToSelector:NSSelectorFromString(setter)]) return nil;
    }
    descriptor.name = @"Wisp Presentation";
    descriptor.queue = dispatch_get_main_queue();
    descriptor.vendorID = 0x5753;
    descriptor.productID = 1;
    descriptor.serialNum = 1;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.25, height * 0.25);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    WispDisplayMode *mode = [[modeType alloc] initWithWidth:width height:height refreshRate:60];
    if (!mode) return nil;
    WispDisplaySettings *settings = [[settingsType alloc] init];
    settings.modes = @[mode];
    _monitor = [[displayType alloc] initWithDescriptor:descriptor];
    if (![_monitor applySettings:settings] || !_monitor.displayID) return nil;
    return self;
}
- (CGDirectDisplayID)displayID { return _monitor.displayID; }
@end
