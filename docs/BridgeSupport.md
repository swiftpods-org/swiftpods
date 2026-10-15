# BridgeSupport

BridgeSupport is optional XML metadata describing Objective-C and C declarations
for runtime language bridges. Enable it in a Podfile with
`generate_bridge_support!`. Swift module interfaces and ordinary dependency
resolution do not use this metadata.

## Enable generation

```ruby
platform :osx, '13.0'
use_frameworks!
generate_bridge_support!

target 'Demo' do
  pod 'SimpleKit', :path => './Modules/SimpleKit'
end
```

SwiftPods invokes the external `gen_bridge_metadata` tool with the existing
aggregate umbrella header and its include directory. For the `Demo` target, the
paths are:

| File | Location |
| --- | --- |
| Input header | `Pods/Target Support Files/Pods-Demo/Pods-Demo-umbrella.h` |
| XML metadata | `Pods/Target Support Files/Pods-Demo/Pods-Demo.bridgesupport` |

The generated project includes the metadata as a resource. Generation describes
the aggregate declarations, including its version exports; it does not promise
metadata for every API in every dependent library.

## Tool availability and failures

The Apple metadata tool must be available through `PATH`. If it cannot be found,
installation fails with `SP-BRIDGE-TOOL` before attempting generation.

If the tool exits unsuccessfully or produces no output file, SwiftPods reports a
warning with the tool's diagnostic. It retains the metadata resource reference
and does not fabricate XML. The missing resource can consequently prevent the
next Xcode build. Fix the tool environment or disable generation if the project
does not need BridgeSupport.

Tool behavior depends on the installed Apple environment. The implementation is
in [NativeBridgeSupport.swift](../Sources/SwiftPodsCore/NativeBridgeSupport.swift).
The acceptance corpus checks the header path, generated aggregate declarations
and the failure diagnostic; its reports retain the actual tool arguments and
output. These checks do not establish coverage of arbitrary library APIs.
