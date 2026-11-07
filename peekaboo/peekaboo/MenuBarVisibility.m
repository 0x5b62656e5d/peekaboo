#import "MenuBarVisibility.h"
#import <dlfcn.h>
#import <objc/message.h>

// The private framework behind assessment (exam lockdown) mode. It's loaded at runtime and every
// call is guarded, so a macOS update that changes it surfaces as an error instead of a crash.
static const char *const PKBFrameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";

// macOS ignores identifiers it doesn't have, so this range covers every system item.
static const NSInteger PKBSystemItemCount = 64;

static NSError *PKBError(NSString *reason) {
    return [NSError errorWithDomain:@"peekaboo" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
}

void PKBMenuBarRestrictionBegin(NSArray<NSString *> *allowedBundleIDs,
                                void (^completion)(id _Nullable, NSError *_Nullable)) {
    void (^finish)(id, NSError *) = ^(id token, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(token, error); });
    };

    SEL configInit = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
    SEL activate = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
    Class configClass = dlopen(PKBFrameworkPath, RTLD_NOW | RTLD_LOCAL) ? NSClassFromString(@"MBAssessmentModeConfiguration") : nil;
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    if (![configClass instancesRespondToSelector:configInit] || ![assertionClass instancesRespondToSelector:activate]) {
        finish(nil, PKBError(@"This version of macOS doesn't support hiding"));
        return;
    }

    NSMutableArray<NSNumber *> *systemItems = [NSMutableArray arrayWithCapacity:PKBSystemItemCount];
    for (NSInteger i = 0; i < PKBSystemItemCount; i++) [systemItems addObject:@(i)];

    @try {
        id config = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)([configClass alloc], configInit, systemItems, allowedBundleIDs);
        id assertion = [[assertionClass alloc] init];
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(assertion, activate, config, ^(NSError *error) {
            finish(error ? nil : assertion, error);
        });
    } @catch (NSException *exception) {
        finish(nil, PKBError(exception.reason ?: exception.name));
    }
}

void PKBMenuBarRestrictionEnd(id token) {
    @try {
        ((void (*)(id, SEL))objc_msgSend)(token, NSSelectorFromString(@"invalidate"));
    } @catch (NSException *exception) {
        NSLog(@"peekaboo: ending restriction failed: %@", exception.reason);
    }
}

void PKBAllowCursorHidingInBackground(void) {
    int (*defaultConnection)(void) = dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
    void (*setProperty)(int, int, CFStringRef, CFTypeRef) = dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
    if (defaultConnection && setProperty) {
        setProperty(defaultConnection(), defaultConnection(), CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
    }
}
