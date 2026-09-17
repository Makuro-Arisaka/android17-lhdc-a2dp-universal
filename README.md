# LHDC A2DP Enabler (Android 17 universal)

让 **Android 17 的原生 LHDC** 真正出声的 Magisk / KernelSU / APatch 模块。

面向这一类设备：**LHDC 协商成功（`Current Codec: LHDCv5`）但完全没声音**。

本模块由`DeepSeekV4.1Flash`制作。

---

## 它解决什么问题

安卓 17 的 AOSP 蓝牙栈内置了 LHDC v5 软件编码器（`lhdcv5BT_enc`）。但很多高通机型是
**混合架构**：

| 组件 | 实现 |
|---|---|
| 蓝牙协议栈 | AOSP（APEX `com.android.bt`） |
| 音频 HAL | 高通 PAL（`btaudio_offload_if.so` + QTI HIDL session） |

A2DP 只有两条互斥通路：

- **(a) QCOM offload**：PAL 驱动厂商 BT HAL。需要蓝牙栈去开 QTI HIDL session —— AOSP 栈
  **永远不会**这么做，于是永远拿不到 encoder config，日志刷：

  ```
  E PAL: Bluetooth: startPlayback: invalid encoder config
  E PAL: StreamPCM: start: Rx device start failed with status -22
  E AHAL: onWriteError: write error -22 (deep-buffer-playback)
  ```

  表现就是**持续静音**，并每约 50ms 重试一次。

- **(b) AOSP 软件编码**：AudioPolicyManager 打开 AOSP 蓝牙音频 HAL
  （`audio.bluetooth.default.so`）的 `a2dp output`，PCM 交给蓝牙栈进程内编码。
  **只有这条通路能跑 LHDC。**

原厂策略把 A2DP 端口**只**声明在 `primary` module 下（即通路 (a)），通路 (b) 根本不可达。
本模块把 A2DP 端口搬进一个独立的 `bluetooth` module（映射到 `audio.bluetooth.default.so`），
并给它们补上 `AUDIO_FORMAT_LHDC`。

```
<module name="bluetooth" halVersion="2.0">   ← 新增，加载 audio.bluetooth.default.so
    mixPorts    : a2dp output
    devicePorts : BT A2DP Out / Headphones / Speaker  (encodedFormats 含 AUDIO_FORMAT_LHDC)
    routes      : 上述三个端口 → a2dp output
</module>
```

> module **必须**叫 `bluetooth`：HAL 按 `audio.<moduleName>.default.so` 查找，
> 而这些机器上没有 `audio.a2dp.default.so`。

---

## 工作原理

因为 `/vendor` 通常是物理只读（强写会把文件截断成 0 字节），本模块**不改分区内容**，
而是运行时用 bind mount 覆盖：

```
state/golden/<key>.xml          ── 原厂备份（神圣，永不作挂载源）
        │
        ├─ 复制 ─→ state/work/<key>.<tag>.xml    ─┐
        │                                        ├─→ bind mount → 目标文件
        └─ awk 打补丁 ──→ state/patched/<key>.<tag>.xml ┘
```

`<tag>` = `<pid>.<epoch>`，**每次 apply 都不同**（见下文「唯一 tag」一节）。

**双层挂载**的意义：底层挂原厂，顶层挂补丁。顶层万一失败，系统看到的仍是可解析的原厂策略，
而不是一个空文件。`work` 只是 `golden` 的一次性副本，用来吸收 mount 传播产生的"幽灵挂载"，
保证 `golden` 永不被污染。

### ⚠️ 挂载必须置 private，而 toybox 的 mount 做不到（v2.0.2 的关键修复）

源文件在 `/data` 上，而 **`/data` 是 shared peer group 成员**
（`/data`、`/data/user/0`、`/data_mirror/*` 共处一组）。Linux 规定：

> 从 shared 挂载的子树 bind 出来的新挂载，会加入**源挂载**的 peer group。

于是我们挂在 `/vendor/etc/...` 上的这层，也变成了 `/data/user/0`、`/data_mirror/*` 的 peer。
后果有两个，都很隐蔽：

