#!/system/bin/sh
# ============================================================================
# customize.sh — 安装阶段由 Magisk / KernelSU 执行
# ----------------------------------------------------------------------------
# 为什么必须有这个文件：
#   KernelSU 解压模块时**不保留 zip 里的权限位**，所有文件都落成 0644。
#   于是 post-fs-data.sh / service.sh 没有 +x，init 到点 exec 不了它们 ——
#   现象是"模块明明装了，却什么都没发生"，日志里连一行都没有，极难查。
#   （marble 上第一次装这个系列模块就踩过，当时是手动 chmod 补的。）
# ============================================================================

MODPATH=${MODPATH:-${0%/*}}
[ -d "$MODPATH" ] || exit 0

chmod 755 "$MODPATH"/*.sh 2>/dev/null
chmod 755 "$MODPATH"/lib 2>/dev/null
chmod 644 "$MODPATH"/lib/* "$MODPATH"/lhdc.conf "$MODPATH"/module.prop "$MODPATH"/README.md 2>/dev/null

# 顺带把残留的运行态清掉，避免上次的 golden/patched 混进新版本（防污染）
rm -rf "$MODPATH/state" 2>/dev/null

exit 0
