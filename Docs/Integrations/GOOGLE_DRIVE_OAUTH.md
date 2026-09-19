# Google Drive OAuth

The committed `basic_config.xcconfig` contains only the disabled baseline.
Google Drive build configuration belongs in the ignored
`GoogleDriveOAuth.local.xcconfig` file or in CI build-setting overrides.

## Local setup

1. Copy `GoogleDriveOAuth.local.xcconfig.example` to
   `GoogleDriveOAuth.local.xcconfig`.
2. Fill in `CLIENT_ID` and `REVERSED_CLIENT_ID` from Google Cloud Console.
3. Regenerate the Xcode project if needed.

The local file is included conditionally by `basic_config.xcconfig`; it is not
copied into the app bundle. Its values are expanded into the built
`Info.plist`, where the app reads:

- `GoogleDriveOAuthClientID`
- `GoogleDriveOAuthReversedClientID`
- `GoogleDriveOAuthRedirectURL`
- `GoogleDriveOAuthEnabled`

`GOOGLE_DRIVE_OAUTH_URL_SCHEME` is also used for the app's registered callback
URL scheme. The recommended value is `REVERSED_CLIENT_ID`, and the redirect URL
must match the value registered in Google Cloud Console.

## Google plist

`App/apps.googleusercontent.com.plist` may remain locally as a reference, but
it is ignored by Git and explicitly excluded from the `MusicFree` target. It is
not loaded at runtime and is not packaged into the app. Only the xcconfig values
are used by the build.

CI can provide the same values without creating a local file:

```sh
GOOGLE_DRIVE_OAUTH_ENABLED=YES \
GOOGLE_DRIVE_OAUTH_CLIENT_ID="..." \
GOOGLE_DRIVE_OAUTH_REVERSED_CLIENT_ID="..." \
GOOGLE_DRIVE_OAUTH_URL_SCHEME="..." \
GOOGLE_DRIVE_OAUTH_REDIRECT_URL="..." \
./publish_tf.sh --no-upload
```
