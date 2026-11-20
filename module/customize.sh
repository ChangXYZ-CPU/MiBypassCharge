SKIPUNZIP=0

# 安装横幅：不用方框包裹中文（中英文字符在 KSU 终端宽度不等，会错位）
ui_print " "
ui_print "  ======== MiBypassCharge ========"
ui_print "   smart_chg 官方停充位"
ui_print " "
# 版本号从 module.prop 动态读取，避免硬编码后忘记更新
if [ -f "$MODPATH/module.prop" ]; then
  _v=$(grep '^version=' "$MODPATH/module.prop" | head -1 | cut -d= -f2)
  [ -n "$_v" ] && ui_print "   $_v"
fi
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755

set_perm "$MODPATH/service.sh"   0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755

ui_print "- 安装完成（重启后生效）"
ui_print "- 打开方式：KernelSU → 模块 → MiBypassCharge → 打开"
ui_print "- 停充阈值等参数见 WebUI；配置不随升级丢失"
ui_print " "
