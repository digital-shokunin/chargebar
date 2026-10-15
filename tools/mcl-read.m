// mcl-read: READ-ONLY query of macOS's own Charge Limit (MCL) via PowerUI.framework (private).
// Calls getters only; never setMCLLimit / enableMCL / disableMCL.
//
//   clang -fobjc-arc -framework Foundation -o build/mcl-read tools/mcl-read.m
//   build/mcl-read

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static const char *desc(NSError *err) { return err ? err.description.UTF8String : "nil"; }

int main(void) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW)) {
            fprintf(stderr, "dlopen PowerUI failed\n");
            return 1;
        }
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        if (!cls) { fprintf(stderr, "PowerUISmartChargeClient not found\n"); return 1; }
        id client = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithClientName:"), @"chargebar-probe");

        NSError *err = nil;
        BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isMCLSupported"));
        printf("isMCLSupported: %d\n", supported);

        err = nil;
        unsigned long long enabled = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"isMCLCurrentlyEnabled:"), &err);
        printf("isMCLCurrentlyEnabled: %llu err=%s\n", enabled, desc(err));

        err = nil;
        unsigned char limit = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"getMCLLimitWithError:"), &err);
        printf("getMCLLimit: %u err=%s\n", limit, desc(err));

        err = nil;
        id available = ((id (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"availableChargeLimitsWithError:"), &err);
        printf("availableChargeLimits: %s err=%s\n", available ? [[available description] UTF8String] : "nil", desc(err));

        err = nil;
        unsigned long long current = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"currentChargeLimit:"), &err);
        printf("currentChargeLimit: %llu err=%s\n", current, desc(err));
    }
    return 0;
}
