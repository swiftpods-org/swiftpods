#import <UIKit/UIKit.h>
#import <GameCore/GameCore.h>
#ifdef SWIFTPODS_VENDOR_FIXTURE
#import <VendorAdapter/VendorAdapter.h>
#endif

static NSDictionary *validate_fixture(void) {
    int value = gamecore_c() + gamecore_cpp() + gamecore_objc() + gamecore_objcpp() + gamecore_swift();
    NSBundle *bundle = gamecore_resource_bundle();
    BOOL resources = [[bundle localizedStringForKey:@"fixture_title" value:nil table:nil] isEqualToString:@"SwiftPods Resources"];
    BOOL privacy = [bundle pathForResource:@"PrivacyInfo" ofType:@"xcprivacy"] != nil;
    int vendor = 0;
#ifdef SWIFTPODS_VENDOR_FIXTURE
    vendor = vendor_adapter_value();
#endif
    return @{@"languages": @(value), @"resources": @(resources), @"privacy": @(privacy), @"vendor": @(vendor)};
}

@interface SwiftPodsFixtureSceneDelegate : NSObject <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation SwiftPodsFixtureSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session;
    (void)options;
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    NSDictionary *result = validate_fixture();
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    [data writeToURL:[documents URLByAppendingPathComponent:@"validation.json"] atomically:YES];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor systemBackgroundColor];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 100, 340, 80)];
    label.numberOfLines = 0;
    label.text = [NSString stringWithFormat:@"SwiftPods fixture\n%@", result];
    [controller.view addSubview:label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
}
@end

@interface SwiftPodsFixtureAppDelegate : NSObject <UIApplicationDelegate>
@end
@implementation SwiftPodsFixtureAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application;
    (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Fixture" sessionRole:session.role];
    configuration.delegateClass = [SwiftPodsFixtureSceneDelegate class];
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SwiftPodsFixtureAppDelegate class]));
    }
}
