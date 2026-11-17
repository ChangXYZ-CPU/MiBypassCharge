#!/system/bin/sh
# bg-daemon.sh — 守护主循环（v1.2）
#
# 和 v1.1 的区别：
#   · 执行层换成 smart_chg 掩码（驱动级停充），不再无脑写输入开关
#   · 不再"每 N 个 tick 无条件重写"；只在"明显回充"时补写一次
#   · 每次开关都做电流校验（写完等它真的停/真的充，再确认状态）
#   · 拔电时主动清掉停充位，保证下次插上一定从"充电"状态开始

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

VERIFY_ON_TRIES=${VERIFY_ON_TRIES:-8}      # 8×2s = 16s 等它停
VERIFY_OFF_TRIES=${VERIFY_OFF_TRIES:-12}   # 12×2s = 24s 等它重新充

logi "=== daemon start v1.2 pid=$$ backend=$BACKEND mode=$MODE thr=$THRESHOLD_ON/$THRESHOLD_OFF ==="

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
  case "$BACKEND" in
    *)
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
      ;;
  esac
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

while true; do
  load_conf
  find_bat
  batt_info

  ONCH=0
  on_charger && ONCH=1

  # 恢复值必须明显低于开启值
  if [ "$THRESHOLD_OFF" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
    THRESHOLD_OFF=$((THRESHOLD_ON - 5))
  fi

  # ---- 决策 ----
  WANT=$BP
  if [ "$ENABLED" != "1" ]; then
    WANT=0
  else
    case "$MODE" in
      force_on)  WANT=1 ;;
      force_off) WANT=0 ;;
      *)
        if [ "$ONCH" = "1" ]; then
          if [ "$LEVEL" -ge "$THRESHOLD_ON" ] 2>/dev/null; then
            WANT=1
          elif [ "$LEVEL" -le "$THRESHOLD_OFF" ] 2>/dev/null; then
            WANT=0
          fi
        else
          WANT=0
        fi
        ;;
    esac
  fi

  # 没插电就没必要维持旁路：清掉停充位，保证下次插上从充电开始
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
    do_off
  elif [ "$WANT" = "1" ] && [ "$BP" = "1" ]; then
    # 稳态：驱动会自己保持，只有在"明显又充上了"时才补一次
    if is_charging; then
      STRIKES=$((STRIKES + 1))
      if [ "$STRIKES" -ge 2 ]; then
        logi "reassert: charging again (cur=$CUR) → rewrite"
        do_on >/dev/null 2>&1
        STRIKES=0
      fi
    else
      STRIKES=0
    fi
  fi

  # 状态变化时同步通知
  if [ "$LAST_STATUS" != "$STATUS" ]; then
    LAST_STATUS=$STATUS
    logi "status -> $STATUS level=$LEVEL cur=$CUR"
    push_ui ""
  fi

  if [ $((TICK % 12)) -eq 0 ]; then
    push_ui ""
  fi

  save_state
  sleep "$POLL"

  if [ -n "$MAX_ROUNDS" ] && [ "$TICK" -ge "$MAX_ROUNDS" ] 2>/dev/null; then
    logi "=== daemon stop after $TICK rounds (test) ==="
    break
  fi
done
