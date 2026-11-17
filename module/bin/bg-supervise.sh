#!/system/bin/sh
# bg-supervise.sh — 守护的看护循环
#
# 只做一件事：把 bg-daemon.sh 当"前台子进程"跑，它退出就重启。
# 守护活着的时候这个脚本在 wait，没有任何定时唤醒（比每 30 秒 pgrep 省电）。
# 单独成文件是为了让 service.sh 和 bg-ctl.sh restart 复用同一份逻辑。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=${DATA_DIR_OVERRIDE:-/data/adb/bypass_guard}
mkdir -p "$DATA_DIR" 2>/dev/null

# pid 会被复用，光看 kill -0 不够，要认命令行
_is_running() {
  [ -n "$1" ] || return 1
  [ -r "/proc/$1/cmdline" ] || return 1
  case "$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)" in
    *bg-supervise.sh*) return 0 ;;
  esac
  return 1
}

if [ -f "$DATA_DIR/supervisor.pid" ]; then
  _old=$(cat "$DATA_DIR/supervisor.pid" 2>/dev/null)
  if [ "$_old" != "$$" ] && _is_running "$_old"; then
    exit 0
  fi
fi
echo $$ > "$DATA_DIR/supervisor.pid"

while true; do
  MODDIR="$MODDIR" sh "$MODDIR/bin/bg-daemon.sh" >/dev/null 2>&1
  sleep 3
done
