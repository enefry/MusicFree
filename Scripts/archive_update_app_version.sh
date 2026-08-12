#!/bin/bash

set -euo pipefail

config_path="${SRCROOT}/basic_config.xcconfig"

if [[ ! -f "${config_path}" ]]; then
    echo "error: Missing version config: ${config_path}" >&2
    exit 1
fi

previous_app_version=$(
    /usr/bin/awk -F '=' '/^[[:space:]]*APP_VERSION[[:space:]]*=/ {
        value = $2
        gsub(/[[:space:]]/, "", value)
        print value
        exit
    }' "${config_path}"
)

if [[ ! "${previous_app_version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "error: APP_VERSION must use major.minor.patch format: ${previous_app_version}" >&2
    exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
new_app_version="${major}.${minor}.$((10#${patch} + 1))"

/usr/bin/sed -i '' -E \
    "s/^[[:space:]]*APP_VERSION[[:space:]]*=.*/APP_VERSION = ${new_app_version}/" \
    "${config_path}"

echo "Next app version: ${previous_app_version} -> ${new_app_version}"
