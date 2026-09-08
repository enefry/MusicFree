#!/bin/sh

set -eu

# Debug builds intentionally work without provider credentials. Release builds
# may ship with Google Drive disabled; once explicitly enabled, every OAuth
# value becomes a hard build requirement so the UI cannot expose a broken flow.
if [ "${CONFIGURATION:-}" != "Release" ]; then
    exit 0
fi

debug_support_enabled="${MUSICFREE_DEBUG_SUPPORT_ENABLED:-NO}"
case "$(printf '%s' "$debug_support_enabled" | tr '[:lower:]' '[:upper:]')" in
    1|YES|TRUE)
        echo "error: Release builds must not enable MusicFreeDebugSupport." >&2
        exit 1
        ;;
    0|NO|FALSE|"")
        ;;
    *)
        echo "error: MUSICFREE_DEBUG_SUPPORT_ENABLED must be YES or NO." >&2
        exit 1
        ;;
esac

enabled="${GOOGLE_DRIVE_OAUTH_ENABLED:-NO}"
client_id="${GOOGLE_DRIVE_OAUTH_CLIENT_ID:-}"
redirect_url="${GOOGLE_DRIVE_OAUTH_REDIRECT_URL:-}"
url_scheme="${GOOGLE_DRIVE_OAUTH_URL_SCHEME:-}"

case "$(printf '%s' "$enabled" | tr '[:lower:]' '[:upper:]')" in
    1|YES|TRUE)
        ;;
    0|NO|FALSE|"")
        exit 0
        ;;
    *)
        echo "error: GOOGLE_DRIVE_OAUTH_ENABLED must be YES or NO." >&2
        exit 1
        ;;
esac

if [ -z "$(printf '%s' "$client_id" | tr -d '[:space:]')" ]; then
    echo "error: Enabled Google Drive OAuth requires GOOGLE_DRIVE_OAUTH_CLIENT_ID." >&2
    exit 1
fi

if [ -z "$(printf '%s' "$redirect_url" | tr -d '[:space:]')" ]; then
    echo "error: Enabled Google Drive OAuth requires GOOGLE_DRIVE_OAUTH_REDIRECT_URL." >&2
    exit 1
fi

if [ -z "$(printf '%s' "$url_scheme" | tr -d '[:space:]')" ]; then
    echo "error: Enabled Google Drive OAuth requires GOOGLE_DRIVE_OAUTH_URL_SCHEME." >&2
    exit 1
fi

case "$redirect_url" in
    "$url_scheme":*)
        ;;
    *)
        echo "error: GOOGLE_DRIVE_OAUTH_REDIRECT_URL must use GOOGLE_DRIVE_OAUTH_URL_SCHEME." >&2
        exit 1
        ;;
esac

case "$client_id" in
    *[[:space:]]*)
        echo "error: GOOGLE_DRIVE_OAUTH_CLIENT_ID must not contain whitespace." >&2
        exit 1
        ;;
esac
