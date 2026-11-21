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

    # 先确认挂载已摘除，再判断文件本身；未摘净时读到的仍是补丁层。
    if [ "$(lc_self_mode "$dst")" != "(无挂载)" ]; then
        echo "  [!!] 未能摘除挂在 $dst 上的层：$(lc_self_mode "$dst")"
        echo "       → 这**不是**分区文件损坏。重启后再卸载一次即可。"
        continue
    fi

    if lc_is_stock "$dst"; then
        echo "  [OK] 分区原文件完好：$dst"
        continue
    fi

    # 分区已是目标形态（ROM 自带或既有改动）时不算损坏，直接跳过。
    if lc_is_patched "$dst"; then
        echo "  [OK] 分区文件已是目标形态（ROM 自带或既有改动），未作改动：$dst"
        continue
    fi

    # 走到这里说明文件缺失、过小或缺少 </modules>，用备份临时兜住。
    sz=$(wc -c < "$dst" 2>/dev/null)
    echo "  [!!] 分区原文件不完整或不可解析（${sz:-?} B）：$dst"
    if [ -s "$golden" ]; then
        if mount --bind "$golden" "$dst" 2>/dev/null; then
            echo "       → 已用原厂备份临时兜住，重启前请先重刷 vendor"
            bridged=1
        fi
    else
        echo "       → 且没有可用的原厂备份，重启后该文件不可解析"
    fi
done

if [ "$bridged" = 1 ]; then
    echo ""
    echo "⚠️  分区上的原始策略文件已损坏。请先重刷 vendor 分区再重启设备。"
    echo "    原厂备份位置：$LHDC_STATE/golden/  与  /sdcard/lhdc-a2dp-backup/"
fi

# raw 是 lc_raw_read 临时 bind 分区根的挂载点；先摘掉再删 state，
# 否则 rm -rf 会顺着挂载点删进真实分区。
lc_unmount_dst "$LHDC_STATE/raw" >/dev/null 2>&1
umount "$LHDC_STATE/raw" 2>/dev/null

# bridged=1 时 golden 正被挂载引用，必须保留 state 供用户恢复。
if [ "$bridged" = 1 ]; then
    echo ""
    echo "state 未清理：分区文件仍靠原厂备份兜着，先把备份留给你。"
    echo "  请重刷 vendor 后手动删除： rm -rf $LHDC_STATE"
    exit 0
fi

rm -rf "$LHDC_STATE" 2>/dev/null
echo "state 已清理。"
exit 0
