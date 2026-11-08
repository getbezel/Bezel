#import "PlayerAutomation.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <ScriptingBridge/ScriptingBridge.h>
#import <math.h>
#import <time.h>

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

static BOOL isYouTubeBrowser(NSString *bundleID) {
    return [bundleID isEqualToString:@"com.google.Chrome"] || [bundleID isEqualToString:@"com.brave.Browser"];
}

static NSString *youTubeBrowserName(NSString *bundleID) {
    return [bundleID isEqualToString:@"com.brave.Browser"] ? @"Brave" : @"Chrome";
}

static BOOL validTarget(NSString *bundleID, pid_t pid) {
    if (pid <= 0) return NO;
    if (![bundleID isEqualToString:@"com.apple.Music"] && ![bundleID isEqualToString:@"com.spotify.client"] && !isYouTubeBrowser(bundleID)) return NO;
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
            BOOL paused = state == 'kPSp' || (!music && state == 2);
            if (!playing && !paused) return @{@"playing": @NO};
            NSNumber *volume = nil;
            @try {
                id rawVolume = property(app, 'pVol');
                if ([rawVolume isKindOfClass:NSNumber.class] && [rawVolume doubleValue] >= 0 && [rawVolume doubleValue] <= 100)
                    volume = rawVolume;
            } @catch (NSException *exception) { (void)exception; }
            // Volume support is optional and must not discard track details.
            errors.error = nil;
            SBObject *track = [app propertyWithCode:'pTrk'];
            NSString *identity = text(property(track, music ? 'pPIS' : 'ID  '));
            if (errors.error) return @{@"error": errors.error.localizedDescription};
            NSNumber *position = nil;
            NSNumber *duration = nil;
            @try {
                id rawPosition = property(app, 'pPos');
                id rawDuration = property(track, 'pDur');
                if ([rawPosition isKindOfClass:NSNumber.class] && [rawDuration isKindOfClass:NSNumber.class]) {
                    double seconds = [rawPosition doubleValue];
                    // Music reports seconds; Spotify's track duration value is milliseconds.
                    double length = [rawDuration doubleValue] / (music ? 1.0 : 1000.0);
                    if (isfinite(seconds) && isfinite(length) && seconds >= 0 && length > 0 && length <= 604800 &&
                        identity.length > 0 && ![identity hasPrefix:@"spotify:ad:"]) {
                        position = @(fmin(seconds, length)); duration = @(length);
                    }
                }
            } @catch (NSException *exception) { (void)exception; }
            errors.error = nil;
            if (identity.length > 0 && [identity isEqualToString:previousTrackID]) {
                NSMutableDictionary *cached = [@{@"playing": @(playing), @"id": identity, @"unchanged": @YES} mutableCopy];
                if (volume) cached[@"volume"] = volume;
                if (position && duration) { cached[@"position"] = position; cached[@"duration"] = duration; }
                return cached;
            }
            NSString *title = text(property(track, 'pnam'));
            NSString *artist = text(property(track, 'pArt'));
            NSString *album = text(property(track, 'pAlb'));
            if (errors.error) return @{@"error": errors.error.localizedDescription};
            NSMutableDictionary *result = [@{@"playing": @(playing), @"id": identity, @"title": title, @"artist": artist, @"album": album} mutableCopy];
            if (volume) result[@"volume"] = volume;
            if (position && duration) { result[@"position"] = position; result[@"duration"] = duration; }
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

NSString *BezelSetPlayerVolume(NSString *bundleID, pid_t pid, NSInteger percent) {
    @autoreleasepool {
        if (percent < 0 || percent > 100) return @"Volume must be between 0 and 100.";
        OSStatus access = BezelPlayerPermission(bundleID, pid, NO);
        if (access != noErr) return permissionMessage(access);
        @try {
            BezelPlayerErrors *errors = [BezelPlayerErrors new];
            SBApplication *app = playerApplication(pid, errors);
            if (!app || !app.running) return @"The player is no longer running.";
            [[app propertyWithCode:'pVol'] setTo:@(percent)];
            return errors.error.localizedDescription;
        } @catch (NSException *exception) {
            (void)exception;
            return @"The player could not change its volume.";
        }
    }
}

@protocol BezelBrowserTab
- (id)executeJavascript:(NSString *)javascript;
@end

static BOOL isYouTubeMusicURL(NSString *value) {
    NSURL *url = [NSURL URLWithString:value];
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
        [url.host.lowercaseString isEqualToString:@"music.youtube.com"] && !url.user && !url.password;
}

static NSDictionary *youtubeReply(SBObject *tab, NSDictionary *request, BezelPlayerErrors *errors, NSString *browserName) {
    NSURL *sourceURL = [NSBundle.mainBundle URLForResource:@"YouTubeMusic" withExtension:@"js"];
    NSString *source = sourceURL ? [NSString stringWithContentsOfURL:sourceURL encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!source) return @{@"error": @"The YouTube Music connection script is missing. Reinstall Bezel."};
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"%@(%@)", source, json];
    errors.error = nil;
    id value = [(id<BezelBrowserTab>)tab executeJavascript:script];
    if (errors.error || ![value isKindOfClass:NSString.class])
        return @{@"error": [NSString stringWithFormat:@"In %@, enable View → Developer → Allow JavaScript from Apple Events, then reconnect YouTube Music.", browserName]};
    if ([(NSString *)value length] > 16384) return @{@"error": @"YouTube Music returned too much metadata."};
    id result = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [result isKindOfClass:NSDictionary.class] ? result : @{@"error": @"YouTube Music did not return track details."};
}

