# 分析结论与证据来源（v1.1 审核）

本目录只保存**文字结论和自写工具**，不含任何从厂商设备提取的二进制文件
（厂商 HAL 的版权归原厂所有，不适合放进开源仓库）。

## 关键结论

1. **`smart_chg` 是小米官方的充电保护位**。安全中心「导航断充保护」最终落到：

   ```java
   IMiCharge.setMiChargePath("smart_chg", "0x{level<<16|flag}")
   ```

   - `flag = 3`：导航模式；`flag = 17`：全局/常态化保护
   - 80% 导航断充 → `0x500003`；关闭 → `0x2`
   - 阈值编码：`(level << 16) | flag`

2. **HAL 负责写入 sysfs**：`vendor.xiaomi.hardware.micharge@1.0-service` 运行后，
   把上述值写到 `/sys/class/qcom-battery/smart_chg`。设备属性
   `persist.vendor.smartchg` 是能力位，`bit1` 表示支持导航断充。

3. **官方不轮询**：写完 `smart_chg` 就退出，状态由充电驱动自己保持，
   只在收到导航广播、电池广播、设置变化时重新裁决。

## 复现方法（需要 root）

```bash
# 确认能力位（含 bit1 即支持）
adb shell getprop persist.vendor.smartchg

# 查看 HAL 是否在运行
adb shell 'su -c "getprop init.svc.micharge-hal-1-0"'

# 找出 HAL 引用的 sysfs 路径（不落盘）
adb shell 'su -c "grep -ao \"/sys/[A-Za-z0-9_./:-]*\" \
  /vendor/lib64/hw/vendor.xiaomi.hardware.micharge@1.0-impl.so | sort -u"'
```

## axml.py

自写的 Android 二进制 XML 解码器，当初用来还原 APK 里的 vector drawable
（图标）。与充电逻辑无关，仅为分析过程工具，保留供参考。
