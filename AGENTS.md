# AGENTS.md — 给 AI 编码助手 / 贡献者看的仓库说明

> 本文面向在**本仓库**里工作的 AI 助手与人类贡献者，讲的是「怎么改才不踩坑」，
> 不是给最终用户看的。用户文档见 [README.md](README.md)（中文）与 [README.en.md](README.en.md)（英文）。

## 这是什么

一个 Magisk / KernelSU / APatch 模块：运行时用 bind mount 覆盖
`audio_policy_configuration.xml`，把 A2DP 输出端口迁进名为 `bluetooth` 的 module
并声明 `AUDIO_FORMAT_LHDC`，让 Android 17 的**原生** LHDC 软件编码器真正出声。

- 目标场景：**LHDC 协商成功（`Current Codec: LHDCv5`）但完全无声**
- 适用：AOSP 蓝牙栈 + 高通 PAL 的**混合架构**（如刷了 Android 17 类原生的高通机）
- 不适用：MTK / 联发科（无高通 PAL，断链不存在）、编码器缺失（Android < 17）、
  纯高通栈（offload 本来就通）

模块**不提供编码器，只做路由**。它**不改任何分区文件**——所有修改活在模块自己的
`state/` 目录和内存挂载表里（唯一的持久改动是一个 `persist.*` 属性 + 两处备份副本）。

## 铁律：改任何东西之前先读懂这三条

这三条是整个仓库踩出来的核心结论，违反其中任何一条都会**静默失效**（不报错、自检却照常全绿），务必牢记：

1. **A2DP 的 devicePort 必须挂在名为 `bluetooth` 的 module 下**，挂 `primary` 会静默无声。
   HAL 按 `audio.<moduleName>.default.so` 查找，而这些机器上没有 `audio.a2dp.default.so`。
2. **XML 列表分隔符随 ROM 而变，与 Android 版本无关**（同是 SDK 37，marble 用空格、
   raphael 用逗号）。写错不报错，只把 profile 降级成 `[dynamic rates]` → A2DP 打不开、蓝牙无声。
   必须用 `detect_sep()` 逐台探测，**禁止按机型/版本硬编码**。
3. **bind mount 必须逐层 `--make-private`，且 toybox 的 `mount` 做不到**（报 bad /etc/fstab）。
   必须用 busybox 的 `mount`。不置 private，层会留在 `/data` 的 peer group 里被开机事件顶掉。

判定「真生效」的一眼判据（不要只看模块自检，那可能是绿的）：

```sh
dumpsys media.audio_policy | grep -A5 '"a2dp output";'
# 必须看到 "sampling rates: 44100, 48000, 88200, 96000"
# 若为 "[dynamic rates]" → 分隔符风格不对，无声
```

## 构建与打包：只准用 build.sh，别手工 zip

```bash
./build.sh                      # 输出 ../android17-lhdc-a2dp-universal.zip + .sha256
./build.sh --reproducible       # 可复现：同一 commit 任意机器字节一致
./build.sh --allow-dirty        # 工作区脏时放行（未跟踪文件不进包）
```

- **文件清单来自 `git ls-files`**，不在排除表里的都会进包。所以**新增仓库文件时，
  必须同时判断它该不该进包**，该排除就加进 `build.sh` 的 `is_excluded()`。
- **不该进包的东西**：`.github/`、`README.en.md`、`AGENTS.md`、`build.sh`、`.git*`、
  `state/`、取证文件（`ap.txt`/`dumpsys*.txt` 等）、`.zip`/`.sha256`。判断标准：
  设备侧运行时用不到的、只服务于开发/GitHub 的，一律不进包。
- **跨机器可复现的两个坑**（已修，别回退）：① zip 条目顺序要靠显式排序的文件列表，
  不能 `zip -r .`（readdir 顺序随文件系统变）；② 权限位要全量显式 chmod
  （目录 755 / 根脚本 755 / 其余 644），且根脚本那条必须配 `-maxdepth 1`，
  否则被 source 的 `lib/*.sh` 会被误设成 755。
- 每次改动 `README.md`、`module.prop`、`lib/*` 等**进包文件**，都会改变包 sha256。
  想更新线上 Release，就改 `module.prop` 版本号 → 提交 → 推 `v*` 标签（触发 Actions 自动发版）。

## 目录与职责

| 路径 | 职责 | 进包？ |
|---|---|---|
| `module.prop` | 模块声明（id / 版本 / 描述） | ✅ |
| `lhdc.conf` | 用户可改配置（SKU / FORCE / MIN_SDK …） | ✅ |
| `customize.sh` | 安装期补脚本 x 位（KernelSU 解压丢权限） | ✅ |
| `post-fs-data.sh` | 早于 audioserver：定位→备份→打补丁→挂载；`--dry-run` 只读诊断 | ✅ |
| `service.sh` | late_start：校验 overlay + 运行态自检 + 反查活跃策略 | ✅ |
| `uninstall.sh` | 摘挂载 + 原文件体检 + 必要时兜住 | ✅ |
| `lib/common.sh` | 共享函数库（被 source，**必须 644**） | ✅ |
| `lib/patch_policy.awk` | XML 补丁器（POSIX awk，设备上无 Python） | ✅ |
| `build.sh` | 打包脚本 | ❌ |
| `.github/` | Actions 发版 workflow + Release 模板 | ❌ |
| `README.md` / `README.en.md` | 用户文档（前者进包，后者不进） | 见右 |
| `AGENTS.md` | 本文档 | ❌ |
| `state/` | 运行时生成（备份 / 日志 / active.path） | ❌ |

## 提交约定（跟随仓库既有习惯）

- 分支 `main`；提交信息**中文**，标题「动作：要点」，正文分段说明改了什么、为什么改
- 提交前自检：`bash -n` 各 `.sh`（build.sh 是 bash，设备侧脚本用 `busybox ash -n`）、
  LF 行尾（CRLF 拒绝）、无 BOM
- **推送前必 `git fetch`**：本仓库 README 常由维护者在 GitHub 网页端直接改，
  本地 `origin/*` 是旧快照。若已分叉用 `git rebase origin/main` 重放，**绝不 force push**。

## 发版流程

1. 改 `module.prop` 的 `version` / `versionCode`（versionCode 递增）
2. 提交
3. `git tag vX.Y.Z && git push origin vX.Y.Z` → Actions 自动构建并发布 Release

推 `main` 不触发发版，只有推 `v*` 标签才触发。