1. 开机途中 vold 对 `/data/user/0`、`/data_mirror/*` 的挂载/卸载会沿 peer group **传播过来**，
   把我们的层顶掉 → `post-fs-data` 日志显示 `RESULT: OK`，`late_start` 校验却是 `VERIFY BAD`
2. kernel 会在**挂载源路径**上复制出一份"幽灵挂载"盖住源文件自己；
   而 `umount` 那个幽灵会沿 peer group 传播，**把真正的补丁层一起卸掉**

**这里有个大坑：Android 自带的 toybox `mount` 根本不支持传播选项。**

```
$ mount --make-private /path
mount: bad /etc/fstab: No such file or directory      ← toybox 0.8.13
$ mount -o make-private /path
mount: bad /etc/fstab: No such file or directory
```

只有 **busybox 的 `mount`** 支持（`--make-private` 与 `-o private` 都行），Magisk 自带
`/data/adb/magisk/busybox`。所以 `lc_make_private()` 会依次找
`$MODDIR/busybox` → `/data/adb/magisk/busybox` → `/data/adb/ksu/bin/busybox` → `/data/adb/ap/bin/busybox`
，找不到就**降级并如实告警**，绝不假装成功（v2.0.1 就是 `2>/dev/null` 吞掉了错误，
日志里那句"（private）"是假的，层其实一直裸奔在 peer group 里）。

另外，挂载源文件名**每次 apply 都带唯一 tag**（`<key>.<pid>.<ts>.xml`），
这样幽灵挂载只会落在本次已不再使用的名字上 —— 既不用去卸它（卸它很危险），
也不会让下次的 `cp`/`mv` 写进被盖住的旧路径。

三道防线，任一层失效都不会静默：

1. **每层 immediate `lc_make_private()`**（治本，需 busybox）
2. **唯一 tag 的挂载源名** —— 幽灵挂载永远不会盖住本次要用的文件
3. `service.sh` 里的 `lc_ensure_running()` —— 直接查运行态转储，
   **原厂配置里绝不会出现 `AUDIO_FORMAT_LHDC`**；没出现就 `setprop ctl.restart audioserver` 重载

> 第 3 条是最后的安全网：只要 audioserver 读到的是原厂配置，它一定会被纠正过来。

### ⚠️ 列表分隔符必须跟随 ROM（v2.1.0 的关键修复）

AOSP 的 `audio_policy_configuration.xml` 里，列表型属性用哪种分隔符**不是固定的**，随 ROM 而变：

| 属性 | Redmi K20 Pro / raphael（Android 17） | Redmi Note 12 Turbo / marble（Android 17） |
|---|---|---|
| `samplingRates` | **逗号** `48000,96000` | 空格 `48000 96000` |
| `channelMasks` | **逗号** | 空格 |
| `encodedFormats` | 空格 | 空格 |

> **分隔符风格跟 Android 版本没关系，别想按机型/版本推断** —— 上表两台**都是
> Android 17 / SDK 37**，风格却完全相反。它取决于**那份原厂 XML 是谁写的**
> （vendor 分支 / ROM 移植来源不同），所以只能**逐台探测**。
> 这正是 `detect_sep()` 存在的理由。

v2.0.x 的 `patch_policy.awk` 把空格**写死了**（照搬 marble 的写法），于是移植到 K20 Pro 之后：

```xml
<!-- 生成的 a2dp output（错——该 ROM 只认逗号） -->
<profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
         samplingRates="44100 48000 88200 96000"
         channelMasks="AUDIO_CHANNEL_OUT_STEREO"/>
```

**致命之处是它完全不报错。** 解析器只是把该 profile 悄悄降级成 `[dynamic rates]`
（采样率表为空），然后在离 XML 十万八千里的地方才爆发：

```
W APM_AudioPolicyManager: openOutputWithProfileAndDevice() missing param
W APM_AudioPolicyManager: checkOutputsForDevice(): No output available for device 0080
I AS.AudioDeviceInventory: APM failed to make available A2DP device addr=… error=1
```

