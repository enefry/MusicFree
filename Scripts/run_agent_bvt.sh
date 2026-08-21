#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
requested_device_name="${BVT_DEVICE_NAME:-}"
bundle_id="win.tools4me.music"
timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
result_bundle_path="${BVT_RESULT_BUNDLE_PATH:-${TMPDIR:-/tmp}/MusicFreeAgentBVT-${timestamp}.xcresult}"
derived_data_path="${project_dir}/.noindex/DerivedData"

if ! command -v jq >/dev/null 2>&1; then
  print -u2 "BVT requires jq at /usr/bin/jq or on PATH."
  exit 2
fi

available_devices="$(xcrun simctl list devices available -j)"

if [[ -n "${requested_device_name}" ]]; then
  device_record="$(
    jq -r --arg name "${requested_device_name}" \
      '[.devices | to_entries[] | .key as $runtime | .value[]
        | select(.name == $name and .isAvailable == true)
        | [.name, .udid, $runtime, .state]][0] // [] | @tsv' \
      <<< "${available_devices}"
  )"
else
  device_record="$(
    jq -r \
      '[.devices | to_entries[] | .key as $runtime | .value[]
        | select(
            .isAvailable == true
            and (.deviceTypeIdentifier | contains("iPhone"))
          )
        | [.name, .udid, $runtime, .state]][0] // [] | @tsv' \
      <<< "${available_devices}"
  )"
fi

if [[ -z "${device_record}" ]]; then
  if [[ -n "${requested_device_name}" ]]; then
    print -u2 "BVT device is unavailable: ${requested_device_name}"
  else
    print -u2 "BVT requires an available iPhone Simulator."
  fi
  exit 2
fi

IFS=$'\t' read -r device_name device_udid device_runtime device_state <<< "${device_record}"

if [[ -e "${result_bundle_path}" ]]; then
  print -u2 "BVT result bundle already exists: ${result_bundle_path}"
  exit 2
fi

/bin/mkdir -p "${result_bundle_path:h}"

print "BVT device: ${device_name}"
print "BVT UDID: ${device_udid}"
print "BVT runtime: ${device_runtime}"
print "BVT initial state: ${device_state}"
print "BVT result bundle: ${result_bundle_path}"
xcodebuild -version

xcrun simctl boot "${device_udid}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${device_udid}" -b
xcrun simctl uninstall "${device_udid}" "${bundle_id}" >/dev/null 2>&1 || true

cd "${project_dir}"
xcodebuild \
  -project MusicFree.xcodeproj \
  -scheme MusicFree \
  -derivedDataPath "${derived_data_path}" \
  -destination "platform=iOS Simulator,id=${device_udid}" \
  -only-testing:MusicFreeUITests/MusicFreeBVTUITests/testAgentBVTCompletesCoreIPhoneFlowAndPersistsState \
  -resultBundlePath "${result_bundle_path}" \
  CODE_SIGNING_ALLOWED=NO \
  test
