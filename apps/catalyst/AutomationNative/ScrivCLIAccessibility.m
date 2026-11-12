#import <AppKit/AppKit.h>
#import <math.h>
#import "ScrivCLIAccessibility.h"

// This bundle observes only objects rooted in this process's existing NSApp.
// It never creates a second NSApplication, uses system-wide accessibility,
// requests permissions, reads accessibility values, or invokes app handlers.
static const NSUInteger ScrivCLIAXNodeLimit = 2048;
static const NSUInteger ScrivCLIAXDepthLimit = 64;
static const NSUInteger ScrivCLIAXChildLimit = 512;
static const NSUInteger ScrivCLIAXWindowLimit = 64;
static const NSUInteger ScrivCLIAXLabelLimit = 512;

static BOOL ScrivCLIAXRuntimeEnabled(void) {
    NSProcessInfo *process = NSProcessInfo.processInfo;
    if (![process.arguments containsObject:@"--scriv-cli"] ||
        ![process.arguments containsObject:@"--screenshots"]) return NO;
    NSString *runID = process.environment[@"SCRIV_CLI_RUN_ID"];
    if (![runID isKindOfClass:NSString.class] || runID.length != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:runID];
    return uuid != nil && [uuid.UUIDString caseInsensitiveCompare:runID] == NSOrderedSame;
}

static NSDictionary *ScrivCLIAXError(NSString *code, NSString *message) {
    return @{@"code": code, @"message": message};
}

static NSDictionary *ScrivCLIAXFailure(NSString *code, NSString *message) {
    return @{@"dispatched": @NO, @"error": ScrivCLIAXError(code, message)};
}

static BOOL ScrivCLIAXFiniteRect(NSRect frame) {
    return isfinite(frame.origin.x) && isfinite(frame.origin.y) &&
        isfinite(frame.size.width) && isfinite(frame.size.height) &&
        frame.size.width > 0 && frame.size.height > 0;
}

static BOOL ScrivCLIAXDescendantPath(NSString *path, NSString *ancestor) {
    return [path isEqualToString:ancestor] ||
        [path hasPrefix:[ancestor stringByAppendingString:@"/"]];
}

@interface ScrivCLIAXNode : NSObject
@property(nonatomic, strong) id object;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *role;
@property(nonatomic) NSRect frame;
@property(nonatomic) BOOL frameKnown;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL actionable;
@property(nonatomic) BOOL modal;
@property(nonatomic) BOOL labelSuppressed;
@end
@implementation ScrivCLIAXNode
@end

@interface ScrivCLIAXScan : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) id fence;
@property(nonatomic, copy) NSString *fencePath;
@property(nonatomic, copy) NSString *modalKind;
@property(nonatomic, strong) NSMutableArray<ScrivCLIAXNode *> *nodes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ScrivCLIAXNode *> *byPath;
@property(nonatomic, strong) NSHashTable *visited;
@property(nonatomic, strong) NSDictionary *error;
@property(nonatomic) BOOL active;
@end
@implementation ScrivCLIAXScan
- (instancetype)init {
    self = [super init];
    if (self) {
        _nodes = [NSMutableArray array];
        _byPath = [NSMutableDictionary dictionary];
        _visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality |
                    NSPointerFunctionsStrongMemory];
        _modalKind = @"none";
        _fencePath = @"";
    }
    return self;
}
@end

@interface ScrivCLIAccessibilityBridge : NSObject <ScrivCLIAccessibility>
@property(nonatomic) BOOL enabledAtInitialization;
@property(nonatomic, strong) NSMapTable<NSString *, id> *observedObjects;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *observedLabels;
@property(nonatomic, weak) NSWindow *observedWindow;
@property(nonatomic, weak) id observedFence;
@property(nonatomic, copy) NSString *observedFencePath;
@property(nonatomic, copy) NSString *observedModalKind;
@end

@implementation ScrivCLIAccessibilityBridge
- (instancetype)init {
    self = [super init];
    if (self) {
        // No AppKit access, callbacks, notifications, or observation at init.
        _enabledAtInitialization = ScrivCLIAXRuntimeEnabled();
    }
    return self;
}

