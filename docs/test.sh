#!/system/bin/sh
# 完整回归测试 —— 真机执行，跑完自动恢复原配置
# 适用版本：v1.7.2 起（v1.7.2 新增：总开关彻底停进程 / toggle 两态 / watch 不堆积 /
#             force_off 迁移 / WebUI 修复点校验）。在 K70 + HyperOS 2 验证。
# 覆盖：进程自愈 / WATCH 开关与不堆积 / 巡检间隔 / 阈值裁决 /
#       总开关彻底停进程 / toggle 两态(无 force_off) / 老配置迁移 / WebUI 元素
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
# 计数必须校验 /proc cmdline：裸 pgrep -f 会把执行脚本的 su/adb shell 自身算进去
pcnt() {
  n=0
  for p in $(pgrep -f "$1" 2>/dev/null); do
    [ -r "/proc/$p/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
      *"$2"*) n=$((n+1)) ;;
    esac
  done
  echo $n
}
dcount(){ pcnt 'bg-[d]aemon' 'bg-daemon.sh'; }
scount(){ pcnt 'bg-[s]upervise' 'bg-supervise.sh'; }
wcount(){ pcnt 'bg-[w]atch' 'bg-watch.sh'; }

wait_stop() {
  i=0
  while [ $i -lt 45 ]; do
    c=$(cur); s=$(smart)
    if [ "${c#-}" -lt 120000 ] 2>/dev/null && [ "$s" != "0" ] 2>/dev/null; then return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}
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

echo "======== 旁路供电守护 完整回归 ========"
echo "版本: $(grep '^version=' $M/module.prop | cut -d= -f2)"
echo "开始: $(date '+%F %T')  电量: $(cap)%"
echo

cp $D/config.conf $D/.test-config.bak

# ============ 0. 基线 ============
echo "[0] 基线检查"
# 先确保守护链路完整起来并稳定（避免刚被外部操作重启/清理的窗口期）
sh $CTL boot >/dev/null 2>&1
sleep 5
ver=$(grep '^version=' $M/module.prop | cut -d= -f2)
case "$ver" in
  v1.7.*) ok "版本 $ver" ;;
  *)      bad "版本异常 $ver" ;;
esac
for f in $M/bin/*.sh $M/service.sh $M/uninstall.sh $M/customize.sh; do
  sh -n "$f" 2>/dev/null || bad "语法 $f"
done
ok "脚本语法全部通过"
[ "$(dcount)" -eq 1 ] && ok "daemon=1" || bad "daemon 数量=$(dcount)"
[ "$(scount)" -eq 1 ] && ok "supervise=1" || bad "supervise 数量=$(scount)"
[ "$(wcount)" -eq 2 ] && ok "watch=2(1主1管道子)" || bad "watch 数量=$(wcount)"

# ============ 1. 守护自愈 ============
echo "[1] kill daemon → supervise 自动重启"
old=$(cat $D/daemon.pid 2>/dev/null)
kill "$old" 2>/dev/null
# 等旧 pid 真的消失（TERM 后要跑 on_exit 的 smart_clear，可能 3 秒）
i=0
while [ $i -lt 12 ]; do
  [ -d "/proc/$old" ] || break
  sleep 1; i=$((i+1))
done
# 再等新 daemon 出现（supervise 3 秒后拉起）
i=0; new=""
while [ $i -lt 20 ]; do
  sleep 1; new=$(cat $D/daemon.pid 2>/dev/null)
  if [ -n "$new" ] && [ -d "/proc/$new" ] && [ "$new" != "$old" ]; then break; fi
  i=$((i+1))
done
[ -n "$new" ] && [ -d "/proc/$new" ] && [ "$new" != "$old" ] && ok "daemon $old → $new (${i}s)" || bad "未重启(old=$old new=$new)"
wait_stop && ok "重启后重新停充" || bad "重启后未停充"

# ============ 2. WATCH 开关（含严格不堆积）============
echo "[2] 插拔监听开关"
sh $CTL set WATCH 0 >/dev/null 2>&1
sleep 2; w0=$(wcount)
[ "$w0" -eq 0 ] && ok "关：进程 0" || bad "关：仍有 $w0"

sh $CTL set WATCH 1 >/dev/null 2>&1
sleep 3; w1=$(wcount)
[ "$w1" -eq 2 ] && ok "开：进程 2" || bad "开：进程 $w1（应为2）"

# 反复开关 3 轮，验证严格不堆积
for r in 1 2 3; do
  sh $CTL set WATCH 0 >/dev/null 2>&1; sleep 1
  sh $CTL set WATCH 1 >/dev/null 2>&1; sleep 2
done
w2=$(wcount)
[ "$w2" -eq 2 ] && ok "反复开关3轮仍=2，不堆积" || bad "堆积：$w2（应为2）"

# 重复 boot 不额外起 watch
sh $CTL boot >/dev/null 2>&1; sleep 3
w3=$(wcount)
[ "$w3" -eq 2 ] && ok "重复 boot 仍=2" || bad "boot 后=$w3（应为2）"

# ============ 3. 巡检间隔 + 老配置补字段 ============
echo "[3] 巡检间隔 + 老配置迁移"
sh $CTL set CHECK_INTERVAL 45 >/dev/null 2>&1
v=$(grep '^CHECK_INTERVAL=' $D/config.conf | cut -d= -f2)
[ "$v" = "45" ] && ok "间隔写入 45" || bad "间隔写入失败($v)"
sed -i '/^WATCH=/d; /^CHECK_INTERVAL=/d' $D/config.conf
sh $CTL status >/dev/null 2>&1; sleep 1
hw=$(grep -c '^WATCH=' $D/config.conf); hc=$(grep -c '^CHECK_INTERVAL=' $D/config.conf)
[ "$hw" -ge 1 ] && [ "$hc" -ge 1 ] && ok "老配置自动补字段" || bad "字段未补(W=$hw C=$hc)"
sh $CTL set CHECK_INTERVAL 60 >/dev/null 2>&1

# force_off 老值迁移到 auto
sed -i 's/^MODE=.*/MODE=force_off/' $D/config.conf
sh $CTL status >/dev/null 2>&1
mv=$(grep '^MODE=' $D/config.conf | cut -d= -f2)
[ "$mv" = "auto" ] && ok "force_off 迁移为 auto" || bad "迁移失败($mv)"

