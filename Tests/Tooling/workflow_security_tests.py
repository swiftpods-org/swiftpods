#!/usr/bin/env python3
"""Static regression checks for release gates that live in GitHub Actions."""

import unittest

from scripts.support.version import ROOT


class WorkflowSecurityTests(unittest.TestCase):
    def test_release_requires_an_annotated_tag_and_the_exact_build_workflow(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("['git', 'cat-file', '-t', tag]", workflow)
        self.assertIn("['git', 'rev-parse', '--verify', tag]", workflow)
        self.assertIn("Release tags must be annotated tags", workflow)
        self.assertIn(
            "source-tag-object: ${{ steps.resolve.outputs.tag-object }}", workflow
        )
        self.assertIn(
            'scripts.release --version "$RELEASE_VERSION" --tag-object "$RELEASE_TAG_OBJECT"',
            workflow,
        )
        self.assertIn("actions/workflows/build.yml/runs", workflow)
        self.assertIn('select(.head_sha == "\'"$RELEASE_COMMIT"\'"', workflow)
        self.assertIn('.event == "push" and .head_branch == "main"', workflow)
        self.assertNotIn("commits/$RELEASE_COMMIT/check-runs", workflow)
        self.assertNotIn('startswith("build")', workflow)

    def test_release_promotes_the_exact_tested_artifact_before_signing(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("build-run-id: ${{ steps.build-gate.outputs.run-id }}", workflow)
        self.assertIn("run-id: ${{ needs.metadata.outputs.build-run-id }}", workflow)
        self.assertIn("name: swiftpods-${{ matrix.runner }}", workflow)
        self.assertIn("Restore the exact tested distribution", workflow)
        self.assertIn("extract_archive(data, Path(temporary))", workflow)
        self.assertIn("Tested distribution differs from its build artifact checksum", workflow)
        self.assertIn("SwiftPods.provenance.json", workflow)
        self.assertIn('"source_revision": os.environ["EXPECTED_COMMIT"]', workflow)
        self.assertIn("Tested artifact provenance does not match the release commit", workflow)
        signing = workflow.index("python3 -m scripts.sign_release")
        self.assertLess(workflow.index("Restore the exact tested distribution"), signing)
        self.assertNotIn(
            'python3 -m scripts.package --destination "$SWIFTPODS_BUILD_ROOT/SwiftPods"',
            workflow,
        )

    def test_build_smoke_tests_the_packaged_release_without_dirtying_the_checkout(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        package = workflow.index("python3 -m scripts.package --destination")
        smoke = workflow.index('"$SWIFTPODS_BUILD_ROOT/SwiftPods/bin/swiftpods" version --json')
        archive = workflow.index("/usr/bin/ditto -c -k")
        self.assertLess(package, smoke)
        self.assertLess(smoke, archive)
        self.assertEqual(workflow.count("git status --porcelain --untracked-files=all"), 2)
        self.assertIn('source_commit="$(git rev-parse --verify HEAD)"', workflow)
        self.assertIn('"$source_commit" != "$GITHUB_SHA"', workflow)
        self.assertIn('"source_revision": os.environ["SWIFTPODS_SOURCE_COMMIT"]', workflow)
        package_source = (ROOT / "scripts/package.py").read_text()
        self.assertIn(
            '[binary, "check", "--offline", "--json", "--project-directory", project]',
            package_source,
        )
        self.assertIn('manifest.get("packages", [])', package_source)

    def test_e2e_cannot_poison_the_fresh_packaging_runners(self):
        workflow = (ROOT / ".github/workflows/build.yml").read_text()
        e2e = workflow.index("  e2e:")
        package = workflow.index("  package:")
        self.assertLess(e2e, package)
        self.assertIn("needs: [test, e2e]", workflow[package:])
        self.assertEqual(workflow.count("name: swiftpods-${{ matrix.runner }}"), 1)
        source = (ROOT / "Tests/SwiftPodsKitTests/EndToEndTests.swift").read_text()
        self.assertIn(
            "revision: '671108c96644956dddcd89dd59c203dcdb36cec7'",
            source,
        )
        self.assertNotIn("swift-collections.git', '~>", source)

    def test_packaging_uses_xcrun_and_a_complete_allowlisted_environment(self):
        source = (ROOT / "scripts/package.py").read_text()
        self.assertIn('["/usr/bin/xcrun", "--find", "swift"]', source)
        self.assertNotIn('build_environment = dict(os.environ', source)
        for variable in ("HOME", "LANG", "LC_ALL", "PATH", "TMPDIR"):
            self.assertIn('"' + variable + '":', source)

    def test_release_secrets_and_writes_have_environment_protection_hooks(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("environment: release-signing", workflow)
        self.assertGreaterEqual(workflow.count("environment: release-publish"), 2)
        self.assertIn("SWIFTPODS_SIGNING_TEAM_ID", workflow)
        self.assertIn('--team-id "$SWIFTPODS_SIGNING_TEAM_ID"', workflow)
        self.assertIn("environment: release-notarization-verification", workflow)
        self.assertIn("SWIFTPODS_NOTARY_VERIFY_KEY", workflow)

    def test_signed_candidate_runs_only_in_a_fresh_job_without_credentials(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        signing = workflow.index("python3 -m scripts.sign_release")
        cleanup = workflow.index("python3 -m scripts.ci_signing cleanup", signing)
        upload = workflow.index("actions/upload-artifact@", cleanup)
        smoke_job = workflow.index("  verify-signed:", upload)
        smoke = workflow.index("python3 -m scripts.smoke_release", smoke_job)
        assemble = workflow.index("  assemble:", smoke)
        self.assertLess(signing, cleanup)
        self.assertLess(cleanup, upload)
        self.assertLess(upload, smoke_job)
        self.assertLess(smoke_job, smoke)
        self.assertLess(smoke, assemble)
        self.assertIn(
            "needs: [metadata, build, verify-notarization, verify-signed]",
            workflow[assemble:],
        )
        self.assertNotIn("environment: release-signing", workflow[smoke_job:assemble])
        verification = workflow[workflow.index("  verify-notarization:"):assemble]
        self.assertEqual(verification.count("timeout-minutes: 60"), 2)
        self.assertNotIn("timeout-minutes: 15", verification)
        signing_source = (ROOT / "scripts/sign_release.py").read_text()
        self.assertNotIn('[str(executable)', signing_source)
        self.assertIn("Never execute artifact code in this process", signing_source)

    def test_every_release_cleanup_is_scoped_to_its_mktemp_directory(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertEqual(workflow.count("Refusing unsafe"), 7)
        for prefix in (
            "swiftpods-existing-release",
            "swiftpods-release-build",
            "swiftpods-release-notary",
            "swiftpods-release-smoke",
            "swiftpods-release-assets",
            "swiftpods-release-publish",
            "swiftpods-release-integrations",
        ):
            self.assertIn("^" + prefix + r"\.[A-Za-z0-9]{6}$", workflow)

    def test_exact_published_release_can_resume_only_with_the_same_payload(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("published: ${{ steps.publication.outputs.published }}", workflow)
        self.assertIn(
            "manifest-sha256: ${{ steps.publication.outputs.manifest-sha256 }}",
            workflow,
        )
        self.assertIn('gh release download "v$RELEASE_VERSION"', workflow)
        self.assertGreaterEqual(workflow.count("--verify-published"), 2)
        self.assertIn('--expected-manifest-sha256 "$expected"', workflow)
        reverify = workflow.split(
            "name: Reverify the public payload before changing integration pins", 1
        )[1].split("- id: pin", 1)[0]
        self.assertIn("GH_TOKEN: ${{ github.token }}", reverify)
        self.assertIn("needs.metadata.outputs.published == 'true'", workflow)
        self.assertNotIn("is already published; release a new version", workflow)
        self.assertIn("A hidden draft exists; the signed payload will be rebuilt", workflow)

        publication = (ROOT / "scripts/publish_release.py").read_text()
        self.assertIn("def verify_published(", publication)
        self.assertIn("GitHub release asset set differs", publication)
        self.assertIn("def validate_reconcilable_draft(", publication)
        self.assertIn('"upload",\n                tag,', publication)
        self.assertIn('"--clobber"', publication)
        self.assertIn("verify_downloaded_payload", publication)
        self.assertIn('"--draft=false"', publication)
        self.assertIn('published.get("immutable") is not True', publication)
        self.assertIn("only after GitHub reports the release as immutable", publication)
        self.assertIn("def validate_remote_source_tag(", publication)
        self.assertIn('github_json("git/ref/tags/" + tag)', publication)
        self.assertIn('target.get("type") != "tag"', publication)
        self.assertIn('target.get("sha") != expected_object', publication)
        self.assertIn('peeled.get("type") != "commit"', publication)
        self.assertIn('peeled.get("sha") != commit', publication)
        self.assertIn(
            '!= {"commit": commit, "tag_object": tag_object}', publication
        )
        self.assertIn("Source annotated tag object:", publication)
        self.assertIn(
            "Existing draft metadata does not match the exact source tag object",
            publication,
        )
        self.assertIn("def recorded_release_notes_checksum(", publication)
        self.assertIn(r'([0-9a-f]{64})', publication)
        self.assertNotIn("def remote_tag_commit(", publication)
        self.assertGreaterEqual(workflow.count('--tag-object "$RELEASE_TAG_OBJECT"'), 5)

    def test_notarization_is_independently_bound_to_apple_log_digest(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        verifier = (ROOT / "scripts/verify_notarization.py").read_text()
        signing = workflow.index("  build:")
        independent = workflow.index("  verify-notarization:")
        smoke = workflow.index("  verify-signed:")
        assemble = workflow.index("  assemble:")
        self.assertLess(signing, independent)
        self.assertLess(independent, smoke)
        self.assertLess(smoke, assemble)
        self.assertIn('query_notarytool(tool, "info"', verifier)
        self.assertIn('query_notarytool(tool, "log"', verifier)
        self.assertIn('log.get("sha256"', verifier)
        self.assertIn('log.get("archiveFilename")', verifier)
        self.assertIn("trusted_xcode_tool", verifier)

        assembly = (ROOT / "scripts/release.py").read_text()
        self.assertIn('source_revision["tag_object"] = tag_object', assembly)
        self.assertIn("Production release requires an annotated tag object", assembly)

    def test_plugin_dependencies_and_ruby_toolchain_are_frozen(self):
        workflow = (ROOT / ".github/workflows/fastlane-plugin.yml").read_text()
        lock = (ROOT / "Gemfile.lock").read_text()
        gemfile = (ROOT / "Gemfile").read_text()
        gemspec = (ROOT / "fastlane-plugin-swiftpods.gemspec").read_text()
        self.assertIn("ruby: ['3.0.7', '4.0.9']", workflow)
        self.assertIn("ruby-version: ${{ matrix.ruby }}", workflow)
        self.assertIn("ruby/setup-ruby@de492cf36cbab201753d720ce4f4e336cd688c94", workflow)
        self.assertIn("bundler: '2.5.23'", workflow)
        self.assertIn("BUNDLE_FROZEN: 'true'", workflow)
        self.assertIn("bundle exec ruby Tests/FastlanePlugin/run.rb", workflow)
        self.assertIn("Gem::Package.new(ARGV.fetch(0)).spec.version.to_s", workflow)
        self.assertIn('gem "fastlane", "2.237.0"', gemfile)
        self.assertIn('gem "minitest", "5.26.1"', gemfile)
        self.assertNotRegex(gemfile, r"(?m)^ruby\s")
        self.assertIn("spec.required_ruby_version = '>= 3.0'", gemspec)
        self.assertIn("fastlane (= 2.237.0)", lock)
        self.assertIn("minitest (= 5.26.1)", lock)
        self.assertIn("CHECKSUMS", lock)
        self.assertNotIn("RUBY VERSION", lock)
        self.assertIn("fastlane (2.237.0) sha256=", lock)
        self.assertRegex(lock, r"BUNDLED WITH\n  2\.5\.23\n\Z")

        checksum_lines = lock.split("CHECKSUMS\n", 1)[1].split("\nBUNDLED WITH", 1)[0].splitlines()
        remote_lines = [line for line in checksum_lines if line and "fastlane-plugin-swiftpods" not in line]
        self.assertTrue(remote_lines)
        for line in remote_lines:
            self.assertRegex(line, r"^  .+ \(.+\) sha256=[0-9a-f]{64}$")

    def test_plugin_failure_annotation_escapes_workflow_commands(self):
        workflow = (ROOT / ".github/workflows/fastlane-plugin.yml").read_text()
        percent = "message=\"${message//'%'/%25}\""
        carriage_return = "message=\"${message//$'\\r'/%0D}\""
        newline = '"${message//$\'\\n\'/%0A}"'
        self.assertIn(percent, workflow)
        self.assertIn(carriage_return, workflow)
        self.assertIn(newline, workflow)
        self.assertLess(workflow.index(percent), workflow.index(carriage_return))
        self.assertLess(workflow.index(carriage_return), workflow.index(newline))

    def test_action_executes_only_the_authenticated_private_runtime_copy(self):
        action = (ROOT / "action.yml").read_text()
        self.assertIn('--runtime-directory "$runtime_directory"', action)
        self.assertIn('/usr/bin/env -i', action)
        self.assertIn('/usr/bin/python3 "$GITHUB_ACTION_PATH/scripts/install.py"', action)
        self.assertIn(
            'runtime_directory="$(cd -- "$runtime_directory" && /bin/pwd -P)"',
            action,
        )
        self.assertIn('echo "$runtime_directory" >> "$GITHUB_PATH"', action)
        self.assertNotIn('echo "$install_prefix/bin" >> "$GITHUB_PATH"', action)

    def test_main_and_release_tree_plugin_candidates_are_checked_before_atomic_publish(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        integration_job = workflow[workflow.index("  update-integrations:") :]
        self.assertIn("timeout-minutes: 100", integration_job)
        self.assertIn("for attempt in {1..270}", integration_job)
        self.assertIn("ref: ${{ needs.metadata.outputs.commit }}", workflow)
        self.assertIn(
            'git merge-base --is-ancestor "$RELEASE_COMMIT" "$main_commit"',
            workflow,
        )
        self.assertIn('echo "base-commit=$main_commit"', workflow)
        self.assertIn('main_commit" != "$BASE_COMMIT', workflow)
        derive = workflow.index("python3 -m scripts.prepare_integrations")
        plugin_candidate = workflow.index('expected_plugin_tree="$(git write-tree)"')
        current_main = workflow.index('git checkout --detach "$main_commit"')
        self.assertLess(derive, current_main)
        self.assertLess(plugin_candidate, current_main)
        self.assertIn('parent" != "$RELEASE_COMMIT', workflow)
        self.assertIn('"$tag_commit^{tree}"', workflow)
        self.assertIn("Current main already pins a newer stable release", workflow)
        self.assertIn('git push --atomic "${tag_lease[@]}" origin', workflow)
        self.assertIn('"$tag_source:refs/tags/$PLUGIN_TAG"', workflow)
        self.assertIn('gh workflow run build.yml --ref "$INTEGRATION_CHECK_BRANCH"', workflow)
        self.assertIn('gh workflow run fastlane-plugin.yml --ref "$INTEGRATION_CHECK_BRANCH"', workflow)
        self.assertIn('gh workflow run fastlane-plugin.yml --ref "$PLUGIN_CHECK_BRANCH"', workflow)
        self.assertEqual(workflow.count("gh workflow run fastlane-plugin.yml --ref"), 2)
        self.assertIn("Both 15-minute Fastlane checks are dispatched up front", workflow)
        self.assertIn("-f event=workflow_dispatch", workflow)
        self.assertIn('-f "branch=$branch"', workflow)
        self.assertIn('.head_branch == "\'"$branch"\'"', workflow)
        self.assertIn(
            "wait_for_workflow build.yml 'Build SwiftPods' \"$INTEGRATION_COMMIT\" \"$INTEGRATION_CHECK_BRANCH\"",
            workflow,
        )
        self.assertIn(
            "wait_for_workflow fastlane-plugin.yml 'Fastlane plugin on current main' \"$INTEGRATION_COMMIT\" \"$INTEGRATION_CHECK_BRANCH\"",
            workflow,
        )
        self.assertIn(
            "wait_for_workflow fastlane-plugin.yml 'Fastlane plugin release tag' \"$PLUGIN_COMMIT\" \"$PLUGIN_CHECK_BRANCH\"",
            workflow,
        )
        self.assertIn('tag -a "$PLUGIN_TAG" "$PLUGIN_COMMIT"', workflow)
        self.assertIn('tag_source="refs/tags/$PLUGIN_TAG"', workflow)
        self.assertIn(
            'tag_source="refs/swiftpods-existing-tags/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"',
            workflow,
        )
        self.assertIn(
            'tag_lease=(--force-with-lease="refs/tags/$PLUGIN_TAG:$TAG_OBJECT")',
            workflow,
        )
        self.assertNotIn('temporary_tag=', workflow)
        self.assertIn('["git", "cat-file", "tag", os.environ["TAG_REF"]]', workflow)
        self.assertEqual(workflow.count('types != ["commit"]'), 2)
        self.assertEqual(workflow.count('len(objects) != 1'), 2)
        self.assertIn('embedded != [os.environ["EXPECTED_TAG"]]', workflow)
        self.assertIn('message != expected_message', workflow)
        self.assertIn("already contain monotonic verified pins", workflow)
        self.assertIn(
            'git push --force-with-lease="refs/heads/$INTEGRATION_CHECK_BRANCH:$INTEGRATION_COMMIT"',
            workflow,
        )
        self.assertIn(
            'git push --force-with-lease="refs/heads/$PLUGIN_CHECK_BRANCH:$PLUGIN_COMMIT"',
            workflow,
        )
        publish_step = workflow[workflow.index("      - name: Atomically publish") :]
        self.assertNotIn(
            'git fetch --no-tags origin "refs/tags/$PLUGIN_TAG:$tag_source"',
            publish_step,
        )
        atomic_push = 'git push --atomic "${tag_lease[@]}" origin'
        self.assertLess(
            workflow.index("wait_for_workflow fastlane-plugin.yml"),
            workflow.index(atomic_push),
        )


if __name__ == "__main__":
    unittest.main()
