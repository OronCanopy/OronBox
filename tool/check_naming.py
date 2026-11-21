#!/usr/bin/env python3
"""Check first-party package names while preserving published identities."""
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRECTORIES = {
    '.github', 'android', 'ios', 'macos', 'linux', 'windows', 'lib', 'test',
    'tool', 'hook', 'native', 'include', 'quickjs', 'opus_decoder', 'webp_encoder',
}
SOURCE_EXTENSIONS = {
    '.dart', '.kt', '.java', '.swift', '.cc', '.cpp', '.c', '.h', '.rs',
    '.gradle', '.kts', '.xml', '.plist', '.pbxproj', '.xcconfig', '.cmake',
    '.txt', '.yml', '.yaml', '.json', '.py', '.sh', '.ps1', '.bat', '.podspec',
    '.md', '.toml', '.in',
}
OBSOLETE = re.compile(
    r'''(?i:zerobox|zxor|\bzb(?:_\w*)?\b|oronbox_location|OronboxLocationPlugin|com\.oronbox)|\b(?:Zb|ZB|zb)[A-Z]\w*|["']oronbox(?:/|\.webview\.)''',
)

# Installation, file associations and existing device-side identities survive updates.
PUBLISHED_APP_FILES = {
    'android/app/build.gradle.kts', 'android/app/src/main/AndroidManifest.xml',
    'android/app/src/main/kotlin/org/zxor/oronbox/ApkFileProvider.kt',
    'android/app/src/main/kotlin/org/zxor/oronbox/BackgroundTaskService.kt',
    'android/app/src/main/kotlin/org/zxor/oronbox/LogDocumentsProvider.kt',
    'android/app/src/main/kotlin/org/zxor/oronbox/MainActivity.kt',
    'android/app/src/main/kotlin/org/zxor/oronbox/OronBoxWearableService.kt',
    'android/app/src/main/kotlin/org/zxor/oronbox/StatusWidgets.kt',
    'android/app/src/main/kotlin/org/oroncanopy/oronbox/QueueActivityNotification.kt',
    'ios/Runner/Info.plist', 'ios/Runner.xcodeproj/project.pbxproj',
    'macos/Runner/Info.plist', 'macos/Runner.xcodeproj/project.pbxproj',
    'macos/Runner/Configs/AppInfo.xcconfig',
    'linux/CMakeLists.txt', 'linux/org.zxor.oronbox.desktop.in',
    'linux/org.zxor.oronbox.xml', '.github/workflows/release.yml',
    'tool/build_common.sh', 'tool/build_linux.sh', 'tool/generate_icons.sh',
    'tool/packaging/flatpak/org.zxor.oronbox.yml',
    'lib/src/features/devices/health/pages/xiaomi_health_workout_page.dart',
    'lib/src/device/xiaomi/protocol/xiaomi_plugin_notification.dart',
}


def check_sources(repository, name):
    listed = subprocess.check_output(
        ['git', '-C', str(repository), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    ).decode().split('\0')
    errors = []
    for relative in sorted(set(listed) - {''}):
        path = repository / relative
        if path == Path(__file__).resolve() or not path.is_file():
            continue
        parts = Path(relative).parts
        if parts[0] not in SOURCE_DIRECTORIES and relative not in ('pubspec.yaml', 'README.md', 'README.en.md'):
            continue
        if {'vendor', 'generated', 'ephemeral', '.symlinks', 'Pods', 'build', 'target', '.build', 'dist'} & set(parts):
            continue
        if path.suffix not in SOURCE_EXTENSIONS or path.name.endswith(('.g.dart', '.freezed.dart')):
            continue
        preserved = []
        if repository == ROOT:
            if relative in PUBLISHED_APP_FILES:
                preserved += ['org.zxor.oronbox', 'org/zxor/oronbox']
            if relative in {
                'lib/src/device/xiaomi/systems/install_system.dart',
                'lib/src/features/resources/services/resource_install_service.dart',
            }:
                preserved.append('com.oronbox.')
        if name == 'wear_location' and relative == 'android/src/main/kotlin/org/oroncanopy/wear_location/WearLocationPlugin.kt':
            # Reads the old permission-request flag during migration.
            preserved.append('oronbox_location')
        content = path.read_text()
        checked_path = relative
        for value in preserved:
            content = content.replace(value, '')
            checked_path = checked_path.replace(value, '')
        content = re.sub(r'(?:oronbox|ob-api)\.zxor\.org', '', content)
        if OBSOLETE.search(checked_path):
            errors.append(f'{repository.name}/{relative}: obsolete path')
        for index, line in enumerate(content.splitlines(), 1):
            if OBSOLETE.search(line):
                errors.append(f'{repository.name}/{relative}:{index}: obsolete name')
    return errors


def main():
    configuration = ROOT / '.dart_tool/package_config.json'
    packages = json.loads(configuration.read_text())['packages']
    repositories = {'oronbox': ROOT}
    for package in packages:
        if package['name'] in {'wasm_abp', 'wear_net', 'wear_location'}:
            uri = urljoin(configuration.as_uri(), package['rootUri'])
            repositories[package['name']] = Path(url2pathname(urlparse(uri).path))
    missing = {'wasm_abp', 'wear_net', 'wear_location'} - repositories.keys()
    if missing:
        raise SystemExit('Unresolved packages: ' + ', '.join(sorted(missing)))
    errors = []
    for name, repository in repositories.items():
        pubspec = (repository / 'pubspec.yaml').read_text()
        if not re.search(rf'^name:\s*{re.escape(name)}\s*$', pubspec, re.MULTILINE):
            errors.append(f'{repository}/pubspec.yaml: expected package {name}')
        android = repository / ('android/app' if repository == ROOT else 'android')
        gradle = next((path for path in (android / 'build.gradle.kts', android / 'build.gradle') if path.exists()), None)
        if gradle is not None:
            namespace = re.search(r'''namespace\s*(?:=\s*)?["']([^"']+)["']''', gradle.read_text())
            if namespace is None or namespace.group(1) != f'org.oroncanopy.{name}':
                errors.append(f'{gradle}: incorrect namespace')
        errors.extend(check_sources(repository, name))
    if errors:
        raise SystemExit('\n'.join(errors))
    print('First-party naming and published identity exceptions passed')


if __name__ == '__main__':
    main()
