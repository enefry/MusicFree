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

check_exclusive_import "VLCKit" "/Packages/MusicFreeVLCKitAdapter/Sources/VLCKitPlaybackAdapter/"
check_exclusive_import "SwiftData" "/Packages/MusicFreeInfrastructure/(Sources/LibraryPersistenceAdapter|Tests/MusicFreeInfrastructureTests)/"
check_exclusive_import "AVFAudio" "/Packages/MusicFreeInfrastructure/Sources/AppleSystemAdapter/"
check_exclusive_import "MediaPlayer" "/Packages/MusicFreeInfrastructure/Sources/AppleSystemAdapter/"

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

feature_adapter_imports=$(rg -n --glob '*.swift' '^[[:space:]]*import[[:space:]]+(LocalMediaAdapter|LibraryPersistenceAdapter|VLCKitPlaybackAdapter|AppleSystemAdapter|PreferencesPersistenceAdapter)([[:space:]]|$)' "$project_root/Packages/MusicFreeUI/Sources" || true)
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

if [ "$violations" -ne 0 ]; then
    exit 1
fi

printf 'Architecture checks passed.\n'
