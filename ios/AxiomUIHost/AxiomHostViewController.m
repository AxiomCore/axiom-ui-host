#import "AxiomHostViewController.h"
#import "AxiomBundleProvider.h"
#import "AxiomRuntimeModule.h"
#import <Lynx/LynxConfig.h>
#import <Lynx/LynxComponentRegistry.h>
#import <Lynx/LynxViewClient.h>
#import <Lynx/LynxView.h>
#import <XElement/LynxUIInput.h>
#import <XElement/LynxUITextArea.h>
#import <XElement/LynxUIOverlay.h>
#import <XElement/LynxOverlayContainer.h>
#import <XElement/LynxUIBlurView.h>
#import <XElement/LynxUIWebView.h>
#import <XElement/LynxUIVideo.h>
#import <XElement/LynxUISVG.h>
#import <XElement/LynxUIRefresh.h>
#import <XElement/LynxUIRefreshHeader.h>
#import <XElement/LynxUIRefreshShadowNode.h>
#import <XElement/LynxUIViewPager.h>
#import <XElement/LynxUIViewPagerItem.h>
#import <XElement/LynxUIScrollCoordinator.h>
#import <XElement/LynxUIScrollCoordinatorHeader.h>
#import <XElement/LynxUIScrollCoordinatorToolbar.h>
#import <XElement/LynxUIScrollCoordinatorSlot.h>

// XElement creates an overlay container as visible before it applies the
// authored `visible` property. That transient default emits a false initial
// dismiss event. Start the UIKit container hidden, matching Acore's default,
// and re-arm overlay touch recognition after the container has joined its
// window (the upstream first attempt can occur while `self.view.window` is
// still nil).
@interface AxiomUIOverlay : LynxUIOverlay
@end

@implementation AxiomUIOverlay
- (UIView *)createView {
  UIView *view = [super createView];
  view.hidden = YES;
  return view;
}

- (void)eventDidSet {
  [super eventDidSet];
  dispatch_async(dispatch_get_main_queue(), ^{
    LynxOverlayContainer *container = (LynxOverlayContainer *)self.view;
    if (container.window != nil) [container enableTouchOverlayEvent:YES];
  });
}
@end

@interface AxiomHostViewController () <LynxViewLifecycle>
@property(nonatomic, strong) LynxView *lynxView;
@property(nonatomic, strong) NSTimer *revisionTimer;
@property(nonatomic, copy) NSString *lastAppliedRevision;
@property(nonatomic, assign) CGSize lastPublishedViewportSize;
@property(nonatomic, assign) UIEdgeInsets lastPublishedSafeAreaInsets;
@property(nonatomic, assign) BOOL hasPublishedViewport;
@property(nonatomic, strong) NSNumber *activeSequence;
@property(nonatomic, copy) NSString *activeGraphRevision;
@property(nonatomic, assign) NSUInteger diagnosticSequence;
@end

// Lynx and XElement are static pods in this host. In the pinned toolchain,
// duplicate Objective-C class symbols can make the scope registry's
// isSubclassOfClass guard reject a valid XElement class. Resolve the live
// runtime class and put it into the config-owned scope used by LynxUIOwner.
static void AxiomRegisterRuntimeUI(LynxConfig *config, NSString *className,
                                   NSString *elementName) {
  id scope = [config valueForKey:@"componentRegistry"];
  id uiClasses = [scope valueForKey:@"uiClasses"];
  Class componentClass = NSClassFromString(className);
  if (uiClasses != nil && componentClass != Nil) {
    [uiClasses setObject:componentClass forKey:elementName];
  }
}

static void AxiomRegisterRuntimeShadowNode(LynxConfig *config, NSString *className,
                                           NSString *elementName) {
  id scope = [config valueForKey:@"componentRegistry"];
  id shadowNodeClasses = [scope valueForKey:@"shadowNodeClasses"];
  Class componentClass = NSClassFromString(className);
  if (shadowNodeClasses != nil && componentClass != Nil) {
    [shadowNodeClasses setObject:componentClass forKey:elementName];
  }
}

@implementation AxiomHostViewController

+ (NSURL *)axiomSupportDirectory {
  NSURL *root = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
  return [root URLByAppendingPathComponent:@"AxiomUIHost" isDirectory:YES];
}

