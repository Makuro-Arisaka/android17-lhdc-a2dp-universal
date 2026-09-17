#!/system/bin/sh
# ============================================================================
# common.sh — lhdc-a2dp-universal 共享函数库
# post-fs-data.sh / service.sh 都 source 它；也可单独 source 做诊断
# ============================================================================

LHDC_ID=lhdc-a2dp-universal
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/$LHDC_ID
[ -d "$MODDIR" ] || MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)

LHDC_STATE=$MODDIR/state
LHDC_LOG=$LHDC_STATE/run.log
LHDC_CONF=$MODDIR/lhdc.conf
LHDC_AWK=""

# ---------------------------------------------------------------- 用户配置
# 优先级：命令行/环境变量 > lhdc.conf > 这里的默认值
__env_SKU=$SKU; __env_PATCH_ALL=$PATCH_ALL; __env_OFFLOAD_FIX=$OFFLOAD_FIX
__env_FORCE=$FORCE; __env_MIN_SDK=$MIN_SDK; __env_VERBOSE=$VERBOSE
__env_DT=$LHDC_DUMPSYS_TIMEOUT

: "${SKU:=}"            # 强制指定 sku 目录名（如 ukee / taro）；留空 = 自动定位
: "${PATCH_ALL:=1}"     # 无法判定活跃 sku 时，是否处理全部候选（安全兜底）
: "${OFFLOAD_FIX:=1}"   # 把 persist.bluetooth.a2dp_offload.disabled 从 true 纠正回 false
: "${FORCE:=0}"         # 跳过前置检查（Android 版本 / HAL 存在性）
: "${MIN_SDK:=37}"      # 低于该 SDK 直接跳过（LHDC 编码器自 Android 17 才有）
: "${VERBOSE:=0}"
: "${LHDC_DUMPSYS_TIMEOUT:=20}"   # dumpsys 单次调用超时（秒）。设备高负载时可调小，别设 0

# 策略文件搜索根目录。非标准 ROM 可覆盖；也可用于离线测试。
: "${LHDC_ETC_ROOTS:=/vendor/etc/audio /odm/etc/audio /vendor/odm/etc/audio}"
: "${LHDC_ETC_TOPDIRS:=/vendor/etc/audio /odm/etc/audio /vendor/odm/etc/audio /vendor/etc /odm/etc}"

[ -f "$LHDC_CONF" ] && . "$LHDC_CONF"

[ -n "$__env_SKU" ]         && SKU=$__env_SKU
[ -n "$__env_PATCH_ALL" ]   && PATCH_ALL=$__env_PATCH_ALL
[ -n "$__env_OFFLOAD_FIX" ] && OFFLOAD_FIX=$__env_OFFLOAD_FIX
[ -n "$__env_FORCE" ]       && FORCE=$__env_FORCE
[ -n "$__env_MIN_SDK" ]     && MIN_SDK=$__env_MIN_SDK
[ -n "$__env_VERBOSE" ]     && VERBOSE=$__env_VERBOSE
[ -n "$__env_DT" ]          && LHDC_DUMPSYS_TIMEOUT=$__env_DT
unset __env_SKU __env_PATCH_ALL __env_OFFLOAD_FIX __env_FORCE __env_MIN_SDK __env_VERBOSE __env_DT

LC_ECHO=0
[ "$VERBOSE" = 1 ] && LC_ECHO=1

# ---------------------------------------------------------------- 基础工具
lc_log() {
    [ -d "$LHDC_STATE" ] || mkdir -p "$LHDC_STATE" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LHDC_LOG" 2>/dev/null
    # ⚠️ verbose 回显必须走 **stderr**：lc_pick_targets / lc_find_candidates 等
    #    函数的返回值是走 stdout 的（调用方用 $(...) 捕获）。回显若走 stdout，
    #    开着 VERBOSE 时日志行会被当成目标路径混进 $targets，去挂一堆不存在的
    #    路径 —— 而且只在开了 verbose 的时候发作，极难查。
    [ "$LC_ECHO" = 1 ] && echo "$*" >&2
    return 0
}

lc_rotatelog() {
    [ -f "$LHDC_LOG" ] || return 0
    local n
    n=$(wc -c < "$LHDC_LOG" 2>/dev/null)
    if [ -n "$n" ] && [ "$n" -gt 131072 ] 2>/dev/null; then
        tail -c 32768 "$LHDC_LOG" > "$LHDC_LOG.t" 2>/dev/null && mv -f "$LHDC_LOG.t" "$LHDC_LOG" 2>/dev/null
    fi
    return 0
}

lc_key() { echo "$1" | sed 's|^/||; s|/audio_policy_configuration\.xml$||; s|/|_|g'; }

