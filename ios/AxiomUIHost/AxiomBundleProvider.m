#import "AxiomBundleProvider.h"

@implementation AxiomBundleProvider

- (void)loadTemplateWithUrl:(NSString *)url onComplete:(LynxTemplateLoadBlock)callback {
  // The release installer places the verified bundle in the host container.
  // A name rather than an arbitrary URL prevents renderer code from selecting
  // filesystem or network locations.
  if (![url isEqualToString:@"axiom.app.lynx"]) {
    callback(nil, [NSError errorWithDomain:@"AxiomUIHost" code:400
                                  userInfo:@{NSLocalizedDescriptionKey: @"Unapproved UI bundle name."}]);
    return;
  }
  NSURL *root = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
  NSURL *bundle = [[[root URLByAppendingPathComponent:@"AxiomUIHost" isDirectory:YES]
                  URLByAppendingPathComponent:@"axiom.app.lynx.bundle"] copy];
  NSError *error = nil;
  NSData *data = [NSData dataWithContentsOfURL:bundle options:0 error:&error];
  callback(data, data == nil ? error : nil);
}

@end
