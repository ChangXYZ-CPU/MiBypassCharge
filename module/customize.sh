SKIPUNZIP=0

ui_print " "
ui_print "  ┌─────────────────────────────┐"
ui_print "  │   旁路供电守护  v1.6        │"
ui_print "  │   Redmi K70 / vermeer       │"
ui_print "  │   smart_chg 官方停充位      │"
ui_print "  └─────────────────────────────┘"
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755

set_perm "$MODPATH/service.sh"   0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755

ui_print "- 安装完成（重启后生效）"
ui_print "- 打开方式：KernelSU → 模块 → 旁路供电守护 → 打开"
ui_print "- 默认：到 80% 停充（真旁路），低于 70% 恢复"
ui_print "- 省电：没插电 60 秒看一眼，插着电 15 秒，快到阈值 3 秒"
ui_print " "
