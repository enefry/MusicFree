# LRCLIB and Discogs Metadata API

This document describes the public API layout used by the deployment in this
repository. The deployment runs two independent HTTP services:

- The lyrics service listens on `127.0.0.1:3300`.
- The Discogs metadata service listens on `127.0.0.1:3310`.

The services use separate databases and can be updated independently. The
metadata service reads a local Discogs dump snapshot; it does not call the
Discogs API for individual requests.

## Public URLs

The example Nginx configuration exposes these prefixes:

| Public prefix | Upstream | Upstream prefix |
| --- | --- | --- |
| `/api/v1/lyrics/` | `127.0.0.1:3300` | `/api/` |
| `/api/v1/metadata/` | `127.0.0.1:3310` | `/api/` |

The trailing slash in `proxy_pass` is required. For example:

```text
/api/v1/lyrics/get?track_name=Song&artist_name=Artist
  -> http://127.0.0.1:3300/api/get?track_name=Song&artist_name=Artist

/api/v1/metadata/search?q=Song&kind=release
  -> http://127.0.0.1:3310/api/search?q=Song&kind=release
```

Use the following Nginx locations. The exact locations redirect a slashless
base path, and the prefix locations remove the public service prefix before
proxying.

```nginx
location = /api/v1/metadata {
    return 308 /api/v1/metadata/;
}

location /api/v1/metadata/ {
    include /etc/nginx/snippets/proxy.conf;
    proxy_pass http://127.0.0.1:3310/api/;
}

location = /api/v1/lyrics {
    return 308 /api/v1/lyrics/;
}

location /api/v1/lyrics/ {
    include /etc/nginx/snippets/proxy.conf;
    proxy_pass http://127.0.0.1:3300/api/;
}
```

`/etc/nginx/snippets/proxy.conf` should contain common proxy settings and must
not contain `proxy_pass`. At minimum, the application needs the following
headers for proxy-aware client IP and GeoIP handling:

The repository template for this file is `deploy/nginx-proxy.conf.example`.

```nginx
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Geo-Country $lrclib_geo_country;
proxy_set_header X-Geo-Region $lrclib_geo_region;
proxy_read_timeout 60s;
```

The application only trusts these forwarded headers when the connection peer
matches `server.trusted_proxies` in `config.toml`. Configure the CIDR seen by
the application container for the Nginx proxy; do not use `0.0.0.0/0`.

## Common response rules

Successful API responses are JSON unless the endpoint is documented as an
empty response. Query parameter values must be URL encoded.

| Status | Meaning |
| --- | --- |
| `200` | Successful query or challenge response |
| `201` | Lyrics publish or flag accepted; response body is empty |
| `204` | Health endpoint is healthy |
| `308` | Slashless public service prefix redirected to its slash form |
| `400` | Invalid query, validation input, or publish token |
| `401` | Missing or invalid required LRCLIB client signature |
| `404` | Lyrics track or Discogs entity was not found |
| `405` | Write endpoint disabled by read-only snapshot mode |
| `413` | Request body exceeds `server.max_body_bytes` |
| `429` | Rate limit exceeded; honor the `Retry-After` header |
| `500` | Internal service error |
| `503` | Service is not ready or is temporarily overloaded |

Lyrics service errors normally use this JSON shape:

```json
{
  "message": "Failed to find specified track",
  "name": "TrackNotFound",
  "statusCode": 404
}
```

Authentication, body-size, and rate-limit failures use a smaller shape:

```json
{
  "statusCode": 401,
  "message": "client signature is required"
}
```

The metadata service returns a plain-text message for a `400` error and an
empty body for a `404` or `500` response.

## Lyrics API

The public base URL is:

```text
https://lyrics.example.com/api/v1/lyrics
```

The legacy upstream routes under `/api` remain available through the default
Nginx location and are also the paths used by the application internally.

### Get lyrics by metadata

```http
GET /api/v1/lyrics/get?track_name=...&artist_name=...[&album_name=...][&duration=...]
```

Parameters:

| Name | Required | Description |
| --- | --- | --- |
| `track_name` | Yes | Track title; must not be empty |
| `artist_name` | Yes | Artist name; must not be empty |
| `album_name` | No | Album name constraint |
| `duration` | No | Duration in seconds, from `1` through `3600` |

The lookup normalizes metadata text. When `duration` is provided, a track is
accepted when its stored duration is within two seconds of the requested value.
At most one track is returned.

Example:

