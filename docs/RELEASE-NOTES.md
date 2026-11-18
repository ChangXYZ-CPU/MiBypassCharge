# Release notes · v1.7.3

> 本文件供打 Release 时复制。发布包：`bypass-guard-v1.7.3.zip`
> MD5：`d50bb9d7c812acaf89fed47fe961bb2d`（31,221 字节）
> 历史版本与完整根因分析见 `变更说明.md`；仓库 Release 页有各版更新说明。

## 支持情况

| 项目 | 状态 |
|---|---|
| Root 方案 | **仅 KernelSU v3.x**（实测 v3.2.5 / 32525）。WebUI 依赖 `window.ksu`，**不支持 Magisk、APatch** |
| 机型 | **已在 Redmi K70**（`23113RKC6C` / `vermeer` / SM8550）实测。其他机型见下方"可能兼容" |
| 系统 | HyperOS 2（实测 `2.0.205.0.VNKCNXM`，Android 15） |
| 停充节点 | `/sys/class/qcom-battery/smart_chg`（需 `persist.vendor.smartchg` 含 bit1） |
| 附加 App | 无。纯脚本 + WebUI，不安装任何 App |

### 可能的兼容设备（未测试，不保障安全）

`smart_chg` 在 K70 之后的小米 / 红米高通机型上大概率也普遍存在，
满足以下条件的设备**理论上可能可用**：

- KernelSU v3.x
- 高通平台，`/sys/class/qcom-battery/smart_chg` 存在且可写
- `getprop persist.vendor.smartchg` 含 `bit1`（支持导航断充）
- HyperOS / MIUI 且系统自带「导航断充保护」

自检：`ls -l /sys/class/qcom-battery/smart_chg` 和 `getprop persist.vendor.smartchg`。

> **作者本人只有一台 K70，没有其他设备可以测试。**
> "可能兼容"只是基于接口存在性的推断，未经验证，**不能保障安全性或兼容性**。
> 在其他机型上使用风险自负，详见仓库 `DISCLAIMER.md`。

## 功能

- 插电后充到设定电量（默认 85%）自动停充，手机改由适配器直供，电池 0 W
- 低于恢复点（默认停充点 −5）自动恢复充电
- WebUI 可调：总开关、停充阈值、插拔即时响应开关、巡检间隔
- 停充走小米官方 `smart_chg` 位（安全中心「导航断充保护」同款），驱动自保持，拔插不丢
- 状态判定只看电池电流，不看滞后的 `status` 字段

## 当前版本 v1.7.3 修复

- 守护状态不再误报"未响应"：开总开关 12 秒宽限期内显示"启动中…"
- 自动自愈：连续约 9 秒查不到守护时自动 `bg-ctl boot`，20 秒限流
- 去掉调整充电上限时的 toast（数字框已即时更新，重复提示打断微调）

## 近期修复（v1.7.2）

五个真机反馈问题：① 关总开关彻底停进程省电；② 去掉"手动充电"模式、修好回不到自动；
③ 开关视觉不同步（滑块动、背景等 toast 才变黑——`background` 走主线程 paint 被 KSU
同步 exec 冻结，改用 `opacity` 合成层）；④ 插拔监听提示误闪；⑤ watch 进程堆积到 4 个。
42 项回归全过，详见 `变更说明.md` ## 15–16 节。

## v1.7.1 修复

- 修「插拔即时响应」开关点了会弹回的问题
- 修旁路中巡检间隔失效（设 60 秒实际每 6 秒醒一次）——实测设 120 秒后 2 分半零日志

## 安装

1. 确认已装 KernelSU 并取得 root
2. 下载 `bypass-guard-v1.7.3.zip`（核对 MD5）
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

## 致谢

部分工程实践参考了 [bypass-charger](https://github.com/QiZhi-yi/bypass-charger)（v10.3.5）：
`flock` 串行化写节点（含其记录的驱动死锁事故）、KernelSU 禁用检测、退出复位与 `trap EXIT` 兜底。
停充通道使用小米系统自带的 `smart_chg` 官方停充位。

## 许可

GPL-3.0