→ A2DP 输出永远建不起来 → 无 profile 可用 → **A2DP 设备永远不可用 → 蓝牙彻底无声**。

而且模块自己的 LHDC 检查**照样全绿**——因为 `encodedFormats` 是对的，崩的只有
`samplingRates`，所以从日志上完全看不出异常。这个坑一路藏到"戴上耳机没声音"才被发现。

**修法（两道）**：

1. `patch_policy.awk` 里的 `detect_sep()` 先**探测原厂文件的分隔符风格**再照着生成
   （探测不到则退回 AOSP 规范值：`samplingRates`/`channelMasks` 逗号、`encodedFormats` 空格）。
   每次 patch 会在 stderr 留一行，可据此确认它学到了什么：

   ```
   INFO: separator samplingRates=[,] encodedFormats=[ ]
   ```

2. `lc_check_a2dp_profile()` 在 `service` 阶段**对账运行态转储**：`a2dp output` 段里
   必须出现 `sampling rates:`；若出现 `[dynamic rates]` 就报 `ERROR`。
   （v2.1.0 之前没有这道自检，才让问题藏了那么久。）

### ⚠️ sku 判定必须分档：平台名不是 sku 名（v2.1.1 的关键修复）

有 `sku_*` 目录布局的 ROM（高通 PAL 常见）会同时摆好几份 `audio_policy_configuration.xml`，
只有一份是**当前设备真正在加载**的。选错不会报错，只会静默无效。

v2.1.0 的判定方式是把一批属性**混成一个字符串**再做**子串**匹配，于是：

```
Redmi Note 12 Turbo / marble 真实属性
  ro.boot.product.vendor.sku = ukee      ← 这才是 sku 名
  ro.boot.hardware.sku       = marble    ← 设备名，不是 sku
  ro.board.platform          = taro      ← 平台名！和 sku_taro 撞名了
```

blob 里同时含 `taro` 和 `ukee` → **一次选中 `sku_taro` 和 `sku_ukee` 两个目标**
（其中一个纯属误伤）。平台名迟早会撞上别的 sku 目录名，所以 v2.1.1 把线索拆成两档：

| 档 | 属性 | 匹配方式 | 采纳条件 |
|---|---|---|---|
| **权威** | `ro.boot.product.vendor.sku` → `ro.boot.sku` → `ro.vendor.sku` → `ro.vendor.build.sku` → `ro.boot.hardware.sku` → `ro.boot.product.hardware.sku` | 按 `_`/空白切词后**整词**相等（`ukee_cdp` 也命中 `ukee`） | **恰好命中 1 个**才采纳；命中多个就顺延下一条属性 |
| **弱线索** | `ro.board.platform` / `ro.hardware` / `ro.soc.model` / `ro.boot.device` / `ro.product.device` / `ro.boot.hardware` | 先整词，无果才退化子串 | 权威档全灭时才用 |

权威档全灭、弱线索也无线索时，仍落到 `PATCH_ALL=1` 的**全处理**兜底
（给非活跃 sku 补一个 `bluetooth` module 无害，比赌错一个安全）。

命中结果会写进日志：`INFO: sku 由 ro.boot.product.vendor.sku=ukee 判定 → sku_ukee`

> 另外修了一个**只在 `VERBOSE=1` 时才发作**的隐蔽 bug：`lc_log()` 的 verbose 回显原本走
> stdout，而 `lc_pick_targets()` 等函数是用 `$(...)` 从 stdout 取返回值的 —— 于是日志行会被
> 当成"目标路径"混进 `$targets`，去挂一堆不存在的路径。已改为回显到 **stderr**。
> 教训与「分隔符」那条同源：**同一个通道既传结果又传日志，迟早出事。**

### 自动流程

`post-fs-data`（早于 audioserver）：

