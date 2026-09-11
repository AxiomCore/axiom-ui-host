#import "AxiomHostViewController.h"
#import "AxiomBundleProvider.h"
#import "AxiomRuntimeModule.h"
#import <Lynx/LynxConfig.h>
#import <Lynx/LynxViewClient.h>
#import <Lynx/LynxView.h>
#import <XElement/LynxUIInput.h>

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
  };
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
  axiom_reset_session();
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
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  LynxView *view = [[LynxView alloc] initWithBuilderBlock:^(LynxViewBuilder *builder) {
    LynxConfig *config = [[LynxConfig alloc] initWithProvider:AxiomBundleProvider.new];
    AxiomInstallRuntimeModule(config);
    // <input> is supplied by XElement rather than Lynx's built-in registry.
    // Register both halves: the UIKit view and its custom-measure shadow node.
    [config registerUI:LynxUIInput.class withName:@"input"];
    [config registerShadowNode:LynxUIInputShadowNode.class withName:@"input"];
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
  [view loadTemplateFromURL:@"axiom.app.lynx" initData:nil];
  [view triggerLayout];
  self.revisionTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                         target:self
                                                       selector:@selector(pollForRevision)
                                                       userInfo:nil
                                                        repeats:YES];
  [self pollForRevision];
}

- (void)lynxView:(LynxView *)view didRecieveError:(NSError *)error {
  @synchronized(self) {
    if (self.activeSequence == nil || self.activeGraphRevision.length == 0) return;
    self.diagnosticSequence += 1;
    NSDictionary *diagnostic = @{
      @"id": @(self.diagnosticSequence),
      @"sequence": self.activeSequence,
      @"graphRevision": self.activeGraphRevision,
      @"severity": @"error",
      @"code": [NSString stringWithFormat:@"LYNX_%ld", (long)error.code],
      @"message": error.localizedDescription ?: @"Unknown Lynx renderer error",
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
  [self.revisionTimer invalidate];
  AxiomShutdownRuntimeModule();
}
@end
