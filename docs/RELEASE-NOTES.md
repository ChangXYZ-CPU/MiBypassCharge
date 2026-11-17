# Release notes · v1.7.1

> 本文件供打 Release 时复制。发布包：`bypass-guard-v1.7.1.zip`
> MD5：`c28f0de6ff102005517b7e86383fecb3`（26,859 字节）

## 支持情况

| 项目 | 状态 |
|---|---|
| Root 方案 | **仅 KernelSU v3.x**（实测 v3.2.5 / 32525）。WebUI 依赖 `window.ksu`，**不支持 Magisk、APatch** |
| 机型 | **仅 Redmi K70**（`23113RKC6C` / `vermeer` / SM8550），其他机型未验证 |
| 系统 | **仅 HyperOS 2**（实测 `2.0.205.0.VNKCNXM`，Android 15） |
| 停充节点 | `/sys/class/qcom-battery/smart_chg`（需 `persist.vendor.smartchg` 含 bit1） |
| 附加 App | 无。纯脚本 + WebUI，不安装任何 App |

## 功能

- 插电后充到设定电量（默认 85%）自动停充，手机改由适配器直供，电池 0 W
- 低于恢复点（默认停充点 −5）自动恢复充电
- WebUI 可调：总开关、停充阈值、插拔即时响应开关、巡检间隔
- 停充走小米官方 `smart_chg` 位（安全中心「导航断充保护」同款），驱动自保持，拔插不丢
- 状态判定只看电池电流，不看滞后的 `status` 字段

## v1.7.1 修复

- 修「插拔即时响应」开关点了会弹回的问题
- 修旁路中巡检间隔失效（设 60 秒实际每 6 秒醒一次）——实测设 120 秒后 2 分半零日志

## 安装

1. 确认已装 KernelSU 并取得 root
2. 下载 `bypass-guard-v1.7.1.zip`（核对 MD5）
3. KernelSU → 模块 → 从本地安装 → 选 zip → 重启
4. 模块卡片点「打开」进入 WebUI

## 卸载与救急

正常卸载：KernelSU 模块列表移除，`uninstall.sh` 会两步复位 `smart_chg`。

**若刷完发现手机不充电**（root 终端执行）：

```sh
echo 0x2 > /sys/class/qcom-battery/smart_chg
sleep 4
echo 0   > /sys/class/qcom-battery/smart_chg
```

仍不行就重启手机（sysfs 不落盘，重启必然复位）。

## 风险提示

修改系统充电行为，**可能导致设备无法充电**。请备份数据并自行承担风险。
与小米、KernelSU 及任何厂商无关。详见仓库 `DISCLAIMER.md`。

## 许可

GPL-3.0
