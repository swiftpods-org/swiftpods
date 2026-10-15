import Foundation

extension NativeXcode {
    static let iOSAppHostSource = """
        #import <UIKit/UIKit.h>
        #import <TargetConditionals.h>

        @interface SwiftPodsSceneDelegate : NSObject <UIWindowSceneDelegate>
        @property(nonatomic, strong) UIWindow *window;
        @end
        @implementation SwiftPodsSceneDelegate
        - (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
            (void)session;
            (void)options;
            if (![scene isKindOfClass:[UIWindowScene class]]) return;
            self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
            UIViewController *controller = [[UIViewController alloc] init];
        #if TARGET_OS_TV
            controller.view.backgroundColor = [UIColor blackColor];
        #else
            controller.view.backgroundColor = [UIColor systemBackgroundColor];
        #endif
            UILabel *label = [[UILabel alloc] initWithFrame:controller.view.bounds];
            label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            label.text = @"SwiftPods";
            label.textAlignment = NSTextAlignmentCenter;
            [controller.view addSubview:label];
            self.window.rootViewController = controller;
            [self.window makeKeyAndVisible];
        }
        @end

        @interface SwiftPodsAppDelegate : NSObject <UIApplicationDelegate> @end
        @implementation SwiftPodsAppDelegate
        - (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
            (void)application;
            (void)options;
            UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"SwiftPods" sessionRole:session.role];
            configuration.delegateClass = [SwiftPodsSceneDelegate class];
            return configuration;
        }
        @end

        int main(int argc, char *argv[]) {
            @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([SwiftPodsAppDelegate class])); }
        }
        """
}
