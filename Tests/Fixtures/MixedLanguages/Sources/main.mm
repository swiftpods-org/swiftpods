#import <Foundation/Foundation.h>
#import <GameCore/GameCore.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        int result = gamecore_c() + gamecore_cpp() + gamecore_objc() + gamecore_objcpp() + gamecore_swift();
        NSBundle *resources = gamecore_resource_bundle();
        NSString *title = [resources localizedStringForKey:@"fixture_title" value:nil table:nil];
        BOOL privacy = [resources pathForResource:@"PrivacyInfo" ofType:@"xcprivacy"] != nil;
        if (result != 15 || ![title isEqualToString:@"SwiftPods Resources"] || !privacy) return 2;
        printf("mixed=15 resources=ok privacy=ok\n");
        return 0;
    }
}
