#import <Foundation/Foundation.h>
#import "MenuVisibility.h"
int main(void) { @autoreleasepool {
    printf("Read-only menu visibility interface: %s\n", BezelMenuVisibilityAvailable() ? "compatible" : "unavailable");
} return 0; }
