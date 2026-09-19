# MyMusic: Local Player Privacy Policy v1.2.0

**Effective date: August 30, 2026**

This version applies to MyMusic: Local Player beginning with app version 1.2.0. It replaces the application privacy policy used for the optional online services described by earlier app versions.

## Summary

MyMusic: Local Player is primarily a local music player. Local importing, the managed library, playback, playlists, favorites, history, and already imported media do not require an online source.

Version 1.2.0 adds optional external media sources:

- **DS Audio**: browse a configured DSM/Audio Station source, optionally search, temporarily audition an audio item over HTTP, and download/import media into the local library.
- **Google Drive**: sign in with Google OAuth, browse audio files and folders, and download/import media into the local library. Google Drive online audition is not supported in this version.

Baidu Netdisk and gateway Providers are reserved extension points and are not available online services in version 1.2.0.

The app does not use advertising, analytics, crash-reporting, or tracking services. The developer does not receive the user's audio files or complete local library through the local-player workflow.

## Information stored on the device

The app may store:

- Audio files selected by the user and their local media metadata, artwork, playlists, favorites, history, and playback queue.
- Metadata, artwork, and lyrics obtained from an enabled optional Provider.
- Non-sensitive online source configuration, such as a display name, Provider type, endpoint, source identifier, enabled state, and accepted disclosure version.
- Download/import task status, source and object identifiers, display names, metadata hints, and redacted failure codes so the task list can survive navigation and app restart.
- Google OAuth credentials in the system Keychain when Google Drive is authorized. OAuth tokens are not written to the settings file, download queue, logs, or media library.
- DS Audio credentials and session data only through the system credential/session facilities used by the configured source. Passwords, DSM session identifiers, and cookies are not written to the download queue or logs.

Remote URLs, temporary playback or download URLs, HTTP headers, cookies, tokens, and VLC player objects are not persisted as application settings, queue records, or library records.

## Consent and controls

Online sources require two independent approvals:

1. The application privacy policy.
2. The privacy disclosure for the specific configured source instance.

The application policy is requested the first time the Online Sources tab is entered or an online source is added. Each source instance has its own disclosure and revocation state, even when two instances use the same Provider type.

The Settings page provides an independent **Privacy & Online Services** section where the user can:

- Turn all online source requests on or off.
- Enable or disable one configured source instance.
- View and revoke one source instance's disclosure.
- Revoke the application policy, which immediately disables all online source network operations and clears all source-level approvals.

Disabling or revoking online access does not delete source configuration, local library records, playlists, history, or media already imported into the device. Existing local media remains playable offline. New browsing, searching, audition, and download operations require the relevant approvals and enabled states again.

## DS Audio requests

When DS Audio is enabled, the app sends requests to the DSM/Audio Station endpoint configured by the user. These requests can include:

- The configured DSM endpoint and account authentication data needed to establish a session.
- Folder, album, track, and audio-file identifiers needed to browse or download the selected source.
- The search text entered by the user when search is used.
- Temporary HTTP playback or transcoding requests for the single item being auditioned.

The app does not upload local audio files to DSM as part of this workflow. Temporary audition is not added to the formal playback queue, playback history, or statistics. DS Audio service operators and network infrastructure may receive normal connection metadata such as IP address, User-Agent, and request timing under their own policies.

## Google Drive requests

When Google Drive is enabled, the app uses Google OAuth to obtain authorization for the configured account. Google receives the OAuth request, account authorization information, and the Drive API requests needed to list selected folders and download selected audio files.

The app requests only the Drive access required by the configured Google integration. Downloaded files are staged temporarily, imported into the local managed media library, and then used through the existing local playback pipeline. Google Drive is not retained as a remote playback Variant in version 1.2.0.

Google controls its own processing, access logs, retention, and privacy practices under Google's policies and the permissions shown during authorization.

## Network and third-party processing

Network providers can receive the request IP address, User-Agent, TLS/connection metadata, and normal server-side logs. The app does not intentionally send the complete local library, unrelated local paths, or local media bytes to online Providers during source browsing, audition, or download.

Already imported media and cached enrichment results remain available locally when online sources are disabled. A Provider may still retain information it received before the user revoked consent; revocation only prevents new requests from this app.

## Files and user content

The user chooses which audio files to import through the system file picker or Finder file sharing. The app processes those files locally to build the library and play them. Users remain responsible for having the right to store and play the audio content they import or download.

## Changes to this policy

If the app's data practices change, this policy will be updated before the change is released. The effective date and version at the top of this document will also be updated. A changed application policy or source disclosure version may require renewed consent in the app.

## Contact

For privacy questions or requests, open an issue in the public [MusicFree GitHub Issues](https://github.com/enefry/MusicFree/issues). Please do not include passwords, private keys, OAuth tokens, or other sensitive personal information in a public issue.