- (UIEdgeInsets)axiomSafeAreaInsets {
  if (@available(iOS 11.0, *)) {
    UIEdgeInsets insets = self.view.safeAreaInsets;
    if (!UIEdgeInsetsEqualToEdgeInsets(insets, UIEdgeInsetsZero)) return insets;
    UIWindow *window = self.view.window;
    if (window != nil && !UIEdgeInsetsEqualToEdgeInsets(window.safeAreaInsets, UIEdgeInsetsZero)) {
      return window.safeAreaInsets;
    }
  }
  return UIEdgeInsetsZero;
}

- (NSDictionary<NSString *, id> *)axiomGlobalProps {
  UIEdgeInsets insets = [self axiomSafeAreaInsets];
  CGSize size = self.view.bounds.size;
  return @{
    @"screenWidth": @(size.width),
    @"screenHeight": @(size.height),
    @"safeAreaTop": @(insets.top),
    @"safeAreaRight": @(insets.right),
    @"safeAreaBottom": @(insets.bottom),
    @"safeAreaLeft": @(insets.left),
    @"isNotchScreen": @((insets.top > 20.0) || (insets.bottom > 0.0)),
    @"reduceMotion": @(UIAccessibilityIsReduceMotionEnabled()),
  };
}

- (void)axiomReduceMotionChanged:(NSNotification *)notification {
  (void)notification;
  if (self.lynxView != nil) {
    [self.lynxView updateGlobalPropsWithDictionary:[self axiomGlobalProps]];
  }
}

- (void)updateLynxViewport {
  if (self.lynxView == nil) return;
  CGSize size = self.view.bounds.size;
  UIEdgeInsets insets = [self axiomSafeAreaInsets];
  self.lynxView.frame = self.view.bounds;
  if (self.hasPublishedViewport &&
      CGSizeEqualToSize(self.lastPublishedViewportSize, size) &&
      UIEdgeInsetsEqualToEdgeInsets(self.lastPublishedSafeAreaInsets, insets)) {
    return;
  }
  self.hasPublishedViewport = YES;
  self.lastPublishedViewportSize = size;
  self.lastPublishedSafeAreaInsets = insets;
  self.lynxView.preferredLayoutWidth = size.width;
  self.lynxView.preferredLayoutHeight = size.height;
  [self.lynxView updateScreenMetricsWithWidth:size.width height:size.height];
  [self.lynxView updateViewportWithPreferredLayoutWidth:size.width
                                  preferredLayoutHeight:size.height
                                             needLayout:YES];
  [self.lynxView updateGlobalPropsWithDictionary:[self axiomGlobalProps]];
}

- (void)writeAcknowledgementForRevision:(NSDictionary *)revision
                                  status:(NSString *)status
                                  reason:(NSString *)reason {
  NSNumber *sequence = revision[@"sequence"];
  NSString *graphRevision = revision[@"graphRevision"];
  if (![sequence isKindOfClass:NSNumber.class] || ![graphRevision isKindOfClass:NSString.class]) return;
  NSDictionary *ack = @{
    @"format": @"axiom-ui-host-ack/v2",
    @"sequence": sequence,
    @"graphRevision": graphRevision,
    @"status": status,
    @"reason": reason ?: @"",
  };
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:ack options:0 error:&error];
  if (data == nil) return;
  NSURL *directory = AxiomHostViewController.axiomSupportDirectory;
  [[NSFileManager defaultManager] createDirectoryAtURL:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&error];
  if (error != nil) return;
  NSURL *destination = [directory URLByAppendingPathComponent:@"axiom.app.ack.json"];
  NSURL *temporary = [directory URLByAppendingPathComponent:@"axiom.app.ack.json.tmp"];
  if (![data writeToURL:temporary options:NSDataWritingAtomic error:&error]) return;
  [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
  [[NSFileManager defaultManager] moveItemAtURL:temporary toURL:destination error:&error];
}

