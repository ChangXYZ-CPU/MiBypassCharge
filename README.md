# 旁路供电守护（Redmi K70）

KernelSU 模块：插上充电器后，电池充到设定电量就停止充电，手机由适配器直供（电池 0 W）。
停充走小米充电驱动的官方位 `smart_chg` —— 和安全中心「导航断充保护」同一条路，
状态由驱动保持，拔插不丢，不需要周期性重写。

- 机型：Redmi K70（`23113RKC6C` / `vermeer` / SM8550）
- 系统：HyperOS 2（实测 `2.0.205.0.VNKCNXM`，Android 15）
- Root：**仅 KernelSU**（WebUI 依赖 `window.ksu`，不支持 Magisk / APatch）
- 模块本身只有 root 脚本 + WebUI，**不安装任何 App**

## 目录

```
module/                    模块本体（可直接打包成 zip 刷入）
  META-INF/                KernelSU 安装脚本入口
  module.prop              模块信息
  customize.sh             安装时权限设置
  service.sh               开机拉起看护与监听器
  uninstall.sh             卸载时两步复位 smart_chg，保证不会留下"永远不充电"
  bin/bg-lib.sh            公共函数：内建 read 读电池、flock 写节点、smart_chg 掩码
  bin/bg-daemon.sh         守护主循环：自适应轮询、阈值滞回、退出复位
  bin/bg-supervise.sh      看护循环：守护退出就重启，活着时零唤醒
  bin/bg-watch.sh          插拔监听：logcat 跟电池事件，插拔时即时叫醒守护
  bin/bg-ctl.sh            控制接口：status / on / resume / off / auto / toggle / set / log / restart
  webroot/                 WebUI 单页（HTML 内联 JS，无外链，避免 WebView 缓存旧代码）

docs/
  变更说明.md              从 v1.1 到 v1.7.1 的改动、实测数据、踩过的坑
  审核报告.md              v1.1 的实机审核：节点矩阵、官方实现反编译、逐条缺陷
  调试速查.md              命令速查（只看电流，不看 status）
  probe-k70.sh             节点探针（默认只读；--test 会逐项写并还原）
  test-full.sh             全量回归脚本（31 项，跑完自动还原配置）
  evidence/                官方 smart_chg 路径的文字结论与自写 AXML 解码器

build.sh                   打包：读 module.prop 的版本号，生成 bypass-guard-v<版本>.zip
```

## 构建 / 安装

```bash
bash build.sh                       # 生成 bypass-guard-v<版本>.zip
# KernelSU → 模块 → 从本地安装 → 选 zip → 重启
```

## 使用

进 KSU 模块卡片点「打开」进入 WebUI：

| 控件 | 作用 |
|---|---|
| 旁路供电（总开关） | 关掉就完全不管，插上一直充 |
| 充到多少停（− 数字 +） | 停充电量，40–100%，点一次 ±5 或直接输入 |
| 插拔即时响应（开关） | 开=插拔立刻响应（多耗约 0.2%/天）；关=省电，等下次巡检 |
| 巡检间隔（− 数字 +） | 平时多久看一眼电量，5–120 秒，越小越灵敏越费电 |
| 恢复充电 / 立即旁路 | 临时手动切换 |
| 状态环 / 四个指标 | 电量、电池功率、电压、电池电流、温度 |

判据只看**电池电流**：充电为正、放电为负，`|I| < 120 mA` 才算停充成功。

**滞回**：≥ 停止阈值就停，≤ 恢复阈值（默认停充点 −5）才继续充，中间保持现状。
旁路下几乎不掉电，所以从 85 掉到 80 通常要几小时，不会来回切。

## 耗电

读取全部用 shell 内建 `read`（不 fork），每轮成本约 50 ms。巡检间隔按场景自适应：

| 场景 | 间隔（默认巡检 60 秒时） | 单核占用 |
|---|---|---|
| 插电、离阈值 ≤3% | 6 s（间隔/10，最小 3 s） | ~0.8% |
| 已在旁路中 / 插电中段 | 60 s | ~0.08% |
| 没插电 / 功能关闭 | 120 s | ~0.04% |

插拔监听（可关）另占约 0.233% 单核。关掉它 + 把巡检调到 120 秒，
就是本模块最省电的配置。详见 `docs/变更说明.md` §10–§14 的实测数据。

## 注意

- **更新 WebUI 后界面没变化**：KernelSU 的 WebView 有缓存。光退出重进不够，
  需要 `am force-stop me.weishu.kernelsu` 并删掉
  `/data/data/me.weishu.kernelsu/app_webview` 再进。
- **卸载**：KernelSU 里移除模块即可，`uninstall.sh` 会走 `0x2 → 等 3 秒 → 0` 两步复位。
  手动救急：
  ```bash
  echo 0x2 > /sys/class/qcom-battery/smart_chg; sleep 4
  echo 0   > /sys/class/qcom-battery/smart_chg
  ```
- 用 KernelSU「禁用」而不是「卸载」时，`uninstall.sh` 不会执行；驱动状态保持到重启。
- 只验证过 K70 / HyperOS 2。其他机型先看 `docs/审核报告.md`，确认 `smart_chg` 存在且
  `persist.vendor.smartchg` 含 `bit1`。

## 免责声明

见 [DISCLAIMER.md](DISCLAIMER.md)。简要说：本项目修改系统充电行为，**可能导致设备无法充电**，
请自行承担风险并保留救急手段；与小米、KernelSU 及任何厂商无关。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。
