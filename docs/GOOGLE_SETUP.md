# Google Cloud setup

Native Drive signs in with OAuth 2.0 (authorization code plus PKCE) and calls the Google Drive API directly. The OAuth client ID is **not** in the repository. You create a client in Google Cloud and put it in `Config.local.xcconfig`, which is gitignored.

## 1. Create a project and enable Drive

1. Open [Google Cloud Console](https://console.cloud.google.com/).
2. Create a project, or pick an existing one.
3. Go to **APIs & Services → Library**, search for **Google Drive API**, and enable it.
4. Go to **APIs & Services → OAuth consent screen**.
   - User type: **External** is fine for your own accounts.
   - Add the scope `https://www.googleapis.com/auth/drive` (and the default OpenID email/profile scopes if the wizard asks).
   - While the app is in **Testing**, add every Google account you will sign in with under **Test users**.
   - The Drive scope is a sensitive/restricted scope. Google will show an "unverified app" warning until the app goes through verification. That is expected for a local open-source build. Continue past the warning only for a client you created yourself.

## 2. Create an OAuth client

Desktop clients are the path this build uses by default (loopback on `127.0.0.1`).

### Desktop client (recommended)

1. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Application type: **Desktop app**.
3. Copy the **client ID** and **client secret**.
4. You do not register a redirect URI. Google allows `http://127.0.0.1` with any port for Desktop clients. Native Drive binds an ephemeral port and uses that exact URI for the code exchange.

### iOS-type client (custom URL scheme)

Use this if you want `ASWebAuthenticationSession` to receive the redirect itself instead of a loopback listener.

1. Application type: **iOS**.
2. Bundle ID: `app.nativedrive.NativeDrive`.
3. The URL scheme is the reversed client ID, for example `com.googleusercontent.apps.1234567890-abcdef`.
4. Native Drive sends this redirect URI:

   ```text
   com.googleusercontent.apps.YOUR_CLIENT_PREFIX:/oauth2callback
   ```

   Register that scheme in `GOOGLE_OAUTH_REDIRECT_SCHEME` (no `:/` suffix). Leave the client secret empty.

## 3. Point the Xcode build at the client

From the repository root:

```bash
cp Config.example.xcconfig Config.local.xcconfig
```

Edit `Config.local.xcconfig`:

```text
GOOGLE_CLIENT_ID=YOUR_ID.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=YOUR_SECRET
GOOGLE_OAUTH_USE_LOOPBACK=YES
GOOGLE_OAUTH_REDIRECT_SCHEME=nativedrive
```

For an iOS-type client, set `GOOGLE_OAUTH_USE_LOOPBACK=NO` and set `GOOGLE_OAUTH_REDIRECT_SCHEME` to the reversed client ID.

`Config.xcconfig` (checked in) supplies defaults and optionally includes `Config.local.xcconfig`. Do not commit `Config.local.xcconfig`. The client secret stays on your machine; it is still not a highly protected secret for an installed app, which is why the app also sends PKCE.

Rebuild after changing the xcconfig. The values are copied into Info.plist at build time. Changing the file without rebuilding does nothing.

## 4. Sign in

Run Native Drive, choose **Add Account**, and complete the Google prompt. Repeat for each Google account. Each account has its own Keychain item and its own cache directory under Application Support. **Sign Out** deletes that account's tokens and cached listings on this Mac.

Cmd+1 through Cmd+9 switch the first nine accounts in the order they were added.
