# Build scripts

Use script phases to generate code or process files during an Xcode build.
Podspec phases run in the pod target. Podfile phases run in the application
target where they are declared. Installation adds the phases without running
their scripts.

```ruby
spec.script_phase = {
  :name => 'Generate headers',
  :execution_position => :before_compile,
  :input_files => ['$(PODS_TARGET_SRCROOT)/schema.json'],
  :output_files => ['$(DERIVED_FILE_DIR)/Generated.h'],
  :show_env_vars_in_log => '0',
  :script => <<~'SH'
    set -eu
    "${PODS_TARGET_SRCROOT}/generate.sh" \
      "${SCRIPT_INPUT_FILE_0}" "${SCRIPT_OUTPUT_FILE_0}"
  SH
}
```

Add the generator itself to `input_files` when changes to that script should
trigger regeneration. To include generated headers during compilation, add
`$(DERIVED_FILE_DIR)` to the pod's `HEADER_SEARCH_PATHS`.

Declare several podspec phases with `spec.script_phases = [first, second]`.
Generic and platform-specific phases are combined for each selected spec.
Subspec phases belong to that subspec; parent phases are not copied into every
child. The singular setter and plural setter describe the same phase list.

Inside a Podfile target, declare application build scripts with
`script_phase :name => 'Process files', :script => '...', ...`.
Use `SRCROOT` for the application project and `PODS_TARGET_SRCROOT` for a pod's
source directory. Standard Xcode build environment variables are available.

The execution positions are `before_compile`, `after_compile`, `before_headers`,
`after_headers` and `any`. The default is `any`. `shell_path` selects an
interpreter; the default is `/bin/sh`.

Declare `input_files`/`output_files`, or `input_file_lists`/`output_file_lists`,
so Xcode can determine when a script needs to run again. File-list paths and
their entries may use Xcode build variables. Tools that produce a dependency
file can set `dependency_file`; do not also list that dependency file as a
regular output. Set `always_out_of_date` to `'1'` for a phase that must run on
every build.

Keep generated files in build directories such as `DERIVED_FILE_DIR`. When
Xcode user script sandboxing is enabled, declare every file the script reads or
writes. SwiftPods preserves the target's sandbox setting. Custom interpreters
and generator tools must be available on the build machine.

`swiftpods install --hardened` rejects podspec script declarations, including
declarations in subspecs and platform sections.
