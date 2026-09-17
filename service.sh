#!/system/bin/sh
# ============================================================================
# android17-lhdc-a2dp-universal — service 阶段（late_start）
# 职责：1) 校验 overlay 是否生效，未生效则补做
#       2) 运行态校验：audioserver 是否真的加载了补丁策略，否则重启它重载
#       3) 从运行中的 audioserver 反查它真正加载了哪个策略文件，供下次开机直接命中
#       4) 把原厂备份导出到 /sdcard
#       5) offload 属性最终兜底
# ============================================================================

[ -n "$MODDIR" ] || MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/android17-lhdc-a2dp-universal

. "$MODDIR/lib/common.sh"

# 等 boot_completed：/sdcard 与 audioserver 都要到此才就绪
i=0
while [ "$i" -lt 90 ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
    sleep 1
    i=$((i + 1))
done

lc_rotatelog
lc_log "=== boot: service (verify) ==="

if ! lc_verify; then
    lc_log "WARN: 校验未通过，在 late_start 阶段重试一次"
    lc_apply_all
    lc_verify
fi

# 文件级生效 ≠ audioserver 已加载：它起得比补丁层稳定下来还早时，读到的仍是
# 原厂配置（症状：LHDC 协商成功却没声音）。这里做最终判定并必要时重载。
lc_ensure_running

lc_learn_active
lc_export_backup
lc_fix_offload_prop

exit 0
