# LHDC A2DP Enabler

适用于 Android 17 的 Magisk / KernelSU / APatch 模块，用于修复
**耳机已协商 LHDC，但 A2DP 音频完全无声**的问题。

本模块由 `DeepSeek-V4.1-Flash(编写代码)` 与 `Kimi-K3.1-Pro(编写文档)` 制作。

> [English documentation](README.en.md)

## 适用范围

本模块面向使用 **AOSP 蓝牙栈 + 高通 PAL 音频 HAL** 的混合架构设备：

- AOSP 蓝牙协议栈不会建立高通 QTI HIDL session；
- 高通 offload 通路因此得不到编码器配置，可能反复输出
  `invalid encoder config` / `write error -22`；
- 模块把 A2DP 转到 AOSP 软件编码通路，使系统自带 LHDC 编码器能够被使用。

模块**只调整音频策略路由，不提供 LHDC 编码器**，也不解决耳机固件、厂商编码器
授权或其他 A2DP/LE Audio 故障。

### 安装时检查的必要条件

| 条件 | 说明 |
|---|---|
| Android SDK ≥ 37 | Android 17 及以上 |
| 有 `awk` | 用于生成补丁策略 |
| 有 `audio.bluetooth.default.so` | 提供 AOSP 蓝牙音频 HAL |
| 有可处理的音频策略文件 | 安装时会实际试运行补丁器，检查 A2DP 端口和输出路由 |

不满足时安装会中止，并在 root 管理器的安装控制台说明具体原因。

`/apex/com.android.bt`、busybox 和 offload 属性会作为辅助信息报告；其中缺少
busybox 会降低挂载隔离的可靠性，但不会单独阻止安装。

联发科平台、纯厂商蓝牙音频实现、没有系统 LHDC 编码器的设备，通常不属于本模块
的适用场景；不能仅凭 SoC 品牌判断，应看 HAL 和实际音频策略。

## 安装与卸载

### 安装

1. 从 [Releases](https://github.com/Makuro-Arisaka/android17-lhdc-a2dp-universal/releases)
   下载 zip，或按下方说明自行构建。
2. 在 Magisk / KernelSU / APatch 中安装，查看安装控制台的检查结果。
3. 重启设备，让 `post-fs-data.sh` 在 audioserver 启动前应用策略。

安装检查是只读的；检查通过后才会修正脚本权限并清除旧版运行数据。
`FORCE=1` 可跳过适用范围检查，但绕过检查并不代表设备能够使用 LHDC。

### 卸载

在 root 管理器中删除模块即可。卸载脚本会：

1. 摘除本模块创建的音频策略挂载；
2. 检查分区中的原始文件；
3. 清理模块运行数据和备份。

原厂备份位于模块目录的 `state/golden/`；正常运行时还会导出至
`/sdcard/lhdc-a2dp-backup/`。分区原文件正常情况下无需恢复，因为模块从未改写它。

## 验证与诊断

重启后不要只看模块状态，需核对 audioserver 的实际运行策略。

### 1. A2DP 输出及采样率

```sh
su -c 'dumpsys media.audio_policy' | grep -A5 '"a2dp output";'
```

应看到 `a2dp output`，并包含明确的采样率，例如：

```text
sampling rates: 44100, 48000, 88200, 96000
```

如果出现 `[dynamic rates]`，说明列表分隔符或 XML profile 解析不正确，A2DP
输出可能打不开。

### 2. 蓝牙编码与播放状态

```sh
dumpsys bluetooth_manager | grep -i 'Current Codec'
logcat -b all -d | grep -i lhdc
logcat -b all -d | grep -E 'invalid encoder config|write error -22|PAL: Bluetooth: startPlayback'
```

耳机应协商到 LHDC；最后一组错误若在播放时持续出现，说明仍在使用故障的
高通 offload 通路。

### 3. 只读诊断

```sh
su -c 'sh /data/adb/modules/android17-lhdc-a2dp-universal/post-fs-data.sh --dry-run'
```

诊断会列出 SDK、HAL、策略文件、选中目标、挂载传播模式及近期日志。
日志保存在模块目录的 `state/run.log`；开机早期的时间戳可能尚未同步。

## 配置

编辑模块目录下的 [`lhdc.conf`](lhdc.conf)，默认下次重启生效。

| 配置 | 默认值 | 用途 |
|---|---:|---|
| `SKU` | 空 | 手动指定 `sku_*` 名称；留空则自动定位 |
| `PATCH_ALL` | `1` | 活跃 SKU 无法确定时处理所有候选 |
| `OFFLOAD_FIX` | `1` | 将 `persist.bluetooth.a2dp_offload.disabled=true` 改回 `false` |
| `FORCE` | `0` | 跳过安装期及启动期的适用范围检查 |
| `MIN_SDK` | `37` | 最低 Android SDK |
| `VERBOSE` | `0` | 输出额外调试信息 |
| `LHDC_DUMPSYS_TIMEOUT` | `20` | `dumpsys` 单次调用超时（秒），不要设为 `0` |

目标策略的定位顺序为：上次记录的活跃路径 → 手动 `SKU` → 权威 SKU 属性 →
平台/设备线索 → 唯一候选 → 全部候选（`PATCH_ALL=1`）。

## 实现概要

模块不改写 `/vendor` 或其他分区，而是在模块 `state/` 中保存文件并进行 bind mount：

```text
原厂 XML → state/golden/       原厂备份
        ├→ state/work/         原厂兜底挂载层
        └→ state/patched/      补丁挂载层
```

- `customize.sh`：安装前检查、权限修正、旧运行数据清理。
- `post-fs-data.sh`：定位策略、备份、生成补丁并挂载。
- `service.sh`：复查文件和 audioserver 状态，记录活跃策略，导出备份。
- `uninstall.sh`：摘除挂载、检查原文件并清理运行数据。
- `lib/patch_policy.awk`：迁移 A2DP 端口，补全 LHDC、`a2dp output` 和路由。

补丁器按 XML 根元素的 `version` 生成列表：`1.0` 使用逗号，`7.0`/`7.1` 使用空格；
`encodedFormats` 始终使用空格。挂载层会使用 busybox 尽可能设置为 private，
降低 shared mount 传播导致补丁层丢失的风险。

## 开发与构建

统一使用 `build.sh` 打包，它会检查必需文件、LF 行尾、shell/awk 语法、zip
结构和文件权限，并生成 SHA-256 校验文件：

```bash
./build.sh
./build.sh --reproducible       # 同一提交可复现构建
./build.sh -o /tmp/module.zip   # 指定输出
./build.sh --allow-dirty        # 工作区有改动时继续打包
```

安装检查可在开发机上用模拟设备环境进行回归测试：

```bash
bash tests/run-install-check.sh
```

`tests/`、构建脚本和 CI 文件不会进入模块包。发布新版本时递增
[`module.prop`](module.prop) 中的 `version` / `versionCode`，提交后推送 `v*`
标签，由 GitHub Actions 构建 Release。

## 许可证

[GNU General Public License v3.0](LICENSE)

---

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