# 带超时执行命令。**凡是对外查询系统状态的地方都必须用它**：这套模块面对的设备
# 可能因为别的故障长时间高负载（实测遇到过 load 57、`dumpsys` 几分钟不返回），
# 没有超时会把 service.sh 直接挂死。找不到 timeout 时退化为直接执行，
# 不因为缺工具而丢掉功能。
lc_tmo() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# 运行态 audio_policy 转储（带超时）。超时/失败返回空串，调用方按"拿不到"处理。
# 可选参数：超时秒数（默认取 $LHDC_DUMPSYS_TIMEOUT，再退到 20）。
lc_dumpsys_ap() {
    lc_tmo "${1:-${LHDC_DUMPSYS_TIMEOUT:-20}}" dumpsys media.audio_policy 2>/dev/null
}

# 我们的签名：bluetooth module + LHDC 同时出现
lc_is_patched() {
    [ -f "$1" ] || return 1
    grep -q 'module name="bluetooth"' "$1" 2>/dev/null || return 1
    grep -q 'AUDIO_FORMAT_LHDC' "$1" 2>/dev/null || return 1
    return 0
}

lc_is_stock() {
    [ -f "$1" ] || return 1
    local sz
    sz=$(wc -c < "$1" 2>/dev/null)
    if [ -z "$sz" ] || [ "$sz" -lt 2000 ] 2>/dev/null; then return 1; fi
    lc_is_patched "$1" && return 1
    grep -q '</modules>' "$1" 2>/dev/null || return 1
    return 0
}

lc_pick_awk() {
    [ -n "$LHDC_AWK" ] && return 0
    local c
    for c in awk /system/bin/awk /system/xbin/awk; do
        if command -v "$c" >/dev/null 2>&1; then LHDC_AWK=$c; return 0; fi
    done
    for c in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$c" ] && "$c" awk --help >/dev/null 2>&1; then LHDC_AWK="$c awk"; return 0; fi
    done
    if command -v busybox >/dev/null 2>&1 && busybox awk --help >/dev/null 2>&1; then
        LHDC_AWK="busybox awk"; return 0
    fi
    return 1
}

lc_hal_present() {
    local d
    for d in /vendor/lib64/hw /vendor/lib/hw /odm/lib64/hw /odm/lib/hw /system/lib64/hw /system/lib/hw; do
        [ -f "$d/audio.bluetooth.default.so" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------- 目标定位
lc_has_sku_dirs() {
    local base d
    for base in $LHDC_ETC_ROOTS; do
        [ -d "$base" ] || continue
        for d in "$base"/sku_*; do
            [ -f "$d/audio_policy_configuration.xml" ] && return 0
        done
    done
    return 1
}

lc_find_candidates() {
    local base d
    for base in $LHDC_ETC_ROOTS; do
        [ -d "$base" ] || continue
        for d in "$base"/sku_*; do
            [ -f "$d/audio_policy_configuration.xml" ] && echo "$d/audio_policy_configuration.xml"
        done
    done
    if ! lc_has_sku_dirs; then
        for base in $LHDC_ETC_TOPDIRS; do
            [ -f "$base/audio_policy_configuration.xml" ] && echo "$base/audio_policy_configuration.xml"
        done
    fi
}

# ---- sku 判定：两档线索必须分开，不能混成一个 blob ------------------------
# 第一档是**真正的 sku 名**（bootloader 经 bootconfig 传下来），可以直接和
# sku_xxx 目录名比。顺序即优先级，ro.boot.product.vendor.sku 最具体放最前。
LHDC_SKU_PROPS="ro.boot.product.vendor.sku ro.boot.sku ro.vendor.sku \
ro.vendor.build.sku ro.boot.hardware.sku ro.boot.product.hardware.sku"

# 第二档是**平台名 / SoC 名 / 设备名**，只是弱线索，命中不唯一时不能当结论。
#   ⚠️ v2.1.0 把两档混成一个 blob 做子串匹配，结果 marble 上
#      ro.board.platform=taro 命中了 sku_taro，而真身是 sku_ukee →
#      一次处理两个 sku（其中一个纯属误伤）。平台名迟早会撞上别的 sku 目录名，
#      所以必须分档：权威属性优先且要求唯一命中，弱线索只在权威档全灭时兜底。
lc_props_blob() {
    local p v out=""
    for p in ro.board.platform ro.hardware ro.soc.model \
             ro.boot.device ro.product.device ro.boot.hardware; do
        v=$(getprop "$p" 2>/dev/null)
        [ -n "$v" ] && out="$out $v"
    done
    echo "$out" | tr 'A-Z' 'a-z'
}

# 属性值里是否含 sku 目录名这个词元：按 _ 与空白切词后**整词**比较。
#   ukee      → 命中 ukee
#   ukee_cdp  → 命中 ukee（QTI 的 cdp / mtp / qrd 变体）
#   marble    → 不命中任何 sku（那是设备名，不是 sku 名）
lc_sku_hit() {
    local tok
    for tok in $(echo "$1" | tr 'A-Z' 'a-z' | tr '_' ' '); do
        [ "$tok" = "$2" ] && return 0
    done
    return 1
}

# 候选路径所属的 sku 名；顶层 audio_policy_configuration.xml（无 sku_ 前缀）返回空串
lc_sku_of() {
    local d
    d=$(basename "$(dirname "$1")")
    case "$d" in sku_*) echo "${d#sku_}" ;; *) echo "" ;; esac
}

