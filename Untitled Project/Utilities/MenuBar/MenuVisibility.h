#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL BezelMenuVisibilityAvailable(void);
NSObject * _Nullable BezelMenuVisibilityActivate(NSArray<NSString *> *allowedBundles,
                                                void (^completion)(NSObject * _Nullable restriction, NSError * _Nullable error));
void BezelMenuVisibilityRelease(NSObject *restriction);
NS_ASSUME_NONNULL_END
