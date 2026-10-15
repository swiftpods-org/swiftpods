#import <Foundation/Foundation.h>
#import "GameCore.h"
@interface GameCoreResourceAnchor : NSObject
@end
@implementation GameCoreResourceAnchor
@end
int gamecore_objc(void) { return (int)[@[@1, @2, @3] count]; }
NSBundle *gamecore_resource_bundle(void) {
    NSBundle *owner = [NSBundle bundleForClass:[GameCoreResourceAnchor class]];
    NSString *path = [owner pathForResource:@"GameCoreResources" ofType:@"bundle"];
    if (!path) path = [[NSBundle mainBundle] pathForResource:@"GameCoreResources" ofType:@"bundle"];
    return path ? [NSBundle bundleWithPath:path] : nil;
}
