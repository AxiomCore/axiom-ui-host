#import "AxiomRuntimeModule.h"
#import "axiom.h"

static const NSInteger AxiomFacadeProtocolVersion = 1;
static const NSInteger AxiomNativeModuleVersion = 1;
static NSMutableDictionary<NSNumber *, LynxCallbackBlock> *AxiomCallbacks;
static NSMutableDictionary<NSString *, NSDictionary *> *AxiomAllowedEndpoints;
static dispatch_once_t AxiomRuntimeOnce;
static dispatch_source_t AxiomResponsePump;
static BOOL AxiomInitialized = NO;
static NSString *AxiomLoadedConfigurationFingerprint;

static AxiomString AxiomStringFromNSString(NSString *value) {
  return (AxiomString){.ptr = (const uint8_t *)value.UTF8String,
                       .len = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]};
}

static NSString *AxiomUTF8String(const AxiomBuffer buffer) {
  if (buffer.ptr == NULL || buffer.len == 0) return @"";
  return [[NSString alloc] initWithBytes:buffer.ptr length:buffer.len
                                encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *AxiomEndpointKey(NSString *namespaceName, NSNumber *endpointID) {
  return [NSString stringWithFormat:@"%@:%@", namespaceName, endpointID];
}

static NSDictionary *AxiomStatus(NSInteger status, NSString *error) {
  NSMutableDictionary *value = [@{ @"status": @(status) } mutableCopy];
  if (error.length > 0) value[@"error"] = error;
  return value;
}

static NSString *AxiomRuntimeDatabasePath(void) {
  NSURL *root = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
  NSURL *directory = [root URLByAppendingPathComponent:@"AxiomUIHost" isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return [[directory URLByAppendingPathComponent:@"axiom-runtime.db"] path];
}

static BOOL AxiomStringValue(NSDictionary *object, NSString *key, NSString **value) {
  id candidate = object[key];
  if (![candidate isKindOfClass:NSString.class] || [(NSString *)candidate length] == 0) return NO;
  if (value != NULL) *value = candidate;
  return YES;
}

static void AxiomRuntimeResponse(const AxiomResponseBuffer *response) {
  if (response == NULL) return;
  NSNumber *requestID = @(response->request_id);
  NSDictionary *event = @{ @"protocolVersion": @(AxiomFacadeProtocolVersion),
                           @"requestId": requestID,
                           @"eventType": @(response->event_type),
                           @"status": @(response->error_code),
                           @"data": AxiomUTF8String(response->data),
                           @"error": AxiomUTF8String(response->error_message) };
  BOOL terminal = response->event_type == 0;
  axiom_free_response_buffer((AxiomResponseBuffer *)response);
  dispatch_async(dispatch_get_main_queue(), ^{
    LynxCallbackBlock callback;
    @synchronized(AxiomCallbacks) {
      callback = AxiomCallbacks[requestID];
      if (terminal) [AxiomCallbacks removeObjectForKey:requestID];
    }
    if (callback != nil) callback(event);
  });
}

@implementation AxiomRuntimeModule

+ (void)initialize {
  if (self != AxiomRuntimeModule.class) return;
  dispatch_once(&AxiomRuntimeOnce, ^{
    AxiomCallbacks = [NSMutableDictionary dictionary];
    AxiomAllowedEndpoints = [NSMutableDictionary dictionary];
    axiom_register_callback(AxiomRuntimeResponse);
    AxiomResponsePump = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(AxiomResponsePump, DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(AxiomResponsePump, ^{ axiom_process_responses(); });
    dispatch_resume(AxiomResponsePump);
  });
}

+ (NSString *)name { return @"AxiomRuntime"; }

+ (NSDictionary<NSString *, NSString *> *)methodLookup {
  return @{ @"runtimeInfo": NSStringFromSelector(@selector(runtimeInfo:)),
            @"initialize": NSStringFromSelector(@selector(initialize:callback:)),
            @"dispatch": NSStringFromSelector(@selector(dispatch:callback:)),
            @"cancel": NSStringFromSelector(@selector(cancel:)),
            @"close": NSStringFromSelector(@selector(close)) };
}

- (void)runtimeInfo:(LynxCallbackBlock)callback {
  callback(@{ @"moduleVersion": @(AxiomNativeModuleVersion),
              @"runtimeAbiVersion": @(axiom_abi_version()),
              @"target": @"ios", @"capabilities": @[] });
}

- (void)initialize:(NSDictionary *)config callback:(LynxCallbackBlock)callback {
  if (![config isKindOfClass:NSDictionary.class] ||
      [config[@"protocolVersion"] integerValue] != AxiomFacadeProtocolVersion ||
      ![config[@"contracts"] isKindOfClass:NSArray.class] || [config[@"contracts"] count] == 0) {
    callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: a non-empty verified contract configuration is required.")); return;
  }
  int32_t status = 0;
  if (!AxiomInitialized) {
    status = axiom_initialize(AxiomStringFromNSString(AxiomRuntimeDatabasePath()));
    if (status == 0) AxiomInitialized = YES;
  }
  if (status != 0) { callback(AxiomStatus(status, @"AXIOM_UI_RUNTIME_INIT: native runtime initialization failed.")); return; }
  NSData *configurationBytes = [NSJSONSerialization dataWithJSONObject:config[@"contracts"] options:0 error:nil];
  if (configurationBytes == nil) { callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: contracts are not serializable.")); return; }
  NSString *configurationFingerprint = [configurationBytes base64EncodedStringWithOptions:0];
  if (AxiomLoadedConfigurationFingerprint != nil && ![AxiomLoadedConfigurationFingerprint isEqual:configurationFingerprint]) {
    callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_RESTART_REQUIRED: verified contract inputs changed; restart the host before replacing its native runtime configuration.")); return;
  }
  BOOL loadContracts = AxiomLoadedConfigurationFingerprint == nil;
  BOOL allContractsVerified = YES;
  NSMutableDictionary<NSString *, NSDictionary *> *approved = [NSMutableDictionary dictionary];
  for (id candidate in config[@"contracts"]) {
    if (![candidate isKindOfClass:NSDictionary.class]) { callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: invalid contract entry.")); return; }
    NSDictionary *contract = candidate;
    NSString *namespaceName, *baseURL, *artifactBase64, *expectedHash;
    id signatureCandidate = contract[@"signature"];
    id publicKeyCandidate = contract[@"publicKey"];
    NSString *signature = [signatureCandidate isKindOfClass:NSString.class] ? signatureCandidate : nil;
    NSString *publicKey = [publicKeyCandidate isKindOfClass:NSString.class] ? publicKeyCandidate : nil;
    BOOL expectedVerified = [contract[@"verified"] boolValue];
    if (!AxiomStringValue(contract, @"namespace", &namespaceName) || !AxiomStringValue(contract, @"baseUrl", &baseURL) ||
        !AxiomStringValue(contract, @"artifactBase64", &artifactBase64) || signature == nil || publicKey == nil ||
        !AxiomStringValue(contract, @"expectedSha256", &expectedHash) ||
        (expectedVerified && (signature.length == 0 || publicKey.length == 0)) ||
        ![contract[@"operations"] isKindOfClass:NSArray.class]) {
      callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: contract has incomplete locked inputs.")); return;
    }
    NSData *artifact = [[NSData alloc] initWithBase64EncodedString:artifactBase64 options:0];
    if (artifact == nil || artifact.length == 0) { callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: invalid artifact encoding.")); return; }
    AxiomBuffer bytes = {.ptr = (uint8_t *)artifact.bytes, .len = artifact.length};
    if (loadContracts) {
      status = axiom_load_contract_locked(AxiomStringFromNSString(namespaceName), AxiomStringFromNSString(baseURL), bytes,
        AxiomStringFromNSString(signature), AxiomStringFromNSString(publicKey), AxiomStringFromNSString(expectedHash));
      if (status != 0 && status != -1) { callback(AxiomStatus(status, @"AXIOM_UI_RUNTIME_VERIFY: locked contract loading failed.")); return; }
      if ((status == 0) != expectedVerified) { callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_VERIFY: contract verification state differs from its lock.")); return; }
    }
    if (!expectedVerified) allContractsVerified = NO;
    for (id operationCandidate in contract[@"operations"]) {
      if (![operationCandidate isKindOfClass:NSDictionary.class]) { callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: invalid operation entry.")); return; }
      NSDictionary *operation = operationCandidate;
      NSString *method, *path, *kind;
      NSNumber *endpointID = operation[@"endpointId"];
      if (![endpointID isKindOfClass:NSNumber.class] || endpointID.unsignedIntValue == 0 ||
          !AxiomStringValue(operation, @"method", &method) || !AxiomStringValue(operation, @"path", &path) ||
          !AxiomStringValue(operation, @"kind", &kind) ||
          !([kind isEqual:@"query"] || [kind isEqual:@"mutation"] || [kind isEqual:@"stream"])) {
        callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: operation is not a valid verified capability.")); return;
      }
      NSString *key = AxiomEndpointKey(namespaceName, endpointID);
      if (approved[key] != nil) { callback(AxiomStatus(2, @"AXIOM_UI_RUNTIME_CONFIG: duplicate operation capability.")); return; }
      approved[key] = @{ @"method": method, @"path": path, @"kind": kind };
    }
  }
  @synchronized(AxiomAllowedEndpoints) { [AxiomAllowedEndpoints setDictionary:approved]; }
  AxiomLoadedConfigurationFingerprint = configurationFingerprint;
  callback(@{ @"status": @0, @"verified": @(allContractsVerified), @"loadedContracts": @([config[@"contracts"] count]) });
}

- (void)dispatch:(NSDictionary *)envelope callback:(LynxCallbackBlock)callback {
  if (![envelope isKindOfClass:NSDictionary.class] || [envelope[@"protocolVersion"] integerValue] != AxiomFacadeProtocolVersion ||
      ![envelope[@"request"] isKindOfClass:NSDictionary.class]) {
    callback(@{ @"accepted": @YES, @"status": @2, @"error": @"AXIOM_UI_RUNTIME_DISPATCH: invalid facade envelope." }); return;
  }
  uint64_t requestID = [envelope[@"requestId"] unsignedLongLongValue];
  NSDictionary *request = envelope[@"request"];
  NSString *namespaceName, *method, *path, *kind;
  NSNumber *endpointID = request[@"endpointId"];
  if (requestID == 0 || ![endpointID isKindOfClass:NSNumber.class] || !AxiomStringValue(request, @"namespace", &namespaceName) ||
      !AxiomStringValue(request, @"method", &method) || !AxiomStringValue(request, @"path", &path) || !AxiomStringValue(request, @"kind", &kind)) {
    callback(@{ @"accepted": @YES, @"status": @2, @"error": @"AXIOM_UI_RUNTIME_DISPATCH: invalid operation request." }); return;
  }
  NSDictionary *approved;
  @synchronized(AxiomAllowedEndpoints) { approved = AxiomAllowedEndpoints[AxiomEndpointKey(namespaceName, endpointID)]; }
  if (approved == nil || ![approved[@"method"] isEqual:method] || ![approved[@"path"] isEqual:path] ||
      ![approved[@"kind"] isEqual:kind] || ![kind isEqual:envelope[@"kind"]]) {
    callback(@{ @"accepted": @YES, @"status": @2, @"error": @"AXIOM_UI_OPERATION_DENIED: request is absent from the verified contract capability set." }); return;
  }
  @synchronized(AxiomCallbacks) {
    if (AxiomCallbacks[@(requestID)] != nil) { callback(@{ @"accepted": @YES, @"status": @2, @"error": @"Duplicate requestId." }); return; }
    AxiomCallbacks[@(requestID)] = [callback copy];
  }
  NSData *payload = [[NSData alloc] initWithBase64EncodedString:request[@"payloadBase64"] ?: @"" options:0] ?: [NSData data];
  AxiomBuffer input = {.ptr = (uint8_t *)payload.bytes, .len = payload.length};
  int32_t status = axiom_call(requestID, AxiomStringFromNSString(namespaceName), endpointID.unsignedIntValue,
    AxiomStringFromNSString(method), AxiomStringFromNSString(path), AxiomStringFromNSString(request[@"traceparent"] ?: @""),
    AxiomStringFromNSString(request[@"headersJson"] ?: @"{}"), input);
  if (status != 0) {
    @synchronized(AxiomCallbacks) { [AxiomCallbacks removeObjectForKey:@(requestID)]; }
    callback(@{ @"accepted": @YES, @"status": @(status), @"error": @"Axiom runtime rejected the request." }); return;
  }
  callback(@{ @"accepted": @YES, @"status": @0 });
}

- (NSDictionary *)cancel:(NSNumber *)requestID { return @{ @"requestId": requestID, @"status": @(axiom_cancel(requestID.unsignedLongLongValue)) }; }

- (NSDictionary *)close {
  NSArray<NSNumber *> *requestIDs;
  @synchronized(AxiomCallbacks) { requestIDs = AxiomCallbacks.allKeys; [AxiomCallbacks removeAllObjects]; }
  for (NSNumber *requestID in requestIDs) axiom_cancel(requestID.unsignedLongLongValue);
  return @{ @"status": @0 };
}
@end

void AxiomShutdownRuntimeModule(void) {
  if (AxiomResponsePump != nil) { dispatch_source_cancel(AxiomResponsePump); AxiomResponsePump = nil; }
  axiom_clear_callback();
  @synchronized(AxiomCallbacks) { [AxiomCallbacks removeAllObjects]; }
  @synchronized(AxiomAllowedEndpoints) { [AxiomAllowedEndpoints removeAllObjects]; }
  AxiomLoadedConfigurationFingerprint = nil;
}
