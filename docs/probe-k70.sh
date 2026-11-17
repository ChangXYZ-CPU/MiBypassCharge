#!/system/bin/sh
# ============================================================================
# probe-k70.sh — 在 K70 上确认"哪个节点能真正停充、极性对不对"
#
# 用法（手机 root shell 里跑，或用 adb shell su -c 'sh /path/probe-k70.sh --test'）：
#   sh probe-k70.sh            只读：只打印节点是否存在 / 当前值 / 权限，不写任何东西
#   sh probe-k70.sh --test     逐项写 3 秒 → 立即还原 → 再等 2 秒
#
# --test 会依次对 5 个候选节点做"写 3 秒就还原"的试验，全程只碰停充节点，
# 不碰任何系统服务、不改设置、不写 /data。每一项都会把原值写回去。
# 中途 Ctrl-C 也会走 trap 还原当前项。
#
# 判据：写入后 current_now 的绝对值接近 0（< 200000）且 status 变成
#       Not charging / Discharging，才算"真停充"。
#       注意 current_now 单位 µA，负值=充电。
# ============================================================================

TEST=0
[ "$1" = "--test" ] && TEST=1

BAT=/sys/class/power_supply/battery
USB=/sys/class/power_supply/usb
QB=/sys/class/qcom-battery

say() { echo "$*"; }
hr()  { echo "------------------------------------------------------------"; }

show_state() {
  st=$(cat $BAT/status 2>/dev/null)
  cur=$(cat $BAT/current_now 2>/dev/null)
  cap=$(cat $BAT/capacity 2>/dev/null)
  onl=$(cat $USB/online 2>/dev/null)
  vbus=$(cat $USB/voltage_now 2>/dev/null)
  say "    status=$st  current=${cur}µA  capacity=${cap}%  usb.online=$onl  vbus=${vbus}µV"
}

# ---- 0. 环境 ----
hr
say "设备：$(getprop ro.product.model) / $(getprop ro.product.device) / $(getprop ro.board.platform)"
say "系统：$(getprop ro.build.version.incremental)  内核：$(uname -r)"
say "smartchg 能力位：persist.vendor.smartchg=$(getprop persist.vendor.smartchg)"
say "时间：$(date)"
hr

# ---- 1. 只读巡检 ----
say "【当前状态】"
show_state
say ""
say "【候选节点存在性 / 值 / 权限 / SELinux】"
for p in \
  $QB/input_suspend $QB/restrict_chg $QB/restrict_cur $QB/charging_suspend_battery \
  $QB/night_charging $QB/smart_chg $QB/smart_batt \
  $BAT/input_suspend $BAT/charging_enabled $BAT/battery_charging_enabled \
  $BAT/charge_disable $BAT/constant_charge_current_max $BAT/constant_charge_current \
  $BAT/charge_control_limit ; do
  if [ -e "$p" ]; then
    printf "  EXIST %-58s = [%s]  %s  %s\n" "$p" "$(cat $p 2>&1)" \
      "$(stat -c %U:%G:%A $p 2>/dev/null)" "$(ls -Z $p 2>/dev/null | awk '{print $1}')"
  else
    printf "  MISS  %s\n" "$p"
  fi
done

if [ "$TEST" = "0" ]; then
  hr
  say "只读模式结束。要真正验证极性，加参数 --test 再跑一次。"
  say "（--test 会每项写 3 秒后立刻还原，不会留下状态）"
  exit 0
fi

# ---- 2. 写测试 ----
# smart_chg 的等级按"当前电量"取，这样写进去就会立刻触发停充，而不是等充到 80%
LV=$(cat $BAT/capacity 2>/dev/null)
[ -z "$LV" ] && LV=50
SCC=$(printf '0x%x' $(( (LV << 16) | 3 )))

# 每项：路径|写入值|还原值|说明
LIST="
$QB/input_suspend|1|0|挂起输入（Scene 用的就是这个）
$QB/restrict_chg|1|0|限制充电
$QB/charging_suspend_battery|1|0|挂起电池充电（可能是真旁路）
$QB/night_charging|1|0|夜间充电位（Scene 表里 1=停）
$QB/smart_chg|$SCC|0x2|官方 smart_chg 掩码（按当前 $LV% 停充，导航模式 $SCC）
"

CUR_NODE=""
CUR_ORIG=""
cleanup() {
  if [ -n "$CUR_NODE" ] && [ -n "$CUR_ORIG" ]; then
    echo "$CUR_ORIG" > "$CUR_NODE" 2>/dev/null
    say "  !! 中断，已还原 $CUR_NODE = $CUR_ORIG"
  fi
}
trap 'cleanup; exit 1' INT TERM

hr
say "开始写测试（每项 3 秒，写完立刻还原）"
say "开始前请保持：插着充电器、电量低于 90%、屏幕亮着"
hr

while IFS='|' read -r node on off desc; do
  [ -z "$node" ] && continue
  [ -e "$node" ] || { say "  跳过（不存在）$node"; continue; }

  orig=$(cat "$node" 2>/dev/null)
  CUR_NODE="$node"; CUR_ORIG="$orig"

  say ""
  say ">>> $node   ($desc)"
  say "    原值 = [$orig]  写入 [$on]"
  show_state

  echo "$on" > "$node" 2>/dev/null
  rc=$?
  sleep 5
  say "    写入 rc=$rc，3 秒后："
  show_state

  echo "$orig" > "$node" 2>/dev/null
  CUR_NODE=""; CUR_ORIG=""
  sleep 3
  say "    已还原为 [$orig]，2 秒后："
  show_state
done <<EOF
$LIST
EOF

hr
say "结论怎么读："
say "  · 写入那 3 秒里 current 绝对值掉到 20 万以下 → 这个节点真能停充"
say "  · current 变正数（+30 万左右）→ 断的是输入，手机在吃电池（不是旁路）"
say "  · current 没怎么变、status 还是 Charging → 这个节点对本机无效"
say "  · 顺便看 usb.online：如果写入后掉成 0，说明『按 usb.online 判断是否插电』"
say "    的做法会在旁路中误判成『拔了充电器』，模块会自己退出旁路。"
hr
