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

# 改完配置后按新配置校正一次停充位，不等守护醒来。
# 原因：mksh 在 wait 子进程时用 sigsuspend，SIGUSR1 会被屏蔽，光靠信号不可靠。
reconcile() {
  _bp=$(read_bp)
  if [ "$ENABLED" != "1" ] || [ "$MODE" = "force_off" ]; then
    smart_clear; write_bp 0
  elif [ "$MODE" = "force_on" ]; then
    smart_set "$LEVEL"; write_bp 1
  elif [ "$ONCH" = "1" ]; then
    # 按"当前电量 vs 阈值"直接裁决，不走滞回区：
    # 把阈值调到当前电量之上，就是想继续充，得把停充位松开。
    if [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
      smart_set "$THRESHOLD_ON"; write_bp 1
    elif [ "$_bp" = "1" ]; then
      smart_clear; write_bp 0
    fi
  fi
  # 顺手叫一下守护（能醒更好，醒不了上面已经校正过了）
  _dpid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
  [ -n "$_dpid" ] && kill -USR1 "$_dpid" 2>/dev/null
}

# 监听器开关：关掉省 ~0.23% 单核，代价是插拔要等巡检周期才被发现
watch_start() {
  # 防止重复：锁文件里的 pid 认命令行才作数
  if [ -f "$DATA_DIR/.watch.lock" ]; then
    _wp=$(cat "$DATA_DIR/.watch.lock/pid" 2>/dev/null)
    case "$_wp" in
      ''|*[!0-9]*) : ;;
      *)
        [ -r "/proc/$_wp/cmdline" ] && \
        case "$(tr '\0' ' ' < "/proc/$_wp/cmdline" 2>/dev/null)" in
          *bg-watch.sh*) return 0 ;;
        esac
        ;;
    esac
  fi
  rm -rf "$DATA_DIR/.watch.lock" 2>/dev/null
  # setsid 脱离本命令的进程组：bg-ctl 由 WebUI exec，退出时会清掉自己 fork 的后台进程
  setsid sh "$MODDIR/bin/bg-watch.sh" >/dev/null 2>&1 < /dev/null &
}

# 找所有真正在跑的 bg-watch 进程（不能只信锁文件：pid 会复用、锁可能残留）
watch_pids() {
  for p in $(pgrep -f "bg-watch[.]sh" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *bg-watch.sh*) echo "$p" ;;
    esac
  done
}

watch_stop() {
  # 先杀子进程（logcat / while 子 shell），再杀主进程
  for p in $(watch_pids); do
    for c in $(pgrep -P "$p" 2>/dev/null); do kill "$c" 2>/dev/null; done
    kill "$p" 2>/dev/null
  done
  sleep 1
  # 兜底：还在就强杀
  for p in $(watch_pids); do kill -9 "$p" 2>/dev/null; done
  rm -rf "$DATA_DIR/.watch.lock" 2>/dev/null
}

watch_status() {
  [ -n "$(watch_pids)" ] && echo "1" || echo "0"
}

cmd=$1

case "$cmd" in
  status)
    # 实时读，界面数据不受守护轮询间隔影响
    BP=$(read_bp)
    print_state ts
    if daemon_alive; then echo "DAEMON=1"; else echo "DAEMON=0"; fi
    echo "WATCH_RUNNING=$(watch_status)"
    ;;

  get)
    cat "$CONF"
    ;;

  set)
    k=$2; v=$3
    [ -z "$k" ] && { echo "ERR|missing key"; exit 1; }
    case "$k" in
      THRESHOLD_ON|THRESHOLD_OFF|POLL|CHECK_INTERVAL|ENABLED|MODE|NOTIFY|BACKEND|SMART_MODE|FALLBACK)
        set_key "$k" "$v"
        load_conf
        case "$k" in
          ENABLED|MODE|THRESHOLD_ON|THRESHOLD_OFF) reconcile ;;
          *) : ;;
        esac
        echo "OK"
        ;;

      WATCH)
        case "$v" in
          1) set_key WATCH 1; watch_start; echo "OK" ;;
          0) set_key WATCH 0; watch_stop;  echo "OK" ;;
          *) echo "ERR|WATCH 只能是 0 或 1"; exit 1 ;;
        esac
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
    load_conf
    reconcile
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
    # 不要在这里杀 supervisor 再重新起：bg-ctl 是由 WebUI exec 拉起来的短命进程，
    # 它 fork 的后台进程会随命令结束被一起清掉，结果就是守护没了。
    # 正确做法：supervisor 活着时只杀守护，它 3 秒后自会拉起新的。
    SPD=$(cat "$DATA_DIR/supervisor.pid" 2>/dev/null)
    DPD=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    alive=0
    case "$SPD" in
      ''|*[!0-9]*) : ;;
      *)
        [ -r "/proc/$SPD/cmdline" ] && \
        case "$(tr '\0' ' ' < "/proc/$SPD/cmdline" 2>/dev/null)" in
          *bg-supervise.sh*) alive=1 ;;
        esac
        ;;
    esac
    if [ "$alive" = "1" ]; then
      [ -n "$DPD" ] && kill "$DPD" 2>/dev/null
      echo "OK"
      exit 0
    fi
    # supervisor 确实不在了才重起；setsid 脱离当前进程组，避免随本命令退出被清掉
    setsid "$MODDIR/bin/bg-supervise.sh" >/dev/null 2>&1 < /dev/null &
    sleep 1
    echo "OK"
    ;;

  *)
    echo "ERR|unknown command: $cmd"
    exit 1
    ;;
esac
