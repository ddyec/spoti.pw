#import <UIKit/UIKit.h>
// Explicit factories used by mod settings; never swizzle Spotify's UIKit objects.
@interface SGSettingsAlert : NSObject
+ (UIAlertController *)alertControllerWithTitle:(NSString *)title message:(NSString *)message
                                preferredStyle:(UIAlertControllerStyle)style;
@end
@interface SGSettingsAction : NSObject
+ (UIAlertAction *)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style
                          handler:(void (^)(UIAlertAction *action))handler;
@end