// A browser can expose hundreds of tabs. A per-event timeout alone multiplies
// into minutes on an unresponsive browser and blocks every player on the reader
// actor. Keep one monotonic budget for the entire visit, including controls.
typedef CFTimeInterval (^BezelMediaClock)(void);
static BOOL prepareBrowserEvent(SBApplication *browser, CFTimeInterval deadline, BezelMediaClock clock) {
    CFTimeInterval remaining = deadline - clock();
    if (remaining < 1.0 / 60.0) return NO;
    // Apple event timeouts are ticks (1/60 second). Never use 0: it means default.
    browser.timeout = (long)fmin(60, floor(remaining * 60));
    return YES;
}

static NSDictionary *scanYouTubeMusic(SBApplication *browser, BezelPlayerErrors *errors,
                                     NSString *bundleID, NSString *previousTrackID, NSString *command,
                                     NSInteger volume, double seconds, BezelMediaClock clock) {
    CFTimeInterval deadline = clock() + 3.0;
    NSDictionary *timeout = @{@"error": @"The browser took too long to respond. Try again when it is responsive."};
    NSArray *parts = [previousTrackID componentsSeparatedByString:@"|"];
    NSString *expectedTab = parts.count > 1 ? parts[0] : nil;
    NSString *expectedSong = parts.count > 1 ? [[parts subarrayWithRange:NSMakeRange(1, parts.count-1)] componentsJoinedByString:@"|"] : nil;
    NSDictionary *candidate = nil;
    NSDictionary *failure = nil;
    NSUInteger checked = 0;
    SBElementArray *windows = [browser elementArrayWithCode:'cwin'];
    if (!prepareBrowserEvent(browser, deadline, clock)) return timeout;
    NSUInteger windowCount = MIN(windows.count, 16);
    if (errors.error) return @{@"error": errors.error.localizedDescription};
    for (NSUInteger w = 0; w < windowCount && checked < 128; w++) {
        if (!prepareBrowserEvent(browser, deadline, clock)) return timeout;
        SBElementArray *tabs = [windows[w] elementArrayWithCode:'CrTb'];
        NSUInteger tabCount = MIN(tabs.count, 128 - checked);
        if (errors.error) return @{@"error": errors.error.localizedDescription};
        for (NSUInteger t = 0; t < tabCount; t++, checked++) {
            if (!prepareBrowserEvent(browser, deadline, clock)) return timeout;
            SBObject *tab = tabs[t];
            NSString *url = text(property(tab, 'URL '));
            if (errors.error) return @{@"error": errors.error.localizedDescription};
            if (!isYouTubeMusicURL(url)) continue;
            if (!prepareBrowserEvent(browser, deadline, clock)) return timeout;
            NSString *tabID = [property(tab, 'ID  ') description];
            if (errors.error) return @{@"error": errors.error.localizedDescription};
            if (!tabID.length) continue;
            if (command && ![tabID isEqualToString:expectedTab]) continue;
            NSMutableDictionary *request = [@{@"action": command ?: @"read"} mutableCopy];
            if (command) { request[@"expectedID"] = expectedSong ?: @""; request[@"volume"] = @(volume); request[@"seconds"] = @(seconds); }
            if (!prepareBrowserEvent(browser, deadline, clock)) return timeout;
            NSDictionary *reply = youtubeReply(tab, request, errors, youTubeBrowserName(bundleID));
            if (reply[@"error"]) { if (command || errors.error) return reply; failure = reply; continue; }
            if (command) return reply; // Do not report failure after a successful side effect.
            if (clock() >= deadline) return timeout;
            if (![text(reply[@"id"]) length]) continue;
            NSMutableDictionary *track = [reply mutableCopy];
            track[@"id"] = [NSString stringWithFormat:@"%@|%@", tabID, reply[@"id"]];
            if ([reply[@"playing"] boolValue]) return track;
            if (!candidate || [tabID isEqualToString:expectedTab]) candidate = track;
        }
    }
    if (clock() >= deadline) return timeout;
    if (command) return @{@"error": @"The connected YouTube Music tab was closed. Start a song and try again."};
    return candidate ?: failure ?: @{@"playing": @NO};
}

