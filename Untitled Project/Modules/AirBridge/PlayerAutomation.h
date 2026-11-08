#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN
/// Only Music, Spotify and supported YouTube Music browsers are accepted. A PID target prevents launching a player.
FOUNDATION_EXPORT int32_t BezelPlayerPermission(NSString *bundleID, pid_t pid, BOOL request);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *BezelReadPlayer(NSString *bundleID, pid_t pid, NSString * _Nullable previousTrackID);
FOUNDATION_EXPORT NSString * _Nullable BezelControlPlayer(NSString *bundleID, pid_t pid, NSString *command);
FOUNDATION_EXPORT NSString * _Nullable BezelSetPlayerVolume(NSString *bundleID, pid_t pid, NSInteger percent);
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSDictionary<NSString *, id> *BezelReadYouTubeMusic(NSString *bundleID, pid_t pid, NSString * _Nullable previousTrackID);
FOUNDATION_EXPORT NSString * _Nullable BezelSeekYouTubeMusic(NSString *bundleID, pid_t pid, NSString *trackID, double seconds);
FOUNDATION_EXPORT NSString * _Nullable BezelControlYouTubeMusic(NSString *bundleID, pid_t pid, NSString *trackID, NSString *command, NSInteger volume);
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * _Nullable BezelSeekPlayer(NSString *bundleID, pid_t pid, NSString *trackID, double seconds);
NS_ASSUME_NONNULL_END
