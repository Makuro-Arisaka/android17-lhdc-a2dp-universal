# LHDC A2DP Enabler (Android 17 universal)

A Magisk / KernelSU / APatch module that makes **Android 17's native LHDC** actually produce sound.

For devices in this situation: **LHDC negotiates successfully (`Current Codec: LHDCv5`) but there is no audio at all**.

This module was made by `DeepSeekV4.1Flash`.

> 中文版 / Chinese version: [README.md](README.md)

---

## What problem it solves

Android 17's AOSP Bluetooth stack ships an LHDC v5 software encoder (`lhdcv5BT_enc`). But many Qualcomm devices use a **hybrid architecture**:

| Component | Implementation |
|---|---|
| Bluetooth stack | AOSP (APEX `com.android.bt`) |
| Audio HAL | Qualcomm PAL (`btaudio_offload_if.so` + QTI HIDL session) |

A2DP has only two mutually exclusive paths:

- **(a) QCOM offload**: the PAL drives the vendor BT HAL. This requires the Bluetooth stack to open a QTI HIDL session — which the AOSP stack **never** does, so it never obtains an encoder config, and the log floods with:

  ```
  E PAL: Bluetooth: startPlayback: invalid encoder config
  E PAL: StreamPCM: start: Rx device start failed with status -22
  E AHAL: onWriteError: write error -22 (deep-buffer-playback)
  ```

  The symptom is **continuous silence**, retried roughly every 50 ms.

- **(b) AOSP software encoding**: AudioPolicyManager opens the `a2dp output` of the AOSP Bluetooth audio HAL (`audio.bluetooth.default.so`) and hands PCM to the Bluetooth stack process for encoding.
  **This is the only path that can run LHDC.**

The stock policy declares A2DP ports **only** under the `primary` module (path (a)), so path (b) is unreachable. This module moves the A2DP ports into a separate `bluetooth` module (which maps to `audio.bluetooth.default.so`) and adds `AUDIO_FORMAT_LHDC` to them.

```
<module name="bluetooth" halVersion="2.0">   <- new; loads audio.bluetooth.default.so
    mixPorts    : a2dp output
    devicePorts : BT A2DP Out / Headphones / Speaker  (encodedFormats includes AUDIO_FORMAT_LHDC)
    routes      : the three ports above -> a2dp output
</module>
```

> The module **must** be named `bluetooth`: the HAL looks up `audio.<moduleName>.default.so`,
> and these devices have no `audio.a2dp.default.so`.

---

## How it works

Because `/vendor` is usually physically read-only (forcing a write truncates the file to 0 bytes), this module **does not modify partition contents** — it overlays them at runtime with a bind mount:

```
state/golden/<key>.xml          -- pristine backup (sacred; never a mount source)
        |
        +- copy ------> state/work/<key>.<tag>.xml    --+
        |                                              +--> bind mount -> target file
        +- awk patch -> state/patched/<key>.<tag>.xml --+
```

`<tag>` = `<pid>.<epoch>`, **different on every apply** (see "unique tag" below).

Why **two layers**: the bottom layer mounts the stock file, the top layer mounts the patch. If the top layer ever fails, the system still sees a parseable stock policy rather than an empty file. `work` is just a one-shot copy of `golden` that absorbs the "ghost mounts" produced by mount propagation, keeping `golden` permanently unpolluted.

### ⚠️ Mounts must be made private, and toybox's `mount` cannot do it (key fix in v2.0.2)

The source file lives on `/data`, and **`/data` is a member of a shared peer group**
(`/data`, `/data/user/0`, `/data_mirror/*` are all in one group). Linux mandates:

> A new mount bound from a subtree of a shared mount joins the peer group of the **source** mount.

So the layer we mount at `/vendor/etc/...` also becomes a peer of `/data/user/0` and `/data_mirror/*`. Two consequences, both subtle:

