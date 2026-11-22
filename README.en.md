<p align="center">
  <img src="assets/images/app_icon.png" width="112" alt="OronBox">
</p>

<h1 align="center">OronBox</h1>

<p align="center">A pretty fast wearable management tool for VelaOS and ZeppOS, built with Flutter</p>

<p align="center">
  <a href="https://github.com/OronCanopy/OronBox/releases"><img src="https://img.shields.io/github/v/release/OronCanopy/OronBox?display_name=tag&sort=semver&label=release" alt="Latest release"></a>
  <a href="https://github.com/OronCanopy/OronBox/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/OronCanopy/OronBox/ci.yml?label=CI" alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/OronCanopy/OronBox" alt="License"></a>
  <a href="https://github.com/OronCanopy/OronBox/stargazers"><img src="https://img.shields.io/github/stars/OronCanopy/OronBox?style=flat" alt="GitHub stars"></a>
</p>

<p align="center"><a href="README.md">简体中文</a> · English</p>

## Quick links

- [Download the latest release](https://github.com/OronCanopy/OronBox/releases)
- [User documentation](https://oronbox.zxor.org/user)
- [Developer documentation](https://oronbox.zxor.org/developer)
- [Report an issue](https://github.com/OronCanopy/OronBox/issues)

## What is OronBox?

OronBox is a cross-platform wearable device management tool that connects to and manages VelaOS / ZeppOS devices without the official client, installs resources, and synchronizes fitness and weather data.

## Supported platforms

> We recommend using a device with Bluetooth support. If you are using Ubuntu, Ubuntu 24.04 or later is recommended.

| Platform | Status | Notes |
|----------|--------|-------|
| Android | ✅ Supported | Android 7+ |
| Linux | ✅ Supported | x86_64 / aarch64 |
| Web | ✅ Supported | The browser must support Web Serial / Bluetooth |
| macOS | ✅ Supported | macOS 12+ |
| Windows | ✅ Supported | Windows 10+; Xiaomi account 2FA login requires WebView2 |
| iOS | ❌ Not currently supported | No physical device is available for debugging or testing |

## Supported devices

### Xiaomi VelaOS

| Device / family | Status |
|-----------------|--------|
| Xiaomi Smart Band 8 Pro / 9 / 9 Pro / 10 / 10 Pro / 11 | ✅ Supported |
| Xiaomi Watch S1 Pro / S3 series / S4 series / S5 series | ✅ Supported |
| REDMI Watch 4 / 5 / 5 eSIM / 6 | ✅ Supported |

### ZeppOS

| Device / family | Status |
|-----------------|--------|
| Amazfit ZeppOS devices | ✅ Supported |
| Xiaomi Smart Band 7 | ✅ Supported |

## Feature support

| Feature | Description |
|---------|-------------|
| Connect VelaOS and ZeppOS devices | Manage paired devices and their connection state |
| View device status and resource overview | Show battery, storage, apps and watch face information |
| Install device resources | Install watch faces, apps, and resource packs |
| Manage Canopus modules | Install, enable, disable, and uninstall modules |
| Adjust device app order | Change the app order in the device launcher |
| Set the device app layout | Adjust how the device app list is displayed |
| Manage device alarms | Add, edit and delete device alarms |
| Find devices in both directions | Let the wearable ring the phone, or make the wearable ring or vibrate from the phone |
| Check or install device firmware | Download and install full or incremental packages, or install local firmware |
| Automatically check for updates and notify users | Covers device firmware, apps, watch faces, and plugins |
| MiWear engineering mode | Switch device modes and update firmware on devices in engineering mode |
| Schedule background data synchronization | Check every 15 minutes and synchronize every hour |
| Sync notifications to the device | Forward notifications from selected Android apps to the wearable |
| Sync music to the device | Transfer MP3 files to the device music library |
| Sync and export device recordings | Retrieve and save recordings from the device |
| Receive and save watch screenshots | Save screenshots to the user's Pictures directory |
| Sync city weather to the device | Update weather information for the selected city |
| Xiaomi wearable eSIM management | Download, enable, disable, and delete GSMA LPA eSIM profiles |
| XiaoAI voice integration & ASR | Listen to wearable XiaoAI trigger and audio streams with local/cloud ASR |
| Wi-Fi credential synchronization | Respond to watch Wi-Fi scan and auth requests for quick network setup |
| Assisted phone location sync | Stream real-time location fixes from the phone for watches without standalone GPS |
| Sign in to Xiaomi accounts with 2FA | Download GNSS ephemeris data and obtain the device authkey |
| Pair Xiaomi devices | Pair locally or use a Xiaomi account |
| Read authkey from Xiaomi Fitness logs | Parse local Xiaomi Fitness app logs to retrieve the device authkey |
| Sync Xiaomi device GNSS ephemeris | Support watch-initiated ephemeris updates; Xiaomi account required |
| Browse community resources | Browse OronBox, AstroBox-Repo, BandBBS, and the Amazfit app store |
| Sign in to BandBBS with OAuth | Obtain BandBBS community resources |
| Publish resources from the creator center | Publish to BandBBS and AstroBox-Repo |
| Install and run plugins | Install and run OronBox and AstroBox-NG plugins |
| Back up and restore app data | Export and restore device pairing information, settings, and other app data |
| Local API Server | Provide a local HTTP and SSE API server for external tools, featuring mDNS broadcast and Ed25519 challenge authentication |

## CLI Tool

OronBox provides an official standalone cross-platform command-line client, [OronBox-CLI](https://github.com/OronCanopy/OronBox-CLI)
Once **Local API Server** is enabled in the OronBox client under **Settings** -> **Advanced** -> **Local API Server**, you can manage wearable devices, install apps and watch faces, and pull diagnostic logs directly from your computer terminal over the local network:

```bash
# Install globally (recommended)
npm install -g oronbox-cli

# Automatically discover and pair
oronbox-cli pair

# Or run directly without installing
npx oronbox-cli pair
```

For more details, see the [OronBox-CLI repository](https://github.com/OronCanopy/OronBox-CLI) and its [User Guide](https://github.com/OronCanopy/OronBox-CLI/blob/main/GUIDE.en.md) and [API Specification](https://github.com/OronCanopy/OronBox-CLI/blob/main/API.en.md).

## Build from source

### Prerequisites

Install the Flutter version specified in `.fvmrc` with [FVM](https://fvm.app), then fetch the project dependencies.

```sh
fvm flutter pub get --enforce-lockfile
```

- **Linux** — `libsecret-1-dev` `clang` `cmake` `ninja-build` `pkg-config` `zip` `curl` `libgtk-3-dev` `libx11-dev` `libxi-dev` `libblkid-dev` `liblzma-dev` `libasound2-dev` `libwebkit2gtk-4.1-dev` `libbluetooth-dev` `libayatana-appindicator3-dev`
  - For packaging, use `dpkg-deb` (DEB), `rpmbuild` (RPM), `makepkg` (Arch), `linuxdeploy` or `appimagetool` (AppImage), or `flatpak-builder` with the GNOME SDK (Flatpak)
- **Windows** — Visual Studio 2022 (Desktop development with C++). The `webview_all` plugin manages the WebView2 SDK
- **macOS** — Xcode, macOS hosts only
- **Android / Web** — No extra dependencies

### Build everything

```sh
tool/build_all.sh [--dev]
```

Builds Android + Web + the desktop platform of the current host. Artifacts land in `build/release/` along with a generated `sha256sums.txt`.

### Per-platform builds

#### Android

```sh
tool/build_android.sh [--format apk|appbundle|all] [--abi arm64-v8a|armeabi-v7a|x86_64]
```

- Without `--format` / `--abi`, every format / ABI is built
- Android release signing is configured through environment variables: `ORONBOX_KEYSTORE_PATH`, `ORONBOX_KEYSTORE_PASSWORD`, `ORONBOX_KEY_ALIAS`, `ORONBOX_KEY_PASSWORD`; without them the debug signing config is used

#### Linux

```sh
tool/build_linux.sh [--format tar.gz|deb|rpm|arch|appimage|flatpak|all] [--abi x86_64|aarch64]
```

- By default builds all available formats; `--abi` defaults to the host architecture
- To cross-build Linux aarch64 on x86_64, point `ORONBOX_LINUX_ARM64_SYSROOT` to an arm64 sysroot containing the Linux development libraries for the target architecture. Cross-builds can produce `tar.gz`, DEB, RPM, and Arch packages.

#### macOS (macOS hosts only)

```sh
fvm exec tool/build_macos.sh [--format zip|dmg|all] [--abi arm64|x86_64|universal]
```

- Builds both ZIP and DMG by default, with a separate symbol archive
- `--abi` defaults to the host architecture and accepts `aarch64` as an alias for `arm64`

#### Windows

```powershell
powershell -File tool/build_windows.ps1 [-Dev]
```

Or run the batch script in CMD:

```bat
tool\build_windows.bat [--dev]
```

#### Web

```sh
tool/build_web.sh
```

## AI development disclosure

This project was developed with the help of AI agent tools.

## Acknowledgements

OronBox uses or references the following projects:

| Project | Nature of use |
|---------|--------------------|
| [AstralSightStudios/AstroBox-Public](https://github.com/AstralSightStudios/AstroBox-Public) | UI structure and interaction design reference |
| [AstralSightStudios/AstroBox-NG-Module-Core](https://github.com/AstralSightStudios/AstroBox-NG-Module-Core) | Xiaomi device protocol and transport layer, ported and modified |
| [AstralSightStudios/AstroBox-NG-Module-Pb](https://github.com/AstralSightStudios/AstroBox-NG-Module-Pb) | Xiaomi wear protocol definitions, adopted verbatim |
| [AstralSightStudios/AstroBox-NG-Module-Bluetooth](https://github.com/AstralSightStudios/AstroBox-NG-Module-Bluetooth) | Bluetooth connection flow reference |
| [AstralSightStudios/AstroBox-NG-Module-Account](https://github.com/AstralSightStudios/AstroBox-NG-Module-Account) | Xiaomi account login and authkey retrieval flow reference |
| [AstralSightStudios/AstroBox-NG-Module-Provider](https://github.com/AstralSightStudios/AstroBox-NG-Module-Provider) | Community resource index and manifest parsing flow reference |
| [AstralSightStudios/AstroBox-NG-Module-AppWasm](https://github.com/AstralSightStudios/AstroBox-NG-Module-AppWasm) | Web Serial connection flow reference |
| [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) | ZeppOS protocol implementation, ported and modified |
| [Kazumi](https://github.com/Predidit/Kazumi) | Material Design components and UI design |

## License

[GNU Affero General Public License v3.0](LICENSE) · [Additional terms](ADDITIONAL-TERMS.md) · [Third-party notices](THIRD-PARTY-NOTICES.md)

## Star History

<a href="https://www.star-history.com/?repos=OronCanopy%2FOronBox&type=date&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=OronCanopy/OronBox&type=date&theme=dark&legend=bottom-right&sealed_token=zjHhbYRQSFR--PiwPij12KvbSLyZpMjCTzHDFKh0Tmg1j9Od44-VRoc2Z_O7YjiNpEWX2n72xgKNaSEpSAXqDiRF709__x-d5YB-JXY2_yqVgDV1FGdGOCwsNkXUFXs37GfZqGiqTnNCKAiIuQh2Njdoxx_yE9I48b4Q6iItHM-O40tXhJhnMJsHn908" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=OronCanopy/OronBox&type=date&legend=bottom-right&sealed_token=zjHhbYRQSFR--PiwPij12KvbSLyZpMjCTzHDFKh0Tmg1j9Od44-VRoc2Z_O7YjiNpEWX2n72xgKNaSEpSAXqDiRF709__x-d5YB-JXY2_yqVgDV1FGdGOCwsNkXUFXs37GfZqGiqTnNCKAiIuQh2Njdoxx_yE9I48b4Q6iItHM-O40tXhJhnMJsHnN908" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=OronCanopy/OronBox&type=date&legend=bottom-right&sealed_token=zjHhbYRQSFR--PiwPij12KvbSLyZpMjCTzHDFKh0Tmg1j9Od44-VRoc2Z_O7YjiNpEWX2n72xgKNaSEpSAXqDiRF709__x-d5YB-JXY2_yqVgDV1FGdGOCwsNkXUFXs37GfZqGiqTnNCKAiIuQh2Njdoxx_yE9I48b4Q6iItHM-O40tXhJhnMJsHnN908" />
 </picture>
</a>
