#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN
/// Only Music and Spotify are accepted. A PID target prevents launching a player.
FOUNDATION_EXPORT int32_t BezelPlayerPermission(NSString *bundleID, pid_t pid, BOOL request);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *BezelReadPlayer(NSString *bundleID, pid_t pid, NSString * _Nullable previousTrackID);
FOUNDATION_EXPORT NSString * _Nullable BezelControlPlayer(NSString *bundleID, pid_t pid, NSString *command);
NS_ASSUME_NONNULL_END
