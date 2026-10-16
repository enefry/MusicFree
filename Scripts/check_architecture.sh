#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
violations=0

check_exclusive_import() {
    module=$1
    allowed_path=$2
    matches=$(rg -n --glob '*.swift' "^[[:space:]]*import[[:space:]]+${module}([[:space:]]|$)" "$project_root/App" "$project_root/Packages" "$project_root/thirdpart/ExtendsPlugins" || true)
    invalid=$(printf '%s\n' "$matches" | rg -v "$allowed_path" || true)

    if [ -n "$invalid" ]; then
        printf 'Forbidden %s import:\n%s\n' "$module" "$invalid" >&2
        violations=1
    fi
}

check_exclusive_import "SwiftData" "/Packages/MusicFreeInfrastructure/(Sources/LibraryPersistenceAdapter|Tests/MusicFreeInfrastructureTests)/"
check_exclusive_import "AVFAudio" "/App/PluginFFmpegPCMAdapter\.swift:|/Packages/(MusicFreeInfrastructure/Sources/AppleSystemAdapter|MusicFreePluginAPI/Sources/MusicFreePluginAppleAudioAPI|MusicFreePluginAudio/(Sources/MusicFreePluginAudio|Tests/MusicFreePluginAudioTests)|MusicFreePluginHostBridge/(Sources/MusicFreePluginHostBridge|Tests/MusicFreePluginHostBridgeTests)|MusicFreeBuiltinDSPPlugins/(Sources/EqualizerDSPPlugin|Tests/EqualizerDSPPluginTests))/"
check_exclusive_import "MediaPlayer" "/Packages/MusicFreeInfrastructure/Sources/AppleSystemAdapter/"

vlc_references=$(rg -n --glob '*.swift' --glob 'Package.swift' \
    '^[[:space:]]*import[[:space:]]+VLCKit([[:space:]]|$)|MusicFreeVLCKit|VLCKitPlaybackAdapter' \
    "$project_root/App" "$project_root/Packages" "$project_root/thirdpart/ExtendsPlugins" || true)
vlc_project_references=$(rg -n 'VLCKit|MusicFreeVLCKit' "$project_root/project.yml" || true)
if [ -n "$vlc_references$vlc_project_references" ]; then
    printf 'App sources and project configuration must not depend on VLCKit:\n%s\n%s\n' \
        "$vlc_references" "$vlc_project_references" >&2
    violations=1
fi

# Every first-party UI surface is native UIKit, including Debug support.
swiftui_references=$(rg -n --glob '*.swift' \
    '^[[:space:]]*(public[[:space:]]+)?import[[:space:]]+SwiftUI([[:space:]]|$)|UIHostingController|UIHostingConfiguration|UIViewControllerRepresentable|UIViewRepresentable' \
    "$project_root/App" "$project_root/Packages" "$project_root/thirdpart/ExtendsPlugins" || true)
if [ -n "$swiftui_references" ]; then
    printf 'App and package sources must use UIKit without SwiftUI hosting:\n%s\n' "$swiftui_references" >&2
    violations=1
fi

