#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C NSException into an NSError.
/// AVFoundation throws NSExceptions (not Swift errors) for engine/tap misuse;
/// Swift cannot catch those, so they unwind through async callers and strand
/// their state. Returns nil on success.
NSError *_Nullable MMCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
