#import "MenuVisibility.h"
#import <objc/runtime.h>

@interface NSObject (BezelMenuInterface)
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
- (void)activateWithConfiguration:(NSObject *)configuration completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end

static NSError *menuError(NSString *message) {
    return [NSError errorWithDomain:@"BezelMenuBar" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL methodMatches(Class cls, NSString *name, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || signature.numberOfArguments != arguments.count + 2 || strcmp(signature.methodReturnType, result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    }
    return YES;
}

BOOL BezelMenuVisibilityAvailable(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) return NO;
    NSBundle *framework = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MenuBarClientCore.framework"];
    if (![framework load]) return NO;
    Class configuration = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    return configuration && assertion &&
        methodMatches(configuration, @"initWithAllowedSystemItems:allowedBundleIdentifiers:", @encode(id), @[@"@", @"@"]) &&
        methodMatches(assertion, @"activateWithConfiguration:completionHandler:", @encode(void), @[@"@", @"@?"]) &&
        methodMatches(assertion, @"invalidate", @encode(void), @[]);
}

NSObject *BezelMenuVisibilityActivate(NSArray<NSString *> *allowedBundles,
                                     void (^completion)(NSObject *, NSError *)) {
    void (^finish)(NSObject *, NSError *) = ^(NSObject *restriction, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(restriction, error); });
    };
    if (!BezelMenuVisibilityAvailable()) {
        finish(nil, menuError(@"This macOS version does not provide a compatible menu-bar visibility interface."));
        return nil;
    }
    @try {
        // Only the menu-bar subsystem is restricted. System items stay visible;
        // no assessment session or app/window/input lockdown is started.
        NSMutableArray<NSNumber *> *systemItems = [NSMutableArray arrayWithCapacity:64];
        for (NSUInteger i = 0; i < 64; i++) [systemItems addObject:@(i)];
        NSObject *configuration = [[NSClassFromString(@"MBAssessmentModeConfiguration") alloc]
                                   initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:[allowedBundles copy]];
        NSObject *restriction = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!configuration || !restriction) {
            finish(nil, menuError(@"macOS could not create the menu-bar visibility request."));
            return nil;
        }
        [restriction activateWithConfiguration:configuration completionHandler:^(NSError *error) {
            if (error) [restriction invalidate];
            finish(error ? nil : restriction, error);
        }];
        return restriction;
    } @catch (NSException *exception) {
        finish(nil, menuError(@"The installed menu-bar interface rejected the request."));
        return nil;
    }
}

void BezelMenuVisibilityRelease(NSObject *restriction) {
    @try {
        if ([restriction respondsToSelector:@selector(invalidate)]) [restriction invalidate];
    } @catch (NSException *exception) {
        NSLog(@"Bezel: the menu-bar restriction could not be released normally.");
    }
}