1. **前置检查** —— SDK ≥ 37 且存在 `audio.bluetooth.default.so`，否则直接跳过（不硬上）
2. **纠正属性** —— `persist.bluetooth.a2dp_offload.disabled` 若是 `true` 则改回 `false`
   （**为 true 会让 A2DP 彻底无声**）
3. **定位目标** —— 见下
4. **备份原厂** —— 只认"未打过补丁"的内容；若可见内容已是补丁态，则从分区原始文件直读
   （`mount --bind` 只复制单个文件系统、不含子挂载，所以能读到未被覆盖的真实文件）
5. **打补丁** —— `lib/patch_policy.awk`（POSIX awk，Android 自带 toybox awk 即可）。
   写列表属性之前先**探测原厂文件的分隔符风格**，照着写（见上一节）
6. **双层挂载**，每层紧接 `--make-private`，然后摘掉源路径幽灵挂载

`service`（late_start）：

- 校验 overlay，未生效则补做一次
- **运行态校验** —— `dumpsys media.audio_policy` 里若没有 `AUDIO_FORMAT_LHDC`，
  说明 audioserver 加载的还是原厂配置，`setprop ctl.restart audioserver` 让它重载
- **采样率解析自检** —— 再确认 `a2dp output` 的 profile 真的解析出了 `sampling rates:`
  （而不是 `[dynamic rates]`）。这一条专门拦"分隔符风格不对"这类**静默失效**
- 从运行中的 audioserver **反查它真正加载了哪个策略文件**，存进 `state/active.path`，
  下次开机直接命中
- 把原厂备份导出到 `/sdcard/lhdc-a2dp-backup/`

### 目标定位顺序

1. `state/active.path`（上次开机反查到的活跃文件）
2. 配置项 `SKU=<名字>` 强制指定
3. **权威 sku 属性**逐条按优先级试，命中**恰好一个**才采纳：
   `ro.boot.product.vendor.sku` → `ro.boot.sku` → `ro.vendor.sku` → `ro.vendor.build.sku`
   → `ro.boot.hardware.sku` → `ro.boot.product.hardware.sku`（整词匹配，见上一节）
4. **弱线索**（平台名 / SoC 名 / 设备名）整词匹配，无果再退化子串
5. 只有一个候选 → 用它
6. 多个且无法判定 → **全部处理**（`PATCH_ALL=1`）。没被加载的那几份补了也没有副作用，
   所以这是安全的兜底

---

## 适用前提

| # | 条件 | 检查方法 | 不满足会怎样 |
|---|---|---|---|
| 1 | Android 17+（SDK 37） | `getprop ro.build.version.sdk` | 没有 LHDC 编码器，模块救不了（改 `MIN_SDK` / `FORCE=1` 可强上） |
| 2 | AOSP 蓝牙栈 + 高通 PAL 混合架构 | `ls /apex/com.android.bt` | 纯高通栈设备 offload 本来就通，不需要本模块 |
| 3 | 存在 `audio.bluetooth.default.so` | `ls /vendor/lib64/hw/audio.bluetooth.default.so` | 新 module 加载失败 → 自动跳过（可用 `FORCE=1` 强上） |
| 4 | 策略文件里有 `BT A2DP Out` 等端口 | `grep 'BT A2DP' <策略文件>` | awk 报 `no A2DP devicePort found` 并跳过 |

**不适用**：编码器本身缺失的设备（`lhdc_codec_support=FALSE`，或 Android < 17）。
**模块只负责把音频接到正确的 HAL 通路，它不提供编码器。**

### MTK / 联发科平台能用吗

基本不能 —— 但判据是上面的第 2、3 条，**不是「芯片是哪个厂」**：

- MTK 设备的音频 HAL 是联发科自己的实现，**没有高通 PAL**，也不存在
  `btaudio_offload_if.so` / QTI HIDL session。本模块要修的那条断链
  （AOSP 蓝牙栈不去开 QTI session → 拿不到 encoder config）在 MTK 上根本不存在
- 因此也不需要把 A2DP 端口挪进 `bluetooth` module：高通平台缺的是软件编码通路，
  MTK 的 A2DP 走自家 HAL，挪过去反而可能没声
