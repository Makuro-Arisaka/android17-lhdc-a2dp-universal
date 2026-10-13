#!/system/bin/sh
# ============================================================================
# android17-lhdc-a2dp-universal — post-fs-data 阶段
# 早于 audioserver 启动，是安装 bind-mount overlay 的唯一时机。
# 手动诊断： sh post-fs-data.sh --dry-run   （只报告，不改动任何东西）
# ============================================================================

[ -n "$MODDIR" ] || MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/android17-lhdc-a2dp-universal

DRY=0
for a in "$@"; do
    case "$a" in
        --dry-run|--check|-n) DRY=1; VERBOSE=1 ;;
        -v|--verbose)         VERBOSE=1 ;;
    esac
done
export VERBOSE

# 先把 DRY_RUN 交给 common.sh —— 它是**写操作的唯一闸门**。
# 只在下面设 LC_ECHO 是不够的：lc_report 会间接调到带写操作的函数
# （lc_log 建目录/写日志、lc_learn_active 写 active.path、lc_pick_targets 删失效的
#  active.path），dry-run 的「不改动任何东西」承诺要靠这个变量守住。
if [ "$DRY" = 1 ]; then
    DRY_RUN=1
    export DRY_RUN
fi

. "$MODDIR/lib/common.sh"

if [ "$DRY" = 1 ]; then
    LC_ECHO=1
    lc_report ""
    exit 0
fi

lc_rotatelog
lc_log "=== boot: post-fs-data ($(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)) ==="
lc_apply_all
exit 0
