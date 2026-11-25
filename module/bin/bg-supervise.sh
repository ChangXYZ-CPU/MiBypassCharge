#!/system/bin/sh
# bg-supervise.sh — 守护的看护循环
#
# 只做一件事：把 bg-daemon.sh 当"前台子进程"跑，它退出就重启。
# 守护活着的时候这个脚本在 wait，没有任何定时唤醒（比每 30 秒 pgrep 省电）。
# 单独成文件是为了让 service.sh 和 bg-ctl.sh restart 复用同一份逻辑。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=${DATA_DIR_OVERRIDE:-/data/adb/MiBypassCharge}
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

# 脱离 KSU 管理器的 app 进程组（原理见 bg-lib.sh 的 cg_escape）。
# 放在单实例判断之后、拉起 daemon 之前：daemon 由本进程 fork，继承根组。
# 若 supervisor 是开机/service.sh 拉起的，本来就在根组，cg_escape 直接返回。
# 这里是"链条真正起来了"的唯一入口，所以只有这里传 loud 写一行取证日志
# （bg-ctl 被 WebUI 每 3 秒轮询一次 status，不能每次都写）。
. "$MODDIR/bin/bg-lib.sh" 2>/dev/null
cg_escape loud 2>/dev/null

while true; do
  MODDIR="$MODDIR" sh "$MODDIR/bin/bg-daemon.sh" >/dev/null 2>&1
  sleep 3
done
