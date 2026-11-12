#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Foundation-only boundary. The Catalyst executable must not link AppKit.
// ScrivCLIAccessibility.bundle is a native macOS bundle whose principal class is
// ScrivCLIAccessibilityBridge. Every method independently enforces the test gate.
@protocol ScrivCLIAccessibility <NSObject>
- (instancetype)init;
- (NSArray<NSDictionary<NSString *, id> *> *)snapshot;
// Requires the exact path and label returned by the latest snapshot. A single
// public accessibilityPerformPress is attempted; dispatched is its BOOL result.
- (NSDictionary<NSString *, id> *)activateRequest:(NSDictionary<NSString *, id> *)request
    NS_SWIFT_NAME(activate(request:));
@end

NS_ASSUME_NONNULL_END
