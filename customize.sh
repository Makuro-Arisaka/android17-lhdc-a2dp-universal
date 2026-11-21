#!/system/bin/sh
# ============================================================================
# customize.sh — 安装阶段由 Magisk / KernelSU / APatch 执行
# customize.sh — 安装阶段由 Magisk / KernelSU / APatch 执行
# ----------------------------------------------------------------------------
# 流程：补权限 → 只读适用范围检查 → 通过后清理 state 并完成安装。
# 检查不通过时通过 abort 让 root 管理器把安装判定为失败。
#
# chmod 必须先于 source：KernelSU 解压会丢执行位，目录没有 x 就进不去 lib/。
# DRY_RUN=1 必须在 source 前设好，保证检查阶段只读、不留任何痕迹。
# ============================================================================

MODPATH=${MODPATH:-${0%/*}}
[ -d "$MODPATH" ] || exit 0
MODDIR=$MODPATH
export MODDIR

# 1. 补权限。lib/* 只被 source，保持 644。
chmod 755 "$MODPATH" 2>/dev/null
chmod 755 "$MODPATH"/*.sh 2>/dev/null
chmod 755 "$MODPATH"/lib 2>/dev/null
chmod 644 "$MODPATH"/lib/* "$MODPATH"/lhdc.conf "$MODPATH"/module.prop "$MODPATH"/README.md 2>/dev/null

# 2. 只读检查。
DRY_RUN=1
export DRY_RUN

# shellcheck source=lib/common.sh
. "$MODPATH/lib/common.sh" || {
    ui_print "!!! 无法加载 lib/common.sh，安装中止" 2>/dev/null \
        || echo "!!! 无法加载 lib/common.sh" >&2
    command -v abort >/dev/null 2>&1 && abort "模块文件不完整"
    exit 1
}

# shellcheck source=lib/install_check.sh
. "$MODPATH/lib/install_check.sh"

if ! lc_install_check; then
    lc_ic_abort "不符合适用范围，已中止安装（详见上方检查结论）"
fi

# 3. 检查通过，清理残留运行数据。
rm -rf "$MODPATH/state" 2>/dev/null

lc_ic_print " 安装完成：重启后由 post-fs-data 打补丁并挂载"
exit 0
