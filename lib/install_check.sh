#!/system/bin/sh
# ============================================================================
# install_check.sh — 安装期适用范围检查（只被 customize.sh 使用）
# ----------------------------------------------------------------------------
# 为什么要有它：
#   本模块的适用范围很窄（Android 17 + audio.bluetooth.default.so + 策略文件里
#   有 A2DP 端口）。不满足时装进去也不会出声，只会在 post-fs-data 里打一行
#   SKIP 就退出 —— 用户看到的是「装成功了却毫无反应」，日志还藏在
#   state/run.log 里，极难自查。所以把判定提前到安装阶段，并把结论直接打到
#   root 管理器的安装控制台上：符合就继续装，不符合就 abort 并指明哪条不满足。
#
# 硬性要求（任一不满足 → 中止安装；FORCE=1 可强制继续）：
#   1. awk 可用（补丁器 lib/patch_policy.awk 靠它执行）
#   2. Android SDK >= MIN_SDK（默认 37）
#   3. 找得到 audio.bluetooth.default.so
#   4. 找得到候选 audio_policy_configuration.xml
#   5. 补丁器对该文件**试运行**成功（退出码 0=可打补丁 / 2=已是目标形态）
#
# 软性提示（只警告，不阻止安装）：
#   · /apex/com.android.bt 是否存在（AOSP 蓝牙栈形态）
#   · busybox 是否可用于 mount --make-private（层隔离能力）
#   · a2dp_offload.disabled 当前值（运行期会被自动纠正）
#
# 约束：本文件内**所有操作都必须只读**。调用方已把 DRY_RUN 置 1（common.sh 里
#       所有写原语的总闸门），这里再自己保证不调用任何写函数 —— 检查失败时
#       设备上除控制台输出外不应留下任何痕迹。
# ============================================================================

# ---------------------------------------------------------------- 控制台输出
# Magisk / KernelSU / APatch 都提供 ui_print 与 abort；缺失时降级为 echo / exit 1。
# ⚠️ 优先用 root 管理器自带的 abort：它会把安装标记为**失败**。只 exit 1 而不调
#    abort 时，部分管理器会照旧把安装标成成功（目录已经解压完了）。
lc_ic_print() {
    if command -v ui_print >/dev/null 2>&1; then
        ui_print "$*"
    else
        printf '%s\n' "$*"
    fi
}