test_support_imports=$(rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+MusicTestSupport([[:space:]]|$)' "$project_root/App" "$project_root/Packages" "$project_root/thirdpart/ExtendsPlugins" | rg '/Sources/' || true)
if [ -n "$test_support_imports" ]; then
    printf 'Product sources must not import MusicTestSupport:\n%s\n' "$test_support_imports" >&2
    violations=1
fi

feature_adapter_imports=$(rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+(LocalMediaAdapter|LibraryPersistenceAdapter|FFmpegPlaybackAdapter|AppleSystemAdapter|PreferencesPersistenceAdapter)([[:space:]]|$)' "$project_root/Packages/MusicFreeUI/Sources" || true)
if [ -n "$feature_adapter_imports" ]; then
    printf 'Feature targets must not import adapters:\n%s\n' "$feature_adapter_imports" >&2
    violations=1
fi

legacy_root_references=$(rg -n --glob '*.swift' --glob '*.yml' --glob '*.pbxproj' \
    --glob '!AppTests/**' --glob '!AppUITests/**' \
    'RootScene|useLegacySwiftUIRoot|use-legacy-swiftui-root|OnlineSourcesHostingController' \
    "$project_root/App" "$project_root/Packages" "$project_root/thirdpart/ExtendsPlugins" "$project_root/project.yml" "$project_root/MusicFree.xcodeproj/project.pbxproj" || true)
if [ -n "$legacy_root_references" ]; then
    printf 'Production sources must not expose a SwiftUI rollback path:\n%s\n' "$legacy_root_references" >&2
    violations=1
fi

amperfy_references=$(rg -ni --glob '*.swift' --glob 'Package.swift' 'amperfy' "$project_root/App" "$project_root/Packages" "$project_root/thirdpart/ExtendsPlugins" || true)
if [ -n "$amperfy_references" ]; then
    printf 'MusicFree source must not reference Amperfy:\n%s\n' "$amperfy_references" >&2
    violations=1
fi

# Built-in and extension data plugins must be independently reusable through the SDK.
data_plugin_business_imports=$(rg -n --glob '*.swift' \
    '^[[:space:]]*import[[:space:]]+(MusicDomain|LibraryAPI|MediaSourceAPI|AppServices|SettingsAPI|LocalMediaAdapter|MusicFreePluginRuntime|MusicFreePluginHostBridge|UIKit|SwiftUI|AVFAudio)([[:space:]]|$)' \
    "$project_root/Packages/MusicFreeBuiltinDataPlugins/Sources" \
    "$project_root/thirdpart/ExtendsPlugins/MusicFreeChineseMusicPlugins/Sources" || true)
if [ -n "$data_plugin_business_imports" ]; then
    printf 'Data plugins must depend only on the plugin SDK and system libraries:\n%s\n' "$data_plugin_business_imports" >&2
    violations=1
fi

# Foundation-only SDK/runtime targets have no host/business/platform imports.
for target in MusicFreePluginAPI/Sources/MusicFreePluginAPI MusicFreePluginAPI/Sources/MusicFreePluginDSPAPI MusicFreePluginRuntime/Sources
 do
    matches=$(rg -n --glob '*.swift' '^[[:space:]]*(public[[:space:]]+)?import[[:space:]]+' "$project_root/Packages/$target" | rg -v 'import (Foundation|MusicFreePluginAPI|MusicFreePluginDSPAPI)([[:space:]]|$)' || true)
    if [ -n "$matches" ]; then
        printf 'Plugin API/Runtime must have zero business/platform dependencies:\n%s\n' "$matches" >&2
        violations=1
    fi
 done
# UIKit companion SDK depends only on the neutral API, never host business modules.
settings_sdk_imports=$(rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+' \
    "$project_root/Packages/MusicFreePluginAPI/Sources/MusicFreePluginSettingsUIKitAPI" | rg -v 'import (Foundation|UIKit|MusicFreePluginAPI)([[:space:]]|$)' || true)
if [ -n "$settings_sdk_imports" ]; then
    printf 'Plugin UIKit settings SDK must not depend on host business modules:\n%s\n' "$settings_sdk_imports" >&2
    violations=1
fi
# Check manifests too, so an unused business dependency cannot slip through.
if ! python3 - "$project_root" <<'PY_ARCH'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
allowed = {'MusicFreePluginAPI': {'MusicFreePluginAPI': set(), 'MusicFreePluginDSPAPI': {'MusicFreePluginAPI'}, 'MusicFreePluginAppleAudioAPI': {'MusicFreePluginDSPAPI'}, 'MusicFreePluginSettingsUIKitAPI': {'MusicFreePluginAPI'}},
           'MusicFreePluginRuntime': {'MusicFreePluginRuntime': {'MusicFreePluginAPI', 'MusicFreePluginDSPAPI'}}}
for package, targets in allowed.items():
    manifest = json.loads(subprocess.check_output(['swift', 'package', '--package-path', str(root/'Packages'/package), 'dump-package']))
    if any('fileSystem' not in dep for dep in manifest['dependencies']):
        raise SystemExit('Forbidden external plugin package dependency: ' + package)
    packages = {Path(dep['fileSystem'][0]['path']).name for dep in manifest['dependencies']}
    if packages != (set() if package == 'MusicFreePluginAPI' else {'MusicFreePluginAPI'}):
        raise SystemExit('Forbidden plugin package dependency: ' + package)
    for target in manifest['targets']:
        if target['name'] not in targets: continue
        dependencies = {next(iter(dep.values()))[0] for dep in target['dependencies']}
        if dependencies != targets[target['name']]: raise SystemExit('Forbidden plugin target dependency: ' + target['name'])
print('Plugin zero-business-dependency checks passed.')
PY_ARCH
then
    violations=1
fi

if [ "$violations" -ne 0 ]; then
    exit 1
fi

printf 'Architecture checks passed.\n'
