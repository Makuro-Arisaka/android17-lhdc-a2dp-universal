#!/system/bin/sh
# ============================================================================
# android17-lhdc-a2dp-universal — 卸载脚本
# 卸载时会摘掉 overlay，让分区上的真实文件重新可见，并检查它是否完好。
# ============================================================================

[ -n "$MODDIR" ] || MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/android17-lhdc-a2dp-universal

. "$MODDIR/lib/common.sh"

echo "=== android17-lhdc-a2dp-universal 卸载 ==="

bridged=0
for dst in $(lc_find_candidates); do
    key=$(lc_key "$dst")
    golden=$LHDC_STATE/golden/$key.xml
    lc_unmount_dst "$dst"
    if lc_is_stock "$dst"; then
        echo "  [OK] 分区原文件完好：$dst"
    else
        echo "  [!!] 分区原文件不可用（$(wc -c < "$dst" 2>/dev/null) B）：$dst"
        if [ -s "$golden" ]; then
            if mount --bind "$golden" "$dst" 2>/dev/null; then
                echo "       → 已用原厂备份临时兜住，重启前请先重刷 vendor"
                bridged=1
            fi
        else
            echo "       → 且没有可用的原厂备份，重启后该文件不可解析"
        fi
    fi
done

if [ "$bridged" = 1 ]; then
    echo ""
    echo "⚠️  分区上的原始策略文件已损坏。请先重刷 vendor 分区再重启设备。"
    echo "    原厂备份位置：$LHDC_STATE/golden/  与  /sdcard/lhdc-a2dp-backup/"
fi

# ⚠️ 删 state 之前必须先把 raw 摘掉。
#    $LHDC_STATE/raw 是 lc_raw_read() 用来 bind 分区根的**挂载点**。
#    rm -rf **默认会递归进挂载点**（阻止它的是 -x/--one-file-system，我们没用，
#    而且 toybox/busybox 的 rm 也未必支持），所以一旦 raw 还挂着，下面那句
#    rm -rf 就会**删进 /vendor**（或 /odm、/system_ext），后果是分区被抹空。
#
#    这不是假想：lc_raw_read 在 mount 与 umount 之间若被强杀（Magisk 超时、
#    OOM、掉电、用户手动 kill），raw 就会留在挂载状态；此后卸载模块即触发。
#    正常路径上它总会先 umount 再返回，但那是**隐式**保证 ——
#    显式兜这一下成本为零，出事却是灾难。
lc_unmount_dst "$LHDC_STATE/raw" >/dev/null 2>&1
umount "$LHDC_STATE/raw" 2>/dev/null

# ⚠️ 兜底挂载还在时不要删 golden。
#    bridged=1 意味着分区文件已损坏、我们刚用 golden 临时兜住。
#    此时删掉 golden，用户按上面提示去 $LHDC_STATE/golden/ 会**找不到任何东西**，
#    而 /sdcard 的导出只在 boot_completed 之后才做、很可能根本不存在；
#    重启后兜底挂载消失、分区文件又确实损坏 → 就没有任何可恢复的副本了。
if [ "$bridged" = 1 ]; then
    echo ""
    echo "state 未清理：分区文件仍靠原厂备份兜着，先把备份留给你。"
    echo "  请重刷 vendor 后手动删除： rm -rf $LHDC_STATE"
    exit 0
fi

rm -rf "$LHDC_STATE" 2>/dev/null
echo "state 已清理。"
exit 0
