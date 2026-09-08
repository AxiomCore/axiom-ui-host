#import "AxiomAppDelegate.h"
#import "AxiomHostViewController.h"
@implementation AxiomAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = AxiomHostViewController.new;
  [self.window makeKeyAndVisible];
  return YES;
}
@end