static NSDictionary *visitYouTubeMusic(NSString *bundleID, pid_t pid, NSString *previousTrackID, NSString *command, NSInteger volume, double seconds) {
    if (!isYouTubeBrowser(bundleID)) return @{@"error": @"Choose a supported YouTube Music browser."};
    OSStatus access = BezelPlayerPermission(bundleID, pid, NO);
    if (access != noErr) return @{@"error": permissionMessage(access)};
    @try {
        BezelPlayerErrors *errors = [BezelPlayerErrors new];
        SBApplication *browser = playerApplication(pid, errors);
        if (!browser || !browser.running) return @{@"error": @"The browser is no longer running."};
        return scanYouTubeMusic(browser, errors, bundleID, previousTrackID, command, volume, seconds, ^{
            return (CFTimeInterval)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
        });
    } @catch (NSException *exception) {
        (void)exception;
        return @{@"error": [NSString stringWithFormat:@"%@ could not read YouTube Music. Check Automation access and Allow JavaScript from Apple Events.", youTubeBrowserName(bundleID)]};
    }
}

NSDictionary<NSString *, id> *BezelReadYouTubeMusic(NSString *bundleID, pid_t pid, NSString *previousTrackID) {
    @autoreleasepool { return visitYouTubeMusic(bundleID, pid, previousTrackID, nil, 0, 0); }
}
NSString *BezelControlYouTubeMusic(NSString *bundleID, pid_t pid, NSString *trackID, NSString *command, NSInteger volume) {
    @autoreleasepool {
        if (![@[@"playPause", @"previous", @"next", @"volume"] containsObject:command]) return @"Unknown playback action.";
        if ([command isEqualToString:@"volume"] && (volume < 0 || volume > 100)) return @"Volume must be between 0 and 100.";
        return visitYouTubeMusic(bundleID, pid, trackID, command, volume, 0)[@"error"];
    }
}

NSString *BezelSeekYouTubeMusic(NSString *bundleID, pid_t pid, NSString *trackID, double seconds) {
    @autoreleasepool {
        if (!isfinite(seconds) || seconds < 0 || seconds > 604800) return @"Choose a valid position in the track.";
        return visitYouTubeMusic(bundleID, pid, trackID, @"seek", 0, seconds)[@"error"];
    }
}

NSString *BezelSeekPlayer(NSString *bundleID, pid_t pid, NSString *trackID, double seconds) {
    @autoreleasepool {
        if (!isfinite(seconds) || seconds < 0 || seconds > 604800) return @"Choose a valid position in the track.";
        if (!trackID.length || [trackID hasPrefix:@"spotify:ad:"]) return @"This source doesn’t support seeking.";
        OSStatus access = BezelPlayerPermission(bundleID, pid, NO);
        if (access != noErr) return permissionMessage(access);
        @try {
            BezelPlayerErrors *errors = [BezelPlayerErrors new];
            SBApplication *app = playerApplication(pid, errors);
            BOOL music = [bundleID isEqualToString:@"com.apple.Music"];
            if (!music && ![bundleID isEqualToString:@"com.spotify.client"]) return @"Seeking is unavailable for this player.";
            SBObject *track = [app propertyWithCode:'pTrk'];
            NSString *actualID = text(property(track, music ? 'pPIS' : 'ID  '));
            if (errors.error) return errors.error.localizedDescription;
            if (![actualID isEqualToString:trackID]) return @"The track changed. Try seeking again.";
            id raw = property(track, 'pDur');
            if (![raw isKindOfClass:NSNumber.class]) return @"This track has no seekable timeline.";
            double duration = [raw doubleValue] / (music ? 1.0 : 1000.0);
            if (errors.error) return errors.error.localizedDescription;
            if (!isfinite(duration) || duration <= 0 || duration > 604800) return @"This track has no seekable timeline.";
            // Recheck after duration lookup before changing the player's global position.
            if (![text(property([app propertyWithCode:'pTrk'], music ? 'pPIS' : 'ID  ')) isEqualToString:trackID])
                return @"The track changed. Try seeking again.";
            if (errors.error) return errors.error.localizedDescription;
            [[app propertyWithCode:'pPos'] setTo:@(fmin(seconds, duration))];
            return errors.error.localizedDescription;
        } @catch (NSException *exception) {
            (void)exception;
            return @"The player could not seek to that position.";
        }
    }
}
