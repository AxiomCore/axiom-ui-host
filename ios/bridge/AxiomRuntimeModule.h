#import <Foundation/Foundation.h>
#import <Lynx/LynxConfig.h>
#import <Lynx/LynxModule.h>

NS_ASSUME_NONNULL_BEGIN

/// Typed contract bridge. It has no renderer state and calls only Axiom's C ABI.
@interface AxiomRuntimeModule : NSObject <LynxModule>
@end

FOUNDATION_EXPORT void AxiomInstallRuntimeModule(LynxConfig *config);
/// Cancel and drain the previous page's runtime requests before Lynx replaces
/// its JavaScript/template generation.
FOUNDATION_EXPORT void AxiomResetRuntimeSession(void);
FOUNDATION_EXPORT void AxiomShutdownRuntimeModule(void);

NS_ASSUME_NONNULL_END
