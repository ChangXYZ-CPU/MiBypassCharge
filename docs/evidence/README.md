# 分析证据（v1.1 审核时从真机提取）

| 文件 | 来源 |
|---|---|
| `vendor/micharge-impl.so` | `/vendor/lib64/hw/vendor.xiaomi.hardware.micharge@1.0-impl.so` |
| `vendor/micharge-service` | `/vendor/bin/hw/vendor.xiaomi.hardware.micharge@1.0-service` |
| `vendor/vendor.xiaomi.hardware.micharge@1.0-service.rc` | `/vendor/etc/init/…-service.rc`（列出被 chown 给 system 的 sysfs 节点） |
| `axml.py` | 自写的 AXML 解码器，用来还原 APK 里的 vector drawable（取图标用） |

HAL 里的 `setMiChargePath / setInputSuspendState / setNightChargingState` 等符号，
就是「安全中心 → 导航断充保护」最终落到 `smart_chg` 的依据。

大文件（MIUISecurityCenter.apk / Settings.apk / framework.jar / services.jar）不在仓库里，
需要时用 `adb pull` 重新取。
