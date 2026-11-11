# Native Drive

An open source, native Mac app for browsing Google Drive, built to feel fast and at home on macOS.

## Why

Google Drive for desktop mounts your files in Finder as if they were on your Mac, which is slow to browse and hides what's actually in the cloud. Native Drive is a standalone app that talks to Google Drive directly, so you can move through folders and find files quickly without waiting on a virtual drive.

## Goals

- **Fast.** Folders open instantly, with local caching and incremental sync, so large Drives stay responsive.
- **Native.** Built for the Mac with platform conventions: keyboard-first navigation, Quick Look previews, drag and drop, and system look and feel.
- **Multi-user.** Sign in with several Google accounts at once, switch between them quickly, and keep each account's files, cache, and permissions separate.
- **Open source.** Free to read, use, and improve.

## Planned features

- Browse My Drive, Shared with me, shared drives, and recent files
- Fast search across files and folders
- Quick Look previews and open in the default app
- Upload and download with drag and drop
- Multiple Google accounts with per-account controls
- Opens Google Docs, Sheets, and Slides in the browser
- In-app photos (including HEIC) and video, so images and clips open without leaving the app

Photos and videos open in the app. Images show a cached thumbnail immediately, then a screen-sized preview, with zoom, pan, and arrow keys to move through the other pictures in the folder. The original downloads when you zoom in. HEIC and HEIF are decoded on the Mac, including orientation. A failed download is reported separately from a failed decode, with the underlying error and a Retry button. MP4, MOV, M4V, and common audio files download, then play with the system player; formats the system can't play, such as MKV and AVI, offer **Open in default app**. Details: [docs/MEDIA.md](docs/MEDIA.md).

## Status

v0.1 is a first working version that needs the Google setup. See [docs/GOOGLE_SETUP.md](docs/GOOGLE_SETUP.md).

## Build

The app target is an Xcode project generated from `project.yml`. The Xcode project is not committed.

```bash
brew install xcodegen && xcodegen && open NativeDrive.xcodeproj
```

Requirements: macOS 14 or later, and Xcode 15 or later. Code signing in the generated project is ad hoc (`CODE_SIGN_IDENTITY = -`) so the app can run locally. Set your team in Xcode if you want a development certificate instead.

Before the first build, copy `Config.example.xcconfig` to `Config.local.xcconfig` and set `GOOGLE_CLIENT_SECRET` (see Setup). The Desktop client ID is already in `Config.xcconfig`. The window explains what is missing.

The Drive API, OAuth, cache, and account model live in the `NativeDriveCore` Swift package. On a machine with a Swift toolchain:

```bash
swift test
```

## Set up Google sign-in

The app cannot sign in until this is done. You do it once per checkout, not on every sign-in. After the secret is baked into a build, each person just chooses **Sign in with Google**. The full walkthrough is in [docs/GOOGLE_SETUP.md](docs/GOOGLE_SETUP.md).

The Desktop client ID already ships in `Config.xcconfig`. The client secret must never be committed.

1. Create a Google Cloud project and enable the Google Drive API.
2. Configure the OAuth consent screen. Choose an **External** audience, add your Google account under **Test users**, and add the Drive scope `https://www.googleapis.com/auth/drive`. The "unverified app" warning is expected while the app is in testing.
3. Create an OAuth client of type **Desktop app** and copy the Client ID and Client secret.
4. In the repo, create the gitignored local config and set the secret. Set `GOOGLE_CLIENT_ID` only if you are using your own client instead of the one shipped in `Config.xcconfig`.

   ```bash
   cp Config.example.xcconfig Config.local.xcconfig
   ```

   ```text
   GOOGLE_CLIENT_SECRET=your-client-secret
   # GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
   ```

5. Rebuild. The values are baked in at build time.

   ```bash
   xcodegen
   ```

   Then build and run `NativeDrive.xcodeproj` in Xcode.

6. In the app, choose **Sign in with Google** or **Add Account**.

While the OAuth app is unverified, every additional Google account you add must also be listed as a test user.

## Contributing

Ideas and pull requests are welcome once the first version is in place.
