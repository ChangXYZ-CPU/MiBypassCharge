#!/system/bin/sh
# bg-ctl.sh — 控制接口（WebUI / 通知按钮 / action.sh 调用）
#
#   status            输出实时状态
#   get               输出配置
#   set KEY VALUE     改配置
#   on                强制旁路（MODE=force_on）
#   off               强制充电（MODE=force_off）
#   resume            只恢复充电，然后回到自动（通知栏那个按钮用这个）
#   auto              交回自动
#   toggle            在旁路与恢复之间切换
#   log [n]           日志尾部
#   restart           重启守护
#   app [install]     壳 App 状态

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
. "$MODDIR/bin/bg-lib.sh"

load_conf
find_bat
batt_info

ONCH=0
on_charger && ONCH=1

cmd=$1

case "$cmd" in
  status)
    BP=$(read_bp)
    if [ -f "$STATE" ]; then cat "$STATE"; else echo "NO_STATE"; fi
    ;;

  get)
    cat "$CONF"
    ;;

  set)
    k=$2; v=$3
    [ -z "$k" ] && { echo "ERR|missing key"; exit 1; }
    case "$k" in
      THRESHOLD_ON|THRESHOLD_OFF|POLL|ENABLED|MODE|NOTIFY|BACKEND|SMART_MODE|FALLBACK)
        set_key "$k" "$v"
        echo "OK"
        ;;
      *)
        echo "ERR|unknown key"
        exit 1
        ;;
    esac
    ;;

  on|pause)
    if ! on_charger; then
      echo "ERR|未插电，旁路无意义"
      exit 1
    fi
    # 立刻生效：停充电量取"当前电量"，不看阈值（阈值 80 而当前 70 时写 80 是不会停的）
    lvl=$LEVEL
    [ -z "$lvl" ] && lvl=80
    [ "$lvl" -lt 20 ] 2>/dev/null && lvl=20
    set_key MODE force_on; MODE=force_on
    if ! smart_set "$lvl"; then
      echo "ERR|写 smart_chg 失败"
      exit 1
    fi
    write_bp 1
    # 只做 3 秒快速确认，确认不到也算"指令已下发"（PD 重协商本来就要几秒）
    i=0; ok=0
    while [ "$i" -lt 3 ]; do
      sleep 1; batt_info
      if is_stopped; then ok=1; break; fi
      i=$((i + 1))
    done
    logi "ctl on level=$lvl stopped=$ok cur=$CUR"
    push_ui "已开启旁路 · 电量 ${LEVEL}%"
    if [ "$ok" = "1" ]; then echo "OK"; else echo "OK|已下发，等待电池停充（当前 ${CUR}µA）"; fi
    exit 0
    ;;

  off|force_off)
    smart_clear
    [ -w "$INPUT_SUSPEND" ] && echo 0 > "$INPUT_SUSPEND" 2>/dev/null
    write_bp 0
    set_key MODE force_off; MODE=force_off
    sleep 1; batt_info
    push_ui "已恢复充电 · 电量 ${LEVEL}%"
    echo "OK"
    ;;

  resume)
    smart_clear
    [ -w "$INPUT_SUSPEND" ] && echo 0 > "$INPUT_SUSPEND" 2>/dev/null
    write_bp 0
    set_key MODE auto; MODE=auto
    sleep 1; batt_info
    push_ui "已恢复充电 · 电量 ${LEVEL}%"
    echo "OK"
    ;;

  auto)
    set_key MODE auto
    MODE=auto
    batt_info
    push_ui "已切回自动模式 · 电量 ${LEVEL}%"
    echo "OK"
    ;;

  toggle)
    if [ "$(read_bp)" = "1" ]; then
      sh "$0" resume
    else
      sh "$0" on
    fi
    ;;

  hide)
    hide_ui
    echo "OK"
    ;;

  log)
    n=${2:-40}
    tail -n "$n" "$LOGFILE" 2>/dev/null
    ;;

  restart)
    if [ -f "$DATA_DIR/daemon.pid" ]; then
      kill "$(cat "$DATA_DIR/daemon.pid")" 2>/dev/null
      sleep 1
    fi
    pkill -f bg-daemon.sh 2>/dev/null
    sleep 1
    MODDIR="$MODDIR" sh "$MODDIR/bin/bg-daemon.sh" >/dev/null 2>&1 &
    echo $! > "$DATA_DIR/daemon.pid"
    echo "OK"
    ;;

  *)
    echo "ERR|unknown command: $cmd"
    exit 1
    ;;
esac
