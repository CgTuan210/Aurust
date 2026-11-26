<h1 align="center">Aurust</h1>

<p align="center">A performance-focused fork of the Liquid Glass Spotify tweak for iOS — built for silky-smooth animations and low CPU usage even on older or throttled devices.</p>

<p align="center">
  <img src="https://img.shields.io/badge/Spotify-9.1.90-1ED760?style=for-the-badge&logo=spotify&logoColor=white" alt="Spotify 9.1.90">
  <img src="https://img.shields.io/badge/iOS-16.1%2B%20%7C%2026%2B%20Glass-000000?style=for-the-badge&logo=apple&logoColor=white" alt="iOS 16.1+ / 26+">
  <img src="https://img.shields.io/badge/Objective--C%20%2F%20Logos-3A95E3?style=for-the-badge&logo=apple&logoColor=white" alt="Objective-C / Logos">
  <img src="https://img.shields.io/badge/Codemagic-Build%20IPA-2671E5?style=for-the-badge&logo=codemagic&logoColor=white" alt="Codemagic">
</p>

<p align="center">
  <img src="docs/screenshots/now-playing.webp" width="16%" alt="Full screen player with lyrics">
  <img src="docs/screenshots/album.webp" width="16%" alt="Album">
  <img src="docs/screenshots/playlist.webp" width="16%" alt="Playlist">
  <img src="docs/screenshots/queue.webp" width="16%" alt="Queue">
  <img src="docs/screenshots/live-activity.webp" width="16%" alt="Live Activity on the lock screen">
</p>

---

## Overview

**Aurust** is a fork of the open-source Liquid Glass Spotify tweak (Theos + Logos), injected into your own decrypted Spotify IPA and signed with your own certificate — no jailbreak required.

### What Aurust focuses on

- **Low-CPU Lock Screen Lyrics & Live Activity**: adaptive timeline scheduling tuned for minimal background CPU while staying responsive on fast / rap lyrics.
- **Zero-compromise GPU rendering (Smooth Mode)**: off-main-thread SIMD blur baking for lyrics, rasterized radial/conic shaders, LUT-based palette extraction, and single-pass pre-composited Fill blur (eliminating nested offscreen `CALayer.mask` passes).
- **Smooth UI motion under CPU throttling**: cached Home compositional layouts, deduplicated gradient animations, event-driven Now Playing & Mixing timers (0 Hz when idle), pure CoreAnimation GPU wordmark in Mod Settings, and Flow/Fluid backgrounds that keep gliding smoothly even in Low Power Mode.

---

## Compatibility

Built and verified on **Spotify `9.1.90`** — use a clean decrypted **`9.1.90`** IPA. Spotify's internal Swift classes and view hierarchies change between updates, and the **Downloads** engine only activates on `9.1.90`.

| Feature | Requirement |
| --- | --- |
| Target Spotify IPA | **9.1.90** (decrypted) |
| Redesigned UI (Liquid Glass) | **iOS 26+** |
| Native UI (tweaked stock screens) | **iOS 16.1+** |
| Live Activity | **iOS 17+** |

Below iOS 26, the **Redesigned UI** switch is unavailable and the mod automatically runs in **Native UI** mode with all shared features active. Both are configured in **Settings → Mod Settings**.

---

## Build

You provide a clean decrypted **Spotify `9.1.90`** `.ipa`; the pipeline compiles the tweak and outputs an unsigned `out/Aurust-<version>-unsigned.ipa` with the default **Spotify** app name and **Bundle ID** (`com.spotify.client`).

### 1. Build with Codemagic (Recommended — no Mac needed)

This repo includes [codemagic.yaml](codemagic.yaml) ready for macOS M2 builds:

1. Connect this repository in Codemagic.
2. Click **Start new build** on branch `stable`.
3. Select workflow **`Build Unsigned IPA (Aurust)`**.
4. Leave `ipa_url` at its default (or paste a direct download link to your own decrypted Spotify `9.1.90` IPA — Catbox, GitHub Release, R2, or Dropbox `?dl=1`).
5. Download the resulting `Aurust-<version>-unsigned.ipa` from **Artifacts**.

> Need only the tweak package? Run the **`Build Tweak Only (.deb)`** workflow instead.

### 2. Build with GitHub Actions

Enable Actions on the repository and trigger **Build IPA from your own Spotify IPA** with a direct link to your decrypted Spotify `9.1.90` `.ipa`.

### 3. Build locally on a Mac

Requires Theos in `~/theos`, Xcode with an iPhoneOS 26+ SDK, and CLI tools:

```bash
brew install make ldid dpkg zsign ideviceinstaller libimobiledevice
uv tool install "cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw"
```

Drop your decrypted Spotify `9.1.90` `.ipa` into `ipa/`, then run:

```bash
make release    # outputs unsigned IPA into out/
make install    # signs using .signing.env and pushes over USB
```

---

## Signing & Installation

Sign the unsigned IPA with **SideStore**, **AltStore**, **Feather**, **Sideloadly**, or **ESign**:

- Keep the bundle ID matched to your signing certificate's App ID so tapping the player from the Lock Screen / Live Activity opens Spotify properly.
- In **Feather**, copy your certificate's App ID into **Identifier** and leave **PPQ protection** off. AltStore, SideStore, and Sideloadly handle this automatically.

---

## Credits

- Forked from upstream **Taurus** and **spoti.pw / chroma.pw**.
- Powered by [Theos](https://theos.dev), [cyan](https://github.com/asdfzxcvbn/pyzule-rw), and [FLEX](https://github.com/FLEXTool/FLEX) (for view-tree inspection).
- Not affiliated with Spotify.