- 少数 MTK 设备可能带 `audio.bluetooth.default.so`（AOSP 通用蓝牙音频 HAL，
  多为 LE Audio / 助听器而打包），但这**不代表**它的 A2DP 走这条通路

MTK 上「LHDC 协商成功却无声」通常是另一回事：厂商没在该机型开放 LHDC、蓝牙
固件/中间件版本不匹配，或 MTK 自家 offload 的配置问题 —— 都不是本模块能解决的，
得去找该机型的 ROM 或内核侧方案。

> 拿不准就跑 `--dry-run`：它只报告不改东西，看 SDK、HAL、候选策略文件三节就能定性。

Root 侧无门槛：Magisk / KernelSU / APatch 都行（只用 `post-fs-data.sh` + `service.sh`，
**不用 `system/` 目录覆盖** —— KernelSU 原生不支持）。

---

## 配置

编辑模块目录下的 `lhdc.conf`，下次开机生效：

| 项 | 默认 | 说明 |
|---|---|---|
| `SKU` | 空 | 强制指定 sku 目录名（`ukee` / `taro` / `kalama` …），留空 = 自动定位 |
| `PATCH_ALL` | `1` | 无法判定活跃 sku 时是否处理全部候选 |
| `OFFLOAD_FIX` | `1` | 是否纠正 `a2dp_offload.disabled`（**建议保持 1**） |
| `FORCE` | `0` | 跳过前置检查，非必要不要开 |
| `MIN_SDK` | `37` | 低于该 SDK 直接跳过 |
| `VERBOSE` | `0` | 额外输出到 stdout |
| `LHDC_DUMPSYS_TIMEOUT` | `20` | `dumpsys` 单次调用超时（秒）。设备被**别的**故障拖到高负载时可调小；别设 0 |

---

## 诊断

```sh
# 只报告，不改动任何东西
su -c 'sh /data/adb/modules/android17-lhdc-a2dp-universal/post-fs-data.sh --dry-run'
```

输出包含：SDK、HAL 是否就位、awk 是否可用、offload 属性、所有候选策略文件及其状态、
选中的目标、state 内已备份的原厂文件、**逐层挂载状态（含传播模式与挂载源）**、
源侧父挂载的传播模式、private 工具是否可用、**运行态（audioserver 是否真的加载了补丁策略）**、最近日志。

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

**怎么读这份报告：**

| 行 | 期望 | 说明 |
|---|---|---|
| `AOSP BT HAL` | `yes` | 没有它就没有软件编码通路 |
| `当前挂载层` | 两层都是 `[private]` | 出现 `[shared]` = 层没隔离住，随时可能被 /data 的挂载事件顶掉 |
| `源侧传播模式` | `shared`（**正常**） | 这是**父挂载** `/vendor` 的模式，解释了我们**为什么**必须 private |
| `传播隔离能力` | 有 busybox | toybox 的 `mount` 不支持 `--make-private`，没有 busybox 就锁不住 |
| `运行态` | `OK` | 原厂配置里绝不会有 `AUDIO_FORMAT_LHDC`，出现即说明 audioserver 读的是补丁版 |

> 「源侧传播模式」与「当前挂载层」两行不是矛盾：前者说的是父挂载（/vendor，常年 shared，
> 无法也不该改），后者说的是**我们自己挂的那层**（必须是 private）。

日志文件：`/data/adb/modules/android17-lhdc-a2dp-universal/state/run.log`
（注意：开机早期的时间戳是 `1970-…`，RTC 尚未同步，判断先后请按行序）

---

## 验证是否生效

