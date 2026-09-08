#import "AxiomRuntimeModule.h"

void AxiomInstallRuntimeModule(LynxConfig *config) {
  [config registerModule:AxiomRuntimeModule.class];
}