lc_ic_abort() {
    lc_ic_print ""
    lc_ic_print "!!! $*"
    if command -v abort >/dev/null 2>&1; then
        abort "$*"
        exit 1                      # 万一某个实现的 abort 不退出
    fi
    printf '%s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------- 结论收集
LC_IC_HARD=""
LC_IC_SOFT=""

lc_ic_hard() { LC_IC_HARD="${LC_IC_HARD}$1
"; }
lc_ic_soft() { LC_IC_SOFT="${LC_IC_SOFT}$1
"; }

# 把多行变量按行打印成 "   - xxx"
lc_ic_bullets() {
    [ -n "$1" ] || return 0
    printf '%s' "$1" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        lc_ic_print "   - $line"
    done
}

lc_ic_version() {
    local v
    v=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)
    [ -n "$v" ] && printf '%s' "$v" || printf '?'
}

# ---------------------------------------------------------------- 主检查
# 返回 0 = 可以安装；1 = 不满足适用范围（调用方应 abort）
lc_install_check() {
    local sdk min hal cands n awk_ok=1 patchable=0 probe rc verdict cand

    lc_ic_print "****************************************"
    lc_ic_print " LHDC A2DP Enabler — 安装前适用范围检查"
    lc_ic_print "****************************************"
    lc_ic_print " 模块 : $LHDC_ID $(lc_ic_version)"
    lc_ic_print " 设备 : $(getprop ro.product.device 2>/dev/null) / $(getprop ro.product.model 2>/dev/null)"
    lc_ic_print " 固件 : $(getprop ro.vendor.build.fingerprint 2>/dev/null)"
    lc_ic_print " 配置 : MIN_SDK=$MIN_SDK FORCE=$FORCE SKU=${SKU:-（自动）} PATCH_ALL=$PATCH_ALL"
    lc_ic_print ""

    # ---- 1. awk：没有它就生成不出补丁策略 ----
    if lc_pick_awk; then
        lc_ic_print " [OK] awk 补丁器       : $LHDC_AWK"
    else
        awk_ok=0
        lc_ic_print " [X]  awk 补丁器       : 缺失"
        lc_ic_hard "找不到可用的 awk（toybox / busybox 都没有）。补丁器 lib/patch_policy.awk 必须由 awk 执行，缺它无法生成补丁策略文件"
    fi

    # ---- 2. Android 版本 ----
    min=$MIN_SDK
    case "$min" in ''|*[!0-9]*) min=37 ;; esac
    sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    case "$sdk" in ''|*[!0-9]*) sdk=0 ;; esac
    if [ "$sdk" -ge "$min" ] 2>/dev/null; then
        lc_ic_print " [OK] Android SDK      : $sdk（要求 >= $min）"
    else
        lc_ic_print " [X]  Android SDK      : $sdk（要求 >= $min）"
        lc_ic_hard "Android 版本不满足：SDK=$sdk < MIN_SDK=$min。AOSP 的 LHDCv5 编码器自 Android 17（SDK 37）起才内置，低版本上补这条路由不会有 LHDC 声音"
    fi

    # ---- 3. AOSP 蓝牙音频 HAL ----
    if hal=$(lc_hal_path); then
        lc_ic_print " [OK] 蓝牙音频 HAL     : $hal"
    else
        lc_ic_print " [X]  蓝牙音频 HAL     : 未找到 audio.bluetooth.default.so"
        lc_ic_hard "缺少 audio.bluetooth.default.so（AOSP 蓝牙音频 HAL）。本模块的原理是让 AudioPolicyManager 打开这个 HAL 的 a2dp output 走软件编码；没有它，新建的 bluetooth module 必然加载失败。MTK / 纯厂商 HAL 设备通常就是这种情况"
    fi

    # ---- 4. 候选策略文件 + 5. 补丁器试运行 ----
    cands=$(lc_find_candidates 2>/dev/null)
    n=0
    [ -n "$cands" ] && n=$(printf '%s\n' "$cands" | grep -c .)

    if [ "$n" -eq 0 ]; then
        lc_ic_print " [X]  策略文件         : 未找到候选"
        lc_ic_hard "在 $LHDC_ETC_ROOTS 下找不到 audio_policy_configuration.xml；没有可处理的策略文件，模块无从下手"
    else
        lc_ic_print " [OK] 策略文件         : 找到 $n 个候选"
        for cand in $cands; do
            if [ "$awk_ok" = 1 ]; then
                # 只读试运行：stdout 丢弃，stderr 收下来（里面有一行 separator 提示）
                probe=$($LHDC_AWK -f "$MODDIR/lib/patch_policy.awk" "$cand" 2>&1 >/dev/null)
                rc=$?
            else
                rc=9
            fi
            case "$rc" in
                0) verdict="可打补丁";       patchable=$((patchable + 1)) ;;
                2) verdict="已是目标形态";   patchable=$((patchable + 1)) ;;
                *) verdict="补丁器无法处理（rc=$rc）" ;;
            esac
            lc_ic_print "        · $cand"
            lc_ic_print "          → $verdict"
            case "$probe" in
                *separator*) lc_ic_print "          → $probe" ;;
            esac
        done
        if [ "$patchable" = 0 ]; then
            lc_ic_hard "补丁器对所有候选策略文件都试运行失败。通常是文件里没有 AUDIO_DEVICE_OUT_BLUETOOTH_A2DP 端口，或缺少 </modules> 收尾标签 —— 这类设备不需要也接不上本模块"
        fi
    fi

    # ---- 软提示：AOSP 蓝牙栈形态 ----
    if [ -d /apex/com.android.bt ]; then
        lc_ic_print " [OK] AOSP 蓝牙栈      : /apex/com.android.bt"
    else
        lc_ic_print " [--] AOSP 蓝牙栈      : 未找到 /apex/com.android.bt"
        lc_ic_soft "未找到 /apex/com.android.bt。本模块针对 AOSP 蓝牙栈（APEX com.android.bt）+ 高通 PAL 的混合架构；不是这种形态时通常不需要它"
    fi

    # ---- 软提示：private 隔离能力 ----
    if lc_pick_priv; then
        lc_ic_print " [OK] 传播隔离工具     : $LHDC_PRIV"
    else
        lc_ic_print " [--] 传播隔离工具     : 无可用 busybox"
        lc_ic_soft "找不到 busybox：toybox 的 mount 不支持 --make-private，补丁层会留在 /data 的 peer group 里，可能被开机挂载事件顶掉（有运行态兜底，但可靠性下降）"
    fi

    lc_ic_print " [--] offload 属性     : supported=$(getprop ro.bluetooth.a2dp_offload.supported 2>/dev/null) disabled=$(getprop persist.bluetooth.a2dp_offload.disabled 2>/dev/null)"

    # ---- 结论 ----
    lc_ic_print "----------------------------------------"
    if [ -n "$LC_IC_SOFT" ]; then
        lc_ic_print " 提示（不影响安装）:"
        lc_ic_bullets "$LC_IC_SOFT"
        lc_ic_print ""
    fi

    if [ -z "$LC_IC_HARD" ]; then
        lc_ic_print " 结论: 符合适用范围 → 继续安装"
        lc_ic_print " 注意: 安装成功 ≠ 已经出声。重启后由 post-fs-data 打补丁并挂载，"
        lc_ic_print "       验证方法见 README「验证是否生效」那节"
        return 0
    fi

    lc_ic_print " 结论: 不符合适用范围，安装将中止"
    lc_ic_print ""
    lc_ic_print " 不符合的要求:"
    lc_ic_bullets "$LC_IC_HARD"
    lc_ic_print ""

    if [ "$FORCE" = 1 ]; then
        lc_ic_print " 但你设了 FORCE=1 → 强制继续安装（不推荐，很可能装完也无声）"
        return 0
    fi

    lc_ic_print " 处理办法:"
    lc_ic_print "   · 换满足条件的设备/ROM（Android 17 + AOSP 蓝牙栈 + 高通 PAL 混合架构）"
    lc_ic_print "   · 确认要强上：在模块目录 lhdc.conf 里设 FORCE=1 后重新安装"
    lc_ic_print "   · 只想看诊断：不装模块，直接跑 post-fs-data.sh --dry-run"
    return 1
}
