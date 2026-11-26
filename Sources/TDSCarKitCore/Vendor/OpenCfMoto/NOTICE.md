OpenCfMoto 协议栈移植说明
=========================

本目录下的 Swift 文件移植自 OpenCfMoto iOS 项目：

  https://github.com/Kevinparra535/opencfmoto-ios
  Packages/OpenCfMotoKit/Sources/OpenCfMotoCore/

  协议层来源（Android 原版）：
  https://github.com/zanderp/open-cfmoto

许可：AGPL-3.0-or-later（各文件头部 SPDX 标识保留）。
本目录代码与 CarWithin（AGPL-3.0-only）组合分发，整体遵循 AGPL-3.0-only。

移植内容（33 个文件，2026-11 源快照）：
- Protocol/：PXC 控制面与媒体面协议（帧、命令表、CLIENT_INFO、探测、触摸、时钟同步、宽松 JSON）
- Link/：会话引擎（监听/回连/握手/看门狗/重连）、BSD socket 传输、RSA 身份签名、幽灵触点过滤
- Video/VideoTypes.swift：画布、编码参数、EncodedFrame、VideoFrameSource 协议契约
- Bike/：车型 profile（legacy=CFDL16）、二维码解析、画布记忆
- Util/：字节流、异步/时钟、日志、宽松 JSON 解析

已裁剪未移植：Dash 自绘 UI、Nav 导航、Trips、Storage、Net(HTTP)、AdaptivePolicy 等 App 层模块。
CarWithin 侧适配器：App/CfmotoEasyConnOutput.swift。
