"""Unicode key collisions fail before Foundation containers lose information."""

import json
import subprocess

from name_boundary_regressions import diagnostic
from native_integration import serialize
from native_xcconfig_tests import create
from project_path_regressions import builds, reinstall
from source_string_regressions import ruby
from structured_input_regressions import scheme_values
from workspace_resource_regressions import read_project

COLLIDING = {"CAFÉ": "first", "CAFE\u0301": "second"}


def specification(parent, form, scope="library", environment=None):
    work, selected = create(parent)
    environment = COLLIDING if environment is None else environment
    source = work / "Kit/Kit.podspec.json"
    attributes = json.loads(source.read_text())
    options = {"scheme": {"environment_variables": environment}}
    if scope == "library":
        attributes.update(options)
    else:
        attributes["testspecs" if scope == "test" else "appspecs"] = [
            dict(name="Inputs", **options)
        ]
    attributes["prepare_command"] = "printf ran > prepare-ran"
    source.write_text(json.dumps(attributes))
    if form == "ruby":
        source.unlink()
        source = source.with_suffix("")
        declaration = "s.scheme = " + ruby(options["scheme"])
        if scope != "library":
            declaration = (
                "s."
                + ("test_spec" if scope == "test" else "app_spec")
                + "('Inputs') { |child| child.scheme = "
                + ruby(options["scheme"])
                + " }"
            )
        source.write_text(
            "Pod::Spec.new do |s|\n"
            "s.name='Kit'\ns.version='1.0'\ns.summary='Fixture'\n"
            "s.homepage='https://swiftpods.org'\ns.authors='Tests'\ns.license='MIT'\n"
            "s.osx.deployment_target='13.0'\ns.source_files='*.{c,h}'\n"
            "s.source={:git=>'https://example.invalid/kit.git',:tag=>'1.0'}\n"
            "s.prepare_command='printf ran > prepare-ran'\n" + declaration + "\nend\n"
        )
    return work, selected, source


def inputs(work, selected, source):
    return {
        path: path.read_bytes()
        for path in [work / "Podfile", selected / "project.pbxproj", source]
    }


def declarations(fixture):
    for form in ["json", "ruby"]:
        for scope in ["library", "test", "app"]:
            label = form + "-" + scope
            work, selected, source = specification(
                fixture.root / ("key-collision-" + label), form, scope
            )
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text()
                + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
            )
            originals = inputs(work, selected, source)
            for action, arguments in [
                ("ipc", ["ipc", "spec", str(source)]),
                ("lint", ["spec", "lint", str(source), "--quick"]),
                ("install", ["install"]),
            ]:
                result = fixture.cli(work, *arguments, succeeds=False)
                assert diagnostic(result, "SP-DATA-KEY"), result
                assert result["project_state"] == (
                    "failed_no_managed_changes" if action == "install" else "untracked"
                ), result
                assert all(p.read_bytes() == before for p, before in originals.items())
                assert not (work / "Pods").exists()
                assert not (work / "Podfile.lock").exists()
                assert not (work / "pre-hook-ran").exists()
                assert not (source.parent / "prepare-ran").exists()
                fixture.verified.append(
                    "dictionary_collision_" + label + "_" + action + "_early_rejection"
                )