```sh
# 0. 最关键的一条：运行中的策略有没有 LHDC
#    原厂配置里绝不会有 AUDIO_FORMAT_LHDC，有即说明 audioserver 加载的是补丁版
su -c 'dumpsys media.audio_policy | grep -c AUDIO_FORMAT_LHDC'
#    期望 >= 1（三个 A2DP 端口各一次，加上 profile 复制）

# 0b. 同样关键、而且更隐蔽：a2dp output 的采样率有没有真的解析出来
#     分隔符风格写错时这里会退化成 [dynamic rates]，而上面那条 LHDC 检查照样是绿的
su -c 'dumpsys media.audio_policy' | grep -A5 '"a2dp output";'
#    期望 "sampling rates: 44100, 48000, 88200, 96000"
#    若为 "[dynamic rates]" → A2DP 输出打不开、蓝牙无声（见「列表分隔符必须跟随 ROM」）

# 1. 音频硬件模块：primary 下不应再有 A2DP 端口，它们应归到 bluetooth
su -c 'dumpsys media.audio_policy | grep "Handle: "'

# 2. 目标文件应含 bluetooth module + LHDC
su -c 'grep -c "module name=\"bluetooth\"" /vendor/etc/audio/sku_*/audio_policy_configuration.xml'

# 3. 我们的层必须是 private（不能是 shared —— 那意味着还会被 /data 的事件带崩）
su -c 'grep audio_policy_configuration /proc/self/mountinfo'

# 4. 耳机协商结果
dumpsys bluetooth_manager | grep -i "Current Codec"      # 期望 LHDCv5

# 5. 播放时确认编码器在跑，且没有故障日志
logcat -b all -d | grep -i lhdcv5
logcat -b all -d | grep -cE "invalid encoder config|write error -22|PAL: Bluetooth: startPlayback"
#    期望 0
```

> ⚠️ 那条 `PAL: Bluetooth: startPlayback` **确实是故障征兆**（PAL 在无限重试启动失败的流），
> 不是无害的 verbose 日志。它是判断"通了但没出声"的最好指标。

---

## 移植到其他设备

模块本身是通用的（自动定位 sku、自动备份、自动打补丁），但仍需确认：

1. **SDK ≥ 37** 且 **AOSP 蓝牙栈目录 `/apex/com.android.bt` 存在**
2. **`audio.bluetooth.default.so` 存在**（上面「适用前提」第 3 条）
3. **确认架构是混合型**：`grep -rl btaudio_offload /vendor/lib64 | head`
   若设备本来就是纯 AOSP 架构，不需要本模块
4. **确认原厂策略里的 A2DP 端口不在 `primary` 下**
   —— 若已经在 `bluetooth` module 里，模块只会补 LHDC，不会动结构

如果目标机的 sku 目录名无法被属性匹配，且有多份候选，模块默认全部处理；也可以直接
在 `lhdc.conf` 里写死 `SKU=`。

### 换个设备时最该先确认的两件事

```sh
# 1. 有没有可用的 busybox？（决定能否把层置 private）
ls -l /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox 2>/dev/null
/data/adb/magisk/busybox mount --make-private /some/mountpoint   # 不报错即可用

# 2. 源侧挂载是不是 shared？（几乎必然是，这是正常现象，模块会自行处理）
awk '$5=="/data"{print $0}' /proc/self/mountinfo
#    看末尾有没有 shared:NN —— 有就说明存在 peer group 牵连
```

只要源文件在 shared 挂载上，bind 出来的层就会加入该 peer group。
模块靠 **每层 immediate `lc_make_private()`（走 busybox）** 断开这个牵连。
万一某台设备连 busybox 都没有，模块会降级：层继续留在 peer group 里，
但**唯一 tag 的源文件名**保证不会写坏文件，`service.sh` 的 `lc_ensure_running()`
也会在 audioserver 读错配置时把它重启回来。

---

## 排障：开机卡住 / 一直起不来（**先排除本模块**）

现象：重启后长时间停在开机画面，`getprop sys.boot_completed` **一直是空**，
但 shell 能用、`/proc/uptime` 一直在涨（即**设备没死，是启动流程没走完**）。

**第一步先做这个判定**，一秒就能分清是不是本模块的锅：

```sh
adb shell getprop sys.init.updatable_crashing     # 空 = 正常；1 = 有别的服务在崩
adb shell "su -c 'dmesg | grep -c dspservice'"    # 这台 K20 Pro 实测每 5 秒崩一次
```

