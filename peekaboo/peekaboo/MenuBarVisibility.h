#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Asks macOS to show only these apps' menu bar items, keeping its own items visible.
/// `completion` runs on the main queue with a token to hold, or an error. Hiding lasts until
/// the token is passed to `PKBMenuBarRestrictionEnd`, or until this process dies.
void PKBMenuBarRestrictionBegin(NSArray<NSString *> *allowedBundleIDs,
                                void (^completion)(id _Nullable token, NSError *_Nullable error));

void PKBMenuBarRestrictionEnd(id token);

/// Lets this app hide the pointer while it isn't frontmost. Does nothing if macOS drops the private call.
void PKBAllowCursorHidingInBackground(void);

/// A picture of what's on screen below a window, at 1x. Nil if macOS drops the call, which it no longer
/// declares publicly, or Screen Recording isn't granted.
CGImageRef _Nullable PKBCreateImageBelowWindow(CGRect rect, CGWindowID window) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
