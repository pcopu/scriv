// Isolated policy regression harness. Links the actual plug-in implementation,
// but never starts SPUUpdater, contacts a feed, or installs/launches an app.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import "../apps/catalyst/UpdateBridge/ScrivUpdateBridge.h"

@interface ScrivSparklePlugin : NSObject <ScrivUpdatePlugin, SPUUserDriver>
- (void)prepareAndReply:(void (^)(SPUUserUpdateChoice))reply;
@end

@interface PolicyEvents : NSObject
@property(nonatomic, copy) NSDictionary *lastEvent;
@property(nonatomic, copy) ScrivUpdateReply lastReply;
@property(nonatomic, strong) NSMutableArray<NSString *> *order;
@end
@implementation PolicyEvents
- (instancetype)init { if ((self = [super init])) _order = [NSMutableArray array]; return self; }
@end

// This deliberately invalid appcast fixture cannot pass download policy. It is
// not an alternate trusted host, signed release, or validation bypass.
@interface RejectedPolicyItem : NSObject
@end
@implementation RejectedPolicyItem
- (NSURL *)fileURL { return nil; }
- (NSString *)versionString { return @"1002"; }
@end

#define REQUIRE(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return NO; } } while (0)

static ScrivSparklePlugin *MakePlugin(PolicyEvents *events, ScrivUpdatePreparation prepare) {
    ScrivSparklePlugin *plugin = [ScrivSparklePlugin new];
    [plugin configureWithEvents:^(NSDictionary *event, ScrivUpdateReply reply) {
        events.lastEvent = event; events.lastReply = reply;
        [events.order addObject:event[@"phase"]];
    } prepare:prepare];
    return plugin;
}

static BOOL RejectedPolicyCancelsBeforeNotice(BOOL synchronousDismiss) {
    PolicyEvents *events = [PolicyEvents new];
    ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) { completion(nil); });
    __block NSUInteger responses = 0;
    __block SPUUserUpdateChoice choice = SPUUserUpdateChoiceInstall;
    [plugin showUpdateFoundWithAppcastItem:(SUAppcastItem *)[RejectedPolicyItem new] state:nil reply:^(SPUUserUpdateChoice value) {
        ++responses; choice = value; [events.order addObject:@"cancel-response"];
        if (synchronousDismiss) [plugin dismissUpdateInstallation];
    }];
    REQUIRE(responses == 1 && choice == SPUUserUpdateChoiceSkip);
    REQUIRE(([events.order isEqual:@[@"cancel-response", @"error"]]));
    REQUIRE(events.lastReply == nil); // No acknowledgement is needed to cancel.
    [plugin dismissUpdateInstallation];
    REQUIRE([events.lastEvent[@"phase"] isEqual:@"error"]);
    REQUIRE(responses == 1);
    return YES;
}

static BOOL FailedAndMissingSaveFenceCancelImmediately(void) {
    for (NSUInteger missing = 0; missing < 2; ++missing) {
        PolicyEvents *events = [PolicyEvents new];
        NSError *error = [NSError errorWithDomain:@"synthetic-save" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Synthetic unsaved edits"}];
        ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) { completion(error); completion(nil); });
        // Tests the defensive missing-provider branch without changing its ABI.
        if (missing) [plugin setValue:nil forKey:@"prepare"];
        __block NSUInteger responses = 0;
        __block SPUUserUpdateChoice choice = SPUUserUpdateChoiceInstall;
        [plugin prepareAndReply:^(SPUUserUpdateChoice value) {
            ++responses; choice = value; [events.order addObject:@"cancel-response"];
        }];
        REQUIRE(responses == 1 && choice == SPUUserUpdateChoiceSkip);
        REQUIRE(([events.order isEqual:@[@"saving", @"cancel-response", @"error"]]));
        REQUIRE(events.lastReply == nil);
        [plugin dismissUpdateInstallation];
        REQUIRE([events.lastEvent[@"phase"] isEqual:@"error"]);
    }
    return YES;
}

static BOOL SaveCompletionIsOneShotAndGenerationFenced(void) {
    for (NSUInteger dismissFirst = 0; dismissFirst < 2; ++dismissFirst) {
        PolicyEvents *events = [PolicyEvents new];
        __block void (^finish)(NSError *) = nil;
        ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) { finish = [completion copy]; });
        __block NSUInteger installs = 0;
        [plugin prepareAndReply:^(SPUUserUpdateChoice choice) { if (choice == SPUUserUpdateChoiceInstall) ++installs; }];
        REQUIRE(finish != nil && installs == 0);
        if (dismissFirst) [plugin dismissUpdateInstallation];
        finish(nil); finish(nil);
        REQUIRE(installs == (dismissFirst ? 0 : 1));
    }
    return YES;
}