```sh
curl --get 'https://lyrics.example.com/api/v1/lyrics/get' \
  --data-urlencode 'track_name=Example Song' \
  --data-urlencode 'artist_name=Example Artist' \
  --data-urlencode 'album_name=Example Album' \
  --data-urlencode 'duration=180'
```

Example `200` response:

```json
{
  "id": 123,
  "name": "Example Song",
  "trackName": "Example Song",
  "artistName": "Example Artist",
  "albumName": "Example Album",
  "duration": 180.0,
  "instrumental": false,
  "plainLyrics": "Example line 1\nExample line 2",
  "syncedLyrics": "[00:01.00]Example line 1\n[00:04.00]Example line 2",
  "lyricsfile": null
}
```

### Get lyrics by track ID

```http
GET /api/v1/lyrics/get/{track_id}
```

`track_id` is the numeric LRCLIB track ID. The response has the same shape as
the metadata lookup. A missing ID returns `404` with a `TrackNotFound` error.

Example:

```sh
curl 'https://lyrics.example.com/api/v1/lyrics/get/123'
```

### Search lyrics

```http
GET /api/v1/lyrics/search[?q=...][&track_name=...][&artist_name=...][&album_name=...]
```

All parameters are optional. If `q` is present, every usable term must occur
in at least one indexed track, artist, or album field. Otherwise the structured
search uses `track_name` and optionally constrains `artist_name` and
`album_name`. A search with no usable terms returns an empty array.

The response is a JSON array containing the same track objects returned by the
metadata lookup:

```json
[
  {
    "id": 123,
    "name": "Example Song",
    "trackName": "Example Song",
    "artistName": "Example Artist",
    "albumName": "Example Album",
    "duration": 180.0,
    "instrumental": false,
    "plainLyrics": "Example line 1",
    "syncedLyrics": null,
    "lyricsfile": null
  }
]
```

### Request a publish challenge

```http
POST /api/v1/lyrics/request-challenge
```

The request body is empty. The response contains a one-time proof-of-work
challenge:

```json
{
  "prefix": "32-character-prefix",
  "target": "64-character-uppercase-hex-target"
}
```

Find a `nonce` for which the SHA-256 digest of `prefix + nonce` is less than or
equal to `target` when compared as big-endian bytes. The challenge is submitted
as `prefix:nonce` in `X-Publish-Token` and is consumed after one successful
submission.

### Publish lyrics

```http
POST /api/v1/lyrics/publish
Content-Type: application/json
X-Publish-Token: {prefix}:{nonce}
```

Request body:

```json
{
  "trackName": "Example Song",
  "artistName": "Example Artist",
  "albumName": "Example Album",
  "duration": 180.0,
  "plainLyrics": "Example line 1\nExample line 2",
  "syncedLyrics": "[00:01.00]Example line 1\n[00:04.00]Example line 2",
  "lyricsfile": null
}
```

`trackName`, `artistName`, `albumName`, and `duration` are required. The legacy
`plainLyrics` and `syncedLyrics` fields are optional. When `lyricsfile` is a
non-empty string, it is used as the stored Lyricsfile representation and the
legacy fields are derived from it when possible. A successful request returns
`201` with an empty body.

In the deployment's `server.read_only = true` snapshot mode, this endpoint is
disabled and returns `405`.

### Flag lyrics

```http
POST /api/v1/lyrics/flag
Content-Type: application/json
X-Publish-Token: {prefix}:{nonce}
```

Request body:

```json
{
  "trackId": 123,
  "content": "Reason for the report"
}
```

`trackId` is required and `content` is optional. A successful request returns
`201` with an empty body. This endpoint is also disabled in read-only snapshot
mode.

## LRCLIB client authentication

The lyrics service supports the HMAC-SHA256 client authentication described in
`CLIENT_INTEGRATION.md`. The modes are:

- `off`: signatures are ignored.
- `optional`: unsigned requests are treated as anonymous.
- `required`: every lyrics API request must carry a valid signature.

The signature headers are:

```text
X-Lrclib-Client-Id
X-Lrclib-Timestamp
X-Lrclib-Nonce
X-Lrclib-Signature
```

The signature binds the exact method, path and query string, timestamp, nonce,
and SHA-256 hash of the exact request body. The public Nginx locations rewrite
the path before it reaches the lyrics service. Therefore a request sent to:

```text
/api/v1/lyrics/get?track_name=Example
```

must sign the upstream path and query:

```text
/api/get?track_name=Example
```

