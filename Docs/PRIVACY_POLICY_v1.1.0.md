# MyMusic: Local Player Privacy Policy v1.1.0

**Effective date: August 21, 2026**

This version applies to MyMusic: Local Player beginning with app version 1.1.0. It replaces the privacy description used by earlier app versions for the features described below.

## Summary

MyMusic: Local Player is a local music player. The local library, playback, playlists, favorites, history, and cached enrichment results remain on the device.

Metadata and lyrics enrichment are optional online features. Every metadata and lyrics Provider is disabled by default. The app only uses an online Provider after the user accepts this policy and the Provider's service disclosure, and then enables that Provider in Settings.

The app does not use advertising, analytics, crash-reporting, or tracking services. The developer does not receive the user's audio files or complete local music library through the local-player workflow. A request can still be sent to a server selected by the enabled Provider, as described below.

## Information stored on the device

The app may store the following information locally:

- Audio files selected by the user and their media metadata, such as title, artist, album, genre, duration, and artwork.
- Playlists, playlist membership, favorites, playback history, and the current playback queue.
- Metadata matching results, artwork, and lyrics obtained from an enabled Provider.
- Playback preferences, appearance choices, language choice, and app icon choice.
- Privacy policy and Provider disclosure versions that the user has accepted.

## Optional online Providers

When a Provider is enabled, the app sends only the metadata needed for that Provider's function. The current Provider scopes are:

| Provider | Recipient and purpose | Request data |
| --- | --- | --- |
| MusicKit | Apple Music / MusicKit catalog metadata and artwork | Song title, artist, and catalog matching information |
| MusicBrainz + Cover Art Archive | Open music metadata and album artwork | Song title and artist; a matched MusicBrainz release identifier may be used for artwork |
| Metadata Server | The Metadata Server endpoint configured by the app build | Metadata searches use song title and artist; lyrics searches may also use album and duration |
| Discogs | Discogs release metadata and artwork | Track title and artist; an application-configured Discogs token is sent only to Discogs when configured |
| LRCLIB | Lyrics lookup | Song title, artist, and, when available, album and duration |

The app does not intentionally send audio bytes, complete local file paths, the full library list, or local account credentials to these services. Network infrastructure may receive the request IP address, User-Agent, and normal connection metadata. Provider operators control their own server logs and retention under their own privacy policies.

Artwork may be downloaded from a Provider's artwork endpoint after a metadata match. Successful metadata, artwork, and lyrics results are stored locally so that later playback can use the local result without repeating the request.

## Consent and controls

The Settings page provides the application policy and Provider service disclosures. Opening the metadata and lyrics settings page does not require accepting every service. When a user enables a Provider, the app requests the current application policy if needed and then only that Provider's service disclosure. Declining keeps that Provider disabled.

The user can disable any Provider at any time. Disabling a Provider stops future requests from the app; it cannot remove request logs that the Provider already received. A policy or disclosure version change may require confirmation again before online requests resume.

The local player remains usable without accepting this policy or enabling any online Provider.

## Third-party policies

The relevant third-party privacy policies are available from the in-app Provider disclosures. They may change independently of this policy:

- [Apple Privacy](https://www.apple.com/legal/privacy/)
- [MetaBrainz Privacy](https://metabrainz.org/privacy) for MusicBrainz and Cover Art Archive
- [Discogs Privacy Policy](https://support.discogs.com/hc/en-us/articles/360007522313-Privacy-Policy)
- [LRCLIB Privacy](https://lrclib.net/privacy)
- [Metadata Server Privacy](https://music.tools4me.win/privacy) for the app-configured Metadata Server deployment

Third-party dependency and license notices are included in the app and in the source distribution under [`ThirdPartyNotices/`](../ThirdPartyNotices/).

## Files and user content

The user chooses which audio files to import through the system file picker or Finder file sharing. The app processes those files locally to build the library and play them. Users remain responsible for having the right to store and play the audio content they import.

## Children's privacy

MyMusic: Local Player does not knowingly collect personal information from children. Online Provider requests are optional and require the same disclosures and controls for every user.

## Changes to this policy

If the app's data practices change, this policy will be updated before the change is released. The effective date and version at the top of this document will also be updated. A changed policy or Provider disclosure version may require renewed consent in the app.

## Contact

For privacy questions or requests, open an issue in the public [MusicFree GitHub Issues](https://github.com/enefry/MusicFree/issues). Please do not include passwords, private keys, or other sensitive personal information in a public issue.