- (NSDictionary *)gateError {
    if (!self.enabledAtInitialization || !ScrivCLIAXRuntimeEnabled())
        return ScrivCLIAXError(@"test_gate_required", @"Native accessibility requires the isolated CLI screenshot run flags and a valid run UUID.");
    if (!NSThread.isMainThread)
        return ScrivCLIAXError(@"main_thread_required", @"Native accessibility must run on the app main thread.");
    return nil;
}

- (void)invalidateSnapshot {
    self.observedObjects = nil;
    self.observedLabels = nil;
    self.observedWindow = nil;
    self.observedFence = nil;
    self.observedFencePath = nil;
    self.observedModalKind = nil;
}

- (BOOL)visibleOwnWindow:(NSWindow *)window windows:(NSArray<NSWindow *> *)windows {
    return window != nil && [windows indexOfObjectIdenticalTo:window] != NSNotFound &&
        window.isVisible && !window.isMiniaturized && ScrivCLIAXFiniteRect(window.frame);
}

- (ScrivCLIAXScan *)scan {
    ScrivCLIAXScan *scan = [[ScrivCLIAXScan alloc] init];
    // Callers enforce the gate before reaching any AppKit object.
    if (!NSApp) {
        scan.error = ScrivCLIAXError(@"app_unavailable", @"The in-process AppKit application is unavailable.");
        return scan;
    }
    NSArray<NSWindow *> *windows = NSApp.windows;
    if (windows.count > ScrivCLIAXWindowLimit) {
        scan.error = ScrivCLIAXError(@"window_limit", @"The native window limit was exceeded.");
        return scan;
    }
    NSWindow *window = NSApp.modalWindow;
    if (window) {
        scan.modalKind = @"application-modal";
    } else {
        window = NSApp.keyWindow ?: NSApp.mainWindow;
    }
    if (![self visibleOwnWindow:window windows:windows]) {
        scan.error = ScrivCLIAXError(@"active_window_unavailable", @"No visible own-process active window is available.");
        return scan;
    }
    NSHashTable *sheets = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality |
                          NSPointerFunctionsStrongMemory];
    while (window.attachedSheet) {
        if ([sheets containsObject:window] || sheets.count >= ScrivCLIAXDepthLimit ||
            ![self visibleOwnWindow:window.attachedSheet windows:windows] ||
            window.attachedSheet.sheetParent != window) {
            scan.error = ScrivCLIAXError(@"sheet_scope_unavailable", @"The current attached sheet cannot be safely resolved.");
            return scan;
        }
        [sheets addObject:window];
        window = window.attachedSheet;
        scan.modalKind = @"attached-sheet";
    }
    if (window.sheetParent) {
        if (![self visibleOwnWindow:window.sheetParent windows:windows] ||
            window.sheetParent.attachedSheet != window) {
            scan.error = ScrivCLIAXError(@"sheet_scope_unavailable", @"The active sheet is not the currently attached sheet.");
            return scan;
        }
        scan.modalKind = @"attached-sheet";
    }
    scan.window = window;
    scan.active = NSApp.isActive && !NSApp.isHidden && NSApp.keyWindow == window &&
        window.screen != nil && (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    NSString *rootPath = [NSString stringWithFormat:@"native/window/%ld", (long)window.windowNumber];
    [self visit:window path:rootPath depth:0 inheritedVisible:YES scan:scan];
    if (scan.error) return scan;

    // UIKit may expose an alert within the host NSWindow rather than as an
    // NSApp modalWindow. Only public modal/dialog/sheet metadata can fence it.
    ScrivCLIAXNode *modal = nil;
    for (ScrivCLIAXNode *node in scan.nodes) {
        if (!node.modal || !node.visible) continue;
        if (!modal || ScrivCLIAXDescendantPath(node.path, modal.path)) {
            modal = node;
        } else if (!ScrivCLIAXDescendantPath(modal.path, node.path)) {
            scan.error = ScrivCLIAXError(@"modal_scope_ambiguous", @"Multiple unrelated native modal containers are visible.");
            return scan;
        }
    }
    if (modal) {
        scan.fence = modal.object;
        scan.fencePath = modal.path;
        if ([scan.modalKind isEqualToString:@"none"]) scan.modalKind = @"accessibility-modal";
    } else if (![scan.modalKind isEqualToString:@"none"]) {
        scan.fence = window;
        scan.fencePath = rootPath;
    }
    return scan;
}

