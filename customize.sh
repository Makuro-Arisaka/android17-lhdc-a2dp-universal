#!/system/bin/sh
# ============================================================================
# customize.sh — 安装阶段由 Magisk / KernelSU / APatch 执行
# ----------------------------------------------------------------------------
# 这一步做两件事，顺序不能颠倒：
#
#   1) **先检查适用范围**（SDK >= MIN_SDK、AOSP 蓝牙音频 HAL、候选策略文件、
#      补丁器试运行等），结论直接打到 root 管理器的安装控制台；
#      不满足就 abort，让安装在管理器里显示为**失败**，并指明是哪一条不满足。
#      —— 之前是"先装、开机后 post-fs-data 里打一行 SKIP 就退出"，用户看到的是
#      「装成功了却毫无反应」，日志还藏在 state/run.log 里，极难自查。
#
#   2) 检查通过后才落盘收尾：补脚本 x 位 + 清掉残留的 state/。
#
# 为什么必须先 chmod 再 source：
#   lib/common.sh 靠 `.` 被加载（不需要 x 位），但 KernelSU 解压会把**所有**文件
#   落成 0644，连 lib/ 目录都可能少 x 位 —— 目录没有 x 就无法进入，`. lib/...`
#   会直接失败。所以 chmod 要放在最前面。
#
# 为什么检查阶段必须先设 DRY_RUN=1：
#   lib/common.sh 会把 DRY_RUN 当作所有写原语（lc_log / mkdir / active.path …）
#   的总闸门。安装检查只允许读：检查不通过时设备上除控制台输出外**不应留下任何
#   痕迹**，也不能因为一次失败的安装就在 /data 里建出 state/ 目录。
# ============================================================================

MODPATH=${MODPATH:-${0%/*}}
[ -d "$MODPATH" ] || exit 0
MODDIR=$MODPATH
export MODDIR

# ---- 第 1 步：补权限（检查阶段就要能 source 到库与配置）----
# 注意 lib/* 保持 644：它只被 source，不 exec。
chmod 755 "$MODPATH" 2>/dev/null
chmod 755 "$MODPATH"/*.sh 2>/dev/null
chmod 755 "$MODPATH"/lib 2>/dev/null
chmod 644 "$MODPATH"/lib/* "$MODPATH"/lhdc.conf "$MODPATH"/module.prop "$MODPATH"/README.md 2>/dev/null

# ---- 第 2 步：只读检查 ----
# DRY_RUN 必须在 source common.sh 之前设好（它 sourced 后会读这个变量并用于
# 每一个写操作）；此处同时 export，避免子进程绕过。
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
    # 检查没通过：交给 abort（管理器据此把这次安装判定为失败）。
    # 不清理任何东西、不建 state —— 保留设备现状，用户装回旧版本也不会被干扰。
    lc_ic_abort "不符合适用范围，已中止安装（详见上方检查结论）"
fi

# ---- 第 3 步：检查通过，落盘收尾 ----
# 权限已在第 1 步设好，这里只剩清运行态。
# 顺带把残留 state 清掉：上次的 golden/patched/active.path 混进新版本会污染
# 备份判定（golden 还能跨 OTA 存活，见 common.sh 里 lc_ensure_golden 的注释）。
rm -rf "$MODPATH/state" 2>/dev/null

lc_ic_print " 安装完成：重启后由 post-fs-data 打补丁并挂载"
exit 0
