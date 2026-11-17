#!/system/bin/sh
# bg-lib.sh — 旁路供电守护 v1.2 公共函数库
#
# v1.2 核心改动：不再往"输入开关"上写 1，而是走小米充电驱动的官方停充位
#   /sys/class/qcom-battery/smart_chg = 0x{电量<<16 | 标志位}
#   标志位 0x3 = 导航模式 + 生效位（安全中心「导航断充保护」用的就是这个）
# 驱动自己保持该状态（拔插都不丢），所以稳态下不需要周期重申。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
SYS=${SYSFS_ROOT:-}
DATA_DIR=${DATA_DIR_OVERRIDE:-/data/adb/bypass_guard}
CONF=$DATA_DIR/config.conf
STATE=$DATA_DIR/state
BPFILE=$DATA_DIR/bp_on
LOGFILE=$DATA_DIR/bypass.log

mkdir -p "$DATA_DIR" 2>/dev/null

# ---- 节点 ----
QB=$SYS/sys/class/qcom-battery
SMART_CHG=$QB/smart_chg
INPUT_SUSPEND=$QB/input_suspend

DEFAULT_CONF='ENABLED=1
MODE=auto
THRESHOLD_ON=80
THRESHOLD_OFF=70
POLL=3
BACKEND=smartchg
SMART_MODE=3
FALLBACK=1
NOTIFY=0'

[ -f "$CONF" ] || printf '%s\n' "$DEFAULT_CONF" > "$CONF"

load_conf() {
  . "$CONF" 2>/dev/null
  [ -z "$POLL" ] && POLL=3
  [ -z "$THRESHOLD_ON" ] && THRESHOLD_ON=80
  [ -z "$THRESHOLD_OFF" ] && THRESHOLD_OFF=70
  [ -z "$MODE" ] && MODE=auto
  [ -z "$ENABLED" ] && ENABLED=1
  [ -z "$NOTIFY" ] && NOTIFY=0
  [ -z "$BACKEND" ] && BACKEND=smartchg
  [ -z "$SMART_MODE" ] && SMART_MODE=3
  [ -z "$FALLBACK" ] && FALLBACK=1
}

save_conf() {
  cat > "$CONF" <<EOF
ENABLED=$ENABLED
MODE=$MODE
THRESHOLD_ON=$THRESHOLD_ON
THRESHOLD_OFF=$THRESHOLD_OFF
POLL=$POLL
BACKEND=$BACKEND
SMART_MODE=$SMART_MODE
FALLBACK=$FALLBACK
NOTIFY=$NOTIFY
EOF
}

set_key() {
  k=$1; v=$2
  if grep -q "^$k=" "$CONF" 2>/dev/null; then
    sed -i "s|^$k=.*|$k=$v|" "$CONF"
  else
    echo "$k=$v" >> "$CONF"
  fi
}

logi() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOGFILE" 2>/dev/null
  if [ -f "$LOGFILE" ]; then
    n=$(wc -l < "$LOGFILE" 2>/dev/null)
    if [ "${n:-0}" -gt 400 ]; then
      tail -200 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
    fi
  fi
}

rd() { cat "$1" 2>/dev/null; }

