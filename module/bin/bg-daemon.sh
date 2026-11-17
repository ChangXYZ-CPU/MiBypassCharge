#!/system/bin/sh
# bg-daemon.sh — 守护主循环
#
# 执行层是 smart_chg 掩码（驱动级停充），不是 input_suspend。
# 驱动自己保持状态，所以稳态不重写；只有连续几十秒"明显在充电"才补写一次。
#
# 省电（v1.5+）：轮询间隔按场景自适应，不再死守 3 秒
#   旁路中 / 快到阈值 → POLL（3s）   要精确停充、要发现拔线
#   插着电、离阈值还远 → POLL×3（9s） 电量涨得慢，9 秒够
#   没插电 / 功能关闭 → POLL×7（21s） 这时什么都做不了
#
# 唤醒（v1.5+）：WebUI 改配置会发 SIGUSR1，nap 立刻被打断重新裁决，
# 不用等睡满一个周期。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
. "$MODDIR/bin/bg-lib.sh"

load_conf
find_bat
batt_info

BP=$(read_bp)
TICK=0
STRIKES=0
BACKOFF=0
LAST_STATUS=""
# 初始化为"当前阈值"，这样启动后的第一轮不会误触发重裁决。
# 重裁决只应该由"用户改了阈值"触发；否则启动时电量刚好在阈值下一格（79/80），
# 会被判成"该充电"，和驱动的补电行为打架，变成 79↔80 反复横跳。
LAST_EN=$THRESHOLD_ON
LAST_DI=$THRESHOLD_OFF
LAST_SMART=""
LAST_IDLE=""
SLEEP_PID=""

# 连续多少个 tick 都在"明显充电"才认为驱动状态真丢了。
# 80% 附近掉一格再补电是驱动的正常行为（官方导航断充也这样），
# 以前 2 tick（6 秒）就补写，等于跟驱动抢控制权，反而把补电打断。
REASSERT_TICKS=${REASSERT_TICKS:-30}

VERIFY_ON_TRIES=${VERIFY_ON_TRIES:-8}      # 8×2s = 16s 等它停
VERIFY_OFF_TRIES=${VERIFY_OFF_TRIES:-12}   # 12×2s = 24s 等它重新充

echo $$ > "$DATA_DIR/daemon.pid"

# 退出必须做的事：驱动状态是"粘"的，守护走了还压着 smart_chg，
# 手机就会一直不充电（比功能失效严重得多）。
# 同时提醒：INT/TERM 要显式 exit，否则 trap 跑完循环还在继续。
on_exit() {
  _rc=$?
  if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi
  if [ "$BP" = "1" ]; then
    logi "=== daemon exit pid=$$ rc=$_rc → 复位 smart_chg ==="
    smart_clear
    write_bp 0
  else
    logi "=== daemon exit pid=$$ rc=$_rc ==="
  fi
}
trap on_exit EXIT
trap 'exit 0' INT TERM

# 可被打断的等待：WebUI 改完配置发 SIGUSR1，立刻醒来重新裁决
trap 'if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi' USR1

