#import "PlayerAutomation.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <ScriptingBridge/ScriptingBridge.h>

@interface BezelPlayerErrors : NSObject <SBApplicationDelegate>
@property(nonatomic, strong, nullable) NSError *error;
@end
@implementation BezelPlayerErrors
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
    (void)event;
    self.error = error;
    return nil;
}
@end

@protocol BezelPlaybackCommands
- (void)playpause;
- (void)nextTrack;
- (void)previousTrack;
@end

static BOOL validTarget(NSString *bundleID, pid_t pid) {
    if (pid <= 0) return NO;
    if (![bundleID isEqualToString:@"com.apple.Music"] && ![bundleID isEqualToString:@"com.spotify.client"]) return NO;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return pid > 0 && app && !app.terminated && [app.bundleIdentifier isEqualToString:bundleID];
}

int32_t BezelPlayerPermission(NSString *bundleID, pid_t pid, BOOL request) {
    if (!validTarget(bundleID, pid)) return procNotFound;
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:pid];
    return AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, request);
}

static NSString *permissionMessage(OSStatus status) {
    if (status == procNotFound) return @"Open the player before connecting it.";
    if (status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent)
        return @"Connect this player and allow Bezel in System Settings → Privacy & Security → Automation.";
    return [NSString stringWithFormat:@"The player could not be reached (%d).", (int)status];
}

static SBApplication *playerApplication(pid_t pid, BezelPlayerErrors *errors) {
    SBApplication *app = [SBApplication applicationWithProcessIdentifier:pid];
    // A one-second Apple event timeout; consent is requested only by Connect.
    app.timeout = 60;
    app.sendMode = kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent;
    app.delegate = errors;
    return app;
}

static id property(SBObject *object, AEKeyword code) {
    return [[object propertyWithCode:code] get];
}
static NSString *text(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

NSDictionary<NSString *, id> *BezelReadPlayer(NSString *bundleID, pid_t pid, NSString *previousTrackID) {
    @autoreleasepool {
        OSStatus access = BezelPlayerPermission(bundleID, pid, NO);
        if (access != noErr) return @{@"error": permissionMessage(access)};
        @try {
            BezelPlayerErrors *errors = [BezelPlayerErrors new];
            SBApplication *app = playerApplication(pid, errors);
            if (!app || !app.running) return @{@"error": @"The player is no longer running."};
            id rawState = property(app, 'pPlS');
            if (errors.error) return @{@"error": errors.error.localizedDescription};
            BOOL music = [bundleID isEqualToString:@"com.apple.Music"];
            unsigned int state;
            if ([rawState isKindOfClass:NSNumber.class]) state = [rawState unsignedIntValue];
            else if ([rawState isKindOfClass:NSAppleEventDescriptor.class]) state = [rawState enumCodeValue];
            else return @{@"error": @"The player returned an unknown playback state."};
            BOOL known = state == 'kPSP' || state == 'kPSS' || state == 'kPSp' || (music && (state == 'kPSF' || state == 'kPSR')) || (!music && state <= 2);
            if (!known) return @{@"error": @"The player returned an unknown playback state."};
            BOOL playing = state == 'kPSP' || (!music && state == 1) || (music && (state == 'kPSF' || state == 'kPSR'));
            if (!playing) return @{@"playing": @NO};
            SBObject *track = [app propertyWithCode:'pTrk'];
            NSString *identity = text(property(track, music ? 'pPIS' : 'ID  '));
            if (errors.error) return @{@"error": errors.error.localizedDescription};
            if (identity.length > 0 && [identity isEqualToString:previousTrackID])
                return @{@"playing": @YES, @"id": identity, @"unchanged": @YES};
            NSString *title = text(property(track, 'pnam'));
            NSString *artist = text(property(track, 'pArt'));
            NSString *album = text(property(track, 'pAlb'));
            if (errors.error) return @{@"error": errors.error.localizedDescription};
            NSMutableDictionary *result = [@{@"playing": @YES, @"id": identity, @"title": title, @"artist": artist, @"album": album} mutableCopy];
            // Optional artwork failures must not discard otherwise valid metadata.
            @try {
                if (music) {
                    SBElementArray *artworks = [track elementArrayWithCode:'cArt'];
                    if (artworks.count > 0) {
                        id raw = property(artworks[0], 'pRaw');
                        NSData *data = [raw isKindOfClass:NSData.class] ? raw : nil;
                        if ([raw isKindOfClass:NSAppleEventDescriptor.class]) data = [raw data];
                        if (data.length > 0 && data.length <= 4 * 1024 * 1024) result[@"artwork"] = data;
                    }
                } else {
                    NSString *url = text(property(track, 'aUrl'));
                    if (url.length <= 4096) result[@"artworkURL"] = url;
                }
            } @catch (NSException *exception) { (void)exception; }
            return result;
        } @catch (NSException *exception) {
            (void)exception;
            return @{@"error": @"This player's scripting interface could not provide the current track."};
        }
    }
}

NSString *BezelControlPlayer(NSString *bundleID, pid_t pid, NSString *command) {
    @autoreleasepool {
        SEL selector;
        if ([command isEqualToString:@"playPause"]) selector = @selector(playpause);
        else if ([command isEqualToString:@"next"]) selector = @selector(nextTrack);
        else if ([command isEqualToString:@"previous"]) selector = @selector(previousTrack);
        else return @"Unknown playback action.";
        OSStatus access = BezelPlayerPermission(bundleID, pid, NO);
        if (access != noErr) return permissionMessage(access);
        @try {
            BezelPlayerErrors *errors = [BezelPlayerErrors new];
            SBApplication *app = playerApplication(pid, errors);
            if (!app || !app.running || ![app respondsToSelector:selector]) return @"The player does not expose this playback action.";
            id<BezelPlaybackCommands> player = (id<BezelPlaybackCommands>)app;
            if (selector == @selector(playpause)) [player playpause];
            else if (selector == @selector(nextTrack)) [player nextTrack];
            else [player previousTrack];
            return errors.error.localizedDescription;
        } @catch (NSException *exception) {
            (void)exception;
            return @"The player could not complete this playback action.";
        }
    }
}
