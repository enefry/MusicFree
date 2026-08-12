#!/bin/bash

set -euo pipefail

config_path="${SRCROOT}/basic_config.xcconfig"

if [[ ! -f "${config_path}" ]]; then
    echo "error: Missing version config: ${config_path}" >&2
    exit 1
fi

previous_build_number=$(
    /usr/bin/awk -F '=' '/^[[:space:]]*BUILD_VERSION[[:space:]]*=/ {
        value = $2
        gsub(/[[:space:]]/, "", value)
        print value
        exit
    }' "${config_path}"
)

if [[ -z "${previous_build_number}" ]]; then
    echo "error: BUILD_VERSION is not defined in ${config_path}" >&2
    exit 1
fi

current_date=$(/bin/date '+%Y%m%d')
new_counter=1

if [[ "${previous_build_number}" =~ ^([0-9]{8})([0-9]{2})$ ]] &&
   [[ "${BASH_REMATCH[1]}" == "${current_date}" ]]; then
    new_counter=$((10#${BASH_REMATCH[2]} + 1))
fi

if ((new_counter > 99)); then
    echo "error: Daily build counter exceeded 99 for ${current_date}" >&2
    exit 1
fi

new_build_number=$(printf '%s%02d' "${current_date}" "${new_counter}")
/usr/bin/sed -i '' -E \
    "s/^[[:space:]]*BUILD_VERSION[[:space:]]*=.*/BUILD_VERSION = ${new_build_number}/" \
    "${config_path}"

echo "Archive build number: ${previous_build_number} -> ${new_build_number}"