nap() {
  sleep "${1:-$IV}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

logi "=== daemon start v1.6 pid=$$ backend=$BACKEND mode=$MODE thr=$THRESHOLD_ON/$THRESHOLD_OFF poll=$POLL ==="

# 启动校验：本地记着"旁路中"，但硬件明明在充电 → 说明重启过，状态已失效
if [ "$BP" = "1" ] && is_charging; then
  BP=0; write_bp 0
  logi "startup: recorded BP=1 but charging (cur=$CUR) → reset"
fi

push_ui "旁路供电守护已启动"

wait_stopped() {
  i=0
  while [ "$i" -lt "$1" ]; do
    sleep 2
    batt_info
    is_stopped && return 0
    i=$((i + 1))
  done
  return 1
}

wait_charging() {
  i=0
  while [ "$i" -lt "$1" ]; do
    sleep 2
    batt_info
    is_charging && return 0
    i=$((i + 1))
  done
  return 1
}

do_on() {
  batt_info
  lvl=$(smart_target_level)
  if smart_set "$lvl" && wait_stopped "$VERIFY_ON_TRIES"; then
    BP=1; write_bp 1
    logi "BP ON smartchg level=$lvl now=$LEVEL cur=$CUR"
    push_ui "已开启旁路 · 电量 ${LEVEL}% · 电池 0.00W"
    return 0
  fi
  logi "smart_set no effect (cur=$CUR status=$STATUS)"
  # 只有"本机根本没有 smart_chg"时才退到 input_suspend。
  # 有 smart_chg 但这次没停住，说明是阈值没到/驱动还在协商，绝不能用断充兜底
  # （断充会让手机转吃电池，UI 上就是"未插电、0W"，v1.2 初版踩过这个坑）。
  if [ "$FALLBACK" = "1" ] && ! smart_present && [ -w "$INPUT_SUSPEND" ]; then
    logi "fallback: input_suspend=1 (断充, 非旁路)"
    echo 1 > "$INPUT_SUSPEND" 2>/dev/null
    if wait_stopped "$VERIFY_ON_TRIES"; then
      BACKEND=input_suspend
      save_conf
      BP=1; write_bp 1
      push_ui "已断充（兜底，非旁路）· 电量 ${LEVEL}%"
      return 0
    fi
    echo 0 > "$INPUT_SUSPEND" 2>/dev/null
  fi
  return 1
}

do_off() {
  case "$BACKEND" in
    input_suspend)
      echo 0 > "$INPUT_SUSPEND" 2>/dev/null
      BACKEND=smartchg; save_conf
      ;;
    *)
      smart_clear
      ;;
  esac

  BP=0; write_bp 0

  # 拔了电就别等它"充上"了（拔着电永远等不到，会白等 20 多秒）
  if ! on_charger; then
    logi "BP OFF (unplugged) level=$LEVEL"
    push_ui "已拔电，旁路解除"
    return 0
  fi

  if wait_charging "$VERIFY_OFF_TRIES"; then
    logi "BP OFF level=$LEVEL cur=$CUR (charging resumed)"
    push_ui "已恢复充电 · 电量 ${LEVEL}%"
  else
    logi "BP OFF but not charging yet (cur=$CUR status=$STATUS) → 再补一次"
    smart_clear
    sleep 4
    batt_info
    push_ui "已恢复充电 · 电量 ${LEVEL}%"
  fi
  return 0
}

# 下一次睡多久。核心思路：smart_chg 是驱动级的「充到 X 停」，
# 插上电后驱动自己就按它执行，守护不需要守着 —— 所以空闲时可以把间隔拉得很长。
# 直接算进 IV，不要用 $(next_interval) —— 命令替换每轮 fork 一次，26ms 白花
next_interval() {
  _p=$POLL
  [ "$_p" -ge 1 ] 2>/dev/null || _p=3
  [ "$_p" -gt 15 ] && _p=15
  if [ "$ENABLED" != "1" ]; then IV=$((_p * 20)); return; fi   # 关闭：彻底闲着
  if [ "$ONCH" != "1" ]; then                                  # 没插电：只等"插上了"
    if [ "$MODE" = "force_on" ]; then IV=$((_p * 3)); else IV=$((_p * 20)); fi
    return
  fi
  if [ "$BP" = "1" ]; then IV=$((_p * 3)); return; fi          # 已在旁路：看补电、看拔线
  if [ "$MODE" != "force_on" ]; then
    _d=$(( THRESHOLD_ON - LEVEL ))
    [ "$_d" -le 3 ] 2>/dev/null && { IV=$_p; return; }          # 快到阈值：精确停
  fi
  IV=$((_p * 5))                                               # 插着电、离阈值还远
}