- (void)visit:(id)object path:(NSString *)path depth:(NSUInteger)depth
    inheritedVisible:(BOOL)inheritedVisible scan:(ScrivCLIAXScan *)scan {
    if (!object || scan.error || [scan.visited containsObject:object]) return;
    if (depth > ScrivCLIAXDepthLimit || scan.visited.count >= ScrivCLIAXNodeLimit) {
        scan.error = ScrivCLIAXError(@"traversal_limit", @"Native accessibility traversal reached its safety limit.");
        return;
    }
    [scan.visited addObject:object];
    if ([object isKindOfClass:NSWindow.class] && object != scan.window) return;
    if ([object isKindOfClass:NSView.class] && ((NSView *)object).window != scan.window) return;
    id<NSAccessibility> accessible = object;
    if ([object respondsToSelector:@selector(accessibilityWindow)]) {
        id owner = accessible.accessibilityWindow;
        if (owner && owner != scan.window) return;
    }
    NSString *role = @"";
    NSString *subrole = @"";
    if ([object respondsToSelector:@selector(accessibilityRole)]) {
        id candidate = accessible.accessibilityRole;
        if ([candidate isKindOfClass:NSString.class]) role = candidate;
    }
    if ([object respondsToSelector:@selector(accessibilitySubrole)]) {
        id candidate = accessible.accessibilitySubrole;
        if ([candidate isKindOfClass:NSString.class]) subrole = candidate;
    }

    // Never ask a protected element for its label, children, or value. Also
    // suppress labels on all text/editable elements: labels can mirror content.
    BOOL protected = [object isKindOfClass:NSSecureTextField.class] ||
        [subrole isEqualToString:NSAccessibilitySecureTextFieldSubrole] ||
        ([object respondsToSelector:@selector(isAccessibilityProtectedContent)] &&
         accessible.isAccessibilityProtectedContent);
    BOOL textElement = [role isEqualToString:NSAccessibilityTextFieldRole] ||
        [role isEqualToString:NSAccessibilityTextAreaRole] ||
        [role isEqualToString:NSAccessibilityStaticTextRole];
    BOOL descendantsVisible = inheritedVisible;
    if ([object isKindOfClass:NSView.class]) {
        NSView *view = object;
        descendantsVisible = descendantsVisible && !view.isHiddenOrHasHiddenAncestor &&
            view.alphaValue > 0.01 && !NSIsEmptyRect(view.visibleRect);
    }
    NSRect frame = NSZeroRect;
    BOOL frameKnown = [object respondsToSelector:@selector(accessibilityFrame)];
    if (frameKnown) frame = accessible.accessibilityFrame;
    frameKnown = frameKnown && ScrivCLIAXFiniteRect(frame);
    // An ignored, frameless accessibility container is not itself visible, but
    // must not hide correctly framed descendants. NSView hidden/clipping state
    // still propagates down both traversals.
    BOOL visible = descendantsVisible && frameKnown && NSIntersectsRect(frame, scan.window.frame);
    BOOL enabled = [object respondsToSelector:@selector(isAccessibilityEnabled)] &&
        accessible.isAccessibilityEnabled;
    NSString *label = @"";
    BOOL suppressed = protected || textElement;
    if (!suppressed && [object respondsToSelector:@selector(accessibilityLabel)]) {
        id candidate = accessible.accessibilityLabel;
        if ([candidate isKindOfClass:NSString.class] && [candidate length] <= ScrivCLIAXLabelLimit)
            label = candidate;
        else if (candidate) suppressed = YES;
    }
    ScrivCLIAXNode *node = [[ScrivCLIAXNode alloc] init];
    node.object = object;
    node.path = path;
    node.role = role;
    node.label = label;
    node.labelSuppressed = suppressed;
    node.frame = frame;
    node.frameKnown = frameKnown;
    node.visible = visible;
    node.enabled = enabled;
    node.modal = !protected &&
        ([role isEqualToString:NSAccessibilitySheetRole] ||
         [subrole isEqualToString:NSAccessibilityDialogSubrole] ||
         [subrole isEqualToString:NSAccessibilitySystemDialogSubrole] ||
         ([object respondsToSelector:@selector(isAccessibilityModal)] && accessible.isAccessibilityModal));
    node.actionable = !suppressed && label.length > 0 && enabled && visible &&
        [role isEqualToString:NSAccessibilityButtonRole] &&
        [object respondsToSelector:@selector(isAccessibilityElement)] && accessible.isAccessibilityElement &&
        [object respondsToSelector:@selector(accessibilityPerformPress)];
    [scan.nodes addObject:node];
    scan.byPath[path] = node;
    if (protected) return;

    // AX children take precedence. The AppKit view hierarchy supplies public
    // containers skipped by accessibility, never UIKit implementation classes.
    if ([object respondsToSelector:@selector(accessibilityChildren)]) {
        id children = accessible.accessibilityChildren;
        if (children && ![children isKindOfClass:NSArray.class]) {
            scan.error = ScrivCLIAXError(@"children_unavailable", @"A native accessibility child list is unavailable.");
            return;
        }
        [self visitChildren:children path:path component:@"ax" depth:depth inheritedVisible:descendantsVisible scan:scan];
    }
    if ([object isKindOfClass:NSWindow.class]) {
        NSView *content = ((NSWindow *)object).contentView;
        if (content) [self visit:content path:[path stringByAppendingString:@"/content"]
                          depth:depth + 1 inheritedVisible:descendantsVisible scan:scan];
    } else if ([object isKindOfClass:NSView.class]) {
        [self visitChildren:((NSView *)object).subviews path:path component:@"view" depth:depth
           inheritedVisible:descendantsVisible scan:scan];
    }
}

