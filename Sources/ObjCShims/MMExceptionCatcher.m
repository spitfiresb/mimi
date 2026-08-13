#import "include/MMExceptionCatcher.h"

NSError *MMCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"(no reason)";
        return [NSError errorWithDomain:@"com.zainsaeed.mimi.objc-exception"
                                   code:1
                               userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       [NSString stringWithFormat:@"%@: %@", exception.name, reason]
                               }];
    }
}
