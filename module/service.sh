#!/system/bin/sh
# service.sh — 开机拉起守护
#
# 守护本体交给 bg-supervise.sh 看护：它退出就重启，活着时零唤醒。
# 原来这里是「每 30 秒 pgrep 一次」，既多一层定时唤醒，pgrep -f 还会误判。

MODDIR=${0%/*}
DATA=/data/adb/bypass_guard

mkdir -p "$DATA" 2>/dev/null

# 等待系统启动完成
i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
  i=$((i + 1))
  [ "$i" -gt 90 ] && break
done

# 再多等一会儿，等充电驱动初始化完
sleep 8

# 清掉上一次残留（重启后 pid 文件还在的情况）
if [ -f "$DATA/supervisor.pid" ]; then
  _o=$(cat "$DATA/supervisor.pid" 2>/dev/null)
  [ -n "$_o" ] && kill "$_o" 2>/dev/null
  sleep 1
fi
pkill -f "bypass_guard/bin/bg-watch.sh" 2>/dev/null
pkill -f "bypass_guard/bin/bg-supervise.sh" 2>/dev/null
pkill -f "bypass_guard/bin/bg-daemon.sh" 2>/dev/null
sleep 1

# 插拔监听器（logcat battery_status）：插拔时即时叫醒守护
MODDIR="$MODDIR" sh "$MODDIR/bin/bg-watch.sh" >/dev/null 2>&1 &

# 守护 + 看护
MODDIR="$MODDIR" sh "$MODDIR/bin/bg-supervise.sh" >/dev/null 2>&1 &
