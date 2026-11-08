// Exercise the production scanner without Apple events, browser access or TCC.
#pragma clang diagnostic push
// Including the implementation lets this fixture exercise its internal scanner.
// Clang otherwise applies header-only completeness warnings to that .m file.
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../../Untitled Project/Modules/AirBridge/PlayerAutomation.m"
#pragma clang diagnostic pop

@interface BrowserFixture : NSObject
@property double now;
@property double delay;
@property long timeout;
@property NSUInteger reads;
@property BOOL fail;
@property(strong) BezelPlayerErrors *errors;
@property(strong) NSMutableArray<NSNumber *> *timeouts;
@end
@implementation BrowserFixture
@end

@interface FakeProperty : NSObject
@property(strong) BrowserFixture *fixture;
@property(strong) id value;
@end
@implementation FakeProperty
- (id)get {
    self.fixture.reads++;
    self.fixture.now += fmin(self.fixture.delay, self.fixture.timeout / 60.0);
    if (self.fixture.fail) self.fixture.errors.error = [NSError errorWithDomain:NSOSStatusErrorDomain code:errAETimeout userInfo:nil];
    return self.value;
}
@end

@interface FakeTab : NSObject
@property(strong) BrowserFixture *fixture;
@end
@implementation FakeTab
- (id)propertyWithCode:(AEKeyword)code {
    FakeProperty *result = [FakeProperty new];
    result.fixture = self.fixture;
    result.value = code == 'URL ' ? @"https://example.com/" : @"1";
    return result;
}
@end

@interface FakeElements : NSObject
@property NSUInteger size;
@property NSUInteger countReads;
@property(strong) id element;
@end
@implementation FakeElements
- (NSUInteger)count { self.countReads++; return self.size; }
- (id)objectAtIndexedSubscript:(NSUInteger)index {
    NSCAssert(index < self.size, @"Out-of-bounds traversal");
    return self.element;
}
@end

@interface FakeWindow : NSObject
@property(strong) FakeElements *tabs;
@end
@implementation FakeWindow
- (id)elementArrayWithCode:(AEKeyword)code { NSCAssert(code == 'CrTb', @"Unexpected element"); return self.tabs; }
@end

@interface FakeBrowser : NSObject
@property(strong) BrowserFixture *fixture;
@property(strong) FakeElements *windows;
@end
@implementation FakeBrowser
- (id)elementArrayWithCode:(AEKeyword)code { NSCAssert(code == 'cwin', @"Unexpected element"); return self.windows; }
- (void)setTimeout:(long)timeout {
    NSCAssert(timeout > 0 && timeout <= 60, @"Invalid or unbounded Apple event timeout");
    self.fixture.timeout = timeout;
    [self.fixture.timeouts addObject:@(timeout)];
}
@end

static FakeBrowser *browserFixture(NSUInteger windows, NSUInteger tabs) {
    BrowserFixture *fixture = [BrowserFixture new];
    fixture.errors = [BezelPlayerErrors new];
    fixture.timeouts = [NSMutableArray new];
    FakeTab *tab = [FakeTab new]; tab.fixture = fixture;
    FakeElements *tabList = [FakeElements new]; tabList.size = tabs; tabList.element = tab;
    FakeWindow *window = [FakeWindow new]; window.tabs = tabList;
    FakeElements *windowList = [FakeElements new]; windowList.size = windows; windowList.element = window;
    FakeBrowser *browser = [FakeBrowser new]; browser.fixture = fixture; browser.windows = windowList;
    return browser;
}
static NSDictionary *scan(FakeBrowser *browser) {
    return scanYouTubeMusic((SBApplication *)browser, browser.fixture.errors, @"com.brave.Browser", nil, nil, 0, 0, ^{ return browser.fixture.now; });
}
int main(void) {
    @autoreleasepool {
        FakeBrowser *fast = browserFixture(1, 200);
        NSDictionary *reply = scan(fast);
        NSCAssert(!reply[@"error"] && ![reply[@"playing"] boolValue], @"An empty scan must succeed");
        NSCAssert(fast.fixture.reads == 128, @"Scan must stop at 128 tabs");
        NSCAssert(fast.windows.countReads == 1 && ((FakeWindow *)fast.windows.element).tabs.countReads == 1,
                  @"Remote counts must be fetched once per collection");
        FakeBrowser *manyWindows = browserFixture(20, 1);
        scan(manyWindows);
        NSCAssert(manyWindows.fixture.reads == 16, @"Scan must stop at 16 windows");

        FakeBrowser *slow = browserFixture(1, 128);
        slow.fixture.delay = 0.4;
        reply = scan(slow);
        NSCAssert([reply[@"error"] containsString:@"too long"], @"Whole-scan deadline must report timeout");
        NSCAssert(slow.fixture.reads <= 8 && slow.fixture.now <= 3.0001, @"Slow browser must not block for 128 event timeouts");
        NSCAssert(slow.fixture.timeouts.lastObject.longValue < 60, @"Final event must use remaining budget");

        FakeBrowser *failed = browserFixture(1, 128);
        failed.fixture.fail = YES;
        reply = scan(failed);
        NSCAssert(reply[@"error"] && failed.fixture.reads == 1, @"A transport error must abort immediately");
        puts("Browser scan checks passed: total monotonic deadline, shrinking event timeouts, count caching, tab/window caps and immediate transport failure.");
    }
}
