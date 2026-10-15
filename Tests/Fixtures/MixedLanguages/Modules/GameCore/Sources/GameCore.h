#pragma once
#ifdef __OBJC__
@class NSBundle;
#endif
#ifdef __cplusplus
extern "C" {
#endif
int gamecore_c(void);
int gamecore_cpp(void);
int gamecore_objc(void);
int gamecore_objcpp(void);
int gamecore_swift(void);
#ifdef __OBJC__
NSBundle * _Nullable gamecore_resource_bundle(void);
#endif
#ifdef __cplusplus
}
#endif