1. During boot, vold's mount/unmount of `/data/user/0` and `/data_mirror/*` **propagates** along the peer group and knocks our layer off → `post-fs-data` logs `RESULT: OK` while the `late_start` check reports `VERIFY BAD`
2. The kernel duplicates a "ghost mount" over the **mount source path** itself, covering the source file; and `umount`ing that ghost propagates along the peer group, **taking the real patch layer down with it**

**Big pitfall here: Android's built-in toybox `mount` does not support propagation options at all.**

```
$ mount --make-private /path
mount: bad /etc/fstab: No such file or directory      <- toybox 0.8.13
$ mount -o make-private /path
mount: bad /etc/fstab: No such file or directory
```

Only **busybox's `mount`** supports them (both `--make-private` and `-o private` work), and Magisk ships `/data/adb/magisk/busybox`. So `lc_make_private()` tries in order:
`$MODDIR/busybox` → `/data/adb/magisk/busybox` → `/data/adb/ksu/bin/busybox` → `/data/adb/ap/bin/busybox`,
and if none is found it **degrades and warns honestly**, never pretending to succeed (v2.0.1 swallowed the error with `2>/dev/null`; the "(private)" line in the log was fake and the layer was actually running naked inside the peer group).

Also, the mount source filename carries a **unique tag on every apply** (`<key>.<pid>.<ts>.xml`), so ghost mounts only ever land on names that are no longer in use — no need to unmount them (which is dangerous), and no risk of a later `cp`/`mv` writing into a covered old path.

Three lines of defence; if any one fails it does not fail silently:

1. **Immediate `lc_make_private()` on every layer** (the actual cure; needs busybox)
2. **Uniquely tagged mount source name** — a ghost mount can never cover the file this run needs
3. `lc_ensure_running()` in `service.sh` — inspects the runtime dump directly;
   **`AUDIO_FORMAT_LHDC` never appears in a stock config**, so if it is missing, `setprop ctl.restart audioserver` reloads

> #3 is the final safety net: as long as audioserver has read the stock config, it will be corrected.

### ⚠️ List separators must follow the ROM (key fix in v2.1.0)

In AOSP's `audio_policy_configuration.xml`, the separator used by list-valued attributes is **not fixed** — it varies by ROM:

| Attribute | Redmi K20 Pro / raphael (Android 17) | Redmi Note 12 Turbo / marble (Android 17) |
|---|---|---|
| `samplingRates` | **comma** `48000,96000` | space `48000 96000` |
| `channelMasks` | **comma** | space |
| `encodedFormats` | space | space |

> **The separator style has nothing to do with the Android version — do not try to infer it from device or version.** Both devices above are **Android 17 / SDK 37**, yet their styles are exactly opposite. It depends on **who wrote that stock XML** (different vendor branch / ROM porting source), so it can only be **detected per device**.
> That is precisely why `detect_sep()` exists.

v2.0.x's `patch_policy.awk` **hardcoded** spaces (copied from marble's style), so after porting to the K20 Pro it produced:

```xml
<!-- generated a2dp output (wrong - this ROM only accepts commas) -->
<profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
         samplingRates="44100 48000 88200 96000"
         channelMasks="AUDIO_CHANNEL_OUT_STEREO"/>
```

**The fatal part is that it reports no error at all.** The parser just quietly degrades that profile to `[dynamic rates]` (empty sample-rate table), and it only blows up far away from the XML:

```
W APM_AudioPolicyManager: openOutputWithProfileAndDevice() missing param
W APM_AudioPolicyManager: checkOutputsForDevice(): No output available for device 0080
I AS.AudioDeviceInventory: APM failed to make available A2DP device addr=… error=1
```

→ the A2DP output can never be created → no profile available → **the A2DP device is permanently unavailable → Bluetooth is completely silent**.

And the module's own LHDC check **stays green** — because `encodedFormats` is correct and only `samplingRates` broke, so nothing looks wrong in the logs. This bug stayed hidden all the way up to "put the headphones on, no sound".