- (void)visitChildren:(NSArray *)children path:(NSString *)path component:(NSString *)component
    depth:(NSUInteger)depth inheritedVisible:(BOOL)visible scan:(ScrivCLIAXScan *)scan {
    if (children.count > ScrivCLIAXChildLimit) {
        scan.error = ScrivCLIAXError(@"child_limit", @"A native accessibility child list reached its safety limit.");
        return;
    }
    for (NSUInteger index = 0; index < children.count && !scan.error; index++) {
        NSString *childPath = [path stringByAppendingFormat:@"/%@/%lu", component, (unsigned long)index];
        [self visit:children[index] path:childPath depth:depth + 1 inheritedVisible:visible scan:scan];
    }
}

- (NSDictionary *)contextForScan:(ScrivCLIAXScan *)scan {
    return @{@"windowNumber": @(scan.window.windowNumber), @"modalKind": scan.modalKind,
             @"modalPath": scan.fencePath, @"active": @(scan.active),
             @"activationAvailable": @(scan.active && scan.fence != nil && scan.error == nil)};
}

- (NSArray<NSDictionary<NSString *, id> *> *)snapshot {
    NSDictionary *gate = [self gateError];
    if (gate) return @[@{@"kind": @"diagnostic", @"error": gate}];
    [self invalidateSnapshot];
    @try {
        ScrivCLIAXScan *scan = [self scan];
        if (scan.error) return @[@{@"kind": @"diagnostic", @"error": scan.error}];
        NSDictionary *context = [self contextForScan:scan];
        NSMutableArray *result = [NSMutableArray arrayWithObject:@{@"kind": @"context", @"context": context}];
        NSMapTable *objects = [NSMapTable strongToWeakObjectsMapTable];
        NSMutableDictionary *labels = [NSMutableDictionary dictionary];
        for (ScrivCLIAXNode *node in scan.nodes) {
            BOOL inScope = scan.fence == nil || ScrivCLIAXDescendantPath(node.path, scan.fencePath);
            NSRect frame = node.frameKnown ? node.frame : NSZeroRect;
            [result addObject:@{@"kind": @"element", @"path": node.path, @"label": node.label,
                @"role": node.role, @"enabled": @(node.enabled), @"visible": @(node.visible),
                @"labelSuppressed": @(node.labelSuppressed), @"frameKnown": @(node.frameKnown),
                @"actionable": @(node.actionable && inScope && scan.active && scan.fence != nil),
                @"inModalScope": @(inScope && scan.fence != nil),
                @"frame": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                             @"width": @(frame.size.width), @"height": @(frame.size.height)},
                @"context": context}];
            if (node.actionable && inScope && scan.active && scan.fence != nil) {
                [objects setObject:node.object forKey:node.path];
                labels[node.path] = node.label;
            }
        }
        self.observedObjects = objects;
        self.observedLabels = labels;
        self.observedWindow = scan.window;
        self.observedFence = scan.fence;
        self.observedFencePath = scan.fencePath;
        self.observedModalKind = scan.modalKind;
        return result;
    } @catch (NSException *exception) {
        (void)exception; // Exception descriptions can contain app/user content.
        [self invalidateSnapshot];
        return @[@{@"kind": @"diagnostic", @"error": ScrivCLIAXError(@"native_snapshot_failed", @"A public native accessibility getter failed.")}];
    }
}

