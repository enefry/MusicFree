#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
violations=0

check_exclusive_import() {
    module=$1
    allowed_path=$2
    matches=$(rg -n --glob '*.swift' "^[[:space:]]*import[[:space:]]+${module}([[:space:]]|$)" "$project_root/App" "$project_root/Packages" || true)
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
    "$project_root/App" "$project_root/Packages" || true)
vlc_project_references=$(rg -n 'VLCKit|MusicFreeVLCKit' "$project_root/project.yml" || true)
if [ -n "$vlc_references$vlc_project_references" ]; then
    printf 'App sources and project configuration must not depend on VLCKit:\n%s\n%s\n' \
        "$vlc_references" "$vlc_project_references" >&2
    violations=1
fi

# The app target has a single intentional SwiftUI boundary: SettingsHosting-
# Controller.swift. Any other SwiftUI import or hosting API in App is a
# production rollback/root path and must fail the architecture check.
app_swiftui_imports=$(rg -n --glob '*.swift' \
    '^[[:space:]]*import[[:space:]]+SwiftUI([[:space:]]|$)|UIHostingController|UIHostingConfiguration' \
    "$project_root/App" | rg -v '/SettingsHostingController\.swift:' || true)
if [ -n "$app_swiftui_imports" ]; then
    printf 'App target may only host SwiftUI from SettingsHostingController.swift:\n%s\n' "$app_swiftui_imports" >&2
    violations=1
fi

test_support_imports=$(rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+MusicTestSupport([[:space:]]|$)' "$project_root/App" "$project_root/Packages" | rg '/Sources/' || true)
if [ -n "$test_support_imports" ]; then
    printf 'Product sources must not import MusicTestSupport:\n%s\n' "$test_support_imports" >&2
    violations=1
fi

feature_adapter_imports=$(rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+(LocalMediaAdapter|LibraryPersistenceAdapter|FFmpegPlaybackAdapter|AppleSystemAdapter|PreferencesPersistenceAdapter)([[:space:]]|$)' "$project_root/Packages/MusicFreeUI/Sources" || true)
if [ -n "$feature_adapter_imports" ]; then
    printf 'Feature targets must not import adapters:\n%s\n' "$feature_adapter_imports" >&2
    violations=1
fi

# The production UIKit route is intentionally strict: Settings is the only
# feature allowed to retain a SwiftUI hosting boundary. Legacy SwiftUI view
# files may remain in their feature targets for model/test compatibility, but
# no UIKit controller or app root may instantiate or import SwiftUI.
uikit_swiftui_imports=""
for uikit_surface_path in \
    "$project_root/App/RootViewController.swift" \
    "$project_root/App/MusicFreeApp.swift" \
    "$project_root/App/SceneDelegate.swift" \
    "$project_root/Packages/MusicFreeUI/Sources/LibraryFeature/UIKit" \
    "$project_root/Packages/MusicFreeUI/Sources/PlaylistFeature/UIKit" \
    "$project_root/Packages/MusicFreeUI/Sources/PlayerFeature/UIKit" \
    "$project_root/Packages/MusicFreeUI/Sources/SettingsFeature/UIKit"
do
    matches=$(rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+SwiftUI([[:space:]]|$)|UIHostingController|UIHostingConfiguration' "$uikit_surface_path" || true)
    if [ -n "$matches" ]; then
        uikit_swiftui_imports="$uikit_swiftui_imports\n$matches"
    fi
done
if [ -n "$uikit_swiftui_imports" ]; then
    printf 'UIKit production surfaces must not embed SwiftUI:\n%s\n' "$uikit_swiftui_imports" >&2
    violations=1
fi

legacy_root_references=$(rg -n --glob '*.swift' --glob '*.yml' --glob '*.pbxproj' \
    --glob '!AppTests/**' --glob '!AppUITests/**' \
    'RootScene|useLegacySwiftUIRoot|use-legacy-swiftui-root|OnlineSourcesHostingController' \
    "$project_root/App" "$project_root/Packages" "$project_root/project.yml" "$project_root/MusicFree.xcodeproj/project.pbxproj" || true)
if [ -n "$legacy_root_references" ]; then
    printf 'Production sources must not expose a SwiftUI rollback path:\n%s\n' "$legacy_root_references" >&2
    violations=1
fi

amperfy_references=$(rg -ni --glob '*.swift' --glob 'Package.swift' 'amperfy' "$project_root/App" "$project_root/Packages" || true)
if [ -n "$amperfy_references" ]; then
    printf 'MusicFree source must not reference Amperfy:\n%s\n' "$amperfy_references" >&2
    violations=1
fi

# Built-in data plugins must be independently reusable through the SDK.
data_plugin_business_imports=$(rg -n --glob '*.swift' \
    '^[[:space:]]*import[[:space:]]+(MusicDomain|LibraryAPI|MediaSourceAPI|AppServices|SettingsAPI|LocalMediaAdapter|MusicFreePluginRuntime|MusicFreePluginHostBridge|UIKit|SwiftUI|AVFAudio)([[:space:]]|$)' \
    "$project_root/Packages/MusicFreeBuiltinDataPlugins/Sources" || true)
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
# Check manifests too, so an unused business dependency cannot slip through.
if ! python3 - "$project_root" <<'PY_ARCH'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
allowed = {'MusicFreePluginAPI': {'MusicFreePluginAPI': set(), 'MusicFreePluginDSPAPI': {'MusicFreePluginAPI'}, 'MusicFreePluginAppleAudioAPI': {'MusicFreePluginDSPAPI'}},
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