def project_and_lock(fixture):
    for form in ["openstep", "xml"]:
        work, selected = create(fixture.root / ("key-project-" + form))
        project = selected / "project.pbxproj"
        graph = read_project(selected)
        graph["objects"][graph["rootObject"]].setdefault("attributes", {})[
            "AuditUnicode"
        ] = COLLIDING
        if form == "openstep":
            project.write_text("// !$*UTF8*$!\n" + serialize(graph))
        else:
            project.write_text(json.dumps(graph))
            subprocess.run(["plutil", "-convert", "xml1", str(project)], check=True)
        retained = read_project(selected)["objects"][graph["rootObject"]]["attributes"][
            "AuditUnicode"
        ]
        assert retained == COLLIDING, retained
        original = project.read_bytes()
        result = fixture.cli(work, "install", succeeds=False)
        assert diagnostic(result, "SP-DATA-KEY"), result
        assert result["project_state"] == "failed_no_managed_changes", result
        assert project.read_bytes() == original
        assert not (work / "Pods").exists() and not (work / "Podfile.lock").exists()
        fixture.verified.append("dictionary_collision_project_" + form + "_preserved")
    work, selected = create(fixture.root / "key-lock-json")
    fixture.cli(work, "install")
    lock = work / "Podfile.lock"
    ruby_binary = fixture.env["SWIFTPODS_RUBY"]
    code = "require 'yaml';require 'json';puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))"
    data = json.loads(
        subprocess.check_output([ruby_binary, "-e", code, str(lock)], env=fixture.env)
    )
    data["AUDIT_METADATA"] = COLLIDING
    lock.write_text(json.dumps(data))
    originals = {
        p: p.read_bytes()
        for p in [
            lock,
            selected / "project.pbxproj",
            work / "Pods/Pods.xcodeproj/project.pbxproj",
        ]
    }
    result = fixture.cli(work, "install", succeeds=False)
    assert diagnostic(result, "SP-DATA-KEY"), result
    assert result["project_state"] == "failed_no_managed_changes", result
    assert all(p.read_bytes() == before for p, before in originals.items())
    fixture.verified.append("dictionary_collision_json_lock_preserves_installed_graph")


def hook_graphs(fixture):
    for callback in [False, True]:
        label = "callback" if callback else "reply"
        work, selected = create(fixture.root / ("key-hook-" + label))
        original = (selected / "project.pbxproj").read_bytes()
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text().split("post_install do |i|", 1)[0]
            + "post_install do |installer|\n"
            "installer.pods_project.build_configurations.each { |c| c.build_settings.merge!("
            + ruby(COLLIDING)
            + ") }\n"
            + ("installer.pods_project.save\n" if callback else "")
            + "end\n"
        )
        result = fixture.cli(work, "install", succeeds=False)
        assert diagnostic(result, "SP-DATA-KEY"), result
        assert result["project_state"] == "recovery_required", result
        assert (selected / "project.pbxproj").read_bytes() == original
        fixture.cli(work, "recover")
        assert (selected / "project.pbxproj").read_bytes() == original
        fixture.verified.append("dictionary_collision_hook_" + label + "_recovery")


def positive_keys(fixture):
    for form in ["json", "ruby"]:
        for spelling, key in [("nfc", "CAFÉ"), ("nfd", "CAFE\u0301")]:
            label = form + "-" + spelling
            expected = {key: "value=東京", "PUZZLE🧩": "separate", "PLAIN": ""}
            work, selected, source = specification(
                fixture.root / ("key-valid-" + label), form, environment=expected
            )
            graph = read_project(selected)
            graph["objects"][graph["rootObject"]].setdefault("attributes", {})[key] = (
                "preserved"
            )
            (selected / "project.pbxproj").write_text(
                "// !$*UTF8*$!\n" + serialize(graph)
            )
            podfile = work / "Podfile"
            podfile.write_text(
                "install! 'cocoapods', :share_schemes_for_development_pods => true\n"
                + podfile.read_text()
            )
            original = source.read_bytes()
            fixture.cli(work, "install")
            scheme = work / "Pods/Pods.xcodeproj/xcshareddata/xcschemes/Kit.xcscheme"
            assert scheme_values(scheme)["environment"] == expected
            attributes = read_project(selected)["objects"][graph["rootObject"]][
                "attributes"
            ]
            assert key in attributes and attributes[key] == "preserved"
            reinstall(fixture, work, selected)
            assert source.read_bytes() == original
            fixture.verified.append(
                "dictionary_unicode_" + label + "_preserved_and_idempotent"
            )
            builds(fixture, work, "key-valid-" + label)
            fixture.verified.append(
                "dictionary_unicode_" + label + "_debug_release_consumers"
            )


def run_regressions(fixture):
    declarations(fixture)
    project_and_lock(fixture)
    hook_graphs(fixture)
    positive_keys(fixture)
