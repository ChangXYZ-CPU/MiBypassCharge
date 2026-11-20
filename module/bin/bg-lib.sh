#!/system/bin/sh
# bg-lib.sh — 旁路供电守护公共函数库
#
# 停充走小米充电驱动的官方位：
#   /sys/class/qcom-battery/smart_chg = 0x{电量<<16 | 标志位}
#   标志位 0x3 = 导航模式 + 生效位（安全中心「导航断充保护」用的就是这个）
# 驱动自己保持该状态（拔插都不丢），所以稳态下不需要周期重申。
#
# 省电要点（v1.5）：每一轮都别再 fork 进程
#   实测（K70 / HZ=100，N=100 次）：
#     cat 一个属性           34 ms   ← 其中 26ms 只是 exec toybox cat
#     cat 6 个属性           39 ms
#     cat battery/uevent     72 ms   ← show 全量，反而更贵
#     read < 文件（内建）     1-3 ms  ← 只走 open/read/close，不 exec
#   所以全部改成 read < file，一轮 6 个属性 ~10ms，是原来的 1/15

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
SYS=${SYSFS_ROOT:-}
DATA_DIR=${DATA_DIR_OVERRIDE:-/data/adb/MiBypassCharge}
CONF=$DATA_DIR/config.conf
STATE=$DATA_DIR/state
BPFILE=$DATA_DIR/bp_on
LOGFILE=$DATA_DIR/bypass.log

# 一次性迁移：旧版本数据目录是 /data/adb/bypass_guard（模块 ID 变更前）。
# 判断依据是 config.conf 是否存在，而不是目录是否存在——
# service.sh 会先 mkdir 出新目录，那时目录已存在但里面还是空的。
# 只复制配置和状态文件，不复制 pid 文件（旧进程已死，复制过去只会误导）。
# 旧目录保留不删：可回退，且旧模块的 uninstall.sh 还要用。
OLD_DATA=/data/adb/bypass_guard
if [ ! -f "$CONF" ] && [ -f "$OLD_DATA/config.conf" ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null
  for _f in config.conf state bp_on bypass.log; do
    [ -e "$OLD_DATA/$_f" ] && cp "$OLD_DATA/$_f" "$DATA_DIR/$_f" 2>/dev/null
  done
  rm -f "$OLD_DATA/.watch.lock" 2>/dev/null
fi

mkdir -p "$DATA_DIR" 2>/dev/null

# ---- 节点 ----
QB=$SYS/sys/class/qcom-battery
PS=$SYS/sys/class/power_supply
SMART_CHG=$QB/smart_chg
INPUT_SUSPEND=$QB/input_suspend

DEFAULT_CONF='ENABLED=1
MODE=auto
THRESHOLD_ON=80
THRESHOLD_OFF=75
POLL=3
CHECK_INTERVAL=30
WATCH=1
BACKEND=smartchg
SMART_MODE=3
FALLBACK=1
NOTIFY=0'

[ -f "$CONF" ] || printf '%s\n' "$DEFAULT_CONF" > "$CONF"

load_conf() {
  . "$CONF" 2>/dev/null
  [ -z "$POLL" ] && POLL=3
  [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=30
  [ -z "$WATCH" ] && WATCH=1
  [ -z "$THRESHOLD_ON" ] && THRESHOLD_ON=80
  [ -z "$THRESHOLD_OFF" ] && THRESHOLD_OFF=70
  [ -z "$MODE" ] && MODE=auto
  [ -z "$ENABLED" ] && ENABLED=1
  [ -z "$NOTIFY" ] && NOTIFY=0
  [ -z "$BACKEND" ] && BACKEND=smartchg
  [ -z "$SMART_MODE" ] && SMART_MODE=3
  [ -z "$FALLBACK" ] && FALLBACK=1
  # v1.7.2 迁移：废弃"手动充电"(force_off)，老配置归一到 auto。
  # 用户关掉旁路总开关就等价于手动充电，不需要单独模式；
  # 留着它会让"恢复自动"按钮永远回不去（老版本卡死的就是这个）。
  if [ "$MODE" = "force_off" ]; then
    MODE=auto
    _mig=1
  else
    _mig=0
  fi
  # 老配置缺新字段时补写回去（否则界面读不到、升级后一直用默认值）
  if ! grep -q '^WATCH=' "$CONF" 2>/dev/null || ! grep -q '^CHECK_INTERVAL=' "$CONF" 2>/dev/null || [ "$_mig" = "1" ]; then
    save_conf
  fi
}

save_conf() {
  {
    echo "ENABLED=$ENABLED"
    echo "MODE=$MODE"
    echo "THRESHOLD_ON=$THRESHOLD_ON"
    echo "THRESHOLD_OFF=$THRESHOLD_OFF"
    echo "POLL=$POLL"
    echo "CHECK_INTERVAL=$CHECK_INTERVAL"
    echo "WATCH=$WATCH"
    echo "BACKEND=$BACKEND"
    echo "SMART_MODE=$SMART_MODE"
    echo "FALLBACK=$FALLBACK"
    echo "NOTIFY=$NOTIFY"
  } > "$CONF"
}

set_key() {
  k=$1; v=$2
  if grep -q "^$k=" "$CONF" 2>/dev/null; then
    sed -i "s|^$k=.*|$k=$v|" "$CONF"
  else
    echo "$k=$v" >> "$CONF"
  fi
}

# 日志：每 40 条才检查一次行数（原来每条都 wc -l，白花 fork）
LOGN=0
logi() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOGFILE" 2>/dev/null
  LOGN=$((LOGN + 1))
  [ $((LOGN % 40)) -eq 0 ] || return 0
  n=$(wc -l < "$LOGFILE" 2>/dev/null)
  if [ "${n:-0}" -gt 400 ]; then
    tail -200 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
  fi
}

rd() { cat "$1" 2>/dev/null; }

# 只认数字（允许前导 -），其它一律当 0。
# 结果写进全局 _N，不要用 $(chk ...) —— 命令替换本身 fork 一次，就把 read 省下的全吃回去了。
# 另外必须用 printf：echo "-154000" 在某些 shell 里会被当成选项，吐空串。
chk_set() {
  case "$1" in
    ''|-) _N=0 ;;
    -*) _t=${1#-}
        case "$_t" in ''|*[!0-9]*) _N=0 ;; *) _N="-$_t" ;; esac ;;
    *[!0-9]*) _N=0 ;;
    *) _N=$1 ;;
  esac
}