static BOOL LaterCancelsPreparedInstallExactlyOnce(void) {
    PolicyEvents *events = [PolicyEvents new];
    __block NSUInteger preparations = 0;
    ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) { ++preparations; completion(nil); });
    __block NSUInteger responses = 0;
    __block SPUUserUpdateChoice choice = SPUUserUpdateChoiceInstall;
    [plugin showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice value) { ++responses; choice = value; }];
    ScrivUpdateReply action = events.lastReply;
    REQUIRE(action != nil);
    action(@"later"); action(@"later"); action(@"install");
    REQUIRE(responses == 1 && choice == SPUUserUpdateChoiceSkip && preparations == 0);
    return YES;
}

static BOOL DownloadCancelSurvivesProgressButNotNewPhase(void) {
    for (NSUInteger extracting = 0; extracting < 2; ++extracting) {
        PolicyEvents *events = [PolicyEvents new];
        ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) { completion(nil); });
        __block NSUInteger cancellations = 0;
        [plugin showDownloadInitiatedWithCancellation:^{ ++cancellations; }];
        ScrivUpdateReply cancel = events.lastReply;
        REQUIRE(cancel != nil);
        [plugin showDownloadDidReceiveExpectedContentLength:100];
        [plugin showDownloadDidReceiveDataOfLength:25];
        REQUIRE([events.lastEvent[@"phase"] isEqual:@"progress"]);
        if (extracting) [plugin showDownloadDidStartExtractingUpdate];
        cancel(@"cancel"); cancel(@"cancel");
        REQUIRE(cancellations == (extracting ? 0 : 1));
    }
    return YES;
}


static BOOL FinalInstallWaitsForRelaunchPreparation(void) {
    PolicyEvents *events = [PolicyEvents new];
    __block void (^finish)(NSError *) = nil;
    __block BOOL relaunch = NO;
    ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) {
        relaunch = willRelaunch; finish = [completion copy];
    });
    __block NSUInteger installs = 0;
    [plugin showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice) { if (choice == SPUUserUpdateChoiceInstall) ++installs; }];
    events.lastReply(@"install");
    REQUIRE(relaunch && finish != nil && installs == 0);
    REQUIRE([events.lastEvent[@"phase"] isEqual:@"saving"]);
    // The UIKit provider must not complete until the complete modal chain has
    // disappeared and the second durability check has passed.
    finish(nil); finish(nil);
    REQUIRE(installs == 1);
    return YES;
}


static BOOL FinalRelaunchFailureCancelsImmediately(void) {
    PolicyEvents *events = [PolicyEvents new];
    __block BOOL relaunch = NO;
    NSError *error = [NSError errorWithDomain:@"synthetic-handoff" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Modal handoff fixture failed"}];
    ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) {
        relaunch = willRelaunch; completion(error); completion(nil);
    });
    __block NSUInteger responses = 0;
    __block SPUUserUpdateChoice choice = SPUUserUpdateChoiceInstall;
    [plugin showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice value) { ++responses; choice = value; }];
    events.lastReply(@"install");
    REQUIRE(relaunch && responses == 1 && choice == SPUUserUpdateChoiceSkip);
    REQUIRE([events.lastEvent[@"phase"] isEqual:@"error"] && events.lastReply == nil);
    return YES;
}

static BOOL DownloadPreparationDoesNotDismissWindows(void) {
    PolicyEvents *events = [PolicyEvents new];
    __block BOOL relaunch = YES;
    ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) {
        relaunch = willRelaunch; completion(nil);
    });
    __block NSUInteger installs = 0;
    [plugin prepareAndReply:^(SPUUserUpdateChoice choice) { if (choice == SPUUserUpdateChoiceInstall) ++installs; }];
    REQUIRE(!relaunch && installs == 1);
    return YES;
}

