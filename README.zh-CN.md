# mac-lid-audio-guard

[English](README.md) | 简体中文

macOS 合盖静音与蓝牙防唤醒工具。它用于避免 MacBook 合盖后被蓝牙键盘或鼠标唤醒，并阻止音乐、视频或系统提示音在夜间意外发声。

项目包含两层相互独立的保护：

```text
蓝牙 HID 活动
    └─ RemoteWakeEnabled = false

合盖事件
    ├─ 保存原输出路由、静音与音量
    ├─ 静音所有可控制输出
    ├─ 将默认/系统声音路由到已静音的安全设备
    ├─ 暂停当前媒体服务
    └─ 开盖后精确恢复并清除临时状态
```

## 当前验证环境

- macOS 26.5.2
- Apple Silicon（M4）
- DELL S2725QC 外接显示器
- MacBook 内建扬声器
- QQ 音乐 11.7.0
- MX2.0S Bluetooth LE 键盘

## 快速使用

```bash
cd ~/workspace/mac-lid-audio-guard
./scripts/test.sh
./scripts/install.sh
./scripts/status.sh
```

安装蓝牙防唤醒时需要一次管理员权限，用于把
`RemoteWakeEnabled=false` 立即写入正在运行的蓝牙控制器。蓝牙开关、配对记录及清醒状态下的使用不受影响。

如果只需要安装或更新合盖静音监听器，保留现有蓝牙设置：

```bash
./scripts/install.sh --skip-bluetooth-wake
```

## 常用命令

```bash
make build
make test
make status

./scripts/bluetooth-wake.sh status
./scripts/bluetooth-wake.sh disable
./scripts/bluetooth-wake.sh enable

./scripts/uninstall.sh
```

`test.sh` 会执行编译器告警检查、Clang 静态分析、Shell 语法检查、LaunchAgent plist 校验，以及一次短暂的“静音 → 安全路由 → 状态落盘 → 模拟重启 → 精确恢复”测试。测试不会主动播放声音。

只做静态检查时：

```bash
./scripts/test.sh --no-live-test
```

## 安装位置

- 监听器：`~/Library/Application Support/LidAudioGuard/lid-audio-guard`
- 登录项：`~/Library/LaunchAgents/com.younglue.lid-audio-guard.plist`
- 日志：`~/Library/Logs/LidAudioGuard.log`
- 合盖期间的恢复状态：`~/Library/Application Support/LidAudioGuard/saved-audio-state.plist`

恢复状态只在合盖保护激活时存在。正常开盖后应自动删除。

## 项目结构

```text
src/LidAudioGuard.m              合盖、CoreAudio 静音与恢复逻辑
src/BluetoothWakeControl.c       实时蓝牙远程唤醒属性控制
config/*.plist.in                LaunchAgent 模板
scripts/build.sh                 构建两个原生 arm64 工具
scripts/install.sh               安装并加载
scripts/uninstall.sh             恢复状态并卸载
scripts/status.sh                只读运行态检查
scripts/test.sh                  静态与实时恢复测试
docs/incident-and-design.md      原始问题与设计边界
```

## 设计说明

合盖静音使用公开的 IOKit 合盖通知与 CoreAudio 属性。媒体暂停使用系统内置 MediaRemote 通道，属于额外保险；即使未来系统版本不再接受媒体暂停命令，静音与安全路由仍是主要防线。

完整背景见 [docs/incident-and-design.md](docs/incident-and-design.md)。