- (NSDictionary<NSString *, id> *)activateRequest:(NSDictionary<NSString *, id> *)request {
    NSDictionary *gate = [self gateError];
    if (gate) return @{@"dispatched": @NO, @"error": gate};
    if (![request isKindOfClass:NSDictionary.class] || request.count != 2 ||
        ![request[@"path"] isKindOfClass:NSString.class] ||
        ![request[@"label"] isKindOfClass:NSString.class] ||
        [request[@"path"] length] == 0 || [request[@"path"] length] > 4096 ||
        [request[@"label"] length] == 0 || [request[@"label"] length] > ScrivCLIAXLabelLimit)
        return ScrivCLIAXFailure(@"invalid_request", @"Native activation requires only an exact snapshot path and label.");
    NSString *path = request[@"path"];
    NSString *label = request[@"label"];
    id observed = [self.observedObjects objectForKey:path];
    if (!observed || ![self.observedLabels[path] isEqualToString:label])
        return ScrivCLIAXFailure(@"snapshot_target_required", @"The target is not an actionable button from the latest native snapshot.");
    BOOL attemptingPress = NO;
    @try {
        ScrivCLIAXScan *scan = [self scan];
        if (scan.error) return @{@"dispatched": @NO, @"error": scan.error};
        if (!scan.active) return ScrivCLIAXFailure(@"inactive_window", @"The native target window is not active and visible.");
        if (!scan.fence) return ScrivCLIAXFailure(@"modal_not_exposed", @"No public native modal boundary is available for activation.");
        if (scan.window != self.observedWindow || scan.fence != self.observedFence ||
            ![scan.fencePath isEqualToString:self.observedFencePath] ||
            ![scan.modalKind isEqualToString:self.observedModalKind])
            return ScrivCLIAXFailure(@"modal_scope_changed", @"The active native modal changed after the snapshot.");
        ScrivCLIAXNode *node = scan.byPath[path];
        if (!node || node.object != observed || ![node.label isEqualToString:label] ||
            !node.actionable || !ScrivCLIAXDescendantPath(path, scan.fencePath))
            return ScrivCLIAXFailure(@"target_changed", @"The exact enabled visible native button is no longer in the active modal.");
        if (![scan.window respondsToSelector:@selector(accessibilityHitTest:)])
            return ScrivCLIAXFailure(@"hit_test_unavailable", @"Public native visibility verification is unavailable.");
        NSRect visibleFrame = NSIntersectionRect(node.frame, scan.window.frame);
        id hit = [scan.window accessibilityHitTest:NSMakePoint(NSMidX(visibleFrame), NSMidY(visibleFrame))];
        BOOL hitMatches = hit == node.object;
        if (!hitMatches && hit) {
            for (ScrivCLIAXNode *child in scan.nodes) {
                if (child.object == hit && ScrivCLIAXDescendantPath(child.path, path)) {
                    hitMatches = YES;
                    break;
                }
            }
        }
        if (!hitMatches)
            return ScrivCLIAXFailure(@"target_not_hittable", @"The public native hit test did not resolve to the exact button or its child.");
        // Invalidate BEFORE the one public action. A false return or exception
        // must never trigger another route, a handler call, or an automatic retry.
        [self invalidateSnapshot];
        attemptingPress = YES;
        BOOL dispatched = [(id<NSAccessibility>)node.object accessibilityPerformPress];
        if (!dispatched) return ScrivCLIAXFailure(@"press_unhandled", @"The public native accessibility press was not handled.");
        return @{@"dispatched": @YES};
    } @catch (NSException *exception) {
        (void)exception;
        [self invalidateSnapshot];
        return attemptingPress ?
            ScrivCLIAXFailure(@"press_outcome_unknown", @"The public native press raised an exception; inspect the UI before any new action.") :
            ScrivCLIAXFailure(@"native_validation_failed", @"A public native accessibility getter failed during validation.");
    }
}
@end