static BOOL TerminationRetryIsExplicitAndOneShot(void) {
    PolicyEvents *events = [PolicyEvents new];
    __block void (^finish)(NSError *) = nil;
    __block NSUInteger preparations = 0, retries = 0;
    __block BOOL relaunch = NO;
    ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) {
        ++preparations; relaunch = willRelaunch; finish = [completion copy];
    });
    [plugin showInstallingUpdateWithApplicationTerminated:NO retryTerminatingApplication:^{ ++retries; }];
    REQUIRE([events.lastEvent[@"phase"] isEqual:@"waitingToQuit"] && events.lastReply == nil && retries == 0);
    [plugin showUpdateInFocus];
    REQUIRE([events.lastEvent[@"phase"] isEqual:@"retryQuit"]);
    ScrivUpdateReply keepWorking = events.lastReply;
    keepWorking(@"cancel"); keepWorking(@"install");
    REQUIRE(retries == 0 && preparations == 0 && [events.lastEvent[@"phase"] isEqual:@"dismiss"]);
    // Closing the retry notice is not cancellation. A fresh deliberate action
    // remains available, but never automatically invokes the retry closure.
    [plugin showUpdateInFocus];
    ScrivUpdateReply install = events.lastReply;
    install(@"install"); install(@"install");
    REQUIRE(relaunch && preparations == 1 && retries == 0 && finish != nil);
    finish(nil); finish(nil); install(@"install");
    REQUIRE(retries == 1 && [events.lastEvent[@"phase"] isEqual:@"waitingToQuit"]);
    return YES;
}

static BOOL LateTerminationRetryIsInvalidated(void) {
    for (NSUInteger terminated = 0; terminated < 2; ++terminated) {
        PolicyEvents *events = [PolicyEvents new];
        __block void (^finish)(NSError *) = nil;
        __block NSUInteger retries = 0;
        ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) { finish = [completion copy]; });
        [plugin showInstallingUpdateWithApplicationTerminated:NO retryTerminatingApplication:^{ ++retries; }];
        [plugin showUpdateInFocus];
        ScrivUpdateReply staleAction = events.lastReply;
        staleAction(@"install");
        if (terminated) [plugin showInstallingUpdateWithApplicationTerminated:YES retryTerminatingApplication:^{ ++retries; }];
        else [plugin dismissUpdateInstallation];
        finish(nil); staleAction(@"install");
        [plugin showUpdateInFocus];
        REQUIRE(retries == 0 && [events.lastEvent[@"phase"] isEqual:@"focus"]);
    }
    return YES;
}

static BOOL RetrySaveFailureDoesNotPretendToCancelPendingInstall(void) {
    for (NSUInteger missing = 0; missing < 2; ++missing) {
        PolicyEvents *events = [PolicyEvents new];
        __block NSUInteger retries = 0;
        NSError *error = [NSError errorWithDomain:@"synthetic-save" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unsaved fixture"}];
        ScrivSparklePlugin *plugin = MakePlugin(events, ^(BOOL willRelaunch, void (^completion)(NSError *)) { completion(error); completion(nil); });
        if (missing) [plugin setValue:nil forKey:@"prepare"];
        [plugin showInstallingUpdateWithApplicationTerminated:NO retryTerminatingApplication:^{ ++retries; }];
        [plugin showUpdateInFocus]; events.lastReply(@"install");
        REQUIRE(retries == 0 && [events.lastEvent[@"phase"] isEqual:@"retryBlocked"]);
        REQUIRE([events.lastEvent[@"message"] containsString:@"still prepared"]);
        REQUIRE([plugin valueForKey:@"cancellationMessage"] == nil);
        [plugin showUpdateInFocus];
        REQUIRE([events.lastEvent[@"phase"] isEqual:@"retryQuit"]);
    }
    return YES;
}

int main(void) {
    @autoreleasepool {
        if (!NSThread.isMainThread) return 2;
        if (!RejectedPolicyCancelsBeforeNotice(NO) || !RejectedPolicyCancelsBeforeNotice(YES)
            || !FailedAndMissingSaveFenceCancelImmediately() || !SaveCompletionIsOneShotAndGenerationFenced()
            || !LaterCancelsPreparedInstallExactlyOnce() || !DownloadCancelSurvivesProgressButNotNewPhase()
            || !FinalInstallWaitsForRelaunchPreparation() || !FinalRelaunchFailureCancelsImmediately()
            || !DownloadPreparationDoesNotDismissWindows()
            || !TerminationRetryIsExplicitAndOneShot() || !LateTerminationRetryIsInvalidated()
            || !RetrySaveFailureDoesNotPretendToCancelPendingInstall()) return 1;
        puts("PASS: actual plug-in cancellation/save-fence/modal-handoff/retry policy; no updater, feed, install or launch performed.");
    }
    return 0;
}
