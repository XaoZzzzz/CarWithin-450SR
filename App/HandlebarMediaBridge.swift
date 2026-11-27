// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: CarWithin-450SR 二次开发
//
// 车把按键桥（HandlebarMediaBridge）
//
// 450SR 车把的上/下键在投屏状态下经车机蓝牙以 AVRCP 绝对音量命令送达 iPhone
// （每按一下系统音量变化 1 步，共 16 步）。iOS 不向第三方 App 开放「拦截音量键」的 API，
// 只能观察 AVAudioSession.outputVolume 的变化。本模块：
//   1. KVO 观察音量步进 → 判定短按/长按：
//      短按（步进停止 0.3 秒且总时长 < 2 秒）→ CarPlay HID 媒体键切歌；
//      长按（步进持续 ≥ 2 秒）→ 音量调整模式：停止复位，音量真实变化，松手 0.6 秒后结束；
//   2. 来电响铃或通话中按下按键 → CarPlay HID 电话 hookSwitch（接听/挂断）；
//   3. 短按确认后把音量一次性复位到按键前的值（避免音量随切歌累积变化）；
//      复位在单击确认后统一执行，减少 MPVolumeView 触发音频路由重评估的次数；
//   4. 可选屏蔽车机 ENT 键：ENT 经车机蓝牙以 AVRCP 播放/暂停命令到达 iPhone，
//      iOS 收到播放命令会自动把音频路由切到车机蓝牙——注册系统命令拦截并吞掉。

import AVFoundation
import MediaPlayer
import CallKit

final class HandlebarMediaBridge: NSObject {

    static let shared = HandlebarMediaBridge()

    private static let enabledKey = "handlebarEnabled"
    private static let swappedKey = "handlebarSwapped"
    private static let restoreKey = "handlebarRestoreVolume"
    private static let blockEntKey = "handlebarBlockEnt"

    /// 短按判定窗口：最后一步进之后静默多久才算松手。
    private static let singleTapWindow: TimeInterval = 0.3
    /// 长按阈值：步进持续多久后转入音量调整模式。
    private static let longPressThreshold: TimeInterval = 2.0
    /// 长按结束后静默多久退出音量调整模式。
    private static let longPressEndWindow: TimeInterval = 0.6

    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume
    /// 忽略音量变化的时间戳（复位音量会再触发 KVO，需自我抑制）。
    private var ignoreUntil: TimeInterval = 0
    private var volumeView: MPVolumeView?
    private var callObserver: CXCallObserver?
    private var incomingCall = false
    private var onGoingCall = false

    // 短按/长按状态机
    private var windowStart: TimeInterval = 0
    private var baseVolume: Float = 0
    private var pendingTap: DispatchWorkItem?
    private var volumeAdjusting = false