# 电池目录只找一次（原来每 tick 遍历 power_supply/* 并 cat type）
find_bat() {
  if [ -n "$BAT_DIR" ] && [ -r "$BAT_DIR/uevent" ]; then return 0; fi
  BAT_DIR=""
  for d in "$PS"/*; do
    [ -r "$d/type" ] || continue
    if [ "$(rd "$d/type")" = "Battery" ]; then BAT_DIR=$d; break; fi
  done
  [ -z "$BAT_DIR" ] && BAT_DIR=$PS/battery
}

# 功率：VOL(µV) × CUR(µA) / 1e12 = W
# 设备上的 sh 是 32 位算术（实测 4119000*403000 溢出成 2099623744），
# 所以先降到 mV / mA 再乘，最大 20000×12000=2.4e8，安全。
# mV×mA = µW；0.01W = 10000µW，四舍五入到 0.01W。
# current_now 负=充电，乘 -1 后：充电为正、放电为负（和 Scene 一致）
calc_power() {
  chk_set "$VOL"; _v=$_N
  chk_set "$CUR"; _c=$_N
  _v=$(( _v / 1000 ))
  _c=$(( _c / 1000 ))
  _p=$(( _v * _c * -1 ))
  _neg=""
  if [ "$_p" -lt 0 ]; then _neg="-"; _p=$(( _p * -1 )); fi
  _q=$(( (_p + 5000) / 10000 ))
  _r=$(( _q % 100 ))
  [ "$_r" -lt 10 ] && _r="0$_r"
  POWER="$_neg$(( _q / 100 )).$_r"
}

# 全部用 shell 内建 read + 重定向，不 fork（见文件头的实测数据）
batt_info() {
  LEVEL=""; STATUS=""; CUR=""; VOL=""; TMP=""
  read -r LEVEL  2>/dev/null < "$BAT_DIR/capacity"
  read -r STATUS 2>/dev/null < "$BAT_DIR/status"
  read -r CUR    2>/dev/null < "$BAT_DIR/current_now"
  read -r VOL    2>/dev/null < "$BAT_DIR/voltage_now"
  read -r TMP    2>/dev/null < "$BAT_DIR/temp"

  chk_set "$LEVEL"; LEVEL=$_N
  STATUS=${STATUS:-Unknown}
  chk_set "$CUR"; CUR=$_N
  chk_set "$VOL"; VOL=$_N
  chk_set "$TMP"; TMP=$_N
  calc_power
}

# 停充判定：电池电流接近 0
is_stopped() {
  _c=${CUR#-}
  case "$_c" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_c" -lt 120000 ]
}

# 充电判定：明显在充电
is_charging() {
  case "$CUR" in
    -*) _c=${CUR#-}; case "$_c" in ''|*[!0-9]*) return 1 ;; esac
        [ "$_c" -gt 300000 ] ;;
    *) return 1 ;;
  esac
}

# 是否插着电：内建 read，usb.online 一次 1ms，再靠 VBUS / 状态字兜底
on_charger() {
  _on=""
  read -r _on 2>/dev/null < "$PS/usb/online"
  [ "$_on" = "1" ] && return 0

  # 旁路中 usb.online 偶尔短暂为 0，但 VBUS 还在
  _uv=""
  read -r _uv 2>/dev/null < "$PS/usb/voltage_now"
  chk_set "$_uv"
  [ "$_N" -gt 4000000 ] && return 0

  # 无线充 / 其它口兜底（K70 没有，留给别的机型；文件不存在时 read 直接失败，成本极低）
  for _p in ac wireless dc; do
    _on=""
    read -r _on 2>/dev/null < "$PS/$_p/online"
    [ "$_on" = "1" ] && return 0
  done

  case "$STATUS" in
    Charging*|Full*|"Not charging") return 0 ;;
  esac
  return 1
}

# ---------------- 节点写入串行化 ----------------
# 来自开源项目 bypass-charger v10.3.5 记录的真实事故（2026-11-10）：
# 守护进程和 WebUI 同时写同一个充电节点，触发厂商充电驱动内部死锁，
# 进程卡在 D 状态、杀不掉、插电不充。所以写节点一律 flock 串行化。
# 用 -n 非阻塞：拿不到锁就放弃本次写入（下一轮再试），绝不阻塞等锁。
LOCKFILE=$DATA_DIR/.node_lock

# $1=节点 $2=值
write_node() {
  [ -z "$1" ] && return 1
  [ ! -e "$1" ] && return 1
  (
    flock -n 9 || return 1
    echo "$2" > "$1" 2>/dev/null
  ) 9>"$LOCKFILE"
}

# ---------------- smart_chg 官方停充位 ----------------

smart_present() { [ -e "$SMART_CHG" ] && [ -w "$SMART_CHG" ]; }

smart_set() {          # $1 = 停充电量
  smart_present || return 1
  v=$(printf '0x%x' $(( ($1 << 16) | SMART_MODE )) 2>/dev/null)
  [ -z "$v" ] && return 1
  write_node "$SMART_CHG" "$v" || return 1
  logi "smart_set $v (level=$1 mode=$SMART_MODE)"
  return 0
}

smart_clear() {        # 实测：只写 0 有时解不掉，必须先 0x2 再 0
  smart_present || return 1
  # 两次写之间要放锁，否则别的进程这三秒全被挡住
  write_node "$SMART_CHG" 0x2
  sleep "${CLEAR_GAP:-3}"
  write_node "$SMART_CHG" 0
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

# 守护是否活着：不能只看 kill -0（pid 会被复用），要认 /proc/<pid>/cmdline
daemon_alive() {
  [ -f "$DATA_DIR/daemon.pid" ] || return 1
  _d=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
  [ -n "$_d" ] || return 1
  [ -r "/proc/$_d/cmdline" ] || return 1
  case "$(tr '\0' ' ' < "/proc/$_d/cmdline" 2>/dev/null)" in
    *bg-daemon.sh*) return 0 ;;
  esac
  return 1
}

# 输出状态 KV 到 stdout（WebUI 的 status 直接用它，拿到的是实时值，不是旧文件）
print_state() {
  echo "LEVEL=$LEVEL"
  echo "STATUS=$STATUS"
  echo "CUR=$CUR"
  echo "VOL=$VOL"
  echo "TMP=$TMP"
  echo "POWER=$POWER"
  echo "BP=$BP"
  echo "MODE=$MODE"
  echo "ENABLED=$ENABLED"
  echo "ON_CHARGER=$ONCH"
  echo "BACKEND=$BACKEND"
  [ "$1" = "ts" ] && echo "TS=$(date +%s)"
  return 0
}

# 只在「看得见的状态」变化时才写盘。
# 电流/电压/温度不参与比较：它们一直在抖，每轮都写等于每轮多 fork 一次 date，
# 而界面读的是 bg-ctl status 的实时值，本来就不依赖这个文件。
STATE_SIG=""
save_state() {
  _sig="$LEVEL|$STATUS|$BP|$MODE|$ENABLED|$ONCH|$BACKEND"
  [ "$_sig" = "$STATE_SIG" ] && return 0
  STATE_SIG=$_sig
  print_state ts > "$STATE"
}

notify() {
  [ "$NOTIFY" = "1" ] || return 0
  cmd notification post -S bigtext -t "MiBypassCharge" mibypasscharge "$1" >/dev/null 2>&1
}

# 没有壳 App 了，这里只做"纯文本通知"，NOTIFY=1 时才发
push_ui() {
  [ "$NOTIFY" = "1" ] || return 0
  notify "$1"
}

hide_ui() {
  cmd notification cancel mibypasscharge >/dev/null 2>&1
}
