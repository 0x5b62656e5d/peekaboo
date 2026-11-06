#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Asks macOS to show only these apps' menu bar items, keeping its own items visible.
/// `completion` runs on the main queue with a token to hold, or an error. Hiding lasts until
/// the token is passed to `PKBMenuBarRestrictionEnd`, or until this process dies.
void PKBMenuBarRestrictionBegin(NSArray<NSString *> *allowedBundleIDs,
                                void (^completion)(id _Nullable token, NSError *_Nullable error));

void PKBMenuBarRestrictionEnd(id token);

NS_ASSUME_NONNULL_END