- (void)pollForRevision {
  NSURL *revisionURL = [AxiomHostViewController.axiomSupportDirectory
      URLByAppendingPathComponent:@"axiom.app.revision.json"];
  NSData *data = [NSData dataWithContentsOfURL:revisionURL];
  if (data == nil) return;
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![parsed isKindOfClass:NSDictionary.class]) return;
  NSDictionary *revision = (NSDictionary *)parsed;
  if (![revision[@"format"] isEqual:@"axiom-ui-host-revision/v2"] ||
      ![revision[@"graphRevision"] isKindOfClass:NSString.class] ||
      ![revision[@"sequence"] isKindOfClass:NSNumber.class] ||
      ![revision[@"deliveryMode"] isKindOfClass:NSString.class]) return;
  NSString *identity = [NSString stringWithFormat:@"%@:%@", revision[@"sequence"], revision[@"graphRevision"]];
  if ([identity isEqualToString:self.lastAppliedRevision]) return;

  // The CLI publishes the bundle first and this fixed revision record last.
  // The provider accepts only the named bundle, never an app-supplied URL.
  // A state-preserving patch is capability-gated. The pinned static template
  // transport used by this host cannot yet prove renderer hook-state retention,
  // so it must use the explicit, visible full-template fallback rather than
  // silently claim Flutter-style reload semantics.
  self.lastAppliedRevision = identity;
  self.activeSequence = revision[@"sequence"];
  self.activeGraphRevision = revision[@"graphRevision"];
  [[NSFileManager defaultManager]
      removeItemAtURL:[AxiomHostViewController.axiomSupportDirectory
                          URLByAppendingPathComponent:@"axiom.app.diagnostic.json"]
               error:nil];
  NSString *mode = revision[@"deliveryMode"];
  if (![mode isEqualToString:@"state_preserving_patch"] &&
      ![mode isEqualToString:@"state_reset_template"]) {
    [self writeAcknowledgementForRevision:revision
                                   status:@"rejected_last_good"
                                   reason:@"unsupported Axiom UI delivery mode"];
    return;
  }
  // A replacement template starts request IDs at 1 again. Cancel and drain
  // the previous facade generation before Lynx creates the next one.
  [self.view endEditing:YES];
  AxiomResetRuntimeSession();
  [self.lynxView loadTemplateFromURL:@"axiom.app.lynx" initData:nil];
  [self.lynxView triggerLayout];
  if ([mode isEqualToString:@"state_preserving_patch"]) {
    [self writeAcknowledgementForRevision:revision
                                   status:@"applied_state_reset"
                                   reason:@"state-preserving renderer patch is not yet proven for the pinned host; full template reload applied"];
  } else {
    NSString *reason = revision[@"fallbackReason"];
    [self writeAcknowledgementForRevision:revision
                                   status:@"applied_state_reset"
                                   reason:[reason isKindOfClass:NSString.class] ? reason : @"full template reload requested"];
  }
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(axiomReduceMotionChanged:)
             name:UIAccessibilityReduceMotionStatusDidChangeNotification
           object:nil];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  __block LynxConfig *hostConfig = nil;
  LynxView *view = [[LynxView alloc] initWithBuilderBlock:^(LynxViewBuilder *builder) {
    LynxConfig *config = [[LynxConfig alloc] initWithProvider:AxiomBundleProvider.new];
    hostConfig = config;
    AxiomInstallRuntimeModule(config);
    // <input> is supplied by XElement rather than Lynx's built-in registry.
    // Register both halves: the UIKit view and its custom-measure shadow node.
    [config registerUI:LynxUIInput.class withName:@"input"];
    [config registerShadowNode:LynxUIInputShadowNode.class withName:@"input"];
    [config registerUI:LynxUITextArea.class withName:@"textarea"];
    [config registerShadowNode:LynxUITextAreaShadowNode.class withName:@"textarea"];
    [config registerUI:AxiomUIOverlay.class withName:@"overlay"];
    [config registerShadowNode:LynxUIOverlayShadowNode.class withName:@"overlay"];
    [config registerUI:LynxUISVG.class withName:@"svg"];
    [config registerUI:LynxUIBlurView.class withName:@"blur-view"];
    [config registerUI:LynxUIWebView.class withName:@"webview"];
    [config registerUI:LynxUIVideo.class withName:@"video"];
    // Static XElement subspecs can be dead-stripped before their lazy
    // registries run. Register the complete Phase 2H hierarchy explicitly.
    [config registerUI:LynxUIRefresh.class withName:@"refresh"];
    [config registerShadowNode:LynxUIRefreshShadowNode.class withName:@"refresh"];
    [config registerUI:LynxUIRefreshHeader.class withName:@"refresh-header"];
    [config registerUI:LynxUIViewPager.class withName:@"viewpager"];
    [config registerUI:LynxUIViewPagerItem.class withName:@"viewpager-item"];
    [config registerUI:LynxUIScrollCoordinator.class withName:@"scroll-coordinator"];
    [config registerUI:LynxUIScrollCoordinatorHeader.class withName:@"scroll-coordinator-header"];
    [config registerUI:LynxUIScrollCoordinatorToolbar.class withName:@"scroll-coordinator-toolbar"];
    [config registerUI:LynxUIScrollCoordinatorSlot.class withName:@"scroll-coordinator-slot"];
    builder.config = config;
    builder.screenSize = self.view.bounds.size;
    builder.fontScale = 1.0;
  }];
  view.frame = self.view.bounds;
  view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  view.preferredLayoutWidth = self.view.bounds.size.width;
  view.preferredLayoutHeight = self.view.bounds.size.height;
  view.layoutWidthMode = LynxViewSizeModeExact;
  view.layoutHeightMode = LynxViewSizeModeExact;
  view.enableAutoLayout = YES;
  [self.view addSubview:view];
  self.lynxView = view;
  [view addLifecycleClient:self];
  [self updateLynxViewport];
  self.revisionTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                         target:self
                                                       selector:@selector(pollForRevision)
                                                       userInfo:nil
                                                        repeats:YES];
  // Static XElement classes finish runtime realization after LynxView returns.
  // Defer the first template load one main-loop turn, register into the live
  // config scope, and only then allow the revision poll to load UI content.
  dispatch_async(dispatch_get_main_queue(), ^{
    AxiomRegisterRuntimeUI(hostConfig, @"AxiomUIOverlay", @"overlay");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIRefresh", @"refresh");
    AxiomRegisterRuntimeShadowNode(hostConfig, @"LynxUIRefreshShadowNode", @"refresh");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIRefreshHeader", @"refresh-header");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIViewPager", @"viewpager");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIViewPagerItem", @"viewpager-item");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIScrollCoordinator", @"scroll-coordinator");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIScrollCoordinatorHeader",
                           @"scroll-coordinator-header");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIScrollCoordinatorToolbar",
                           @"scroll-coordinator-toolbar");
    AxiomRegisterRuntimeUI(hostConfig, @"LynxUIScrollCoordinatorSlot",
                           @"scroll-coordinator-slot");
    // The revision record is published after its bundle and is the sole
    // authority for initial delivery. Loading here and again in the poll
    // creates two page generations and can route teardown lifecycle events
    // from the first overlay into the second page.
    [self pollForRevision];
  });
}

