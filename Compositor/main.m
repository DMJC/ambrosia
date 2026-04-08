#import <Foundation/Foundation.h>
#import "AmbrosiaCompositor.h"

#include <signal.h>
#include <wlr/util/log.h>

static AmbrosiaCompositor *gCompositorRef = nil;

static void handle_signal(int sig)
{
    [gCompositorRef stop];
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        gCompositorRef = [[AmbrosiaCompositor alloc] init];
        if (!gCompositorRef) {
            fprintf(stderr, "ambrosia: failed to allocate compositor\n");
            return 1;
        }

        NSError *error = nil;
        if (![gCompositorRef setup:&error]) {
            fprintf(stderr, "ambrosia: setup failed: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        signal(SIGTERM, handle_signal);
        signal(SIGINT,  handle_signal);

        [gCompositorRef run];
    }
    return 0;
}