`sys.init.updatable_crashing=1` 说明 **init 的「可更新组件在 boot_completed 之前崩了 4 次」
恢复机制被触发**（`apexd` 会尝试回滚那个 APEX），这与本模块无关 —— 本模块只改一个
`audio_policy_configuration.xml`，不可能让别的原生进程收到 `SIGSYS`。

### 真实案例（Redmi K20 Pro / raphael，Android 17 移植 ROM）

```
[ 9.70] init: Service 'vendor.dspservice' (pid 1331) received SIGSYS     ← 启动后 ~100ms 就被杀
[14.63] init: Service 'vendor.dspservice' (pid 2483) received SIGSYS     ← 每 5 秒一次，永远不停
[21.68] init: processing action (sys.boot_completed=1)                   ← 成功的那次：抢在前面
```

- 进程 exec 后约 100ms 就 `SIGSYS`，**每次都是** → 典型的 **seccomp 策略不匹配**
  （老 vendor 二进制 + 新系统）
- **它和本模块毫无关系**：同一次开机里，本模块的
  `post-fs-data → RESULT: OK`、`late_start → VERIFY OK` 全部正常
- **决定开机成败的是一场赛跑**：
  - `boot_completed` 在 **21.7s** 完成，`dspservice` 第 4 次崩在 **24s**
    → 差 **约 2.3 秒**，这一轮侥幸过关
  - 只要这次开机比平时慢 2.5 秒以上，第 4 次崩溃就会抢在 `boot_completed` 之前，
    触发 `updatable_crashing` + `apexd` 回滚 → **启动永久卡死，且不会自动重启**

也就是说：**这台设备在系统层面任何"开机慢一点"的情况下都会卡死，与本模块无关。**
想让开机不再随机卡死，得去修那个崩溃的厂商服务（补/换 seccomp 策略，或屏蔽该服务），
不要在本模块上找原因。

### 卡住之后怎么救回来

```sh
# 1) 先把现场存下来（dmesg 重启即清空，很关键）
adb shell "su -c 'dmesg > /data/local/tmp/dmesg.log'"

# 2) 正常重启通道会全部失效，别浪费时间：
#      adb reboot                    → 挂住（要经 system_server）
#      setprop sys.powerctl reboot   → 被 SELinux 拦下，且读回是空的
#      /proc/sysrq-trigger           → sysrq 被禁用（/proc/sys/kernel/sysrq = 0）
#    能用的只有直接调 reboot(2) 的那个二进制，**给它足够时间（30s+）**：
adb shell "su -c '/system/bin/reboot'"
```

> 实测取证的坑：`setprop sys.powerctl reboot` 返回 0 但**属性根本没写进去**
> （`getprop sys.powerctl` 读回是空的）。**不要用返回码判断是否生效，要读回验证。**
>
> 另外：`ps -o STAT,NAME | awk | sort | uniq -c` 这类管道在系统僵住时会一起挂住，
> 排查时用最简单的单命令，别串管道。

---

## 卸载

在 root 管理器里删除模块即可。`uninstall.sh` 会：

1. 摘掉 overlay，让分区上的真实文件重新可见
2. 检查它是否完好；**若不可用**，会用 `state/golden/` 里的原厂备份临时兜住，
   并提示你先重刷 vendor 再重启

原厂备份的位置：
- 设备内：`/data/adb/modules/android17-lhdc-a2dp-universal/state/golden/`
- 可随时取回：`/sdcard/lhdc-a2dp-backup/`（开机后自动导出）

---

## 目录结构

