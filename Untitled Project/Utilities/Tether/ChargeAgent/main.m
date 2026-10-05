#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdint.h>

// Runtime-bound and isolated because PowerUI is not a public SDK contract.
// No SMC writes, root access, shell commands, or arbitrary key/value operations.
@interface NSObject (BezelChargeInterface)
- (instancetype)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (NSUInteger)isMCLCurrentlyEnabled:(NSError **)error;
- (uint8_t)getMCLLimitWithError:(NSError **)error;
- (BOOL)setMCLLimit:(uint8_t)limit error:(NSError **)error;
- (BOOL)enableMCL:(NSError **)error;
- (BOOL)disableMCL:(NSError **)error;
- (BOOL)temporarilyOverrideMCLTargetSoC:(uint8_t)limit error:(NSError **)error;
@end

#if defined(__arm64__)
static BOOL validMethod(Class cls, NSString *name, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || signature.numberOfArguments != arguments.count + 2) return NO;
    if (strcmp(signature.methodReturnType, result) != 0) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String) != 0) return NO;
    }
    return YES;
}

static BOOL validBoolMethod(Class cls, NSString *name, NSArray<NSString *> *arguments) {
    return validMethod(cls, name, @encode(BOOL), arguments);
}
#endif

static id createClient(NSString **reason) {
#if !defined(__arm64__)
    *reason = @"Native charge control requires Apple silicon.";
    return nil;
#else
    if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 4, 0}]) {
        *reason = @"Native charge control requires macOS 26.4 or later.";
        return nil;
    }
    NSError *error = nil;
    NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PowerUI.framework"];
    if (![bundle loadAndReturnError:&error]) {
        *reason = @"The native battery-control framework is unavailable.";
        return nil;
    }
    Class cls = NSClassFromString(@"PowerUISmartChargeClient");
    BOOL matches = cls &&
        validMethod(cls, @"initWithClientName:", @encode(id), @[@"@"]) &&
        validBoolMethod(cls, @"isMCLSupported", @[]) &&
        validMethod(cls, @"isMCLCurrentlyEnabled:", @encode(NSUInteger), @[@"^@"]) &&
        validMethod(cls, @"getMCLLimitWithError:", @encode(uint8_t), @[@"^@"]) &&
        validBoolMethod(cls, @"setMCLLimit:error:", @[@"C", @"^@"]) &&
        validBoolMethod(cls, @"enableMCL:", @[@"^@"]) &&
        validBoolMethod(cls, @"disableMCL:", @[@"^@"]) &&
        validBoolMethod(cls, @"temporarilyOverrideMCLTargetSoC:error:", @[@"C", @"^@"]);
    if (!matches) {
        *reason = @"The installed battery-control interface is not compatible with this build.";
        return nil;
    }
    id client = [[cls alloc] initWithClientName:@"com.bezel.utility"];
    if (!client || ![client isMCLSupported]) {
        *reason = @"This Mac does not support the native charge limit.";
        return nil;
    }
    return client;
#endif
}

static NSDictionary *snapshot(id client, NSError **error) {
    NSUInteger enabled = [client isMCLCurrentlyEnabled:error];
    if (*error) return nil;
    if (enabled > 1) {
        *error = [NSError errorWithDomain:@"BezelCharge" code:2 userInfo:@{NSLocalizedDescriptionKey: @"The charge-limit state could not be interpreted."}];
        return nil;
    }
    uint8_t limit = [client getMCLLimitWithError:error];
    if (*error) return nil;
    if (enabled && (limit < 80 || limit > 100)) {
        *error = [NSError errorWithDomain:@"BezelCharge" code:3 userInfo:@{NSLocalizedDescriptionKey: @"The existing charge limit is outside the supported range."}];
        return nil;
    }
    return @{@"supported": @YES, @"enabled": enabled == 1 ? @YES : @NO, @"limit": limit >= 80 && limit <= 100 ? @(limit) : [NSNull null]};
}

static void restore(id client, NSDictionary *previous) {
    NSError *error = nil;
    NSNumber *limit = previous[@"limit"];
    if ([limit isKindOfClass:NSNumber.class]) [client setMCLLimit:limit.unsignedCharValue error:&error];
    error = nil;
    if ([previous[@"enabled"] boolValue]) [client enableMCL:&error];
    else [client disableMCL:&error];
}

static int respond(NSDictionary *response, int status) {
    NSMutableDictionary *result = [response mutableCopy];
    result[@"version"] = @1;
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    if (!json) return 70;
    [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    return status;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Validate before loading the framework: this executable is intentionally
        // not a general-purpose PowerUI bridge or privileged hardware helper.
        if (argc != 2) return respond(@{@"supported": @NO, @"error": @"Expected one charge-control action."}, 64);
        NSString *action = [NSString stringWithUTF8String:argv[1]];
        if (![@[@"status", @"limit80", @"topoff100", @"removeLimit"] containsObject:action])
            return respond(@{@"supported": @NO, @"error": @"Unknown charge-control action."}, 64);
        @try {
            NSString *reason = nil;
            id client = createClient(&reason);
            if (!client) return respond(@{@"supported": @NO, @"error": reason}, [action isEqual:@"status"] ? 0 : 69);
            NSError *error = nil;
            NSDictionary *previous = snapshot(client, &error);
            if (!previous) return respond(@{@"supported": @NO, @"error": error.localizedDescription}, 69);
            if ([action isEqual:@"status"]) return respond(previous, 0);
            BOOL succeeded = NO;
            if ([action isEqual:@"limit80"]) {
                succeeded = [client setMCLLimit:80 error:&error] && [client enableMCL:&error];
            } else if ([action isEqual:@"removeLimit"]) {
                succeeded = [client disableMCL:&error];
            } else {
                if (![previous[@"enabled"] boolValue])
                    return respond(@{@"supported": @YES, @"error": @"There is no charge limit to override."}, 65);
                succeeded = [client temporarilyOverrideMCLTargetSoC:100 error:&error];
            }
            if (!succeeded) {
                if ([action isEqual:@"limit80"]) restore(client, previous);
                return respond(@{@"supported": @YES, @"error": error.localizedDescription ?: @"macOS rejected the charge-control request."}, 74);
            }
            error = nil;
            NSDictionary *current = snapshot(client, &error);
            if (!current) return respond(@{@"supported": @YES, @"error": error.localizedDescription}, 74);
            BOOL verified = [action isEqual:@"topoff100"] ||
                ([action isEqual:@"limit80"] && [current[@"enabled"] boolValue] && [current[@"limit"] isEqual:@80]) ||
                ([action isEqual:@"removeLimit"] && ![current[@"enabled"] boolValue]);
            if (!verified) {
                if ([action isEqual:@"limit80"]) restore(client, previous);
                return respond(@{@"supported": @YES, @"error": @"macOS did not report the requested charge limit."}, 74);
            }
            return respond(current, 0);
        } @catch (NSException *exception) {
            return respond(@{@"supported": @NO, @"error": @"The native charge-control interface raised an exception."}, 70);
        }
    }
}
