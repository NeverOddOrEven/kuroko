// Declarations for CoreGraphics' private virtual display classes.
// These ship in CoreGraphics.framework but have no public header.
// Same surface used by DeskPad and BetterDisplay.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nullable) dispatch_queue_t queue;
@property (retain, nullable) NSString *name;
@property unsigned int maxPixelsWide;
@property unsigned int maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property unsigned int productID;
@property unsigned int vendorID;
@property unsigned int serialNum;
@property (copy, nullable) void (^terminationHandler)(id _Nullable display, id _Nullable reason);
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly) unsigned int width;
@property (readonly) unsigned int height;
@property (readonly) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
