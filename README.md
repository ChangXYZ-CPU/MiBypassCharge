# 旁路供电守护（Redmi K70）

KernelSU 模块：插上充电器后，电池充到设定电量就停止充电，手机由适配器直供（电池 0 W）。
停充走的是小米充电驱动的官方位 `smart_chg` —— 和安全中心「导航断充保护」同一条路，
状态由驱动保持，拔插不丢，不需要周期性重写。

- 机型：Redmi K70（`23113RKC6C` / `vermeer` / SM8550）
- 系统：HyperOS 2（实测 `2.0.205.0.VNKCNXM`，Android 15）
- 依赖：KernelSU（模块本身只跑 root 脚本，不装任何 App）

## 目录

```
module/           模块本体（可直接打包成 zip 刷入）
  META-INF/       KernelSU 安装脚本入口
  bin/bg-lib.sh   公共函数：节点读写、电池信息、smart_chg 操作
  bin/bg-daemon.sh 守护主循环：按阈值开关旁路、校验电流、失败退避
  bin/bg-ctl.sh   控制接口：status / on / resume / off / auto / toggle / set / log / restart
  webroot/        WebUI 单页（HTML 内联 JS，无外链，避免 WebView 缓存旧代码）
  module.prop     模块信息
  customize.sh    安装时权限设置
  service.sh      开机拉起守护 + 看门狗
  uninstall.sh    卸载时两步复位 smart_chg，保证不会留下"永远不充电"

docs/
  变更说明.md     从 v1.1 到 v1.4 改了什么、实测数据、已知限制
  审核报告.md     v1.1 的实机审核：节点矩阵、官方实现反编译、逐条缺陷
  调试速查.md     命令速查（只看电流，不看 status）
  probe-k70.sh    节点探针（默认只读；--test 会逐项写 3 秒并还原）

build.sh          打包：读 module.prop 的版本号，生成 bypass-guard-v<版本>.zip
```

## 构建 / 安装

```bash
bash build.sh                       # 生成 bypass-guard-v1.4.5.zip
# KernelSU → 模块 → 从本地安装 → 选 zip → 重启
```

## 使用

打开 WebUI 后有四个东西：

| 控件 | 作用 |
|---|---|
| 旁路供电（开关） | 总开关。关掉就完全不管，插上一直充 |
| 充到多少停（− 数字 +） | 停充电量，40–100%，点一次 ±5 或直接输入 |
| 恢复充电 / 立即旁路 | 临时手动切换，等于把模式切到「手动」 |
| 状态环 / 四个指标 | 电量、电池功率、电压、电池电流、温度 |

判据只看**电池电流**：充电为正、放电为负，`|I| < 120 mA` 才算停充成功。

## 注意

- **更新 WebUI 后界面没变化**：KernelSU 的 WebView 有缓存，`/data/data/me.weishu.kernelsu/app_webview`
  删掉再进（或强制停止管理器）。
- **卸载**：KernelSU 里移除模块即可，`uninstall.sh` 会走 `0x2 → 等 3 秒 → 0` 两步复位。
  手动救急：
  ```bash
  echo 0x2 > /sys/class/qcom-battery/smart_chg; sleep 3
  echo 0   > /sys/class/qcom-battery/smart_chg
  ```
- 用 KernelSU "禁用" 而不是 "卸载" 时，`uninstall.sh` 不会执行；驱动状态会保持到重启，重启后自然复位。
- 只验证过 K70 / HyperOS 2；其他机型先读 `docs/审核报告.md` 和 `smart_chg` 是否存在。
