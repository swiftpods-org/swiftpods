"""Hooks and graph assertions shared by native and reference project-layout tests."""
import json
from pathlib import Path
import subprocess
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as XML

HOOKS = '''
require 'cocoapods/installer/post_install_hooks_context'
pre_install do |installer|
  $layout_installer = installer
end
post_install do |installer|
  raise 'Installer identity changed' unless installer.equal?($layout_installer)
  $layout_projects = installer.generated_projects.to_h { |project| [project.path.to_s, project] }
  $layout_configurations = {}
  by_name = installer.generated_projects.to_h { |project| [project.path.basename('.xcodeproj').to_s, project] }
  if by_name['SpecKit'] && by_name['AppHelper']
    test = by_name['SpecKit'].targets.find { |target| target.name == 'SpecKit-Unit-Tests' }
    helper = by_name['AppHelper'].targets.find { |target| target.name == 'AppHelper' }
    test.add_dependency(helper)
    count = test.dependencies.size
    test.add_dependency(helper)
    raise 'Duplicate cross-project dependency' unless test.dependencies.size == count && test.dependency_for_target(helper)
  end
  installer.generated_projects.each do |project|
    owner = project.path.basename('.xcodeproj').to_s
    project.root_object.attributes['LayoutMarker'] = owner
    project.build_configurations.each do |configuration|
      configuration.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'LAYOUT_ROOT_' + owner.upcase + '=1']
      configuration.build_settings['LAYOUT_PROJECT'] = owner
    end
    $layout_configurations[project.path.to_s] = project.build_configurations.find { |configuration| configuration.name == 'Debug' }
    project.save
    raise 'Project save was deferred' unless File.read(project.path + 'project.pbxproj').include?('LayoutMarker')
  end
  context = Pod::Installer::PostInstallHooksContext.new(installer.sandbox, installer.sandbox.root.to_s, installer.pods_project, installer.generated_projects, [])
  raise 'Wrong base context' unless context.is_a?(Pod::Installer::BaseInstallHooksContext)
  raise 'Missing projects in context' unless context.generated_projects.size == installer.generated_projects.size + 1
  installer.pods_project.root_object.attributes['LayoutMarker'] = 'aggregate'
  installer.pods_project.save
end
post_integrate do |installer|
  installer.generated_projects.each do |project|
    raise 'Child project identity changed' unless project.equal?($layout_projects.fetch(project.path.to_s))
    raise 'Configuration identity changed' unless project.build_configurations.find { |configuration| configuration.name == 'Debug' }.equal?($layout_configurations.fetch(project.path.to_s))
    project.build_configurations.each { |configuration| configuration.build_settings['LATE_LAYOUT'] = project.path.basename('.xcodeproj').to_s }
    project.save
  end
end
'''


def enable(work, hooks=True):
    path = work / 'Podfile'
    path.write_text("install! 'cocoapods', :generate_multiple_pod_projects => true\n" + path.read_text() + (HOOKS if hooks else ''))
    spec = work / 'Specs/AppHelper/1.0/AppHelper.podspec.json'
    if spec.exists():
        value = json.loads(spec.read_text()); source = Path(unquote(urlparse(value['source']['git']).path))
        source_project = source / 'AppHelper.xcodeproj/project.pbxproj'; source_project.parent.mkdir()
        source_project.write_text('source project must survive\n')
        def commit(directory, message):
            subprocess.run(['git', '-C', str(directory), 'add', '.'], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['git', '-C', str(directory), '-c', 'user.name=SwiftPods Fixture', '-c', 'user.email=fixture@swiftpods.org', '-c', 'commit.gpgsign=false', 'commit', '-m', message], check=True, stdout=subprocess.DEVNULL)
        commit(source, 'Include original source project')
        value['source']['commit'] = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        value['preserve_paths'] = 'AppHelper.xcodeproj'
        spec.write_text(json.dumps(value)); commit(work / 'Specs', 'Update source revision')
    for source, flag in [('Modules/SpecKit/Sources/SpecKit.m', 'SPECKIT'), ('Modules/UIWidget/Sources/UIWidget.m', 'UIWIDGET')]:
        path = work / source
        if path.exists() and hooks:
            path.write_text('#ifndef LAYOUT_ROOT_' + flag + '\n#error Project hook flag is missing\n#endif\n' + path.read_text())


def graph(path):
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def contract(work, expected, hooks=True):
    projects = {path.parent.stem: graph(path) for path in work.glob('Pods/*.xcodeproj/project.pbxproj')}
    assert set(projects) == set(expected) | {'Pods'}, projects.keys()
    if 'AppHelper' in expected: assert work.joinpath('Pods/AppHelper/AppHelper.xcodeproj/project.pbxproj').read_text() == 'source project must survive\n'
    owners = {}
    for name, data in projects.items():
        objects = data['objects']; root = objects[data['rootObject']]
        if hooks:
            assert root['attributes']['LayoutMarker'] == (name if name != 'Pods' else 'aggregate')
        for identifier in root['targets']:
            assert identifier not in owners, 'Duplicate target in generated projects'
            owners[identifier] = name
        if name != 'Pods' and hooks:
            for identifier in objects[root['buildConfigurationList']]['buildConfigurations']:
                settings = objects[identifier]['buildSettings']
                assert settings['LAYOUT_PROJECT'] == name and settings['LATE_LAYOUT'] == name
            source_paths = [item.get('path', '') for item in objects.values() if item['isa'] == 'PBXFileReference']
            if name == 'SpecKit': assert not any(path.endswith(('/TestHelper.c', '/AppHelper.c')) for path in source_paths)
    for path in work.glob('Pods/**/*.xcscheme'):
        document = XML.parse(path)
        for reference in document.iter('BuildableReference'):
            identifier = reference.attrib['BlueprintIdentifier']; container = reference.attrib['ReferencedContainer']
            assert identifier in owners, (path, identifier)
            assert Path(container.removeprefix('container:')).name == owners[identifier] + '.xcodeproj', (path, container, owners[identifier])
    return projects
