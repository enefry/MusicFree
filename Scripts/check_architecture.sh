#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
violations=0

check_exclusive_import() {
    module=$1
    allowed_path=$2
    matches=$(rg -n --glob '*.swift' "^[[:space:]]*import[[:space:]]+${module}([[:space:]]|$)" "$project_root" || true)
    invalid=$(printf '%s\n' "$matches" | rg -v "$allowed_path" || true)

    if [ -n "$invalid" ]; then
        printf 'Forbidden %s import:\n%s\n' "$module" "$invalid" >&2
        violations=1
    fi
}

check_exclusive_import "VLCKit" "/Packages/MusicFreeVLCKit/Sources/VLCKitPlaybackAdapter/"
check_exclusive_import "SwiftData" "/Packages/MusicFreeInfrastructure/(Sources/LibraryPersistenceAdapter|Tests/MusicFreeInfrastructureTests)/"
check_exclusive_import "AVFAudio" "/Packages/MusicFreeInfrastructure/Sources/AppleSystemAdapter/"
check_exclusive_import "MediaPlayer" "/Packages/MusicFreeInfrastructure/Sources/AppleSystemAdapter/"

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

amperfy_references=$(rg -ni --glob '*.swift' --glob 'Package.swift' 'amperfy' "$project_root/App" "$project_root/Packages" || true)
if [ -n "$amperfy_references" ]; then
    printf 'MusicFree source must not reference Amperfy:\n%s\n' "$amperfy_references" >&2
    violations=1
fi

if [ "$violations" -ne 0 ]; then
    exit 1
fi

printf 'Architecture checks passed.\n'
