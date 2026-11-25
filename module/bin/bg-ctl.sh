#!/system/bin/sh
# bg-ctl.sh — 控制接口（WebUI 调用）
#
#   status            输出实时状态（直接读 sysfs，不是旧文件）
#   get               输出配置
#   set KEY VALUE     改配置
#   boot              开机启动完整链路（service.sh 调，ENABLED=0 时不启动）
#   on                手动旁路（MODE=force_on），仅在插电时有意义
#   auto              交回自动模式（点到"恢复自动"就是它），按阈值裁决
#   stop              彻底停止所有守护进程（关总开关时用，零常驻省电）
#   log [n]           日志尾部
#   restart           重启守护
#
# v1.7.2：去掉独立的"手动充电"模式（force_off）。用户关掉旁路总开关就等价于
#        手动充电，没必要多一个模式；按钮改成"手动旁路 ↔ 恢复自动"两态。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
. "$MODDIR/bin/bg-lib.sh"

# 第一件事：如果自己是 WebUI(ksu.exec) 拉起来的，先脱离管理器 app 进程组。
# 必须在本脚本 fork 任何后台进程（supervise / watch）之前做，子进程才会继承根组。
# 默认静默：status 被 WebUI 每 3 秒轮询一次，只有 bg-supervise 会写那行取证日志。
cg_escape

load_conf
find_bat
batt_info

ONCH=0
on_charger && ONCH=1

# 改完配置后按新配置校正一次停充位，不等守护醒来。
# 原因：mksh 在 wait 子进程时用 sigsuspend，SIGUSR1 会被屏蔽，光靠信号不可靠。
reconcile() {
  _bp=$(read_bp)
  if [ "$ENABLED" != "1" ]; then
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

# ---- 进程管理：关总开关时彻底停掉，零常驻、零唤醒 ----
# 关键：supervise 会在 daemon 退出后 3 秒把它拉起来，所以必须先停 supervise，
# 再停 daemon 和 watch，否则杀了 daemon 又活过来，等于没停。
supervise_pids() {
  for p in $(pgrep -f "bg-supervise[.]sh" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *bg-supervise.sh*) echo "$p" ;;
    esac
  done
}

daemon_pids() {
  for p in $(pgrep -f "bg-daemon[.]sh" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *bg-daemon.sh*) echo "$p" ;;
    esac
  done
}

# 彻底停止：先 supervise（防止它拉起 daemon），再 daemon，再 watch
stop_all() {
  for p in $(supervise_pids); do kill "$p" 2>/dev/null; done
  for p in $(daemon_pids); do kill "$p" 2>/dev/null; done
  watch_stop
  # 轮询等退出，没了就立刻走（省掉固定 sleep 1）
  i=0
  while [ "$i" -lt 10 ]; do
    [ -z "$(supervise_pids)" ] && [ -z "$(daemon_pids)" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  # 兜底强杀（supervise 可能在 sleep 3 里，TERM 后仍会再拉一次）
  for p in $(supervise_pids); do kill -9 "$p" 2>/dev/null; done
  for p in $(daemon_pids); do kill -9 "$p" 2>/dev/null; done
  rm -f "$DATA_DIR/daemon.pid" "$DATA_DIR/supervisor.pid" 2>/dev/null
}

# 完整启动：开机 / 重新打开总开关时用
start_all() {
  # 已经在跑就不重复拉
  if [ -n "$(supervise_pids)" ]; then
    # supervise 在，只需确保 daemon 活着（它会自己拉）
    # 但 watch 是独立进程，可能被单独杀掉或配置刚改过，要按当前配置校正
    if [ "${WATCH:-1}" = "1" ]; then
      watch_start
    else
      watch_stop
    fi
    return 0
  fi
  # setsid 脱离本命令的进程组：bg-ctl 由 WebUI exec，退出会清掉自己 fork 的后台进程
  setsid "$MODDIR/bin/bg-supervise.sh" >/dev/null 2>&1 < /dev/null &
  if [ "${WATCH:-1}" = "1" ]; then
    # 不要在这里 rm .watch.lock：那会让 watch_start 的去重失效，
    # 每次 boot 都多起一个 watch，旧的杀不掉就堆成 4 个实例白费电。
    # 让 watch_start 自己看锁 + cmdline 判断要不要起。
    watch_start
  else
    # 配置要求关监听：清掉残留的 watch，否则关不掉会持续唤醒耗电
    watch_stop
  fi
}

# 监听器开关：关掉省 ~0.23% 单核，代价是插拔要等巡检周期才被发现
watch_start() {
  # 去重要彻底：只要已经有任何活着的 watch 实例（含子 shell），就不再起。
  # 旧版只看锁文件里的单个 pid，锁被覆盖/残留时漏判，导致反复 boot 堆出 4 个实例。
  [ -n "$(watch_pids)" ] && return 0
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
  # 先 TERM 所有实例（主+子 shell 都被 watch_pids 认 cmdline 抓到）
  for p in $(watch_pids); do kill "$p" 2>/dev/null; done
  # 轮询等待退出，没了就立刻返回（不再固定睡两轮，关闭响应从 ~3s 降到 ~0.2s）
  i=0
  while [ "$i" -lt 10 ]; do
    [ -z "$(watch_pids)" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  # 还没死透就强杀一次
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
      ENABLED)
        set_key ENABLED "$v"; load_conf
        if [ "$v" = "0" ]; then
          # 关总开关：先松开停充位（否则插电不充），再彻底停掉所有进程省电
          smart_clear; write_bp 0
          stop_all
          echo "OK"
        else
          # 开总开关：拉起完整链路
          set_key MODE auto; MODE=auto
          start_all
          echo "OK"
        fi
        ;;
      MODE|THRESHOLD_ON|THRESHOLD_OFF)
        set_key "$k" "$v"; load_conf; reconcile
        echo "OK"
        ;;
      POLL|CHECK_INTERVAL|NOTIFY|BACKEND|SMART_MODE|FALLBACK)
        set_key "$k" "$v"; load_conf
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
    # 立刻生效：停充电量取"当前电量"，不看阈值（阈值 85 而当前 70 时写 85 是不会停的）
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

  auto)
    # "恢复自动"：清掉手动标记，按阈值重新裁决。
    # 去掉了原来的 resume(force_off)：手动充电没必要单独做个模式，
    # 关掉旁路总开关就等价于手动充电，这里只负责交回自动。
    set_key MODE auto
    load_conf
    reconcile
    batt_info
    push_ui "已恢复自动模式 · 电量 ${LEVEL}%"
    echo "OK"
    ;;

  boot)
    # 开机入口：ENABLED=0 时什么都不起（彻底省电），否则拉起完整链路
    if [ "$ENABLED" != "1" ]; then
      smart_clear; write_bp 0
      stop_all          # 连残留进程一起清，保证"关了就是零占用"
      echo "OK|disabled"
      exit 0
    fi
    start_all
    echo "OK"
    ;;

  stop)
    # 彻底停止（关总开关 / 排障用）
    smart_clear; write_bp 0
    stop_all
    echo "OK"
    ;;

  toggle)
    # 两态：手动旁路(on=force_on) ↔ 恢复自动(auto)
    # 判断依据用 MODE，不是 BP：BP 只是记账标志，驱动补电时会短暂失真
    case "$MODE" in
      force_on) sh "$0" auto ;;
      *)        sh "$0" on ;;
    esac
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
