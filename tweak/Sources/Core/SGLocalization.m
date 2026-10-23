#import "SGLocalization.h"
#import <dispatch/dispatch.h>

NSString *SGTextForLanguage(NSString *text, NSString *language) {
    if (!text || ![language.lowercaseString hasPrefix:@"zh"]) return text;
    static NSDictionary<NSString *, NSString *> *chinese;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        chinese = @{
#include "SGChinese.inc"
        };
    });
    return chinese[text] ?: text;
}

NSString *SGText(NSString *text) {
    return SGTextForLanguage(text, NSLocale.preferredLanguages.firstObject);
}
