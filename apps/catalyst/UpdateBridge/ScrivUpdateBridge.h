#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Foundation-only ABI. Catalyst never links AppKit or Sparkle; the native bundle does.
typedef void (^ScrivUpdateReply)(NSString *choice);
typedef void (^ScrivUpdateEvents)(NSDictionary<NSString *, id> *event, ScrivUpdateReply _Nullable reply);
// willRelaunch requires saving AND removing the updater/Settings modal chain
// before completion. A download-only preparation must leave presentation intact.
typedef void (^ScrivUpdatePreparation)(BOOL willRelaunch, void (^completion)(NSError * _Nullable error));
@protocol ScrivUpdatePlugin <NSObject>
- (instancetype)init;
- (void)configureWithEvents:(ScrivUpdateEvents)events prepare:(ScrivUpdatePreparation)prepare NS_SWIFT_NAME(configure(events:prepare:));
- (void)checkForUpdates;
@end
// A native adapter owns named XPC and Security APIs unavailable to Catalyst.
// This Foundation-only protocol carries no secret in logs, URLs or arguments.
@protocol ScrivRuntimeBootstrapAdapter <NSObject>
- (instancetype)init;
- (void)connectAfterUserConsent:(BOOL)approved completion:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion NS_SWIFT_NAME(connectAfterUserConsent(_:completion:));
- (void)disconnect;
@end
NS_ASSUME_NONNULL_END
