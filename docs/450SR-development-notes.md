# CarWithin-450SR 开发笔记

本仓库是 [xmz28/CarWithin](https://github.com/xmz28/CarWithin)（AGPL-3.0-only）的二次开发分支，目标车型为 **2024 款春风 450SR**（5 寸 TFT 仪表，MotoPlay / EasyConnect / Carbit 体系）。

## 背景

- 上游 1.0.5 的「春风 5 寸」模式（`App/CfmotoOutput.swift` + `App/PxcConnection.swift`）维护者无实车，实测在本车上无法连接。
- 社区存在一个闭源的「CarWithin 1.0.86 (build 86)」融合版，实测可在 450SR 上完整跑通投屏。通过对该 IPA 的符号级分析确认，其融合来源为开源项目 **[OpenCfMoto iOS](https://github.com/Kevinparra535/opencfmoto-ios)**（AGPL-3.0-or-later，Android 原版为 [zanderp/open-cfmoto](https://github.com/zanderp/open-cfmoto)）。
- 因此本分支的路线是：把 OpenCfMoto 的 PXC/EasyConn 链路移植进 CarWithin 1.0.5，重建可维护的开源春风模式，再叠加自有功能。

## IPA 分析结论（1.0.86 vs 1.0.5）

| 项目 | 1.0.5 官方 | 1.0.86 融合版 |
| --- | --- | --- |
| Swift 符号数 | 8439 | 28959 |
| 春风链路 | `CfmotoOutput` / `PxcConnection`（TCP 10920/10921/10922，探测 10930） | 新增 `CfMotoVideoSource` / `CfMotoTuning` / `CfMotoLiveStats` / `CfMotoLogServer` / `PxcOrgJSON` / `HuTimeSync` |
| 仪表自绘 UI | 无 | `DashUIController` / `DashPalette` / `DashModel` / `DashLayout`（对应 OpenCfMoto `Dash/`） |
| 导航 | 无（投 CarPlay 画面） | `NavigationSession` / `RouteOrchestrator` / `PlaceSearch`（OpenStreetMap 自绘导航） |
| 车把按键 | 无 | `HandlebarGestureEngine` / `ButtonAction.handlebarDashInput` |
| 其他 | — | `TripRecorder`、`LapTimer`、`GhostTouchFilter`、`BikeProfile`/`BikeSettings`、`POSIXNetworkProvider`、`AndroidOrgJSON` |
| 内置身份 | certificate.p7b / leaf.cer / private.x963 | 相同（Bundle ID 同为 com.hanlinzhou.SameDeviceCarPlayPoC） |

1.0.86 二进制中的字符串 `GPX creator="OpenCfMoto"`、`OpenCfMoto needs ports [10922, 10921, 10920]`、`http://manual.opencfmoto.local` 与 OpenCfMoto iOS 源码一一对应。

## 450SR 实测参数（2026-11-27）

- 仪表 Wi-Fi：`DIRECT-go-CFMOTA-4F9091` 形态（DIRECT-go-CFMOTO-XXXX），无网关发布
- 手机获配 IP：`192.168.49.x/24`；**车机地址为 `192.168.49.1`**（上游默认 `192.168.0.1` 不在本网段，探测必然超时）
- 探测端口 10930 通；握手 CLIENT_INFO：SDK `0.9.23.4`、pxcVersion `1.0.2`、`supportScreenTouch: false`（仪表无触控回传）、`transportType: 2`
- 车机画布协商结果：**800×400**（非 1024×512）；测试图案以 ~29 fps 稳定拉流
- 车机会主动回连手机监听的 10920–10922；若探测目标 IP 错误，会话会在 probe 超时后被中止
- **端口 10920–10922 冲突**：手机上的春风出行/MotoPlay 官方 App 占用这些端口，必须上滑关闭（EADDRINUSE）
- CarPlay 侧会话完整健康：iAP2 认证 → Pair-Setup/Verify → H.264 首帧 ~4.7s（1024×512, profile 100/level 3.1）→ App 内强制转码 Baseline 3.1 输出给车机

完整成功链路日志样例：车机 Wi-Fi → 10930 探测 → CLIENT_INFO 握手 → 800×400 画布 → 拉流 29fps。

## 开发路线

- [x] 阶段①：建立本仓库（1.0.5 基线 + 本笔记 + CI 自动打包）
- [ ] 阶段②：移植 OpenCfMoto PXC/EasyConn 到 CarWithin，复现 450SR 可连接
- [ ] 阶段③：手机连上车蓝牙自动启动 CarPlay 并连接仪表（参考 YouNai-012/CarWithin 补丁）
- [ ] 阶段④：车把按键 → CarPlay 媒体控制/接听（参考 z626213826/CarWithin-handlebar 与 OpenCfMoto `HandlebarGestureEngine`）

## 构建

```sh
python3 Tools/generate_project.py
xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/source
```

GitHub Actions 会在每次 push 到 main 时自动构建并上传 unsigned IPA artifact，用侧载工具签名后安装。

配件认证身份不包含在源码中，需自行放置到 `App/BundledIdentity/`（见上游 SOURCE-BUILD.md）。

## 许可

完整组合程序按 **AGPL-3.0-only** 分发，保留上游所有作者署名与提交历史。详见 LICENSE 与 THIRD_PARTY_NOTICES.txt。CarWithin 与 Apple、CFMOTO 无官方关联。
