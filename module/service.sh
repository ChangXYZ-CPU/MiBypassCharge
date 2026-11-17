#!/system/bin/sh
# service.sh — 开机启动守护进程

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

# 防止重复启动
if [ -f "$DATA/daemon.pid" ]; then
  old=$(cat "$DATA/daemon.pid" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    exit 0
  fi
fi

MODDIR="$MODDIR" sh "$MODDIR/bin/bg-daemon.sh" >/dev/null 2>&1 &
echo $! > "$DATA/daemon.pid"

# 看门狗：daemon 意外退出时自动拉起
(
  while true; do
    sleep 30
    if ! pgrep -f "bg-daemon.sh" >/dev/null 2>&1; then
      MODDIR="$MODDIR" sh "$MODDIR/bin/bg-daemon.sh" >/dev/null 2>&1 &
      echo $! > "$DATA/daemon.pid"
    fi
  done
) >/dev/null 2>&1 &