while true; do
  # KernelSU 里"禁用"模块不会跑 uninstall.sh，只能靠这里自己退出并放开充电
  if [ -f "$MODDIR/disable" ]; then
    logi "检测到 disable 标记 → 恢复充电并退出"
    if [ "$BP" = "1" ]; then smart_clear; write_bp 0; BP=0; fi
    break
  fi

  load_conf
  find_bat
  batt_info

  ONCH=0
  on_charger && ONCH=1

  # 恢复值必须明显低于开启值
  if [ "$THRESHOLD_OFF" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
    THRESHOLD_OFF=$((THRESHOLD_ON - 5))
  fi

  # 拔电时把停充位对齐到「当前阈值」，而不是清 0：
  # smart_chg 是驱动级的「充到 X 停」，插上电后驱动自己就会按它执行，
  # 根本不需要守护守着。这是把空闲轮询拉到 60 秒的前提。
  if [ "$ONCH" != "1" ]; then
    _ws="off"
    if [ "$ENABLED" = "1" ] && [ "$MODE" = "auto" ]; then _ws=$THRESHOLD_ON; fi
    if [ "$LAST_SMART" != "$_ws" ]; then
      if [ "$_ws" = "off" ]; then smart_clear; else smart_set "$_ws"; fi
      LAST_SMART=$_ws
      logi "unplugged: 停充位对齐 -> $_ws"
    fi
  fi

  # force_off 是「一键恢复充电」用的，充满后自动交回 auto，不用用户再管
  if [ "$MODE" = "force_off" ] && [ "$LEVEL" -ge 100 ] 2>/dev/null; then
    set_key MODE auto; MODE=auto
    logi "force_off 已充满 -> 回到 auto"
  fi

  # ---- 决策 ----
  if [ "$ENABLED" != "1" ]; then
    WANT=0
  else
    case "$MODE" in
      force_on)
        WANT=1
        ;;
      force_off)
        WANT=0
        ;;
      *)
        if [ "$ONCH" != "1" ]; then
          WANT=0
        elif [ "$THRESHOLD_ON" != "$LAST_EN" ] || [ "$THRESHOLD_OFF" != "$LAST_DI" ]; then
          # 阈值刚被改过 / 刚启动 / 刚插电：按当前电量直接裁决，不走滞回区。
          # 否则把停止阈值调到当前电量之上后，会一直卡在死区里不动。
          if [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then WANT=1; else WANT=0; fi
        elif [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
          WANT=1
        elif [ "$LEVEL" -le "$THRESHOLD_OFF" ] 2>/dev/null; then
          WANT=0
        else
          WANT=$BP          # 滞回区：维持现状
        fi
        ;;
    esac
  fi
  LAST_EN=$THRESHOLD_ON
  LAST_DI=$THRESHOLD_OFF

  # 没插电就没必要维持旁路
  if [ "$ONCH" != "1" ] && [ "$MODE" != "force_on" ]; then
    WANT=0
  fi

  TICK=$((TICK + 1))

  # ---- 执行 ----
  if [ "$WANT" = "1" ] && [ "$BP" != "1" ]; then
    if [ "$BACKOFF" -gt 0 ]; then
      BACKOFF=$((BACKOFF - 1))
    elif ! do_on; then
      BACKOFF=6
      logi "do_on failed, backoff 6 ticks"
    fi
  elif [ "$WANT" = "0" ] && [ "$BP" = "1" ]; then
    if [ "$ONCH" = "1" ]; then
      do_off
    else
      # 拔电：只清记账；停充位上面已经对齐成"充到 X 停"，插上后驱动自己干活
      BP=0; write_bp 0
      logi "BP OFF (unplugged, smart_chg 保留)"
    fi
  elif [ "$WANT" = "1" ] && [ "$BP" = "1" ]; then
    if is_charging; then
      STRIKES=$((STRIKES + 1))
      if [ "$STRIKES" -ge "$REASSERT_TICKS" ]; then
        logi "reassert: charging $STRIKES ticks (cur=$CUR level=$LEVEL) → rewrite"
        do_on >/dev/null 2>&1
        STRIKES=0
      fi
    else
      STRIKES=0
    fi
  fi

  # 状态变化时记一笔
  if [ "$LAST_STATUS" != "$STATUS" ]; then
    LAST_STATUS=$STATUS
    logi "status -> $STATUS level=$LEVEL cur=$CUR"
  fi

  save_state
  next_interval
  nap "$IV"
done