find_bat() {
  BAT_DIR=""
  for d in $SYS/sys/class/power_supply/*; do
    [ -f "$d/type" ] || continue
    if [ "$(rd "$d/type")" = "Battery" ]; then
      BAT_DIR=$d
      break
    fi
  done
  [ -z "$BAT_DIR" ] && BAT_DIR=$SYS/sys/class/power_supply/battery
}

absnum() {   # 去符号、去非数字
  v=${1#-}
  case "$v" in ''|*[!0-9]*) echo 999999999 ;; *) echo "$v" ;; esac
}

batt_info() {
  LEVEL=$(rd "$BAT_DIR/capacity");  [ -z "$LEVEL" ]  && LEVEL=0
  STATUS=$(rd "$BAT_DIR/status");   [ -z "$STATUS" ] && STATUS=Unknown
  CUR=$(rd "$BAT_DIR/current_now"); [ -z "$CUR" ]    && CUR=0
  VOL=$(rd "$BAT_DIR/voltage_now"); [ -z "$VOL" ]    && VOL=0
  TMP=$(rd "$BAT_DIR/temp");        [ -z "$TMP" ]    && TMP=0
  # CUR 带符号：负=充电，正=放电/停充。POWER 只用于显示
  # 带符号：充电为正、放电（没插电）为负。current_now 负=充电，所以要取反
  POWER=$(awk -v v="$VOL" -v c="$CUR" 'BEGIN{printf "%.2f", -(v*c)/1e12}' 2>/dev/null)
  [ -z "$POWER" ] && POWER=0.00
}

# 停充判定：电池电流接近 0
is_stopped() {
  c=$(absnum "$CUR")
  [ "$c" -lt 120000 ]
}

# 充电判定：明显在充电
is_charging() {
  case "$CUR" in
    -*) c=$(absnum "$CUR"); [ "$c" -gt 300000 ] ;;
    *) return 1 ;;
  esac
}

on_charger() {
  # 1) usb/ac/wireless 的 online|present
  for p in usb ac wireless dc; do
    for f in online present; do
      ff=$SYS/sys/class/power_supply/$p/$f
      if [ -f "$ff" ]; then
        [ "$(rd "$ff")" = "1" ] && return 0
      fi
    done
  done
  # 2) VBUS 电压兜底（旁路中 online 偶尔短暂为 0，但 VBUS 还在）
  v=$(absnum "$(rd "$SYS/sys/class/power_supply/usb/voltage_now")")
  [ "$v" -gt 4000000 ] && return 0
  # 3) 状态字兜底
  case "$STATUS" in
    Charging*|Full*|"Not charging") return 0 ;;
  esac
  return 1
}

# ---------------- smart_chg 官方停充位 ----------------

smart_present() { [ -e "$SMART_CHG" ] && [ -w "$SMART_CHG" ]; }

smart_set() {          # $1 = 停充电量
  smart_present || return 1
  v=$(printf '0x%x' $(( ($1 << 16) | SMART_MODE )) 2>/dev/null)
  [ -z "$v" ] && return 1
  echo "$v" > "$SMART_CHG" 2>/dev/null || return 1
  logi "smart_set $v (level=$1 mode=$SMART_MODE)"
  return 0
}

smart_clear() {        # 实测：只写 0 有时解不掉，必须先 0x2 再 0
  smart_present || return 1
  echo 0x2 > "$SMART_CHG" 2>/dev/null
  sleep "${CLEAR_GAP:-3}"
  echo 0 > "$SMART_CHG" 2>/dev/null
  logi "smart_clear done"
  return 0
}

# 该写多少"停充电量"：
#   auto     → THRESHOLD_ON（这时 LEVEL 已经 ≥ 阈值，写进去立刻生效）
#   force_on → 当前电量（用户点"立即旁路"时不管阈值，马上停）
smart_target_level() {
  case "$MODE" in
    force_on) lv=$LEVEL ;;
    *)        lv=$THRESHOLD_ON ;;
  esac
  [ -z "$lv" ] && lv=80
  [ "$lv" -lt 20 ] 2>/dev/null && lv=20
  [ "$lv" -gt 100 ] 2>/dev/null && lv=100
  echo "$lv"
}

read_bp() { if [ -f "$BPFILE" ]; then cat "$BPFILE" 2>/dev/null; else echo 0; fi; }
write_bp() { echo "$1" > "$BPFILE" 2>/dev/null; }

save_state() {
  cat > "$STATE" <<EOF
LEVEL=$LEVEL
STATUS=$STATUS
CUR=$CUR
VOL=$VOL
TMP=$TMP
POWER=$POWER
BP=$BP
MODE=$MODE
ENABLED=$ENABLED
ON_CHARGER=$ONCH
BACKEND=$BACKEND
TS=$(date +%s)
EOF
}

notify() {
  [ "$NOTIFY" = "1" ] || return 0
  cmd notification post -S bigtext -t "旁路供电守护" bypass_guard "$1" >/dev/null 2>&1
}

# ---------------- 通知（可选，默认关） ----------------
# 没有壳 App 了，这里只做"纯文本通知"，NOTIFY=1 时才发。
push_ui() {
  [ "$NOTIFY" = "1" ] || return 0
  notify "$1"
}

hide_ui() {
  cmd notification cancel bypass_guard >/dev/null 2>&1
}