# 选出要处理的目标（每行一个）
lc_pick_targets() {
    local all blob matched m2 p p2 sn n n2 val first tok
    all=$(lc_find_candidates)
    [ -n "$all" ] || return 1

    # 1) 上次学到的活跃路径最可信
    if [ -s "$LHDC_STATE/active.path" ]; then
        first=$(head -1 "$LHDC_STATE/active.path")
        if [ -f "$first" ]; then echo "$first"; return 0; fi
        rm -f "$LHDC_STATE/active.path" 2>/dev/null
    fi

    # 2) 显式指定 SKU
    if [ -n "$SKU" ]; then
        for p in $all; do
            case "$p" in */sku_"$SKU"/*) echo "$p"; return 0 ;; esac
        done
        lc_log "WARN: SKU=$SKU 未匹配到候选，回退自动判定"
    fi

    # 3) 权威 sku 属性：逐条按优先级试，**命中恰好一个**才采纳
    for p in $LHDC_SKU_PROPS; do
        val=$(getprop "$p" 2>/dev/null)
        [ -n "$val" ] || continue
        m2=""
        for p2 in $all; do
            sn=$(lc_sku_of "$p2")
            [ -n "$sn" ] || continue
            lc_sku_hit "$val" "$sn" && m2="${m2:+$m2 }$p2"
        done
        n2=$(echo $m2 | wc -w)
        if [ "$n2" = 1 ]; then
            lc_log "INFO: sku 由 $p=$val 判定 → sku_$(lc_sku_of "$m2")"
            echo "$m2"
            return 0
        fi
        [ "$n2" -gt 1 ] && lc_log "WARN: $p=$val 命中 $n2 个候选（不唯一），改用下一条属性"
    done

    # 4) 弱线索（平台/SoC/设备名）：先整词
    blob=$(lc_props_blob)
    matched=""
    for p in $all; do
        sn=$(lc_sku_of "$p")
        [ -n "$sn" ] || continue
        for tok in $blob; do
            if [ "$tok" = "$sn" ]; then matched="${matched:+$matched }$p"; break; fi
        done
    done
    # 4b) 整词没结果才退化成子串（老 ROM 的 sku 目录名未必按词元来）
    if [ -z "$matched" ]; then
        for p in $all; do
            sn=$(lc_sku_of "$p")
            [ -n "$sn" ] || continue
            case "$blob" in *"$sn"*) matched="${matched:+$matched }$p" ;; esac
        done
        [ -n "$matched" ] && lc_log "INFO: 弱线索子串匹配命中：$matched（可靠性低）"
    fi
    if [ -n "$matched" ]; then
        for p in $matched; do echo "$p"; done
        return 0
    fi

    # 5) 只有一个候选
    n=$(echo "$all" | wc -l)
    if [ "$n" = 1 ]; then echo "$all"; return 0; fi

    # 6) 多个且无法判定 → 全部处理。每个 sku 都是它自己那款设备的合法配置，
    #    给非活跃 sku 多补一个 bluetooth module 无害，比赌错一个更安全。
    if [ "$PATCH_ALL" = 1 ]; then
        lc_log "INFO: $n 个 sku 候选无法判定活跃项，全部处理（安全兜底）"
        echo "$all"
        return 0
    fi
    lc_log "WARN: 无法判定活跃 sku 且 PATCH_ALL=0 → 放弃"
    return 1
}

# ---------------------------------------------------------------- 原厂备份
# 从分区原始文件直读：普通 mount --bind 只复制单个文件系统、不含子挂载，
# 所以把分区根 bind 到别处后，能读到未被我们覆盖的真实文件。
lc_raw_read() {
    local src="$1" dst="$2" root mnt rel
    case "$src" in
        /vendor/*)     root=/vendor ;;
        /odm/*)        root=/odm ;;
        /system_ext/*) root=/system_ext ;;
        /system/*)     root=/system ;;
        *) return 1 ;;
    esac
    mnt=$LHDC_STATE/raw
    mkdir -p "$mnt" 2>/dev/null
    umount "$mnt" 2>/dev/null
    mount --bind "$root" "$mnt" 2>/dev/null || { umount "$mnt" 2>/dev/null; return 1; }
    rel=${src#"$root"}
    [ -s "$mnt$rel" ] && cat "$mnt$rel" > "$dst" 2>/dev/null
    umount "$mnt" 2>/dev/null
    [ -s "$dst" ] || return 1
    lc_is_patched "$dst" && return 1     # 没绕开，作废
    return 0
}

# 确保原厂备份存在且干净
lc_ensure_golden() {
    local src="$1" key golden
    key=$(lc_key "$src")
    golden=$LHDC_STATE/golden/$key.xml
    mkdir -p "$LHDC_STATE/golden" 2>/dev/null

    if [ -s "$golden" ] && lc_is_stock "$golden"; then return 0; fi

    if lc_is_stock "$src"; then
        cat "$src" > "$golden" 2>/dev/null
        lc_log "BACKUP: $key ← 当前可见原厂 ($(wc -c < "$golden" 2>/dev/null) B)"
    else
        lc_log "INFO: $key 可见内容已是补丁态，改从分区原始文件直读"
        if lc_raw_read "$src" "$golden"; then
            lc_log "BACKUP: $key ← 分区原始文件 ($(wc -c < "$golden" 2>/dev/null) B)"
        else
            rm -f "$golden" 2>/dev/null
            lc_log "ERROR: $key 取不到原厂配置 → 跳过（请先移除其它覆盖方案，或重刷 vendor）"
            return 1
        fi
    fi

    [ -s "$golden" ] || return 1
    md5sum "$golden" 2>/dev/null | cut -d' ' -f1 > "$LHDC_STATE/golden/$key.md5"
    return 0
}

# 把备份导出到 /sdcard（只在 boot_completed 之后做，post-fs-data 阶段 /sdcard 还没挂）
lc_export_backup() {
    local g outdir f
    outdir=/sdcard/lhdc-a2dp-backup
    [ -d /sdcard ] || return 0
    for g in "$LHDC_STATE"/golden/*.xml; do
        [ -f "$g" ] || continue
        f="$outdir/$(basename "$g")"
        [ -f "$f" ] && continue
        mkdir -p "$outdir" 2>/dev/null
        cp -f "$g" "$f" 2>/dev/null && lc_log "EXPORT: 原厂备份已导出到 $f"
    done
    return 0
}

# ---------------------------------------------------------------- 打补丁
# 返回 0 = 已打补丁；2 = 本来就是目标形态；1 = 失败
lc_gen_patched() {
    local golden="$1" out="$2" rc
    lc_pick_awk || { lc_log "ERROR: 找不到可用的 awk（toybox awk / busybox awk 都没有）"; return 1; }
    mkdir -p "$(dirname "$out")" 2>/dev/null
    $LHDC_AWK -f "$MODDIR/lib/patch_policy.awk" "$golden" > "$out.tmp" 2>"$LHDC_STATE/patch.err"
    rc=$?
    if [ "$rc" = 2 ]; then
        cp -f "$golden" "$out" 2>/dev/null
        return 2
    fi
    if [ "$rc" != 0 ] || [ ! -s "$out.tmp" ]; then
        rm -f "$out.tmp"
        lc_log "ERROR: 打补丁失败 rc=$rc $(head -2 "$LHDC_STATE/patch.err" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    mv -f "$out.tmp" "$out" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- 挂载

# ---- 传播隔离工具 ----------------------------------------------------------
# toybox（Android 自带）的 `mount` **不支持** 传播选项：
#     mount --make-private /path   →  "mount: bad /etc/fstab: No such file or directory"
#     mount -o make-private /path  →  同上
# 只有 busybox 的 mount 支持（`--make-private` 与 `-o private` 都行）。
# 这点很关键：拿不到 private，我们挂的层就会留在源挂载（/data）的 peer group 里，
# vold 在开机途中对 /data/user/0、/data_mirror/* 的挂载事件会沿 peer group 把我们
# 的层顶掉 —— 而且 `umount` 任何一个幽灵挂载都会连带卸掉真正的补丁层。
LHDC_PRIV=""
LHDC_PRIV_TRIED=0
lc_pick_priv() {
    [ "$LHDC_PRIV_TRIED" = 1 ] && { [ -n "$LHDC_PRIV" ]; return $?; }
    LHDC_PRIV_TRIED=1
    local c
    for c in "$MODDIR/busybox" /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
             /data/adb/ap/bin/busybox /data/adb/magisk/busybox.static; do
        [ -x "$c" ] && { LHDC_PRIV=$c; break; }
    done
    if [ -z "$LHDC_PRIV" ]; then
        c=$(command -v busybox 2>/dev/null)
        [ -n "$c" ] && [ -x "$c" ] && LHDC_PRIV=$c
    fi
    [ -n "$LHDC_PRIV" ]
}

# 把 $1 的挂载设为 private。成功返回 0；没有任何可用工具时返回 1（调用方必须据此降级）
lc_make_private() {
    local p="$1"
    lc_pick_priv || return 1
    "$LHDC_PRIV" mount --make-private "$p" 2>/dev/null && return 0
    "$LHDC_PRIV" mount -o private "$p"      2>/dev/null && return 0
    return 1
}

# 读取 $1 所在挂载（不含 $1 自身）的传播模式 → shared | slave | private | unknown
lc_prop_mode() {
    awk -v p="$1" '
        {
            mp = $5
            if (mp == p) next
            if (index(p, mp) != 1) next
            if (length(mp) > length(best)) { best = mp; line = $0 }
        }
        END {
            if (best == "") { print "unknown"; exit }
            n = split(line, f, " ")
            for (i = 6; i <= n; i++) {
                if (f[i] ~ /^shared:/)        { print "shared";  exit }
                if (f[i] ~ /^master:/)        { print "slave";   exit }
                if (f[i] ~ /^propagate_from/) { print "slave";   exit }
                if (f[i] == "-")              break
            }
            print "private"
        }' /proc/self/mountinfo 2>/dev/null
}

# 读取「挂在 $1 上的那一层」**自身**的传播模式 → shared | slave | private | (无挂载)
# ⚠️ 与 lc_prop_mode 的关键区别：后者会跳过 $1 自身，返回**包含它的父挂载**的模式。
#    用它来显示"当前层模式"会取到父挂载（/vendor 常年是 shared），把已经 private 的
#    层误报成 shared —— 曾因此让诊断输出与 /proc/self/mountinfo 直接矛盾。
#    有堆叠挂载时取**最后一行**（= 最上层，即真正生效的那层）。
lc_self_mode() {
    awk -v p="$1" '
        $5 == p { line = $0 }
        END {
            if (line == "") { print "(无挂载)"; exit }
            n = split(line, f, " ")
            for (i = 6; i <= n; i++) {
                if (f[i] ~ /^shared:/)        { print "shared";  exit }
                if (f[i] ~ /^master:/)        { print "slave";   exit }
                if (f[i] ~ /^propagate_from/) { print "slave";   exit }
                if (f[i] == "-")              break
            }
            print "private"
        }' /proc/self/mountinfo 2>/dev/null
}

# 摘掉挂在 $1 上的"幽灵挂载"。
# 背景：源文件在 /data（shared）上时，bind 出来的层会加入 /data 的 peer group，
# 并反向在源路径复制出一份"幽灵挂载"盖住源文件自己。
# ⚠️ 只有在**成功 make-private 之后**才能 umount：否则这次 umount 会沿 peer group
#    传播，把真正的补丁层一起卸掉（v2.0.1 就栽在这里）。
lc_clear_ghost() {
    local src="$1" n=0
    [ -n "$src" ] || return 0
    while [ "$n" -lt 8 ] && grep -q " $src " /proc/self/mountinfo 2>/dev/null; do
        if ! lc_make_private "$src"; then
            lc_log "WARN: 无法把 $src 置 private（缺 busybox），跳过幽灵挂载清理以免误伤补丁层"
            return 1
        fi
        umount "$src" 2>/dev/null || break
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && lc_log "CLEAN: 源路径 $src 摘除 $n 层幽灵挂载"
    return 0
}

lc_unmount_dst() {
    local dst="$1" n=0
    while [ "$n" -lt 8 ] && grep -q " $dst " /proc/self/mountinfo 2>/dev/null; do
        # 能 private 就 private；不能也无妨 —— 从最顶层往下卸，卸载传播只会顺带
        # 清掉我们自己的幽灵副本，不会碰到别的层。
        lc_make_private "$dst"
        umount "$dst" 2>/dev/null || break
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] && lc_log "CLEAN: $dst 卸下 $n 层旧挂载"
    return 0
}

# $1 兜底源(原厂)  $2 主源(补丁)  $3 目标路径
lc_mount_overlay() {
    local base="$1" src="$2" dst="$3" okpriv=1 m

    lc_unmount_dst "$dst"

    # ---- 关键修正（v2.0.1）：每挂一层立刻 make-private，不能只在最后做一次 ----
    # 我们的源文件在 /data 上，而 /data 是 shared peer group 成员。Linux 规定：
    # 「从 shared 挂载的子树 bind 出来的新挂载，会加入**源挂载**的 peer group」。
    # 于是挂在 /vendor/etc/... 上的这层也变成了 /data、/data/user/0、/data_mirror/*
    # 的 peer —— 开机途中 vold 对 /data/user/0、/data_mirror/* 的挂载/卸载会沿
    # peer group 传播过来，把我们的层顶掉。现象：post-fs-data 明明打上了，
    # late_start 校验却是 BAD，audioserver 读到原厂配置（能协商 LHDC 却没声音）。
    # 旧代码只在最顶层做一次 make-private，兜底层会留在 peer group 里 →
    # 整个 overlay 仍随 /data 的挂载事件抖动。
    if [ -n "$base" ] && [ -f "$base" ]; then
        chcon u:object_r:vendor_configs_file:s0 "$base" 2>/dev/null
        if mount --bind "$base" "$dst" 2>/dev/null; then
            lc_make_private "$dst"
            m=$(lc_self_mode "$dst")
            # 日志以**实测**为准，不写乐观常量：v2.0.1 就是既把 make-private 的
            # 失败 2>/dev/null 吞掉、又硬编码打印"（private）"，日志才长期撒谎。
            if [ "$m" = private ]; then
                lc_log "BASE: 兜底层已挂载（实测 private）"
            else
                okpriv=0
                lc_log "BASE: 兜底层已挂载，但实测传播模式=$m（未隔离）"
            fi
        else
            okpriv=0
            lc_log "BASE: 兜底层挂载失败"
        fi
    else
        lc_log "WARN: 无兜底源，DST 一旦顶层失败就会暴露分区原文件"
    fi
    if [ -f "$src" ]; then
        chcon u:object_r:vendor_configs_file:s0 "$src" 2>/dev/null
        if mount --bind "$src" "$dst" 2>/dev/null; then
            lc_make_private "$dst"
            m=$(lc_self_mode "$dst")
            if [ "$m" = private ]; then
                lc_log "TOP : 补丁层已挂载（实测 private）"
            else
                okpriv=0
                lc_log "TOP : 补丁层已挂载，但实测传播模式=$m（未隔离）"
            fi
        else
            okpriv=0
            lc_log "TOP : 补丁层挂载失败"
        fi
    fi
    [ "$okpriv" = 0 ] && lc_log "WARN: 层未隔离，仍可能被 /data 的挂载事件波及；service 阶段有运行态兜底"

    # 源文件名每次 apply 都唯一（见 lc_apply_all），所以不需要去卸幽灵挂载：
    # 那些幽灵只落在本次已不再使用的名字上，卸它反而可能沿 peer group 误伤补丁层。
    # golden 从不作挂载源，理论上不会有幽灵，这里只做一次无害的兜底检查。
    lc_clear_ghost "$LHDC_STATE/golden/$(lc_key "$dst").xml" >/dev/null 2>&1

    if lc_is_patched "$dst"; then
        lc_log "RESULT: OK — $(lc_key "$dst") 生效"
        return 0
    fi
    lc_log "RESULT: FAIL — $(lc_key "$dst") 未生效"
    return 1
}

# ---------------------------------------------------------------- 属性纠正
lc_fix_offload_prop() {
    [ "$OFFLOAD_FIX" = 1 ] || return 0
    local sup dis
    sup=$(getprop ro.bluetooth.a2dp_offload.supported 2>/dev/null)
    dis=$(getprop persist.bluetooth.a2dp_offload.disabled 2>/dev/null)
    if [ "$dis" = "true" ]; then
        if [ "$sup" = "true" ] || [ "$FORCE" = 1 ]; then
            setprop persist.bluetooth.a2dp_offload.disabled false 2>/dev/null
            lc_log "PROP : a2dp_offload.disabled true → false（offload 通路必须开，禁用会彻底无声）"
        else
            lc_log "INFO : a2dp_offload.disabled=true 但 supported≠true，保持原样"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------- 主流程
lc_gate() {
    local sdk
    sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    case "$sdk" in ''|*[!0-9]*) sdk=0 ;; esac
    if [ "$sdk" -lt "$MIN_SDK" ] 2>/dev/null && [ "$FORCE" != 1 ]; then
        lc_log "SKIP: SDK=$sdk < $MIN_SDK —— AOSP 的 LHDC 编码器自 Android 17 起才内置"
        return 1
    fi
    if ! lc_hal_present && [ "$FORCE" != 1 ]; then
        lc_log "SKIP: 未找到 audio.bluetooth.default.so（AOSP 蓝牙音频 HAL）"
        return 1
    fi
    return 0
}

lc_apply_all() {
    local dst key golden patched work tag
    local ok=0 fail=0

    lc_gate || return 1
    lc_fix_offload_prop

    local targets
    targets=$(lc_pick_targets) || { lc_log "SKIP: 找不到可处理的 audio_policy_configuration.xml"; return 1; }

    # 每次 apply 用唯一的 tag 命名挂载源，这样绝不会有"上一次留下的幽灵挂载"
    # 盖住这次要用的文件（同一个 boot 里 service 阶段可能再补做一次）。
    tag="$$.$(date +%s 2>/dev/null)"
    mkdir -p "$LHDC_STATE/patched" "$LHDC_STATE/work" 2>/dev/null
    # 清掉历史副本；被幽灵挂载盖住的会删不掉（EBUSY），忽略即可 —— 下次开机会清成功
    rm -f "$LHDC_STATE"/work/*.xml "$LHDC_STATE"/patched/*.xml 2>/dev/null

    for dst in $targets; do
        key=$(lc_key "$dst")
        golden=$LHDC_STATE/golden/$key.xml
        patched=$LHDC_STATE/patched/$key.$tag.xml
        work=$LHDC_STATE/work/$key.$tag.xml

        lc_log "---- 目标 $key ($dst)"
        # golden 从不作挂载源 → 理论上不会有幽灵；这里只做廉价的安全检查
        lc_clear_ghost "$golden" >/dev/null 2>&1

        lc_ensure_golden "$dst" || { fail=$((fail + 1)); continue; }
        lc_gen_patched "$golden" "$patched" || { fail=$((fail + 1)); continue; }
        # 兜底工作副本从 golden 刷新。文件名带本次 apply 的唯一 tag，
        # 保证它不会是被幽灵挂载盖住的旧路径。
        cp -f "$golden" "$work" 2>/dev/null
        if lc_mount_overlay "$work" "$patched" "$dst"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done

    lc_log "=== 汇总: 成功 $ok / 失败 $fail ==="
    [ "$ok" -gt 0 ]
}

lc_verify() {
    local dst bad=0
    local targets
    targets=$(lc_pick_targets 2>/dev/null) || return 1
    [ -n "$targets" ] || return 1
    for dst in $targets; do
        if lc_is_patched "$dst"; then
            lc_log "VERIFY OK: $(lc_key "$dst")"
        else
            lc_log "VERIFY BAD: $(lc_key "$dst") 未生效"
            bad=$((bad + 1))
        fi
    done
    [ "$bad" = 0 ]
}

# -- 运行态校验 ---------------------------------------------------------------
# 文件级挂载生效 ≠ audioserver 加载了它。audioserver 在 main class 启动
# （本机约开机第 11 秒），如果补丁层在那之前掉了或还没打上，它读的就是原厂
# 配置 —— 表现为"能协商 LHDC 但完全没声音"。这里用运行时转储做最终判定：
# 原厂配置里绝不会出现 AUDIO_FORMAT_LHDC，出现即说明加载的是补丁版。
lc_ensure_running() {
    local dump n
    dump=$(lc_dumpsys_ap)
    if [ -z "$dump" ]; then
        lc_log "AUDIO: 拿不到 audio_policy 转储，跳过运行态校验"
        return 0
    fi
    case "$dump" in
        *AUDIO_FORMAT_LHDC*)
            lc_log "AUDIO: 运行中的策略已含 LHDC ✓"
            lc_check_a2dp_profile "$dump" || lc_log "WARN: A2DP 采样率自检未通过 → 蓝牙可能无声（见上）"
            return 0 ;;
    esac

    lc_log "AUDIO: 运行中的策略仍是旧版（audioserver 起得比挂载早）→ 重启 audioserver 重载"
    lc_tmo 10 setprop ctl.restart audioserver 2>/dev/null
    # 总等待有上界：设备高负载时单次 dumpsys 就可能耗掉超时上限，
    # 所以这里用更短的探测超时（8s）× 10 轮，最坏约 100s 收尾，
    # 不会让 service.sh 无限期挂在开机阶段。
    n=0
    while [ "$n" -lt 10 ]; do
        sleep 2
        n=$((n + 1))
        dump=$(lc_dumpsys_ap 8)
        case "$dump" in
            *AUDIO_FORMAT_LHDC*)
                lc_log "AUDIO: audioserver 已重载补丁策略 ✓（等待 $((n * 2))s）"
                lc_check_a2dp_profile "$dump" || lc_log "WARN: A2DP 采样率自检未通过 → 蓝牙可能无声（见上）"
                return 0 ;;
        esac
    done
    lc_log "WARN: 重启 audioserver 后运行态仍未含 LHDC，请检查挂载是否被覆盖"
    return 1
}

# 运行态自检：确认 a2dp output 这个输出档的**采样率真的被解析出来了**。
# 参数：audio_policy 的 dumpsys 转储文本
#
# ★ 为什么必须单独查这一项（2026-09-18 在 Redmi K20 Pro 上踩到的坑）
#   XML 里「列表型属性」的分隔符风格写错时，解析器**不会报任何错**，
#   只会把该 profile 悄悄降级成 "[dynamic rates]"（采样率表为空）。随后：
#       W APM_AudioPolicyManager: openOutputWithProfileAndDevice() missing param
#       W APM_AudioPolicyManager: checkOutputsForDevice(): No output available for device 0080
#   → A2DP 输出永远建不起来 → A2DP 设备永远不可用（AudioDeviceInventory 报
#   "APM failed to make available A2DP device"）→ 蓝牙彻底无声。
#   全链路没有半条显式错误，而且本模块的 LHDC 声明检查照样全绿
#   （因为 encodedFormats 是对的、只有 samplingRates 崩了），极易漏判。
#   分隔符风格实测随 ROM 而变（K20 Pro 用逗号 / POCO F5 用空格），
#   patch_policy.awk 会自动跟随原厂文件；这里是它的运行态对账。
lc_check_a2dp_profile() {
    local seg
    [ -n "$1" ] || { lc_log "A2DP: 无转储，跳过采样率解析自检"; return 0; }
    # 只取「mixPorts 段里那个条目」——routes 段也有 Sources: "a2dp output"，别混进来
    seg=$(printf '%s\n' "$1" | awk '
        /^[ \t]*[0-9]+\. "a2dp output"/ { inb = 1 }
        inb { print; if (++n >= 10) exit }')
    case "$seg" in
        *"sampling rates:"*)
            lc_log "A2DP: a2dp output 采样率已正确解析 ✓"
            return 0 ;;
        *"[dynamic rates]"*)
            lc_log "ERROR: a2dp output 的采样率解析失败（[dynamic rates]）→ A2DP 输出打不开、蓝牙无声"
            lc_log "       原因：XML 列表分隔符风格与该 ROM 不符。看本次 patch 日志的 separator 行"
            return 1 ;;
    esac
    lc_log "A2DP: 未能判定 a2dp output 采样率状态（未提取到该条目）"
    return 0
}

# 从正在运行的 audioserver 反查它真正加载了哪个策略文件，供下次开机直接使用
lc_learn_active() {
    local pid found p
    for pid in $(pidof audioserver 2>/dev/null); do
        found=$(ls -l /proc/$pid/fd 2>/dev/null | grep -oE '/(vendor|odm|system_ext|system)/[^ ]*audio_policy_configuration\.xml' | head -1)
        [ -n "$found" ] && break
        found=$(grep -oE '/(vendor|odm|system_ext|system)/[^ ]*audio_policy_configuration\.xml' /proc/$pid/maps 2>/dev/null | head -1)
        [ -n "$found" ] && break
    done
    if [ -z "$found" ]; then
        found=$(logcat -d -b all 2>/dev/null | grep -oE '/(vendor|odm)/etc/audio/[a-zA-Z0-9_/]*audio_policy_configuration\.xml' | sort -u | head -1)
    fi
    [ -n "$found" ] || return 0
    [ -f "$found" ] || return 0
    # 只接受我们候选列表里的路径，避免学到无关文件
    for p in $(lc_find_candidates); do
        if [ "$p" = "$found" ]; then
            echo "$found" > "$LHDC_STATE/active.path"
            lc_log "LEARN: 活跃策略 = $found（下次开机直接用它）"
            return 0
        fi
    done
    return 0
}

lc_report() {
    local base=$1
    echo "=== lhdc-a2dp-universal 诊断 ==="
    echo "SDK            : $(getprop ro.build.version.sdk)  (MIN_SDK=$MIN_SDK, FORCE=$FORCE)"
    echo "AOSP BT HAL    : $(lc_hal_present && echo yes || echo NO)"
    echo "awk            : $(lc_pick_awk && echo "$LHDC_AWK" || echo MISSING)"
    echo "offload 属性   : supported=$(getprop ro.bluetooth.a2dp_offload.supported) disabled=$(getprop persist.bluetooth.a2dp_offload.disabled)"
    echo "--- 候选策略文件 ---"
    lc_find_candidates | while read -r p; do
        echo "  $(lc_key "$p")  [$(wc -c < "$p" 2>/dev/null) B]  $(lc_is_patched "$p" && echo 已补丁 || echo 原厂)"
    done
    [ -n "$base" ] && echo "强制目标       : $base"
    echo "--- 选中的目标 ---"
    local t
    t=$(lc_pick_targets) || t="(无)"
    for p in $t; do echo "  $p"; done
    echo "--- state 目录 ---"
    ls -l "$LHDC_STATE/golden" 2>/dev/null | tail -n +2 | awk '{print "  " $NF "  (" $5 " B)"}'
    echo "--- 当前挂载层（[传播模式] 挂载点 ← 源） ---"
    if grep -q audio_policy /proc/self/mountinfo 2>/dev/null; then
        grep audio_policy /proc/self/mountinfo | awk '
            {
                sep = 0; mode = "private"
                for (i = 6; i <= NF; i++) {
                    if ($i == "-")              { sep = i; break }
                    if ($i ~ /^shared:/)        mode = "shared"
                    if ($i ~ /^master:/)        mode = "slave"
                    if ($i ~ /^propagate_from/) mode = "slave"
                }
                printf "  [%-7s] %s\n                  ← %s\n", mode, $5, (sep ? $(sep + 2) : "?")
            }'
    else
        echo "  (无)"
    fi
    echo "--- 源侧传播模式（shared 是危险信号） ---"
    local st
    st=$(lc_pick_targets 2>/dev/null)
    for p in $st; do
        echo "  $p  ← 父挂载 $(lc_prop_mode "$(dirname "$p")")"
    done
    echo "--- 传播隔离能力 ---"
    if lc_pick_priv; then
        echo "  private 工具: $LHDC_PRIV （busybox，支持 --make-private）"
    else
        echo "  未找到 busybox → 层无法置 private（toybox 的 mount 不支持）"
        echo "  影响：补丁层会留在 /data 的 peer group 中，可能被开机挂载事件顶掉"
    fi
    echo "--- 运行态（audioserver 是否真的加载了补丁策略） ---"
    if lc_dumpsys_ap | grep -q AUDIO_FORMAT_LHDC; then
        echo "  OK — 运行中的策略含 AUDIO_FORMAT_LHDC"
    else
        echo "  旧版 — 运行中的策略不含 LHDC（需重启 audioserver 重载）"
    fi
    echo "--- 最近日志 ---"
    tail -12 "$LHDC_LOG" 2>/dev/null | sed 's/^/  /'
    [ -s "$LHDC_LOG" ] || echo "  (暂无)"
    return 0
}
