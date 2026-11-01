#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <Sparkle/Sparkle.h>
#import "../UpdateBridge/ScrivUpdateBridge.h"

// The only AppKit boundary is this native macOS bundle. No shell, daemon,
// companion pairing, privileged custom installer, or Catalyst Process shim.
@interface ScrivSparklePlugin : NSObject <ScrivUpdatePlugin, SPUUserDriver, SPUUpdaterDelegate>
@property(nonatomic, strong) SPUUpdater *updater;
@property(nonatomic, copy) ScrivUpdateEvents events;
@property(nonatomic, copy) ScrivUpdatePreparation prepare;
@property(nonatomic) uint64_t expectedBytes;
@property(nonatomic) uint64_t receivedBytes;
@property(nonatomic) NSUInteger eventGeneration;
@property(nonatomic, copy) NSString *cancellationMessage;
@property(nonatomic, copy) void (^retryTermination)(void);
@end

@implementation ScrivSparklePlugin
- (NSError *)failure:(NSString *)message {
    return [NSError errorWithDomain:@"app.scriv.updates" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
- (NSError *)validateHost {
    NSBundle *host = NSBundle.mainBundle;
    NSString *team = [host objectForInfoDictionaryKey:@"ScrivUpdateTeamIdentifier"];
    NSData *key = [[NSData alloc] initWithBase64EncodedString:[host objectForInfoDictionaryKey:@"SUPublicEDKey"] ?: @"" options:0];
    if (key.length != 32 || team.length != 10 || [team rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet]].location != NSNotFound)
        return [self failure:@"Updates will be available after Scriv’s release signing is configured. This development build was not changed."];
    NSDictionary *info = host.infoDictionary;
    if (![self pinnedFeedURL]) return [self failure:@"This build has an invalid signed update-channel configuration."];
    if (![info[@"SURequireSignedFeed"] boolValue] || ![info[@"SUVerifyUpdateBeforeExtraction"] boolValue] || !info[@"SUSignedFeedFailureExpirationInterval"] || [info[@"SUSignedFeedFailureExpirationInterval"] doubleValue] != 0 || [info[@"SUAllowsAutomaticUpdates"] boolValue])
        return [self failure:@"This build is missing the required update security policy."];
    NSString *rule = [NSString stringWithFormat:@"anchor apple generic and identifier \"app.scriv.uikit\" and certificate leaf[subject.OU] = \"%@\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists", team];
    SecStaticCodeRef code = NULL; SecRequirementRef requirement = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)host.bundleURL, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecRequirementCreateWithString((__bridge CFStringRef)rule, kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures | kSecCSStrictValidate, requirement);
    if (requirement) CFRelease(requirement); if (code) CFRelease(code);
    if (status != errSecSuccess) return [self failure:@"Updates require an intact Developer ID signed Scriv release. Unsigned and ad-hoc development builds cannot install updates."];
    return nil;
}
- (void)configureWithEvents:(ScrivUpdateEvents)events prepare:(ScrivUpdatePreparation)prepare {
    self.events = events; self.prepare = prepare;
}
- (void)emit:(NSDictionary *)event reply:(ScrivUpdateReply)reply {
    // Every callback is one-shot and scoped to the current presentation. A stale
    // button, repeated click, or dismissed sheet cannot authorize a later update.
    NSUInteger generation = ++self.eventGeneration;
    __block BOOL consumed = NO; __weak typeof(self) weakSelf = self;
    self.events(event, reply ? ^(NSString *choice) {
        typeof(self) self = weakSelf;
        if (!self || consumed || generation != self.eventGeneration) return;
        consumed = YES; reply(choice);
    } : nil);
}
- (void)checkForUpdates {
    // Keep the error readable while Sparkle finishes the already-requested
    // cancellation. A new deliberate check starts only after that teardown.
    if (self.cancellationMessage && self.updater && !self.updater.canCheckForUpdates) {
        [self emit:@{@"phase":@"error", @"message":self.cancellationMessage} reply:nil]; return;
    }
    self.cancellationMessage = nil;
    NSError *error = [self validateHost];
    if (error) { [self emit:@{@"phase":@"blocked", @"message":error.localizedDescription} reply:nil]; return; }
    if (!self.updater) {
        self.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle applicationBundle:NSBundle.mainBundle userDriver:self delegate:self];
        if (![self.updater startUpdater:&error]) { [self emit:@{@"phase":@"error", @"message":error.localizedDescription} reply:nil]; self.updater = nil; return; }
    }
    if (self.updater.canCheckForUpdates) [self.updater checkForUpdates];
    else [self showUpdateInFocus];
}
- (NSString *)pinnedFeedURL {
    // Channel is sealed into the signed app, never a user-default or remote flag.
    NSString *channel = [NSBundle.mainBundle objectForInfoDictionaryKey:@"ScrivUpdateChannel"];
    if (![channel isKindOfClass:NSString.class]) return nil;
    NSRegularExpression *test = [NSRegularExpression regularExpressionWithPattern:@"^acceptance-[a-z0-9][a-z0-9-]{0,47}$" options:0 error:nil];
    NSString *path;
    if ([channel isEqual:@"stable"]) path = @"/appcast.xml";
    else if ([test numberOfMatchesInString:channel options:0 range:NSMakeRange(0,channel.length)] == 1) path = [NSString stringWithFormat:@"/channels/%@/appcast.xml", channel];
    else return nil;
    NSString *expected = [@"https://scriv-updates.why-not.work" stringByAppendingString:path];
    return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"SUFeedURL"] isEqual:expected] ? expected : nil;
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return [self pinnedFeedURL]; }
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater {
    NSString *channel = [NSBundle.mainBundle objectForInfoDictionaryKey:@"ScrivUpdateChannel"];
    return [self pinnedFeedURL] ? [NSSet setWithObject:channel] : [NSSet set];
}
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater { return @[]; }
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    NSError *failure = check == SPUUpdateCheckUpdates ? [self validateHost] : [self failure:@"Scriv only checks for updates when you choose Check for Scriv updates."]; if (failure && error) *error = failure; return failure == nil;
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    // Manual checks only. No profiling and no implicit background permission.
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancel {
    [self emit:@{@"phase":@"checking"} reply:^(NSString *choice) { cancel(); }];
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    NSURL *url = item.fileURL;
    NSRegularExpression *path = [NSRegularExpression regularExpressionWithPattern:@"^/releases/[1-9][0-9]{0,14}/[a-f0-9]{64}\\.zip$" options:0 error:nil];
    BOOL allowed = [url.scheme isEqual:@"https"] && [url.host isEqual:@"scriv-updates.why-not.work"] && !url.port && !url.user && !url.password && !url.query && !url.fragment && [path numberOfMatchesInString:url.path options:0 range:NSMakeRange(0,url.path.length)] == 1;
    NSRegularExpression *buildPattern = [NSRegularExpression regularExpressionWithPattern:@"^[1-9][0-9]{0,14}$" options:0 error:nil];
    BOOL newerBuild = [buildPattern numberOfMatchesInString:item.versionString options:0 range:NSMakeRange(0,item.versionString.length)] == 1 && item.versionString.longLongValue > [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] longLongValue];
    if (!allowed || !newerBuild || ![item.channel isEqual:[NSBundle.mainBundle objectForInfoDictionaryKey:@"ScrivUpdateChannel"]] || item.signingValidationStatus != SPUAppcastSigningValidationStatusSucceeded || item.informationOnlyUpdate) { [self cancelUpdateWithReply:reply message:@"The signed release does not match Scriv’s update policy. This update was canceled; your current version was kept."]; return; }
    [self emit:@{@"phase":@"available", @"version":item.displayVersionString ?: @"", @"notes":item.itemDescription ?: @"A new version of Scriv is available."} reply:^(NSString *choice) {
        if (![choice isEqual:@"install"]) { reply(state.stage == SPUUserUpdateStageInstalling ? SPUUserUpdateChoiceSkip : SPUUserUpdateChoiceDismiss); return; }
        [self prepareForRelaunch:state.stage == SPUUserUpdateStageInstalling reply:reply];
    }];
}
- (void)cancelUpdateWithReply:(void (^)(SPUUserUpdateChoice))reply message:(NSString *)message {
    // Sparkle 2.10.1 SPUUserDriver.h: Dismiss can retain install-on-quit;
    // Skip cancels an already-prepared installation. Never defer this response
    // until an error acknowledgement: quitting in that gap must not install it.
    self.retryTermination = nil;
    self.cancellationMessage = message;
    reply(SPUUserUpdateChoiceSkip);
    [self emit:@{@"phase":@"error", @"message":message} reply:nil];
}
- (void)prepareAndReply:(void (^)(SPUUserUpdateChoice))reply {
    [self prepareForRelaunch:NO reply:reply];
}
- (void)prepareForRelaunch:(BOOL)willRelaunch reply:(void (^)(SPUUserUpdateChoice))reply {
    [self emit:@{@"phase":@"saving"} reply:nil];
    NSUInteger generation = self.eventGeneration;
    if (!self.prepare) { [self cancelUpdateWithReply:reply message:@"Scriv could not check that your work was saved. This update was canceled; your current version was kept."]; return; }
    __block BOOL completed = NO; __weak typeof(self) weakSelf = self;
    self.prepare(willRelaunch, ^(NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || completed || generation != self.eventGeneration) return;
        completed = YES;
        if (error) [self cancelUpdateWithReply:reply message:error.localizedDescription];
        else reply(SPUUserUpdateChoiceInstall);
    });
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data { /* Release notes are embedded plain text in the signed feed. */ }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack {
    [self emit:@{@"phase":@"current", @"message":error.localizedDescription} reply:^(NSString *choice) { ack(); }];
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack {
    [self emit:@{@"phase":@"error", @"message":error.localizedDescription} reply:^(NSString *choice) { ack(); }];
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancel {
    self.receivedBytes = 0; self.expectedBytes = 0;
    [self emit:@{@"phase":@"downloading"} reply:^(NSString *choice) { cancel(); }];
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { self.expectedBytes = length; }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
    self.receivedBytes += length;
    // Progress is not a new action state; preserve the existing cancellation.
    self.events(@{@"phase":@"progress", @"progress":@(self.expectedBytes ? MIN(1.0,(double)self.receivedBytes/self.expectedBytes) : 0)}, nil);
}
- (void)showDownloadDidStartExtractingUpdate { [self emit:@{@"phase":@"verifying"} reply:nil]; }
- (void)showExtractionReceivedProgress:(double)progress { self.events(@{@"phase":@"progress", @"progress":@(MAX(0,MIN(1,progress)))}, nil); }
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    self.retryTermination = nil;
    [self emit:@{@"phase":@"ready"} reply:^(NSString *choice) {
        // Dismiss would schedule install-on-quit. Skip cancels this prepared
        // installation (not future version checks): Later really means later.
        if (![choice isEqual:@"install"]) reply(SPUUserUpdateChoiceSkip);
        else [self prepareForRelaunch:YES reply:reply];
    }];
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    // Sparkle has completed preparation, not necessarily host termination.
    // Never keep a Catalyst formSheet open here: it can veto the Apple quit
    // event. The prepare(true) completion has already removed that modal chain.
    self.retryTermination = terminated ? nil : retry;
    [self emit:@{@"phase":terminated ? @"installing" : @"waitingToQuit"} reply:nil];
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack {
    [self emit:@{@"phase":@"complete"} reply:^(NSString *choice) { ack(); }];
}
- (void)dismissUpdateInstallation {
    self.retryTermination = nil;
    // Cancellation is already sent, independent of this retained error notice.
    // Sparkle may call teardown synchronously or later; neither may dismiss the
    // explanation or revive an earlier pending save completion.
    if (self.cancellationMessage) { ++self.eventGeneration; return; }
    [self emit:@{@"phase":@"dismiss"} reply:nil];
}
- (void)retryTerminationAfterSaving {
    void (^retry)(void) = self.retryTermination;
    if (!retry) return;
    [self emit:@{@"phase":@"saving"} reply:nil];
    NSUInteger generation = self.eventGeneration;
    __block BOOL completed = NO; __weak typeof(self) weakSelf = self;
    void (^finish)(NSError *) = ^(NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || completed || generation != self.eventGeneration || !self.retryTermination) return;
        completed = YES;
        if (error) {
            // Stage 2 has no public cancellation callback. Do not claim that a
            // failed retry canceled an already-prepared install-on-quit.
            [self emit:@{@"phase":@"retryBlocked", @"message":[NSString stringWithFormat:@"%@ The update is still prepared and may install when Scriv quits. Save your work before quitting.", error.localizedDescription]} reply:nil];
        } else {
            [self emit:@{@"phase":@"waitingToQuit"} reply:nil];
            retry(); // Explicit user choice, once; never force termination.
        }
    };
    if (self.prepare) self.prepare(YES, finish);
    else finish([self failure:@"Scriv could not check that your work was saved."]);
}
- (void)showUpdateInFocus {
    if (!self.retryTermination) { self.events(@{@"phase":@"focus"}, nil); return; }
    [self emit:@{@"phase":@"retryQuit"} reply:^(NSString *choice) {
        if ([choice isEqual:@"install"]) [self retryTerminationAfterSaving];
        else [self emit:@{@"phase":@"dismiss"} reply:nil];
    }];
}
@end
