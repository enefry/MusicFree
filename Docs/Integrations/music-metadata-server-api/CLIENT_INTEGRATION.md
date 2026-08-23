# LRCLIB Client Integration

This service accepts the existing LRCLIB API routes under `/api`. TLS is terminated by
Nginx. The deployment can expose the lyrics service publicly under
`/api/v1/lyrics/`; see `API.md` for the complete lyrics and Discogs metadata contract.
Signed clients use per-client HMAC-SHA256 credentials configured in `config.toml`.

## Client configuration

Generate a different secret for every client:

```sh
openssl rand -hex 32
```

Add the client to the server configuration:

```toml
[auth]
mode = "optional"

[[auth.clients]]
id = "desktop-example"
secret = "the-generated-secret"
enabled = true
allowed_path_prefixes = ["/api"]
```

Use `mode = "required"` when every API request must be signed. Configuration changes
are reloaded automatically after the file is replaced atomically.

## Request signing

The client sends these headers:

```text
X-Lrclib-Client-Id
X-Lrclib-Timestamp
X-Lrclib-Nonce
X-Lrclib-Signature
```

The signed body is the exact byte sequence sent over HTTP. For a GET request the body
is empty. First compute:

```text
body_sha256 = lowercase_hex(SHA256(request_body))
```

Then construct the canonical string with Unix seconds and the exact path/query string:

```text
LRCLIB-SHA256-HMAC-V1
HTTP_METHOD
PATH_AND_QUERY
UNIX_TIMESTAMP
NONCE
BODY_SHA256
```

The signature is lowercase hexadecimal HMAC-SHA256 using the configured secret.
`PATH_AND_QUERY` must match the request exactly, including query encoding.

When using the example Nginx v1 prefix, sign the path after Nginx rewrites it:
`/api/v1/lyrics/get?...` is forwarded to the lyrics service as
`/api/get?...`, so `/api/get?...` is the value in the canonical string. Direct
requests to the upstream `/api` routes use their visible path unchanged.

## Python example

```python
import hashlib
import hmac
import secrets
import time
from urllib.parse import urlsplit
import requests


def signed_headers(method, url, body, client_id, secret):
    timestamp = str(int(time.time()))
    nonce = secrets.token_hex(16)
    parsed = urlsplit(url)
    path_and_query = parsed.path or "/"
    if parsed.query:
        path_and_query += "?" + parsed.query
    body_hash = hashlib.sha256(body).hexdigest()
    canonical = "\n".join([
        "LRCLIB-SHA256-HMAC-V1",
        method.upper(),
        path_and_query,
        timestamp,
        nonce,
        body_hash,
    ])
    signature = hmac.new(
        secret.encode("utf-8"), canonical.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    return {
        "X-Lrclib-Client-Id": client_id,
        "X-Lrclib-Timestamp": timestamp,
        "X-Lrclib-Nonce": nonce,
        "X-Lrclib-Signature": signature,
    }


url = "https://lyrics.example.com/api/get?track_name=Example&artist_name=Artist"
body = b""
headers = signed_headers("GET", url, body, "desktop-example", "the-generated-secret")
response = requests.get(url, headers=headers, timeout=10)
response.raise_for_status()
print(response.json())
```

For JSON POST requests, serialize the JSON once, sign those bytes, and send the same
bytes as the request body. Do not sign a pretty-printed form and send a compact form.

## Responses and errors

Useful status codes are:

```text
401  missing, invalid, expired, or replayed signature
413  request body exceeds server.max_body_bytes
429  rate limit exceeded; observe Retry-After
503  backend is overloaded or search is not ready
```

When `auth.mode = "optional"`, unsigned requests are treated as `anonymous` and use
the IP-based default rate limit. Signed clients can receive a separate client-based
limit through `rate_limit.rules`.

For a shared quota across an IP range, use `key = "cidr"` and list the range in
`cidrs`. The first matching CIDR is the bucket key. `key = "ip"` keeps separate
buckets for individual addresses, while `key = "country"` and `key = "region"`
group requests using the values supplied by trusted Nginx GeoIP headers.

## Nginx requirements

The application trusts `X-Real-IP`, `X-Geo-Country`, and `X-Geo-Region` only when the
TCP peer belongs to `server.trusted_proxies`. Do not expose the application port to
the public Internet and do not configure `0.0.0.0/0` as a trusted proxy.

The example Nginx configuration is in `deploy/nginx-lrclib.conf.example`.

## Database update manifest

When automatic read-only snapshot updates are enabled, `manifest_url` returns JSON:

```json
{
  "version": "2026-08-14T08:00:00Z",
  "download_url": "https://download.example.com/lrclib.sqlite3.gz",
  "sha256": "64-lowercase-hex-characters",
  "compressed_size": 123456789
}
```

The service streams the archive to `/data/staging`, verifies SHA-256, decompresses it,
runs SQLite validation, and only then schedules a graceful restart and file switch.
Automatic updates require `server.read_only = true`; this prevents local publish data
from being silently replaced by a weekly full snapshot.