# ============ 4~6. 阈值裁决 ============
echo "[4] 阈值 85 → 90（应恢复充电）"
sh $CTL set THRESHOLD_ON 90 >/dev/null 2>&1
wait_charge && ok "恢复充电(cur=$(cur))" || bad "未恢复"

echo "[5] 阈值 90 → 85（应停充）"
sh $CTL set THRESHOLD_ON 85 >/dev/null 2>&1
wait_stop && ok "停充(cur=$(cur))" || bad "未停"

echo "[6] 边界 100 / 40"
sh $CTL set THRESHOLD_ON 100 >/dev/null 2>&1
wait_charge && ok "100 恢复充电" || bad "100 未恢复"
sh $CTL set THRESHOLD_ON 40 >/dev/null 2>&1
wait_stop && ok "40 停充" || bad "40 未停"
sh $CTL set THRESHOLD_ON 85 >/dev/null 2>&1
sh $CTL set THRESHOLD_OFF 80 >/dev/null 2>&1
wait_stop && ok "回 85/80" || bad "回 85/80 失败"

# ============ 7. 总开关：彻底停进程 ============
echo "[7] 总开关 → 彻底停进程省电"
sh $CTL set ENABLED 0 >/dev/null 2>&1
sleep 4
[ "$(dcount)" -eq 0 ] && [ "$(scount)" -eq 0 ] && [ "$(wcount)" -eq 0 ] \
  && ok "关：daemon/supervise/watch 全停" \
  || bad "关：仍有进程 d=$(dcount) s=$(scount) w=$(wcount)"
wait_charge && ok "关：恢复充电" || bad "关：未恢复充电"

sh $CTL set ENABLED 1 >/dev/null 2>&1
sleep 4
[ "$(dcount)" -eq 1 ] && [ "$(scount)" -eq 1 ] && [ "$(wcount)" -eq 2 ] \
  && ok "开：进程恢复 1/1/2" \
  || bad "开：进程异常 d=$(dcount) s=$(scount) w=$(wcount)"
wait_stop && ok "开：重新停充" || bad "开：未停充"

# ============ 8. toggle 两态（不产生 force_off）============
echo "[8] toggle 两态 auto ↔ force_on"
sh $CTL auto >/dev/null 2>&1; sleep 1
m0=$(grep '^MODE=' $D/config.conf | cut -d= -f2)
[ "$m0" = "auto" ] && ok "起点 auto" || bad "起点=$m0"

sh $CTL toggle >/dev/null 2>&1; sleep 2
m1=$(grep '^MODE=' $D/config.conf | cut -d= -f2)
[ "$m1" = "force_on" ] && ok "第一次 toggle → force_on" || bad "toggle1=$m1"

sh $CTL toggle >/dev/null 2>&1; sleep 1
m2=$(grep '^MODE=' $D/config.conf | cut -d= -f2)
[ "$m2" = "auto" ] && ok "第二次 toggle → auto（不再力 force_off）" || bad "toggle2=$m2"

# 确认全流程从未出现 force_off
grep -q '^MODE=force_off' $D/config.conf && bad "配置残留 force_off" || ok "配置无 force_off 残留"

# ============ 9. WebUI 元素 + 修复点 ============
echo "[9] WebUI 元素与本次修复点"
html=$M/webroot/index.html
for id in enabled watchOn pollNum thNum btnToggle nodeText daemonText bgtoast; do
  grep -q "id=\"$id\"" "$html" && ok "元素 $id" || bad "元素 $id 缺失"
done
grep -q 'function nextFrame' "$html" && ok "nextFrame 存在" || bad "nextFrame 缺失"
grep -qE 'ksu[.]toast|k[.]toast' "$html" && ok "调用系统 toast" || bad "未用系统 toast"
grep -q 'setInterval(refreshState, 3000)' "$html" && ok "3 秒刷新" || bad "刷新异常"
css=$M/webroot/style.css
grep -q 'track::before' "$css" && ok "开关背景用 opacity 合成层" || bad "CSS 未改合成层"
grep -q 'will-change' "$css" && ok "will-change 已加" || bad "缺 will-change"
grep -q '已随总开关停止' "$html" && ok "总开关关闭文案" || bad "缺关闭文案"
grep -q '启动中' "$html" && ok "watch 启动宽限文案" || bad "缺宽限文案"

# ============ 恢复 ============
echo "[10] 恢复原配置"
cp $D/.test-config.bak $D/config.conf
rm -f $D/.test-config.bak
sh $CTL boot >/dev/null 2>&1
sleep 3
echo "  最终: cap=$(cap)% cur=$(cur) smart=$(smart) bp=$(bp)"
echo "  进程: d=$(dcount) s=$(scount) w=$(wcount)"
echo "  配置: $(grep -E 'ENABLED|MODE|THRESHOLD_ON|THRESHOLD_OFF|WATCH|CHECK_INTERVAL' $D/config.conf | tr '\n' ' ')"
echo
echo "======== 结果: $pass PASS / $fail FAIL ========"
echo "结束: $(date '+%F %T')"
