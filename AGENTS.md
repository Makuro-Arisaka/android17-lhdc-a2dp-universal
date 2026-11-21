# 开发指南

本文说明仓库结构、修改约束和验证方法。面向用户的使用说明见
[README.md](README.md) 和 [README.en.md](README.en.md)。

## 项目结构

这是一个 Android 17 音频策略模块，支持 Magisk、KernelSU 和 APatch。它把 A2DP
端口移入 `bluetooth` module 并补全 LHDC、mixPort 和 route，使 AOSP 蓝牙栈能够
通过 `audio.bluetooth.default.so` 使用软件编码。

模块不提供编码器。适用目标是 AOSP 蓝牙栈与高通 PAL 共存的设备。

| 路径 | 职责 |
|---|---|
| `customize.sh` | 安装时检查运行条件、修正权限并清理旧运行数据 |
| `post-fs-data.sh` | 开机早期定位、备份、修改并挂载音频策略 |
| `service.sh` | 启动后复查策略和 audioserver，记录活跃文件并导出备份 |
| `uninstall.sh` | 卸载挂载、检查原始文件并清理运行数据 |
| `lib/common.sh` | 设备脚本共用的函数；通过 `source` 加载 |
| `lib/install_check.sh` | 安装时的只读检查和控制台输出 |
| `lib/patch_policy.awk` | 使用 POSIX awk 修改音频策略 XML |
| `lhdc.conf` | 用户配置 |
| `module.prop` | 模块元数据及版本 |
| `build.sh` | 构建、静态检查和打包 |
| `tests/` | 安装检查的本地测试及 XML fixtures |

## 音频策略约束

修改补丁器或验证逻辑时，应保留以下行为。

### Module 和路由

- A2DP devicePort 必须属于名为 `bluetooth` 的 module，HAL 名称由
  `audio.<moduleName>.default.so` 决定。
- 完整的输出路径需要 A2DP devicePort、`a2dp output` mixPort 及对应 route。
- `patch_policy.awk` 的退出码 `2` 表示无需修改；只有上述三部分都完整时才能返回它。
- 已部分迁移或通过 `xi:include` 引入的策略也要正确处理，避免重复节点。
- 只修改 A2DP 端口，不要把助听器等其他蓝牙输出改成 LHDC。

### XML 列表格式

`samplingRates` 和 `channelMasks` 的分隔符由根元素 `version` 决定：

| `version` | 分隔符 |
|---|---|
| `1.0` | 逗号 |
| `7.0` / `7.1` | 空格 |

`encodedFormats` 固定使用空格，不采用上述规则。`sep_by_version()` 是主要判定
方法，`detect_sep()` 只用于无法读取有效版本时的回退。不要根据机型或 Android
版本推断分隔符。

格式错误可能不会产生直接的 XML 错误，而会让 dumpsys 中的 profile 显示为
`[dynamic rates]`。因此验证时除了检查 LHDC，还要检查 `a2dp output` 的采样率：

```sh
dumpsys media.audio_policy | grep -A5 '"a2dp output";'
```

### 挂载与原始文件

- 不要直接改写 `/vendor`、`/odm` 等分区上的策略文件。
- `state/golden/` 保存原始副本，不作为挂载源；`state/work/` 和
  `state/patched/` 分别用于兜底层和补丁层。
- 每次 bind mount 后都应尽快用 busybox 执行 `mount --make-private`。toybox
  mount 不支持所需选项。
- 缺少 busybox 时按现有逻辑报告能力降级，不要把未隔离的挂载记录为 private。
- 卸载或清理 `state/` 前必须处理其中的挂载点，尤其是 `state/raw/`。
- 原始备份需要随固件变化重新核对，不能仅凭旧文件存在就继续复用。

## 安装检查

`customize.sh` 的执行顺序是：

1. 修正模块目录和脚本权限；
2. 设置 `DRY_RUN=1`，加载公共函数及安装检查；
3. 检查 awk、SDK、蓝牙 HAL 和候选策略，并试运行补丁器；
4. 检查失败时通过 `abort` 返回安装失败；
5. 检查成功后清理旧 `state/` 并完成安装。

权限修正必须早于 `source`，因为 KernelSU 解压可能连目录执行位也不保留。
安装检查必须保持只读，不得创建 `state/`、写日志或应用挂载。`FORCE=1` 保留为
跳过检查的选项。

`lib/common.sh` 同时被安装环境和开机脚本加载。读取可能未定义的环境变量时使用
`${VAR:-}`，避免不同 root 管理器的 shell 选项导致安装失败。用于命令替换返回
结果的函数不要把日志写到 stdout；调试输出走 stderr。

## 修改与验证

设备脚本以 POSIX shell / busybox ash 为目标，补丁器保持 POSIX awk 兼容，避免
依赖 GNU awk、Python 或仅开发机具备的工具。

相关改动后至少运行：

```bash
for f in customize.sh post-fs-data.sh service.sh uninstall.sh \
         lib/common.sh lib/install_check.sh; do
    busybox ash -n "$f"
done
bash -n build.sh
awk -f lib/patch_policy.awk </dev/null  # 预期报 input too small，不应有语法错误
bash tests/run-install-check.sh
./build.sh --allow-dirty -o /tmp/lhdc-check.zip
```

新增 XML 场景时，同时添加 fixture 和断言，至少检查首次生成、再次处理和已有
目标形态的行为。仅验证脚本退出成功不够，还要检查生成的端口、mixPort、route
和分隔符。

如果进行真机测试，结束后移除测试模块、临时安装包和挂载，并确认分区策略恢复
原状。用户已有模块和运行数据不属于测试清理范围。

## 打包与发布

统一使用构建脚本：

```bash
./build.sh
./build.sh --reproducible
./build.sh -o /tmp/module.zip
./build.sh --allow-dirty
```

打包清单来自 `git ls-files`。新增仓库文件时检查 `build.sh` 的 `is_excluded()`，
决定它是否属于设备运行所需内容。开发工具、CI、测试、`state/` 和取证输出不进包；
`lib/install_check.sh` 需要进包。中文 README 进包，英文 README 不进包。

构建脚本负责排序 zip 条目并统一权限：目录和根目录脚本为 `755`，库及其他文件为
`644`。不要在递归 chmod 中把 `lib/*.sh` 设为可执行。进包文件变化会影响 SHA-256。

发布步骤：

1. 递增 `module.prop` 的 `version` 和 `versionCode`；
2. 完成验证并提交；
3. 创建并推送 `v*` 标签，由 GitHub Actions 构建 Release。

提交信息使用中文，标题采用「动作：要点」。提交前检查 LF 行尾和无 BOM。
推送前执行 `git fetch`，必要时将本地提交 rebase 到 `origin/main`，不要 force push。
