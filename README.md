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

## Status

v0.1 is a first working version that needs the Google setup. See [docs/GOOGLE_SETUP.md](docs/GOOGLE_SETUP.md).

## Build

The app target is an Xcode project generated from `project.yml`. The Xcode project is not committed.

```bash
brew install xcodegen && xcodegen && open NativeDrive.xcodeproj
```

Requirements: macOS 14 or later, and Xcode 15 or later. Code signing in the generated project is ad hoc (`CODE_SIGN_IDENTITY = -`) so the app can run locally. Set your team in Xcode if you want a development certificate instead.

Before the first build, create `Config.local.xcconfig` from the example (see Setup). An empty client ID still compiles; the window explains what is missing.

The Drive API, OAuth, cache, and account model live in the `NativeDriveCore` Swift package. On a machine with a Swift toolchain:

```bash
swift test
```

## Setup

Create a Google Cloud OAuth client, enable the Drive API, and put the client ID in a gitignored `Config.local.xcconfig`. Steps: [docs/GOOGLE_SETUP.md](docs/GOOGLE_SETUP.md).

## Contributing

Ideas and pull requests are welcome once the first version is in place.
