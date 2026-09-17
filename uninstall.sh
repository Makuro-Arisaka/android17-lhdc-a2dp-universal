#!/system/bin/sh
# ============================================================================
# lhdc-a2dp-universal — 卸载脚本
# 卸载时会摘掉 overlay，让分区上的真实文件重新可见，并检查它是否完好。
# ============================================================================

[ -n "$MODDIR" ] || MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/lhdc-a2dp-universal

. "$MODDIR/lib/common.sh"

echo "=== lhdc-a2dp-universal 卸载 ==="

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

rm -rf "$LHDC_STATE" 2>/dev/null
echo "state 已清理。"
exit 0
