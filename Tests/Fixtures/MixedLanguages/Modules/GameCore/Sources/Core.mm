#import <Foundation/Foundation.h>
#include <array>
#include "GameCore.h"
int gamecore_objcpp(void) { return (int)std::array<NSNumber *, 4>{ @1, @2, @3, @4 }.size(); }
