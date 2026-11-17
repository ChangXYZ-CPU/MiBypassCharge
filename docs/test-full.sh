#!/system/bin/sh
# 完整回归测试（v1.7）——真机执行，跑完自动恢复原配置
M=/data/adb/modules/bypass_guard
D=/data/adb/bypass_guard
CTL="$M/bin/bg-ctl.sh"
B=/sys/class/power_supply/battery
Q=/sys/class/qcom-battery

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

cur()  { cat $B/current_now 2>/dev/null; }
cap()  { cat $B/capacity 2>/dev/null; }
smart(){ cat $Q/smart_chg 2>/dev/null; }
bp()   { cat $D/bp_on 2>/dev/null; }

# 等停充：|cur| < 120mA 且 smart_chg 非 0
wait_stop() {
  i=0
  while [ $i -lt 45 ]; do
    c=$(cur); s=$(smart)
    if [ "${c#-}" -lt 120000 ] 2>/dev/null && [ "$s" != "0" ] 2>/dev/null; then return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}
# 等充电：cur < -300mA 且 smart_chg = 0
wait_charge() {
  i=0; hit=0
  while [ $i -lt 40 ]; do
    c=$(cur); s=$(smart)
    case "$c" in
      -*) n=${c#-}; if [ "$n" -gt 500000 ] 2>/dev/null && [ "$s" = "0" ] 2>/dev/null; then hit=$((hit+1)); else hit=0; fi ;;
      *) hit=0 ;;
    esac
    [ "$hit" -ge 2 ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

echo "======== 旁路供电守护 v1.7 完整回归 ========"
echo "开始时间: $(date '+%F %T')  电量: $(cap)%"
echo

# ---- 保存原配置 ----
cp $D/config.conf $D/.test-config.bak

# ============ 0. 静态与进程 ============
echo "[0] 基线检查"
ver=$(grep '^version=' $M/module.prop | cut -d= -f2)
[ "$ver" = "v1.7" ] && ok "版本 $ver" || bad "版本异常 $ver"

for f in $M/bin/*.sh $M/service.sh $M/uninstall.sh $M/customize.sh; do
  sh -n "$f" 2>/dev/null || bad "语法 $f"
done
ok "全部脚本语法检查完毕"

ps -A -o ARGS | grep -q 'bg-supervise[.]sh' && ok "supervisor 存活" || bad "supervisor 不在"
ps -A -o ARGS | grep -q 'bg-daemon[.]sh'    && ok "daemon 存活"    || bad "daemon 不在"
wcount=$(pgrep -f 'bg-watch[.]sh' | wc -l)
[ "$wcount" -ge 1 ] && ok "watch 存活（$wcount 个进程：主+管道子）" || bad "watch 不在"

# ============ 1. 守护自愈 ============
echo "[1] kill daemon → supervisor 是否自动重启"
old=$(cat $D/daemon.pid 2>/dev/null)
kill "$old" 2>/dev/null
i=0; new=""
while [ $i -lt 16 ]; do
  sleep 1; new=$(cat $D/daemon.pid 2>/dev/null)
  [ -n "$new" ] && [ "$new" != "$old" ] && break
  i=$((i+1))
done
[ -n "$new" ] && [ "$new" != "$old" ] && ok "daemon $old → $new（${i}s）" || bad "守护未重启（old=$old new=$new）"
wait_stop && ok "重启后重新停充" || bad "重启后未停充（cur=$(cur) smart=$(smart)）"

# ============ 2. WATCH 开关 ============
echo "[2] 插拔监听开关"
sh $CTL set WATCH 0 >/dev/null 2>&1
sleep 2
w0=$(pgrep -f 'bg-watch[.]sh' | wc -l)
[ "$w0" -eq 0 ] && ok "关：进程数 0" || bad "关：还有 $w0 个进程"

sh $CTL set WATCH 1 >/dev/null 2>&1
sleep 3
w1=$(pgrep -f 'bg-watch[.]sh' | wc -l)
[ "$w1" -ge 1 ] && ok "开：进程数 $w1" || bad "开：进程没起来"

sh $CTL set WATCH 0 >/dev/null 2>&1; sleep 1
sh $CTL set WATCH 1 >/dev/null 2>&1; sleep 3
w2=$(pgrep -f 'bg-watch[.]sh' | wc -l)
[ "$w2" -le "$w1" ] && ok "反复开关不堆积（$w1 → $w2）" || bad "进程堆积（$w1 → $w2）"

# ============ 3. 巡检间隔 ============
echo "[3] 巡检间隔 + 老配置迁移"
sh $CTL set CHECK_INTERVAL 45 >/dev/null 2>&1
v=$(grep '^CHECK_INTERVAL=' $D/config.conf | cut -d= -f2)
[ "$v" = "45" ] && ok "间隔写入 45" || bad "间隔写入失败（$v）"

# 删掉两个新字段，触发 load_conf 自动补写
sed -i '/^WATCH=/d; /^CHECK_INTERVAL=/d' $D/config.conf
sh $CTL status >/dev/null 2>&1
sleep 1
hw=$(grep -c '^WATCH=' $D/config.conf); hc=$(grep -c '^CHECK_INTERVAL=' $D/config.conf)
[ "$hw" -ge 1 ] && [ "$hc" -ge 1 ] && ok "老配置自动补字段" || bad "字段未补回（WATCH=$hw CHECK=$hc）"
sh $CTL set CHECK_INTERVAL 60 >/dev/null 2>&1

# ============ 4~7. 阈值裁决 ============
echo "[4] 阈值 85 → 90（当前 $(cap)%，应恢复充电）"
sh $CTL set THRESHOLD_ON 90 >/dev/null 2>&1
wait_charge && ok "恢复充电（cur=$(cur)）" || bad "未恢复（cur=$(cur) smart=$(smart)）"

echo "[5] 阈值 90 → 85（应停充）"
sh $CTL set THRESHOLD_ON 85 >/dev/null 2>&1
wait_stop && ok "停充（cur=$(cur)）" || bad "未停（cur=$(cur) smart=$(smart)）"

echo "[6] 边界：阈值 → 100（应恢复充电）"
sh $CTL set THRESHOLD_ON 100 >/dev/null 2>&1
wait_charge && ok "100 时恢复充电" || bad "100 时未恢复（cur=$(cur)）"

echo "[7] 边界：阈值 → 40（应停充）"
sh $CTL set THRESHOLD_ON 40 >/dev/null 2>&1
wait_stop && ok "40 时停充" || bad "40 时未停（cur=$(cur)）"

sh $CTL set THRESHOLD_ON 85 >/dev/null 2>&1
sh $CTL set THRESHOLD_OFF 80 >/dev/null 2>&1
wait_stop && ok "恢复 85/80" || bad "恢复阈值失败"

# ============ 8. 总开关 ============
echo "[8] 旁路总开关"
sh $CTL set ENABLED 0 >/dev/null 2>&1
wait_charge && ok "关开关 → 充电" || bad "关开关仍未充电（cur=$(cur) smart=$(smart)）"
sh $CTL set ENABLED 1 >/dev/null 2>&1
wait_stop && ok "开开关 → 停充" || bad "开开关未停（cur=$(cur) smart=$(smart)）"

# ============ 9. 三模式 ============
echo "[9] force_on / resume / auto"
sh $CTL on >/dev/null 2>&1
wait_stop && ok "立即旁路 force_on" || bad "force_on 失败"
sh $CTL resume >/dev/null 2>&1
wait_charge && ok "恢复充电 resume" || bad "resume 失败（cur=$(cur)）"
sh $CTL auto >/dev/null 2>&1
wait_stop && ok "交回自动 auto（当前电量超阈值）" || bad "auto 未停（cur=$(cur)）"

# ============ 10. 界面元素 ============
echo "[10] WebUI 元素"
html=$M/webroot/index.html
for id in enabled watchOn pollNum thNum btnToggle nodeText daemonText; do
  grep -q "id=\"$id\"" "$html" && ok "元素 $id 存在" || bad "元素 $id 缺失"
done
grep -q '插拔即时响应' "$html" && ok "独立省电块存在" || bad "省电块缺失"
grep -q 'setInterval(refreshState, 3000)' "$html" && ok "3 秒刷新" || bad "刷新间隔异常"

# ============ 恢复 ============
echo "[11] 恢复原配置"
cp $D/.test-config.bak $D/config.conf
rm -f $D/.test-config.bak
sh $CTL set CHECK_INTERVAL 60 >/dev/null 2>&1  # 用户当前设的 60
sleep 2
echo "  最终: cap=$(cap)% cur=$(cur) smart=$(smart) bp=$(bp)"
echo "  配置: $(grep -E 'ENABLED|THRESHOLD_ON|THRESHOLD_OFF|WATCH|CHECK_INTERVAL' $D/config.conf | tr '\n' ' ')"
echo
echo "======== 结果: $pass PASS / $fail FAIL ========"
echo "结束时间: $(date '+%F %T')"
