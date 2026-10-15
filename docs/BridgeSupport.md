# BridgeSupport compatibility difference

BridgeSupport is optional XML metadata describing Objective-C/C declarations for
runtime language bridges. `generate_bridge_support!` enables it. The ordinary
dependency resolver, compiled libraries and Swift module interfaces do not use
this metadata.

The isolated 1.17.0 reference and SwiftPods produce different results for this
option in the same environment. SwiftPods preserves the input and fixes the
reference's header path. This is a tested improvement under the input-compatible
contract; reproducing the reference failure is not required.

## Reproducer

Create a macOS application target named `Demo` and a local pod with a public
header, then install this manifest with each engine in separate directories:

```ruby
platform :osx, '13.0'
use_frameworks!
generate_bridge_support!
target 'Demo' do
  pod 'SimpleKit', :path => './Modules/SimpleKit'
end
```

The automated fixture supplies the same wrapper around
`/usr/bin/gen_bridge_metadata` to both installers. It removes Ruby/Bundler
variables specific to the reference process and records the actual arguments.

```sh
python3 scripts/native_ecosystem_tests.py --gem-home /path/to/reference-gems
```

`test-results/native-ecosystem-reference.json` identifies the retained fixture
directory. `metadata-tool.log` records arguments and `bridge-reference.log`
contains the reference installation output. The complete acceptance archive
includes these logs.

## Cause

The reference aggregate target installer derives header paths with:

```ruby
sandbox.root + build_file.file_ref.path
```

The file reference stores `Pods-Demo-umbrella.h`. Its PBX group supplies the
remaining `Target Support Files/Pods-Demo` components. Concatenating the sandbox
root and the filename loses that group path:

| | Header passed to the Apple tool |
|---|---|
| Reference | `Pods/Pods-Demo-umbrella.h` — absent |
| SwiftPods | `Pods/Target Support Files/Pods-Demo/Pods-Demo-umbrella.h` — present |

The reference implementation is retained only in the test tree:
[aggregate target installer](../Tests/Reference/vendor/cocoapods/lib/cocoapods/installer/xcode/pods_project_generator/aggregate_target_installer.rb)
and [metadata generator](../Tests/Reference/vendor/cocoapods/lib/cocoapods/generator/bridge_support.rb).
SwiftPods invokes the external tool from
[NativeBridgeSupport.swift](../Sources/SwiftPodsCore/NativeBridgeSupport.swift).

## Observable behavior

The Apple tool fails to resolve the reference's nonexistent header. The
reference installer still exits successfully, leaves a `.bridgesupport` resource
reference in its generated project, and produces no metadata file. SwiftPods
passes the existing aggregate header and produces XML containing aggregate
version declarations. This does not imply metadata for every declaration in
every dependent library.

A separate fixture forces the metadata tool to fail. Both installers warn,
retain the missing resource reference, and do not fabricate an output file.
Tool availability and behavior depend on the Apple environment.

SwiftPods retains the working generation. The acceptance report preserves
`parity: false` as an observation and classifies
`BridgeSupport.aggregate_header_path` as `accepted_improvement` when the current
native and reference reports prove unchanged manifests, the existing header path
and metadata containing aggregate declarations. This fix does not block stable
acceptance. Missing proof, unrelated differences and unverified external gates
remain separate acceptance requirements.