```
android17-lhdc-a2dp-universal/
├── module.prop            模块声明
├── lhdc.conf              用户配置
├── customize.sh           安装期：补脚本权限（KernelSU 解压会丢 x 位）
├── post-fs-data.sh        开机早段：定位 → 备份 → 打补丁 → 挂载
├── service.sh             开机后：校验 / 反查活跃策略 / 导出备份
├── uninstall.sh           卸载：摘挂载 + 原文件体检 + 必要时兜住
├── lib/
│   ├── common.sh          共享函数库（定位、备份、打补丁、挂载）
│   └── patch_policy.awk   XML 补丁器（POSIX awk）
├── .github/
│   ├── workflows/release.yml   推 v* 标签即自动构建 + 发版（**不进包**）
│   └── RELEASE_TEMPLATE.md     Release 说明模板（**不进包**）
├── build.sh               打包脚本（**开发者用，不进包**）
├── README.md              文档
├── LICENSE                GPL-3.0 全文
└── state/                 运行时生成，含备份与日志（**不进包**）
```

---

## 构建与打包

```bash
./build.sh                      # → ../android17-lhdc-a2dp-universal.zip + .sha256
./build.sh --reproducible       # 可复现：同一个 commit 打出的包字节完全相同
./build.sh -o /tmp/xx.zip       # 指定输出
./build.sh --allow-dirty        # 工作区有未提交改动时也放行
./build.sh -h                   # 全部参数
```

**不要手工 `zip -r`**，有三个坑：

| 坑 | 后果 |
|---|---|
| 把 `.git/`、`.gitignore` 打进去 | 体积翻倍，还可能把历史一起散出去 |
| 把 `state/`、`ap.txt`、`dumpsys.txt` 等打进去 | 包不干净；取证文件可能含你的设备信息 |
| 忘了 `chmod 755` | 装到设备上 `post-fs-data.sh` 没有 `+x`，init exec 失败 —— 现象是**「模块装了却毫无反应」**，日志里一行都没有 |

`build.sh` 的做法：

- **文件清单取自 `git ls-files`** —— 只有该进包的东西才会进包，不靠手写黑名单
  （不在 git 仓库里时退回 `find` + 黑名单模式）
- **工作区不干净就拒绝打包**（未提交/未跟踪的改动会让产物与仓库状态对不上）；
  用 `--allow-dirty` 可放行，并会明确警告「`??` 开头的未跟踪文件不会进包」
- **静态检查**：必需文件齐全、行尾必须 LF（含 CRLF 直接拒绝）、无 BOM、
  `busybox ash -n` 语法检查（贴近设备侧 shell）、`*.sh` 语法、awk 脚本语法
- **打包后自检**：`module.prop` 必须在 zip **根目录**（多嵌一层目录会装不上）、
  不得混入 `.git` / `state/`、zip 内权限位必须是脚本 755 / 数据 644
- 同时输出 `.sha256`，方便核对「设备上那个包 == 这个 commit」

把包装到设备：

```bash
adb push ../android17-lhdc-a2dp-universal.zip /data/local/tmp/
adb shell su -c 'ksud module install /data/local/tmp/android17-lhdc-a2dp-universal.zip'   # KernelSU
# Magisk：在管理器里选「从本地安装」那个 zip
```

KernelSU 会先放进 `modules_update/`，**重启后才转正**。本项目惯例再存一份到 `/sdcard/`。

### 下载预编译包（Releases）

不想自己构建的话，直接取 [Releases](/Makuro-Arisaka/android17-lhdc-a2dp-universal/releases) 里的附件：

| 附件 | 说明 |
|---|---|
| `android17-lhdc-a2dp-universal.zip` | 模块包，直接装 |
| `android17-lhdc-a2dp-universal.zip.sha256` | 校验和 |

这些包由 GitHub Actions 在对应提交上跑 `./build.sh --reproducible` 构建，**不是手工上传的二进制**：
时间戳取自 commit 时间，所以同一个 commit 在任何机器上构建，产物字节完全一致 —— 你可以自己

```bash
git checkout v2.1.1 && ./build.sh --reproducible
```

复现出同一个 sha256，来核对附件确实来自那个提交的源码。

---

## 许可证

**GNU General Public License v3.0**（全文见 [LICENSE](LICENSE)）。

> 本模块在运行时以 bind mount 覆盖系统配置，**不改写任何分区上的原始文件**，
> 卸载后设备即恢复原状。许可证覆盖的是本仓库的代码与文档。
