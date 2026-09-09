#import "AxiomHostViewController.h"
#import "AxiomBundleProvider.h"
#import "AxiomRuntimeModule.h"
#import <Lynx/LynxConfig.h>
#import <Lynx/LynxView.h>

@interface AxiomHostViewController ()
@property(nonatomic, strong) LynxView *lynxView;
@property(nonatomic, strong) NSTimer *revisionTimer;
@property(nonatomic, copy) NSString *lastAppliedRevision;
@end

@implementation AxiomHostViewController

+ (NSURL *)axiomSupportDirectory {
  NSURL *root = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
  return [root URLByAppendingPathComponent:@"AxiomUIHost" isDirectory:YES];
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
  NSString *mode = revision[@"deliveryMode"];
  if (![mode isEqualToString:@"state_preserving_patch"] &&
      ![mode isEqualToString:@"state_reset_template"]) {
    [self writeAcknowledgementForRevision:revision
                                   status:@"rejected_last_good"
                                   reason:@"unsupported Axiom UI delivery mode"];
    return;
  }
  [self.lynxView loadTemplateFromURL:@"axiom.app.lynx" initData:nil];
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
  [self.view addSubview:view];
  self.lynxView = view;
  [view loadTemplateFromURL:@"axiom.app.lynx" initData:nil];
  self.revisionTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                         target:self
                                                       selector:@selector(pollForRevision)
                                                       userInfo:nil
                                                        repeats:YES];
  [self pollForRevision];
}

- (void)dealloc {
  [self.revisionTimer invalidate];
  AxiomShutdownRuntimeModule();
}
@end