    // ENT（AVRCP 播放/暂停）拦截
    private var entHandlers: [Any] = []

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }
    /// true = 上键是上一曲；false（默认）= 上键是下一曲。
    var swapsDirection: Bool {
        get { UserDefaults.standard.bool(forKey: Self.swappedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.swappedKey) }
    }
    var restoresVolume: Bool {
        get { UserDefaults.standard.object(forKey: Self.restoreKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.restoreKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.restoreKey) }
    }
    var blocksEntKey: Bool {
        get { UserDefaults.standard.object(forKey: Self.blockEntKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.blockEntKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.blockEntKey) }
    }

    /// 按键事件的回调（用于日志与 UI 提示）。
    var onEvent: ((String) -> Void)?
    /// 命令回调：由 UI 层注入，转发给 NativeReceiver.press(.next/.previous/.hookSwitch)。
    var onCommand: ((CarPlayControl) -> Void)?

    private override init() {}

    // MARK: - 启停（投屏运行期间启用）

    func start() {
        guard isEnabled, observation == nil else { return }
        lastVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let new = change.newValue else { return }
            DispatchQueue.main.async { self.volumeChanged(from: self.lastVolume, to: new) }
        }
        let observer = CXCallObserver()
        observer.setDelegate(self, queue: .main)
        callObserver = observer
        if blocksEntKey { installEntBlock() }
        log("车把按键桥已启用（短按切歌 · 长按 2 秒调音量）")
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        callObserver = nil
        incomingCall = false
        onGoingCall = false
        pendingTap?.cancel()
        pendingTap = nil
        volumeAdjusting = false
        removeEntBlock()
        if isEnabled { log("车把按键桥已停用") }
    }

    // MARK: - 音量步进 → 短按/长按

    /// iOS 系统音量步长（1/16）。
    private static let stepSize: Float = 0.0625

    private func volumeChanged(from old: Float, to new: Float) {
        defer { lastVolume = new }
        // 自我抑制：复位音量引发的变化不当作按键。
        let now = ProcessInfo.processInfo.systemUptime
        if now < ignoreUntil { return }
        let delta = new - old
        guard abs(delta) >= Self.stepSize / 2 else { return }
        let isUp = delta > 0

        if incomingCall || onGoingCall {
            pendingTap?.cancel(); pendingTap = nil
            volumeAdjusting = false
            onCommand?(.hookSwitch)
            onEvent?("车把「\(isUp ? "上" : "下")」键 → \(incomingCall ? "接听来电" : "挂断通话")")
            return
        }

        // 步进序列开始：记录窗口起点与音量基准。
        if volumeAdjusting || windowStart == 0 {
            if !volumeAdjusting {
                windowStart = now
                baseVolume = old
            }
        }
        let elapsed = now - windowStart

        if !volumeAdjusting && elapsed >= Self.longPressThreshold {
            // 长按确认：转入音量调整模式，停止复位，音量开始真实变化。
            volumeAdjusting = true
            pendingTap?.cancel(); pendingTap = nil
            onEvent?("车把长按 → 音量调整模式（松手结束）")
        }

        pendingTap?.cancel()
        if volumeAdjusting {
            let item = DispatchWorkItem { [weak self] in self?.endLongPress() }
            pendingTap = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressEndWindow, execute: item)
        } else {
            let item = DispatchWorkItem { [weak self] in self?.fireSingleTap(isUp: isUp) }
            pendingTap = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.singleTapWindow, execute: item)
        }
    }

    /// 短按确认：切歌一次，并把音量复位到按键前的值。
    private func fireSingleTap(isUp: Bool) {
        pendingTap = nil
        windowStart = 0
        let isNext = isUp != swapsDirection
        onEvent?("车把「\(isUp ? "上" : "下")」键 → \(isNext ? CWL("下一曲") : CWL("上一曲"))")
        onCommand?(isNext ? .next : .previous)
        if restoresVolume {
            // 复位放在单击确认后一次性执行：减少 MPVolumeView 触发路由重评估的频率。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.restoreVolume(to: self?.baseVolume ?? 0) }
        }
    }

    /// 长按结束：退出音量调整模式，音量保持（用户要的就是调整后的音量）。
    private func endLongPress() {
        pendingTap = nil
        windowStart = 0
        if volumeAdjusting {
            volumeAdjusting = false
            onEvent?("音量调整结束")
        }
    }

    // MARK: - ENT（AVRCP 播放/暂停）拦截

    private func installEntBlock() {
        let center = MPRemoteCommandCenter.shared()
        entHandlers = [
            center.playCommand.addTarget { _ in .success },
            center.pauseCommand.addTarget { _ in .success },
            center.togglePlayPauseCommand.addTarget { _ in .success }
        ]
    }

    private func removeEntBlock() {
        guard !entHandlers.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(entHandlers[0])
        center.pauseCommand.removeTarget(entHandlers[1])
        center.togglePlayPauseCommand.removeTarget(entHandlers[2])
        entHandlers = []
    }

    // MARK: - 音量复位（MPVolumeView 滑块方式）

    private func restoreVolume(to target: Float) {
        ignoreUntil = ProcessInfo.processInfo.systemUptime + 0.5
        let view = ensureVolumeView()
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = target
    }

    private func ensureVolumeView() -> MPVolumeView {
        if let volumeView { return volumeView }
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.isHidden = true
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first {
            window.addSubview(view)
        }
        volumeView = view
        return view
    }

    private func log(_ message: String) {
        onEvent?(message)
        Log.i("Handlebar", message)
    }
}

extension HandlebarMediaBridge: CXCallObserverDelegate {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.isOutgoing {
            onGoingCall = call.hasConnected && !call.hasEnded
        } else {
            if call.hasEnded { incomingCall = false; onGoingCall = false }
            else if call.hasConnected { incomingCall = false; onGoingCall = true }
            else { incomingCall = true }
        }
    }
}
