#import "AxiomRuntimeModule.h"
#import "axiom.h"

static NSMutableDictionary<NSNumber *, LynxCallbackBlock> *AxiomCallbacks;
static dispatch_once_t AxiomRuntimeOnce;
static dispatch_source_t AxiomResponsePump;

static AxiomString AxiomStringFromNSString(NSString *value) {
  return (AxiomString){.ptr = (const uint8_t *)value.UTF8String,
                       .len = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]};
}

static NSString *AxiomUTF8String(const AxiomBuffer buffer) {
  if (buffer.ptr == NULL || buffer.len == 0) return @"";
  return [[NSString alloc] initWithBytes:buffer.ptr length:buffer.len
                                encoding:NSUTF8StringEncoding] ?: @"";
}

static void AxiomRuntimeResponse(const AxiomResponseBuffer *response) {
  if (response == NULL) return;
  NSNumber *requestID = @(response->request_id);
  NSDictionary *event = @{ @"requestId": requestID, @"eventType": @(response->event_type),
                           @"status": @(response->error_code), @"data": AxiomUTF8String(response->data),
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
  return @{ @"abiVersion": NSStringFromSelector(@selector(abiVersion:)),
            @"initialize": NSStringFromSelector(@selector(initialize:callback:)),
            @"query": NSStringFromSelector(@selector(query:callback:)),
            @"cancel": NSStringFromSelector(@selector(cancel:)) };
}

- (void)abiVersion:(LynxCallbackBlock)callback { callback(@{ @"abiVersion": @(axiom_abi_version()) }); }

- (void)initialize:(NSDictionary *)config callback:(LynxCallbackBlock)callback {
  NSString *dbPath = config[@"dbPath"] ?: @"";
  NSString *namespaceName = config[@"namespace"] ?: @"default";
  NSString *baseURL = config[@"baseUrl"] ?: @"";
  NSData *artifact = [[NSData alloc] initWithBase64EncodedString:config[@"artifactBase64"] ?: @"" options:0];
  NSString *signature = config[@"signature"] ?: @"";
  NSString *publicKey = config[@"publicKey"] ?: @"";
  if (artifact == nil || signature.length == 0 || publicKey.length == 0) {
    callback(@{ @"status": @10, @"error": @"A local signed artifact is required." }); return;
  }
  int32_t status = axiom_initialize(AxiomStringFromNSString(dbPath));
  if (status == 0) {
    AxiomBuffer bytes = {.ptr = (uint8_t *)artifact.bytes, .len = artifact.length};
    status = axiom_load_contract(AxiomStringFromNSString(namespaceName), AxiomStringFromNSString(baseURL), bytes,
                                 AxiomStringFromNSString(signature), AxiomStringFromNSString(publicKey));
  }
  callback(@{ @"status": @(status), @"verified": @(status == 0) });
}

- (void)query:(NSDictionary *)request callback:(LynxCallbackBlock)callback {
  uint64_t requestID = [request[@"requestId"] unsignedLongLongValue];
  if (requestID == 0) { callback(@{ @"status": @2, @"error": @"requestId must be non-zero." }); return; }
  @synchronized(AxiomCallbacks) {
    if (AxiomCallbacks[@(requestID)] != nil) { callback(@{ @"requestId": @(requestID), @"status": @2, @"error": @"Duplicate requestId." }); return; }
    AxiomCallbacks[@(requestID)] = [callback copy];
  }
  NSData *payload = [[NSData alloc] initWithBase64EncodedString:request[@"payloadBase64"] ?: @"" options:0] ?: [NSData data];
  AxiomBuffer input = {.ptr = (uint8_t *)payload.bytes, .len = payload.length};
  int32_t status = axiom_call(requestID, AxiomStringFromNSString(request[@"namespace"] ?: @"default"),
    [request[@"endpointId"] unsignedIntValue], AxiomStringFromNSString(request[@"method"] ?: @"GET"),
    AxiomStringFromNSString(request[@"path"] ?: @""), AxiomStringFromNSString(request[@"traceparent"] ?: @""),
    AxiomStringFromNSString(request[@"headersJson"] ?: @"{}"), input);
  if (status != 0) {
    @synchronized(AxiomCallbacks) { [AxiomCallbacks removeObjectForKey:@(requestID)]; }
    callback(@{ @"requestId": @(requestID), @"status": @(status), @"error": @"Request ID has already been used or is invalid." });
  }
}

- (NSDictionary *)cancel:(NSNumber *)requestID {
  return @{ @"requestId": requestID, @"status": @(axiom_cancel(requestID.unsignedLongLongValue)) };
}
@end

void AxiomShutdownRuntimeModule(void) {
  if (AxiomResponsePump != nil) { dispatch_source_cancel(AxiomResponsePump); AxiomResponsePump = nil; }
  axiom_clear_callback();
  @synchronized(AxiomCallbacks) { [AxiomCallbacks removeAllObjects]; }
}
