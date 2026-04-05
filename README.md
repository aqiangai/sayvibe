# say vibe

<p align="center">
  <a href="./README.md"><strong>English</strong></a> ·
  <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="assets/logo/ltr-logo.svg" width="108" alt="say vibe logo" />
</p>

<p align="center">
  <strong>Use the iPhone's built-in voice input to capture thoughts quietly, then keep the text flowing into your Mac.</strong>
</p>

<p align="center">
  say vibe is a local-first iPhone + Mac workflow for low-friction dictation, silent vibe capture, and fast text handoff.
</p>

## Preview

### Vibe Flow

<p align="center">
  <img src="docs/media/vibe-demo.gif" width="240" alt="say vibe vibe flow demo" />
</p>

### Mobile Screens

<table>
  <tr>
    <td width="50%" align="center">
      <img src="docs/media/mobile-settings.jpg" width="280" alt="say vibe mobile settings screen" />
    </td>
    <td width="50%" align="center">
      <img src="docs/media/mobile-vibe.jpg" width="280" alt="say vibe mobile vibe screen" />
    </td>
  </tr>
  <tr>
    <td align="center"><strong>Settings</strong></td>
    <td align="center"><strong>Vibe</strong></td>
  </tr>
</table>

### Desktop Console

<p align="center">
  <img src="docs/media/desktop-console.png" alt="say vibe desktop console" />
</p>

## Why say vibe

1. It reuses the system input method's voice typing instead of rebuilding ASR from scratch, which makes dialects and language switching much easier to inherit from the OS.
2. It supports a quieter, lower-friction vibe workflow: speak first, land text fast, then refine on the Mac without breaking flow.

## Open-source Focus

This repository is currently centered around two actively maintained directories:

- `ios/`
  - SwiftUI iPhone client
  - connection, syncing, pairing, meeting notes
- `pc_rust/`
  - `Vue + Vite + Tauri + Rust` desktop relay
  - pairing QR, relay state, logs, auto output

Other folders are legacy experiments or transition artifacts and are not the main focus of this open-source release.

## What It Does

### iOS

- Three main tabs: `Settings`, `Vibe`, `Meeting Notes`
- LAN scan, recent devices, QR pairing
- Debounced text sync to the desktop relay
- Remote control for desktop auto-output mode
- Dedicated `PC Enter` trigger
- Meeting notes stored as exportable documents
- Chinese / English UI
- Light / dark / system theme
- Home Screen widget shortcut

### Desktop

- Runs a local relay that stays compatible with the mobile protocol
- Shows pairing QR, LAN addresses, sync status, recent text, and logs
- Supports two auto-output action modes
  - `Review`: replace text and stay in the field
  - `Send`: replace text and press Return
- Supports a dedicated `/api/control/pc-enter` endpoint
- Keeps the text mirror non-copyable by default to avoid accidental `Command+A` interaction

## How It Works

1. Start the desktop relay on your Mac.
2. Pair the iPhone by scanning the QR code or entering the LAN address manually.
3. Use the iPhone keyboard's voice input to capture text and push it to the focused desktop workflow.

## Repository Structure

- `ios/SayVibe.xcodeproj`
- `ios/SayVibe/`
- `ios/SayVibeWidget/`
- `ios/scripts/`
- `pc_rust/src/`
- `pc_rust/src-tauri/`
- `docs/media/`
- `assets/logo/`

## Quick Start

### Desktop

```bash
cd pc_rust
npm install
npm run tauri:dev
```

Default relay port: `18700`

If the port is already in use:

```bash
cd pc_rust
PORT=18701 npm run tauri:dev
```

Build the desktop app:

```bash
cd pc_rust
npm run tauri:build
```

### iOS

1. Open `ios/SayVibe.xcodeproj` with full Xcode.
2. Select your own Apple Team in `Signing & Capabilities`.
3. Run on an iPhone.
4. Pair with the desktop app via QR or LAN address.

Package an IPA:

```bash
./ios/scripts/package-iphone.sh
```

Rebuild the app icon from the shared logo:

```bash
./ios/scripts/generate-appicon.sh
```

## Local Relay API

- `GET /health`
- `GET /api/state`
- `GET /events`
- `GET /dashboard`
- `GET /android`
- `POST /api/push_text`
- `POST /api/control/auto-ime`
- `POST /api/control/auto-ime-mode`
- `POST /api/control/pc-enter`

## Permissions and Limits

- The current product shape is local-first and LAN-only.
- There is no cloud account system, TLS layer, or authentication yet.
- macOS auto output requires Accessibility permission.
- For release builds on macOS, the authorized app should be `say vibe.app`.
- IPA export depends on your own Apple signing environment, certificates, and Team.

## Community and Support

If you use `say vibe`, want to follow future updates, or would like to support ongoing development, you can use the channels below:

- The WeChat group QR code is temporary. If it has expired, add the personal WeChat account first and I can invite you into the latest group later.
- Sponsorship is welcome and helps keep development moving consistently.

<table>
  <tr>
    <td width="33%" align="center">
      <img src="docs/media/wechat-group.jpg" width="220" alt="say vibe WeChat group" />
    </td>
    <td width="33%" align="center">
      <img src="docs/media/personal-wechat.jpg" width="220" alt="say vibe personal WeChat" />
    </td>
    <td width="33%" align="center">
      <img src="docs/media/sponsor-wechat-pay.jpg" width="220" alt="say vibe WeChat sponsorship" />
    </td>
  </tr>
  <tr>
    <td align="center"><strong>WeChat Group</strong></td>
    <td align="center"><strong>Personal WeChat</strong></td>
    <td align="center"><strong>Sponsorship</strong></td>
  </tr>
</table>

## Maintainer

- Maintainer: `aqiangai`
- License: `MIT`
