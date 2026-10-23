// Translate mod-owned presentation text only. Preferences, identifiers and network data stay raw.
#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSString *SGText(NSString *text);
FOUNDATION_EXPORT NSString *SGTextForLanguage(NSString *text, NSString *language);
