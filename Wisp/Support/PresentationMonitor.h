#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Releasing the owner disconnects its extended display.
@interface PresentationMonitor : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height;
@end
NS_ASSUME_NONNULL_END
