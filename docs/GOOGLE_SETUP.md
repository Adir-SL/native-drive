# Google Cloud setup

Native Drive signs in with OAuth 2.0 (authorization code plus PKCE) and calls the Google Drive API directly. The Desktop OAuth **client ID** ships in `Config.xcconfig`. The **client secret** does not: Google requires it for a Desktop client's token exchange, and it belongs only in gitignored `Config.local.xcconfig`.

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

### Desktop client (this repository)

The checked-in client ID is:

```text
438919472583-fu1nekhd5fq8rh3326bk65qfjcjvtfek.apps.googleusercontent.com
```

It is a Desktop app client. You do not register a redirect URI. Google allows `http://127.0.0.1` with any port for Desktop clients. Native Drive binds an ephemeral port and uses that exact URI for the code exchange.

Copy the **client secret** from the same credential in Google Cloud Console. Do not commit it. The token exchange fails without it, so the app asks for `GOOGLE_CLIENT_SECRET` until you rebuild with the secret set locally.

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

## 3. Add the client secret locally

From the repository root:

```bash
cp Config.example.xcconfig Config.local.xcconfig
```

Edit `Config.local.xcconfig` and set only the secret:

```text
GOOGLE_CLIENT_SECRET=the-secret-from-google-cloud
GOOGLE_OAUTH_USE_LOOPBACK=YES
GOOGLE_OAUTH_REDIRECT_SCHEME=nativedrive
```

Leave `GOOGLE_CLIENT_ID` unset in that file so the ID in `Config.xcconfig` is used. `Config.xcconfig` includes `Config.local.xcconfig` when it exists, and the local values override the defaults. Do not commit `Config.local.xcconfig`.

Until that secret is present, the app shows setup instructions and does not offer sign-in. After you rebuild, **Sign in with Google** is available.

For an iOS-type client, set `GOOGLE_OAUTH_USE_LOOPBACK=NO`, set `GOOGLE_OAUTH_REDIRECT_SCHEME` to the reversed client ID, and leave the secret empty. That public-client flow can sign in without a secret.

Rebuild after changing the xcconfig. The values are copied into Info.plist at build time. Changing the file without rebuilding does nothing. The app also sends PKCE on every token exchange.

## 4. Sign in

Run Native Drive, choose **Sign in with Google**, and complete the Google prompt. Repeat with **Add Account** for each Google account. Each account has its own Keychain item and its own cache directory under Application Support. **Sign Out** deletes that account's tokens and cached listings on this Mac.

Cmd+1 through Cmd+9 switch the first nine accounts in the order they were added.