- (void)lynxView:(LynxView *)view didRecieveError:(NSError *)error {
  @synchronized(self) {
    if (self.activeSequence == nil || self.activeGraphRevision.length == 0) return;
    self.diagnosticSequence += 1;
    NSString *message = error.localizedDescription ?: @"Unknown Lynx renderer error";
    if (error.userInfo.count > 0) {
      message = [NSString stringWithFormat:@"%@ | %@", message, error.userInfo.description];
    }
    NSDictionary *diagnostic = @{
      @"id": @(self.diagnosticSequence),
      @"sequence": self.activeSequence,
      @"graphRevision": self.activeGraphRevision,
      @"severity": @"error",
      @"code": [NSString stringWithFormat:@"LYNX_%ld", (long)error.code],
      @"message": message,
    };
    NSURL *destination = [AxiomHostViewController.axiomSupportDirectory
        URLByAppendingPathComponent:@"axiom.app.diagnostic.json"];
    NSData *existingData = [NSData dataWithContentsOfURL:destination];
    NSDictionary *existing = existingData == nil
        ? nil
        : [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil];
    NSMutableArray *diagnostics = [NSMutableArray array];
    if ([existing[@"format"] isEqual:@"axiom-ui-host-diagnostics/v1"] &&
        [existing[@"diagnostics"] isKindOfClass:NSArray.class]) {
      [diagnostics addObjectsFromArray:existing[@"diagnostics"]];
    }
    [diagnostics addObject:diagnostic];
    if (diagnostics.count > 50) {
      [diagnostics removeObjectsInRange:NSMakeRange(0, diagnostics.count - 50)];
    }
    NSDictionary *envelope = @{
      @"format": @"axiom-ui-host-diagnostics/v1",
      @"diagnostics": diagnostics,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    if (data == nil) return;
    [data writeToURL:destination options:NSDataWritingAtomic error:nil];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self updateLynxViewport];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self.revisionTimer invalidate];
  AxiomShutdownRuntimeModule();
}
@end