The query string is not rewritten. Metadata requests do not use the LRCLIB
HMAC middleware; protect the metadata location with Nginx or another network
boundary if it must not be public.

The `X-Publish-Token` proof-of-work header is separate from HMAC client
authentication. If `auth.mode = "required"`, publish and flag requests need a
valid HMAC signature as well as a valid publish token.

## Discogs metadata API

The public base URL is:

```text
https://lyrics.example.com/api/v1/metadata
```

The metadata snapshot is imported from the four monthly Discogs dump files.
The returned arrays contain the corresponding Discogs JSON values and may be
empty when a compact import omitted large fields.

### Full-text metadata search

```http
GET /api/v1/metadata/search?q=...&kind=release&page=1&per_page=25
```

Parameters:

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `q` or `query` | Yes | None | Search text; must contain a searchable term |
| `kind` or `type` | No | `release` | `release`, `master`, `artist`, or `label` |
| `page` | No | `1` | One-based page number; values below 1 become 1 |
| `per_page` | No | `25` | Page size, clamped to `1..=100` |

Example:

```sh
curl --get 'https://lyrics.example.com/api/v1/metadata/search' \
  --data-urlencode 'q=Example Artist' \
  --data-urlencode 'kind=release' \
  --data-urlencode 'page=1' \
  --data-urlencode 'per_page=10'
```

Example response:

```json
{
  "kind": "release",
  "page": 1,
  "perPage": 10,
  "total": 1,
  "results": [
    {
      "kind": "release",
      "id": 123456,
      "name": "Example Album",
      "year": 2024,
      "country": "US",
      "masterId": 654321
    }
  ]
}
```

`country` and `masterId` are `null` when they do not apply to the result kind.

### Match a track to Discogs releases

```http
GET /api/v1/metadata/track?track_name=...&artist_name=...[&album_name=...][&duration=...]
```

`track_name` and `artist_name` are required. The camelCase aliases
`trackName`, `artistName`, and `albumName` are also accepted. `duration` is
optional and must be between `1` and `3600` seconds.

The service searches the local release FTS index, then applies normalized track
title and artist matching. If supplied, the album name is compared against the
release title and duration is matched within two seconds. The response contains
at most 20 matches.

Example response:

```json
{
  "trackName": "Example Song",
  "artistName": "Example Artist",
  "albumName": "Example Album",
  "results": [
    {
      "releaseId": 123456,
      "masterId": 654321,
      "releaseTitle": "Example Album",
      "year": 2024,
      "country": "US",
      "track": {
        "position": "1-1",
        "title": "Example Song",
        "duration": "3:00",
        "artists": [
          {"name": "Example Artist"}
        ]
      }
    }
  ]
}
```

The `track` object is the raw Discogs tracklist item. Its fields can vary by
dump record.

### Entity details

```http
GET /api/v1/metadata/releases/{id}
GET /api/v1/metadata/masters/{id}
GET /api/v1/metadata/artists/{id}
GET /api/v1/metadata/labels/{id}
```

All IDs are numeric. A found entity returns `200` JSON. A missing entity
returns `404` with an empty body.

Release response fields:

```text
id, status, title, year, country, released, notes, dataQuality,
masterId, updatedAt, artists, labels, formats, genres, styles, tracklist,
identifiers, companies, images, videos, series
```

Master response fields:

```text
id, title, year, mainRelease, dataQuality, updatedAt,
artists, genres, styles, tracklist, images, videos
```

Artist response fields:

```text
id, name, realName, profile, dataQuality, updatedAt,
urls, nameVariations, aliases, members, groups, images
```

Label response fields:

```text
id, name, contactInfo, profile, dataQuality, updatedAt, urls, images
```

Scalar fields may be `null`. The array fields are always JSON arrays in the
service response.

## Health and readiness

Both services expose these internal endpoints:

```http
GET http://127.0.0.1:3300/healthz
GET http://127.0.0.1:3300/readyz

GET http://127.0.0.1:3310/healthz
GET http://127.0.0.1:3310/readyz
```

`/healthz` returns `204` when the process is running. The lyrics `/readyz`
requires a usable SQLite database and ready Tantivy index. The metadata
`/readyz` requires a successfully imported snapshot marker. An unready service
returns `503`.

## Data and attribution

The metadata API serves a local copy of Discogs database dump data. Keep the
required Discogs attribution and follow the current Discogs data-use terms when
redistributing or displaying the returned metadata. The automatic update
workflow and snapshot rollback procedure are documented in the deployment
workspace's `deploy/README.md`.
