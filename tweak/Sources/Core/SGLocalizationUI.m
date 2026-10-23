#import "SGLocalization.h"
#import "SGLocalizationUI.h"
@implementation SGSettingsAlert
+ (UIAlertController *)alertControllerWithTitle:(NSString *)title message:(NSString *)message
                                preferredStyle:(UIAlertControllerStyle)style {
    return [UIAlertController alertControllerWithTitle:SGText(title) message:SGText(message) preferredStyle:style];
}
@end
@implementation SGSettingsAction
+ (UIAlertAction *)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style
                          handler:(void (^)(UIAlertAction *action))handler {
    return [UIAlertAction actionWithTitle:SGText(title) style:style handler:handler];
}
@end
