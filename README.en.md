# LHDC A2DP Enabler

A Magisk / KernelSU / APatch module for Android 17 that fixes the case where
**headphones negotiate LHDC, but A2DP audio remains completely silent**.

This module was made by `DeepSeek-V4.1-Flash (writing code)` and `Kimi-K3.1-Pro (writing documentation)`.

> [中文文档](README.md)

## Scope

This module targets devices using a hybrid **AOSP Bluetooth stack + Qualcomm PAL
audio HAL** architecture:

- The AOSP Bluetooth stack does not establish a Qualcomm QTI HIDL session.
- The Qualcomm offload path therefore cannot obtain its encoder configuration and
  may repeatedly log `invalid encoder config` / `write error -22`.
- The module routes A2DP through the AOSP software-encoding path so the system's
  built-in LHDC encoder can be used.

The module **only changes audio-policy routing; it does not supply an LHDC encoder**.
It does not address headphone firmware, vendor encoder licensing, or unrelated
A2DP/LE Audio failures.

### Requirements checked during installation

| Requirement | Purpose |
|---|---|
| Android SDK ≥ 37 | Android 17 or later |
| `awk` is available | Generates the patched policy |
| `audio.bluetooth.default.so` exists | Provides the AOSP Bluetooth audio HAL |
| A compatible audio policy is available | The installer performs a real patcher trial to check A2DP ports and output routes |

If a requirement is not met, installation stops and the root manager's installation
console explains the exact reason.

`/apex/com.android.bt`, busybox, and offload properties are reported as supporting
information. Missing busybox reduces mount-isolation reliability but does not by
itself block installation.

MediaTek platforms, vendor-only Bluetooth audio implementations, and devices without
a system LHDC encoder generally fall outside this module's scope. SoC branding alone
is not decisive; inspect the HAL and actual audio policy.

## Installation and removal

### Installation

1. Download a zip from [Releases](https://github.com/Makuro-Arisaka/android17-lhdc-a2dp-universal/releases),
   or build it yourself as described below.
2. Install it with Magisk / KernelSU / APatch and read the check results in the
   installation console.
3. Reboot so `post-fs-data.sh` can apply the policy before audioserver starts.

You can also install through the KernelSU command line:

```sh
adb push android17-lhdc-a2dp-universal.zip /data/local/tmp/
adb shell su -c 'ksud module install /data/local/tmp/android17-lhdc-a2dp-universal.zip'
```

The installation check is read-only. Script permissions and stale runtime data are
handled only after the check succeeds. `FORCE=1` skips the scope checks, but bypassing
them does not make LHDC available on an incompatible device.

### Removal

Remove the module in your root manager. The uninstall script will:

1. Remove the audio-policy mounts created by this module.
2. Check the original files on their partitions.
3. Clean up module runtime data and backups.

Stock backups are stored in `state/golden/` within the module directory and are also
exported to `/sdcard/lhdc-a2dp-backup/` during normal operation. The original
partition files normally need no restoration because the module never rewrites them.

## Verification and diagnostics

After rebooting, check audioserver's active policy rather than relying only on the
module's enabled status.

### 1. A2DP output and sampling rates

```sh
su -c 'dumpsys media.audio_policy' | grep -A5 '"a2dp output";'
```

The output should contain `a2dp output` and explicit sampling rates, for example:

```text
sampling rates: 44100, 48000, 88200, 96000
```

`[dynamic rates]` indicates an incorrect list separator or XML profile parsing
problem; the A2DP output may then fail to open.

### 2. Bluetooth codec and playback status

```sh
dumpsys bluetooth_manager | grep -i 'Current Codec'
logcat -b all -d | grep -i lhdc
logcat -b all -d | grep -E 'invalid encoder config|write error -22|PAL: Bluetooth: startPlayback'
```

The headphones should negotiate LHDC. If the errors matched by the last command keep
appearing during playback, audio is still using the broken Qualcomm offload path.

### 3. Read-only diagnostics

```sh
su -c 'sh /data/adb/modules/android17-lhdc-a2dp-universal/post-fs-data.sh --dry-run'
```

The report includes the SDK, HAL, policy files, selected targets, mount propagation
modes, and recent logs. Logs are stored in `state/run.log` in the module directory;
timestamps from early boot may not yet be synchronized.

## Configuration

Edit [`lhdc.conf`](lhdc.conf) in the module directory. Changes normally take effect
after the next reboot.

| Setting | Default | Purpose |
|---|---:|---|
| `SKU` | empty | Manually select a `sku_*` name; leave empty for automatic detection |
| `PATCH_ALL` | `1` | Process every candidate when the active SKU cannot be determined |
| `OFFLOAD_FIX` | `1` | Change `persist.bluetooth.a2dp_offload.disabled=true` back to `false` |
| `FORCE` | `0` | Skip scope checks during installation and boot |
| `MIN_SDK` | `37` | Minimum Android SDK |
| `VERBOSE` | `0` | Print additional debugging information |
| `LHDC_DUMPSYS_TIMEOUT` | `20` | Timeout in seconds for each `dumpsys` call; do not set it to `0` |

Target policies are located in this order: previously learned active path → manual
`SKU` → authoritative SKU properties → platform/device hints → sole candidate →
all candidates when `PATCH_ALL=1`.

## Implementation overview

The module does not rewrite `/vendor` or other partitions. It keeps files under the
module's `state/` directory and bind-mounts them:

```text
Stock XML → state/golden/       stock backup
          ├→ state/work/        stock fallback mount layer
          └→ state/patched/     patched mount layer
```

- `customize.sh`: installation checks, permission fixes, and stale runtime-data cleanup.
- `post-fs-data.sh`: policy discovery, backup, patch generation, and mounting.
- `service.sh`: file and audioserver verification, active-policy learning, and backup export.
- `uninstall.sh`: mount removal, original-file checks, and runtime-data cleanup.
- `lib/patch_policy.awk`: A2DP port migration and completion of LHDC,
  `a2dp output`, and route declarations.

The patcher selects list separators from the XML root's `version`: commas for `1.0`
and spaces for `7.0`/`7.1`. `encodedFormats` always uses spaces. Where busybox is
available, mount layers are made private to reduce the risk of shared-mount
propagation removing the patched layer.

## Development and building

Always package the module with `build.sh`. It checks required files, LF line endings,
shell/awk syntax, zip structure, and file permissions, then produces a SHA-256 file:

```bash
./build.sh
./build.sh --reproducible       # reproducible build for the same commit
./build.sh -o /tmp/module.zip   # choose the output path
./build.sh --allow-dirty        # build with working-tree changes
```

The installation checks can be regression-tested on a development machine using a
simulated device environment:

```bash
bash tests/run-install-check.sh
```

`tests/`, build scripts, and CI files are excluded from the module package. To publish
a new version, increment `version` / `versionCode` in [`module.prop`](module.prop),
commit the change, and push a `v*` tag. GitHub Actions then builds the Release.

## License

[GNU General Public License v3.0](LICENSE)