**The fix (two layers)**:

1. `detect_sep()` in `patch_policy.awk` first **probes the separator style of the stock file** and then generates accordingly
   (if detection fails it falls back to the AOSP canonical values: comma for `samplingRates`/`channelMasks`, space for `encodedFormats`).
   Every patch leaves one line on stderr so you can confirm what it learned:

   ```
   INFO: separator samplingRates=[,] encodedFormats=[ ]
   ```

2. `lc_check_a2dp_profile()` **reconciles against the runtime dump** in the `service` stage: the `a2dp output` section must contain `sampling rates:`; if it shows `[dynamic rates]` it raises `ERROR`.
   (v2.1.0 had no such self-check, which is why the problem stayed hidden for so long.)

### ⚠️ sku detection must be tiered: the platform name is not the sku name (key fix in v2.1.1)

ROMs with a `sku_*` directory layout (common with Qualcomm PAL) ship several copies of `audio_policy_configuration.xml`, and only one of them is **actually loaded by this device**. Picking the wrong one raises no error — it just silently does nothing.

v2.1.0 decided by **mixing a batch of properties into one string** and doing **substring** matching, so:

```
Redmi Note 12 Turbo / marble, real properties
  ro.boot.product.vendor.sku = ukee      <- this is the sku name
  ro.boot.hardware.sku       = marble    <- device name, not a sku
  ro.board.platform          = taro      <- platform name! collides with sku_taro
```

The blob contained both `taro` and `ukee` → **two targets selected at once: `sku_taro` and `sku_ukee`** (one of them pure collateral). A platform name will eventually collide with some other sku directory name, so v2.1.1 splits the hints into two tiers:

| Tier | Properties | Matching | Accepted when |
|---|---|---|---|
| **Authoritative** | `ro.boot.product.vendor.sku` → `ro.boot.sku` → `ro.vendor.sku` → `ro.vendor.build.sku` → `ro.boot.hardware.sku` → `ro.boot.product.hardware.sku` | split on `_`/whitespace, then **whole-word** equality (`ukee_cdp` also matches `ukee`) | **exactly 1 hit**; several hits fall through to the next property |
| **Weak hints** | `ro.board.platform` / `ro.hardware` / `ro.soc.model` / `ro.boot.device` / `ro.product.device` / `ro.boot.hardware` | whole-word first, substring only as fallback | used only when the authoritative tier yields nothing |

If the authoritative tier yields nothing and the weak hints give nothing either, it still falls back to **patching everything** under `PATCH_ALL=1`
(adding a `bluetooth` module to a non-active sku is harmless and safer than betting on the wrong one).

The hit is written to the log: `INFO: sku 由 ro.boot.product.vendor.sku=ukee 判定 → sku_ukee`

> Also fixed a subtle bug that **only struck with `VERBOSE=1`**: `lc_log()`'s verbose echo used to go to stdout, while functions like `lc_pick_targets()` capture return values from stdout via `$(...)` — so log lines were mistaken for "target paths" and mixed into `$targets`, leading to mounts of nonexistent paths. Now it echoes to **stderr**.
> The lesson is the same as the separator one: **a channel that carries both results and logs will bite you eventually.**

### Automatic flow

`post-fs-data` (before audioserver):

1. **Pre-check** — SDK ≥ 37 and `audio.bluetooth.default.so` present, otherwise skip (no forcing)
2. **Correct the property** — if `persist.bluetooth.a2dp_offload.disabled` is `true`, set it back to `false`
   (**when true, A2DP is completely silent**)
3. **Locate the target** — see below
4. **Back up the stock file** — only accepts "unpatched" content; if the visible content is already patched, it reads the partition's original file directly
   (`mount --bind` copies a single filesystem without submounts, so the real uncovered file can still be read)
