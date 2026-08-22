#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_file="$script_dir/MusicFree.xcodeproj"
scheme_name="MusicFree"
team_id="${PUBLISH_TF_TEAM_ID:-34PEP7YC95}"
timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
output_root="${PUBLISH_TF_OUTPUT_ROOT:-$script_dir/dist}"
derived_data_path="${PUBLISH_TF_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/MusicFree-TestFlight-$timestamp}"
no_upload="${PUBLISH_TF_NO_UPLOAD:-0}"
upload_home=""

if [[ "$output_root" != /* ]]; then
    output_root="$script_dir/$output_root"
fi

usage() {
    cat <<'EOF'
Usage: ./publish_tf.sh [--no-upload]

Archives MusicFree, exports an App Store Connect IPA, and optionally uploads it.

Environment:
  APP_STORE_CONNECT_KEY_ID / ASC_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID / ASC_ISSUER_ID
  APP_STORE_CONNECT_API_KEY_PATH / ASC_API_KEY_PATH
  APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD
  PUBLISH_TF_NO_UPLOAD=1
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--no-upload" ]]; then
    no_upload=1
    shift
fi

if [[ "$#" -ne 0 ]]; then
    echo "error: unexpected argument: $1" >&2
    usage >&2
    exit 2
fi

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required command not found: $1" >&2
        exit 2
    }
}

run_logged() {
    local log_path="$1"
    shift
    local command_status=0

    set +e
    "$@" 2>&1 | /usr/bin/tee "$log_path"
    command_status="${PIPESTATUS[0]}"
    set -e
    return "$command_status"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}

find_uploader() {
    local candidate

    if command -v iTMSTransporter >/dev/null 2>&1; then
        command -v iTMSTransporter
        return 0
    fi

    for candidate in \
        "/Applications/Xcode.app/Contents/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter" \
        "/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

cleanup() {
    if [[ -n "$upload_home" && -d "$upload_home" ]]; then
        /bin/rm -rf "$upload_home"
    fi
}

trap cleanup EXIT

require_command xcodebuild
require_command tee
require_command mktemp
require_command plutil
require_command unzip

/bin/mkdir -p "$output_root"
run_dir="$(mktemp -d "$output_root/MusicFree-testflight-$timestamp-XXXXXX")"
archive_path="$run_dir/MusicFree.xcarchive"
export_path="$run_dir/export"
export_options_path="$run_dir/ExportOptions.plist"
archive_log_path="$run_dir/archive.log"
export_log_path="$run_dir/export.log"
upload_log_path="$run_dir/upload.log"

echo "Output directory: $run_dir"
echo "Derived data: $derived_data_path"

archive_status=0
run_logged "$archive_log_path" xcodebuild \
    -project "$project_file" \
    -scheme "$scheme_name" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data_path" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Automatic \
    archive || archive_status=$?

if [[ "$archive_status" -ne 0 ]]; then
    echo "error: Release archive failed with exit code $archive_status." >&2
    echo "Archive log: $archive_log_path" >&2
    exit "$archive_status"
fi

app_path="$archive_path/Products/Applications/MusicFree.app"
archive_info_path="$archive_path/Info.plist"
if [[ ! -d "$app_path" || ! -f "$archive_info_path" ]]; then
    echo "error: archive is missing the application or metadata." >&2
    exit 1
fi

app_version="$(plist_value 'ApplicationProperties:CFBundleShortVersionString' "$archive_info_path")"
build_version="$(plist_value 'ApplicationProperties:CFBundleVersion' "$archive_info_path")"
bundle_id="$(plist_value 'ApplicationProperties:CFBundleIdentifier' "$archive_info_path")"
echo "Archive: $archive_path"
echo "Bundle: $bundle_id"
echo "Version: $app_version ($build_version)"

/usr/bin/plutil -create xml1 "$export_options_path"
/usr/bin/plutil -insert method -string app-store-connect "$export_options_path"
/usr/bin/plutil -insert signingStyle -string automatic "$export_options_path"
/usr/bin/plutil -insert teamID -string "$team_id" "$export_options_path"
/usr/bin/plutil -insert stripSwiftSymbols -bool true "$export_options_path"
/usr/bin/plutil -insert uploadSymbols -bool true "$export_options_path"
/bin/mkdir -p "$export_path"

export_status=0
run_logged "$export_log_path" xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options_path" \
    -allowProvisioningUpdates || export_status=$?

if [[ "$export_status" -ne 0 ]]; then
    echo "error: IPA export failed with exit code $export_status." >&2
    echo "Export log: $export_log_path" >&2
    exit "$export_status"
fi

ipa_path="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
if [[ -z "$ipa_path" ]]; then
    echo "error: export succeeded but no IPA was found." >&2
    exit 1
fi

/usr/bin/unzip -tqq "$ipa_path"
echo "IPA: $ipa_path"
echo "Archive log: $archive_log_path"
echo "Export log: $export_log_path"

if [[ "$no_upload" == "1" ]]; then
    echo "Upload skipped (--no-upload or PUBLISH_TF_NO_UPLOAD=1)."
    exit 0
fi

asc_key_id="${APP_STORE_CONNECT_KEY_ID:-${ASC_KEY_ID:-}}"
asc_issuer_id="${APP_STORE_CONNECT_ISSUER_ID:-${ASC_ISSUER_ID:-}}"
asc_key_path="${APP_STORE_CONNECT_API_KEY_PATH:-${ASC_API_KEY_PATH:-}}"
apple_id="${APPLE_ID:-${APP_STORE_CONNECT_APPLE_ID:-}}"
apple_password="${APPLE_APP_SPECIFIC_PASSWORD:-${APP_STORE_CONNECT_APP_SPECIFIC_PASSWORD:-}}"

if [[ -n "$asc_key_id" || -n "$asc_issuer_id" || -n "$asc_key_path" ]]; then
    if [[ -z "$asc_key_id" || -z "$asc_issuer_id" ]]; then
        echo "error: API key upload requires key ID and issuer ID." >&2
        exit 2
    fi
    if [[ -n "$asc_key_path" && ! -f "$asc_key_path" ]]; then
        echo "error: API key file not found: $asc_key_path" >&2
        exit 2
    fi
    upload_mode="api-key"
elif [[ -n "$apple_id" || -n "$apple_password" ]]; then
    if [[ -z "$apple_id" || -z "$apple_password" ]]; then
        echo "error: Apple ID upload requires both credentials." >&2
        exit 2
    fi
    upload_mode="apple-id"
else
    echo "error: no App Store Connect upload credentials were provided." >&2
    echo "IPA was generated successfully: $ipa_path" >&2
    exit 2
fi

transporter_path="$(find_uploader || true)"
if [[ -z "$transporter_path" ]]; then
    echo "error: iTMSTransporter is not available." >&2
    exit 2
fi

upload_status=0
if [[ "$upload_mode" == "api-key" ]]; then
    if [[ -n "$asc_key_path" ]]; then
        upload_home="$(mktemp -d "${TMPDIR:-/tmp}/MusicFree-asc-home-XXXXXX")"
        /bin/mkdir -p "$upload_home/.appstoreconnect/private_keys"
        /bin/cp "$asc_key_path" "$upload_home/.appstoreconnect/private_keys/AuthKey_$asc_key_id.p8"
        /bin/chmod 600 "$upload_home/.appstoreconnect/private_keys/AuthKey_$asc_key_id.p8"
        run_logged "$upload_log_path" /usr/bin/env HOME="$upload_home" "$transporter_path" \
            -m upload \
            -assetFile "$ipa_path" \
            -apiKey "$asc_key_id" \
            -apiIssuer "$asc_issuer_id" || upload_status=$?
    else
        run_logged "$upload_log_path" "$transporter_path" \
            -m upload \
            -assetFile "$ipa_path" \
            -apiKey "$asc_key_id" \
            -apiIssuer "$asc_issuer_id" || upload_status=$?
    fi
else
    run_logged "$upload_log_path" "$transporter_path" \
        -m upload \
        -assetFile "$ipa_path" \
        -u "$apple_id" \
        -p "$apple_password" || upload_status=$?
fi

if [[ "$upload_status" -ne 0 ]]; then
    echo "error: TestFlight upload failed with exit code $upload_status." >&2
    echo "IPA: $ipa_path" >&2
    echo "Upload log: $upload_log_path" >&2
    exit "$upload_status"
fi

echo "TestFlight upload completed successfully."
echo "Upload log: $upload_log_path"
