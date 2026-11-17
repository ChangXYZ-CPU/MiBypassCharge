#!/system/bin/sh
# bg-ctl.sh — 控制接口（WebUI 调用）
#
#   status            输出实时状态（直接读 sysfs，不是旧文件）
#   get               输出配置
#   set KEY VALUE     改配置
#   on                强制旁路（MODE=force_on）
#   off               强制充电（MODE=force_off）
#   resume            只恢复充电，然后回到自动
#   auto              交回自动
#   toggle            在旁路与恢复之间切换
#   log [n]           日志尾部
#   restart           重启守护

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
    # 实时读，界面数据不受守护轮询间隔影响
    BP=$(read_bp)
    print_state ts
    if daemon_alive; then echo "DAEMON=1"; else echo "DAEMON=0"; fi
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
        # 守护可能正睡 9/21 秒，叫醒它立刻按新配置重新裁决
        _dpid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
        [ -n "$_dpid" ] && kill -USR1 "$_dpid" 2>/dev/null
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
    # 必须用 force_off，不能回 auto：
    # auto 下"电量 ≥ 阈值就停"，80% 时点恢复充电会被下一轮立刻又停掉，按钮等于没用。
    # force_off 会一直充，充满 100% 由守护自动切回 auto（见 bg-daemon.sh）。
    smart_clear
    [ -w "$INPUT_SUSPEND" ] && echo 0 > "$INPUT_SUSPEND" 2>/dev/null
    write_bp 0
    set_key MODE force_off; MODE=force_off
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
    # 先停 supervisor，否则它 5 秒后又把旧守护拉起来，新旧两个打架
    if [ -f "$DATA_DIR/supervisor.pid" ]; then
      kill "$(cat "$DATA_DIR/supervisor.pid" 2>/dev/null)" 2>/dev/null
    fi
    pkill -f "bypass_guard/bin/bg-supervise.sh" 2>/dev/null
    pkill -f "bypass_guard/bin/bg-daemon.sh" 2>/dev/null
    sleep 1
    MODDIR="$MODDIR" sh "$MODDIR/bin/bg-supervise.sh" >/dev/null 2>&1 &
    sleep 1
    echo "OK"
    ;;

  *)
    echo "ERR|unknown command: $cmd"
    exit 1
    ;;
esac
