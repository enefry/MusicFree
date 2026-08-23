# MyMusic: Local Player — LRCLIB Provider Privacy Disclosure v1.0.0

**Effective date: August 22, 2026**

## Important notice

This document is an application-provided privacy disclosure for MyMusic: Local Player's optional use of the LRCLIB lyrics service. It is not a privacy policy issued by LRCLIB, does not represent LRCLIB, and cannot change how the LRCLIB service operates.

The app provides this disclosure because it does not have an official LRCLIB privacy-policy text to link to. The service may publish or change its own terms independently; users should review the latest information on the [LRCLIB website](https://lrclib.net/) and its [API documentation](https://lrclib.net/docs/) where available.

## Service and purpose

LRCLIB is an optional lyrics Provider. When it is enabled and the app needs lyrics for a song, the app sends a lookup request to the LRCLIB API endpoint configured for the app build. The purpose is to find plain or synchronized lyrics for that song.

LRCLIB is disabled by default. The app requires acceptance of the application privacy policy and this Provider disclosure before enabling the Provider.

## Information sent by the app

Depending on the metadata available for the local song, the lookup request may include:

- `track_name`: the song title;
- `artist_name`: the artist name;
- `album_name`: the album name, when available;
- `duration`: the duration in seconds, when available.

The app also sends the normal HTTP headers needed for the request, including `Accept: application/json` and the app User-Agent `MusicFree/1.0`.

The app does not intentionally send audio bytes, complete local file paths, the full music library, local account credentials, contacts, advertising identifiers, or an LRCLIB login credential. The app does not require an LRCLIB account or access token for this Provider.

## Server and network information

The LRCLIB endpoint and ordinary network infrastructure can receive the request IP address, request time, User-Agent, connection metadata, and the query values listed above. The endpoint operator may log request URLs, which can contain song title, artist, album, and duration. The app does not control the operator's logs, retention period, security practices, or disclosure practices.

The app does not send these requests to the app developer's analytics or advertising systems. Failed, rate-limited, or otherwise unsuccessful requests may be represented in the app's local diagnostic log with their request URL and HTTP status; those local logs leave the device only if the user exports or shares them.

## Local results and caching

Lyrics returned by LRCLIB may be saved in the app's local library so later playback can use the local result without repeating the online lookup. The app does not intentionally upload the saved lyrics or the local library to the app developer.

## Consent and controls

The user can enable or disable LRCLIB in Settings. Disabling the Provider stops new LRCLIB requests from the app. It cannot delete request logs that the endpoint operator already received. Disabling the Provider also does not automatically delete lyrics already saved locally; those remain subject to the app's normal local-library deletion and storage controls.

The user can withdraw Provider consent at any time from the LRCLIB Provider detail page. Withdrawal also disables the Provider. The local player and locally stored media remain usable without accepting this disclosure or enabling LRCLIB.

## Changes

If the app changes the information sent to LRCLIB or the purpose of the integration, this disclosure will be updated before the changed behavior is released. The version and effective date above will also be updated, and the app may request consent again.

## Contact

For questions about how MyMusic: Local Player integrates LRCLIB, open an issue in the public [MusicFree GitHub Issues](https://github.com/enefry/MusicFree/issues). Please do not include passwords, private keys, or other sensitive personal information in a public issue.