5. **Patch** — `lib/patch_policy.awk` (POSIX awk; Android's toybox awk suffices).
   Before writing list attributes it **probes the stock file's separator style** and writes accordingly (see previous section)
6. **Two-layer mount**, each layer followed immediately by `--make-private`, then remove the ghost mount on the source path

`service` (late_start):

- Verify the overlay; redo it once if not in effect
- **Runtime verification** — if `dumpsys media.audio_policy` contains no `AUDIO_FORMAT_LHDC`, audioserver still loaded the stock config, so `setprop ctl.restart audioserver` makes it reload
- **Sample-rate parsing self-check** — confirm that the `a2dp output` profile really parsed `sampling rates:`
  (rather than `[dynamic rates]`). This one specifically catches **silent failures** like a wrong separator style
- **Reverse-look up which policy file the running audioserver actually loaded**, store it in `state/active.path`, and hit it directly on next boot
- Export the stock backup to `/sdcard/lhdc-a2dp-backup/`

### Target resolution order

1. `state/active.path` (the active file reverse-looked-up on last boot)
2. Config item `SKU=<name>` to force it
3. **Authoritative sku properties**, tried one by one in priority order, accepted on **exactly one** hit:
   `ro.boot.product.vendor.sku` → `ro.boot.sku` → `ro.vendor.sku` → `ro.vendor.build.sku`
   → `ro.boot.hardware.sku` → `ro.boot.product.hardware.sku` (whole-word match, see previous section)
4. **Weak hints** (platform name / SoC name / device name), whole-word first, substring as fallback
5. Only one candidate → use it
6. Several and undecidable → **patch all** (`PATCH_ALL=1`). Patching the ones that are not loaded has no side effect, so this is a safe fallback

---

## Requirements

| # | Condition | How to check | If not met |
|---|---|---|---|
| 1 | Android 17+ (SDK 37) | `getprop ro.build.version.sdk` | No LHDC encoder exists; this module cannot help (set `MIN_SDK` / `FORCE=1` to force) |
| 2 | AOSP Bluetooth stack + Qualcomm PAL hybrid | `ls /apex/com.android.bt` | A pure-Qualcomm-stack device's offload already works; it does not need this module |
| 3 | `audio.bluetooth.default.so` exists | `ls /vendor/lib64/hw/audio.bluetooth.default.so` | The new module fails to load → auto-skip (can force with `FORCE=1`) |
| 4 | The policy file has ports like `BT A2DP Out` | `grep 'BT A2DP' <policy file>` | awk reports `no A2DP devicePort found` and skips |

**Not applicable**: devices that lack the encoder itself (`lhdc_codec_support=FALSE`, or Android < 17).
**This module only routes audio to the correct HAL path; it does not provide an encoder.**

### Does it work on MTK / MediaTek?

Basically no — but the criterion is items 2 and 3 above, **not "which vendor made the SoC"**:

- MTK devices use MediaTek's own audio HAL; there is **no Qualcomm PAL**, and no `btaudio_offload_if.so` / QTI HIDL session. The broken link this module fixes (AOSP stack not opening a QTI session → no encoder config) **simply does not exist on MTK**
- So there is no need to move A2DP ports into a `bluetooth` module either: what Qualcomm platforms lack is the software encoding path, whereas MTK's A2DP goes through its own HAL — moving it could actually kill the sound
- A few MTK devices do carry `audio.bluetooth.default.so` (the generic AOSP Bluetooth audio HAL, usually packaged for LE Audio / hearing aids), but that **does not mean** their A2DP goes through it

"LHDC negotiated but silent" on MTK usually has different causes: the vendor never enabled LHDC on that model, a Bluetooth firmware/middleware version mismatch, or MTK's own offload configuration — none of which this module can fix. Look for a ROM- or kernel-side solution for that specific model.

> If unsure, run `--dry-run`: it only reports, never changes anything. The SDK, HAL, and candidate-policy sections are enough to settle it.

No root-side barrier: Magisk / KernelSU / APatch all work (only `post-fs-data.sh` + `service.sh` are used;
**no `system/` directory overlay** — KernelSU does not support that natively).

---

## Configuration

Edit `lhdc.conf` in the module directory; takes effect on next boot:

| Key | Default | Meaning |
|---|---|---|
| `SKU` | empty | Force a sku directory name (`ukee` / `taro` / `kalama` …); empty = auto-detect |
| `PATCH_ALL` | `1` | Whether to patch all candidates when the active sku cannot be determined |
| `OFFLOAD_FIX` | `1` | Whether to correct `a2dp_offload.disabled` (**recommended: keep 1**) |
| `FORCE` | `0` | Skip pre-checks; do not enable unless necessary |
| `MIN_SDK` | `37` | Skip outright below this SDK |
| `VERBOSE` | `0` | Extra output to stdout |
| `LHDC_DUMPSYS_TIMEOUT` | `20` | Per-call `dumpsys` timeout (seconds). Lower it if the device is dragged to high load by **other** faults; do not set 0 |

---

## Diagnostics

```sh
# Report only - changes nothing
su -c 'sh /data/adb/modules/android17-lhdc-a2dp-universal/post-fs-data.sh --dry-run'
```

The output covers: SDK, whether the HAL is in place, whether awk is usable, the offload property, all candidate policy files and their state, the selected target, the stock files backed up in state, **per-layer mount state (with propagation mode and mount source)**, the propagation mode of the source-side parent mount, whether a private-capable tool is available, **runtime state (whether audioserver really loaded the patched policy)**, and recent logs.

```
=== android17-lhdc-a2dp-universal 诊断 ===
SDK            : 37  (MIN_SDK=37, FORCE=0)
AOSP BT HAL    : yes
awk            : awk
offload 属性   : supported=true disabled=
--- 候选策略文件 ---
  vendor_etc  [31761 B]  已补丁
--- 选中的目标 ---
  /vendor/etc/audio_policy_configuration.xml
--- state 目录 ---
  vendor_etc.md5  (33 B)
  vendor_etc.xml  (30734 B)
--- 当前挂载层（[传播模式] 挂载点 ← 源） ---
  [private] /vendor/etc/audio_policy_configuration.xml
                  ← /vendor/etc/audio_policy_configuration.xml   ← 应为 [private] ×2
  [private] /vendor/etc/audio_policy_configuration.xml
--- 源侧传播模式（shared 是危险信号） ---
  /vendor/etc/audio_policy_configuration.xml  ← 父挂载 shared
--- 传播隔离能力 ---
  private 工具: /data/adb/magisk/busybox （busybox，支持 --make-private）
--- 运行态（audioserver 是否真的加载了补丁策略） ---
  OK — 运行中的策略含 AUDIO_FORMAT_LHDC
```

> The output above is verbatim from a real device (the script prints Chinese), so you can match it line by line on your own device.

**How to read this report:**

| Line | Expected | Meaning |
|---|---|---|
| `AOSP BT HAL` | `yes` | Without it there is no software encoding path |
| `当前挂载层` (current mount layers) | both layers `[private]` | `[shared]` means the layer is not isolated and can be knocked off by `/data` mount events at any time |
| `源侧传播模式` (source-side mode) | `shared` (**normal**) | This is the **parent mount** (`/vendor`), and explains **why** we must go private |
| `传播隔离能力` (isolation capability) | busybox present | toybox's `mount` lacks `--make-private`; without busybox the layer cannot be locked down |
| `运行态` (runtime state) | `OK` | A stock config never contains `AUDIO_FORMAT_LHDC`; its presence proves audioserver read the patched version |

> The "source-side mode" and "current mount layers" lines are not contradictory: the former is about the parent mount (`/vendor`, permanently shared — you cannot and should not change it), the latter about **the layer we mount ourselves** (which must be private).

Log file: `/data/adb/modules/android17-lhdc-a2dp-universal/state/run.log`
(note: early-boot timestamps read `1970-…` because the RTC is not yet synced — judge ordering by line sequence, not timestamps)

---

## Verifying that it works

```sh
# 0. The most important one: does the running policy contain LHDC?
#    A stock config never contains AUDIO_FORMAT_LHDC; its presence means audioserver loaded the patched version
su -c 'dumpsys media.audio_policy | grep -c AUDIO_FORMAT_LHDC'
#    expect >= 1 (once per A2DP port, plus profile copies)

# 0b. Equally important and more subtle: did the a2dp output sample rates really parse?
#     With the wrong separator style this degrades to [dynamic rates] while the check above stays green
su -c 'dumpsys media.audio_policy' | grep -A5 '"a2dp output";'
#    expect "sampling rates: 44100, 48000, 88200, 96000"
#    "[dynamic rates]" instead -> A2DP output cannot open, Bluetooth silent (see "separators must follow the ROM")

# 1. Audio HW modules: primary should no longer hold A2DP ports; they belong to bluetooth
su -c 'dumpsys media.audio_policy | grep "Handle: "'

# 2. The target file should contain the bluetooth module + LHDC
su -c 'grep -c "module name=\"bluetooth\"" /vendor/etc/audio/sku_*/audio_policy_configuration.xml'

# 3. Our layer must be private (shared means it can still be knocked down by /data events)
su -c 'grep audio_policy_configuration /proc/self/mountinfo'

# 4. Headset negotiation result
dumpsys bluetooth_manager | grep -i "Current Codec"      # expect LHDCv5

# 5. While playing: confirm the encoder runs and there are no fault logs
logcat -b all -d | grep -i lhdcv5
logcat -b all -d | grep -cE "invalid encoder config|write error -22|PAL: Bluetooth: startPlayback"
#    expect 0
```

> ⚠️ That `PAL: Bluetooth: startPlayback` line **is a genuine fault signal** (the PAL retrying a stream that failed to start), not harmless verbose output. It is the best indicator of "connected but silent".

---

## Porting to another device

The module itself is generic (auto-locates sku, auto-backs-up, auto-patches), but you still need to confirm:

1. **SDK ≥ 37** and **the AOSP Bluetooth stack directory `/apex/com.android.bt` exists**
2. **`audio.bluetooth.default.so` exists** (requirement #3 above)
3. **The architecture is hybrid**: `grep -rl btaudio_offload /vendor/lib64 | head`
   If the device is already pure AOSP, it does not need this module
4. **The stock policy's A2DP ports are not already under `primary`**
   — if they are already in a `bluetooth` module, the module only adds LHDC and does not restructure anything

If the target's sku directory name cannot be matched by properties and there are several candidates, the module patches all of them by default; you can also hardcode `SKU=` in `lhdc.conf`.

### The two things to confirm first on a new device

```sh
# 1. Is there a usable busybox? (determines whether layers can be made private)
ls -l /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox 2>/dev/null
/data/adb/magisk/busybox mount --make-private /some/mountpoint   # no error = usable

# 2. Is the source-side mount shared? (almost always yes - normal, the module handles it)
awk '$5=="/data"{print $0}' /proc/self/mountinfo
#    look for shared:NN at the end - present means a peer group is involved
```

As long as the source file sits on a shared mount, the bound layer joins that peer group.
The module breaks this with an **immediate `lc_make_private()` on each layer (via busybox)**.
Should a device lack busybox entirely, the module degrades: the layers stay in the peer group,
but the **uniquely tagged source filename** guarantees no file is written wrong, and
`lc_ensure_running()` in `service.sh` still restarts audioserver when it reads the wrong config.

---

## Troubleshooting: boot hangs / never finishes (**rule this module out first**)

Symptom: after reboot the device sits on the boot animation for a long time, `getprop sys.boot_completed` **stays empty**, but the shell works and `/proc/uptime` keeps increasing (so **the device is not dead — boot simply never completed**).

**Do this first** — it takes a second and tells you whether this module is at fault:

```sh
adb shell getprop sys.init.updatable_crashing     # empty = normal; 1 = some other service is crashing
adb shell "su -c 'dmesg | grep -c dspservice'"    # on this K20 Pro it crashed every 5 seconds
```

`sys.init.updatable_crashing=1` means **init's "updatable component crashed 4 times before boot_completed" recovery kicked in** (`apexd` will try to roll that APEX back). That has nothing to do with this module — the module only rewrites one `audio_policy_configuration.xml` and cannot make any other native process take a `SIGSYS`.

### Real case (Redmi K20 Pro / raphael, Android 17 ported ROM)

```
[ 9.70] init: Service 'vendor.dspservice' (pid 1331) received SIGSYS     <- killed ~100ms after start
[14.63] init: Service 'vendor.dspservice' (pid 2483) received SIGSYS     <- every 5 seconds, forever
[21.68] init: processing action (sys.boot_completed=1)                   <- the successful one: it won the race
```

- The process takes a `SIGSYS` about 100 ms after exec, **every single time** → classic **seccomp policy mismatch** (old vendor binary + new system)
- **Completely unrelated to this module**: in the same boot, this module's
  `post-fs-data → RESULT: OK` and `late_start → VERIFY OK` were both normal
- **What decides whether boot succeeds is a race**:
  - `boot_completed` finished at **21.7s**; dspservice's 4th crash was at **24s**
    → a **~2.3 second** margin; this round passed by luck
  - If boot is just 2.5 seconds slower than usual, the 4th crash lands before `boot_completed`,
    triggering `updatable_crashing` + `apexd` rollback → **boot hangs permanently, with no auto-restart**

In other words: **this device hangs on any boot that is "a bit slow" at the system level, regardless of this module.** To stop the random hangs you must fix that crashing vendor service (patch/replace its seccomp policy, or mask the service) — do not look for the cause in this module.

### How to recover once it hangs

```sh
# 1) Save the scene first (dmesg is cleared on reboot - critical)
adb shell "su -c 'dmesg > /data/local/tmp/dmesg.log'"

# 2) All normal reboot paths fail - don't waste time on them:
#      adb reboot                    -> hangs (goes through system_server)
#      setprop sys.powerctl reboot   -> blocked by SELinux, and reads back empty
#      /proc/sysrq-trigger           -> sysrq disabled (/proc/sys/kernel/sysrq = 0)
#    Only the binary that calls reboot(2) directly works, and **give it plenty of time (30s+)**:
adb shell "su -c '/system/bin/reboot'"
```

> Forensics pitfall: `setprop sys.powerctl reboot` returns 0 but **the property is never actually written**
> (reading `getprop sys.powerctl` back gives empty). **Do not judge success by the return code — read it back.**
>
> Also: pipelines like `ps -o STAT,NAME | awk | sort | uniq -c` hang together when the system is wedged;
> use the simplest single commands while debugging.

---

## Uninstall

Just remove the module in your root manager. `uninstall.sh` will:

1. Take down the overlay so the real file on the partition becomes visible again
2. Check whether it is intact; **if not**, it temporarily holds things together with the stock backup in `state/golden/`
   and tells you to reflash vendor before rebooting

Where the stock backup lives:
- On device: `/data/adb/modules/android17-lhdc-a2dp-universal/state/golden/`
- Retrievable anytime: `/sdcard/lhdc-a2dp-backup/` (exported automatically after boot)

---

## Directory layout

```
android17-lhdc-a2dp-universal/
├── module.prop            module declaration
├── lhdc.conf              user configuration
├── customize.sh           install time: fix script permissions (KernelSU drops the x bit)
├── post-fs-data.sh        early boot: locate -> back up -> patch -> mount
├── service.sh             after boot: verify / reverse-look-up active policy / export backup
├── uninstall.sh           uninstall: take down mounts + check original file + hold if needed
├── lib/
│   ├── common.sh          shared library (locate, back up, patch, mount)
│   └── patch_policy.awk   XML patcher (POSIX awk)
├── .github/
│   ├── workflows/release.yml   push a v* tag -> auto build + release (**not packaged**)
│   └── RELEASE_TEMPLATE.md     release notes template (**not packaged**)
├── build.sh               packaging script (**for developers, not packaged**)
├── README.md              documentation (Chinese)
├── README.en.md           documentation (English, **not packaged**)
├── LICENSE                GPL-3.0 full text
└── state/                 generated at runtime: backups and logs (**not packaged**)
```

---

## Building and packaging

```bash
./build.sh                      # -> ../android17-lhdc-a2dp-universal.zip + .sha256
./build.sh --reproducible       # reproducible: same commit yields a byte-identical zip
./build.sh -o /tmp/xx.zip       # custom output path
./build.sh --allow-dirty        # allow building with uncommitted changes
./build.sh -h                   # all options
```

**Do not `zip -r` by hand** — three pitfalls:

| Pitfall | Consequence |
|---|---|
| Including `.git/` and `.gitignore` | Doubles the size and may leak history |
| Including `state/`, `ap.txt`, `dumpsys.txt`, etc. | Unclean package; forensic files may contain your device info |
| Forgetting `chmod 755` | On device, `post-fs-data.sh` has no `+x`, init's exec fails — symptom is **"module installed but nothing happens"**, with not a single log line |

What `build.sh` does:

- **The file list comes from `git ls-files`** — only what should be packaged gets packaged, no hand-written blacklist
  (outside a git repo it falls back to `find` + blacklist mode)
- **Refuses to build with a dirty worktree** (uncommitted/untracked changes would make the artifact diverge from the repo state);
  `--allow-dirty` overrides this and explicitly warns that "untracked files starting with `??` will not be packaged"
- **Static checks**: required files present, line endings must be LF (CRLF rejected outright), no BOM,
  `busybox ash -n` syntax check (close to the device-side shell), `*.sh` syntax, awk script syntax
- **Post-build self-check**: `module.prop` must be at the zip **root** (an extra nesting level makes it uninstallable),
  no `.git` / `state/` mixed in, in-zip permission bits must be 755 for scripts / 644 for data
- Also emits `.sha256` so you can verify that "the package on the device == this commit"

Installing the package:

```bash
adb push ../android17-lhdc-a2dp-universal.zip /data/local/tmp/
adb shell su -c 'ksud module install /data/local/tmp/android17-lhdc-a2dp-universal.zip'   # KernelSU
# Magisk: choose "Install from storage" and pick the zip
```

KernelSU puts it into `modules_update/` first; **it only becomes active after a reboot**. This project also keeps a copy on `/sdcard/` by convention.

### Downloading prebuilt packages (Releases)

If you would rather not build it yourself, grab the assets from [Releases](/Makuro-Arisaka/android17-lhdc-a2dp-universal/releases):

| Asset | Description |
|---|---|
| `android17-lhdc-a2dp-universal.zip` | The module package — install directly |
| `android17-lhdc-a2dp-universal.zip.sha256` | Checksum |

These are built by GitHub Actions running `./build.sh --reproducible` on the corresponding commit, **not hand-uploaded binaries**:
timestamps come from the commit time, so the same commit produces byte-identical output on any machine — you can

```bash
git checkout v2.1.1 && ./build.sh --reproducible
```

reproduce the same sha256 yourself, to confirm the asset really came from that commit's source.

---

## License

**GNU General Public License v3.0** (full text in [LICENSE](LICENSE)).

> At runtime this module overlays system configuration with a bind mount and **never rewrites the original files on any partition**; the device returns to its original state after uninstalling. The license covers the code and documentation in this repository.
