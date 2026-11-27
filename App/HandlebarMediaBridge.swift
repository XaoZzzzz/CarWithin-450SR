// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: CarWithin-450SR 二次开发
//
// 车把按键桥（HandlebarMediaBridge）
//
// 450SR 车把的上/下键在投屏状态下经车机蓝牙以 AVRCP 绝对音量命令送达 iPhone
// （每按一下系统音量变化 1 步，共 16 步）。iOS 不向第三方 App 开放「拦截音量键」的 API，
// 只能观察 AVAudioSession.outputVolume 的变化。本模块：
//   1. KVO 观察音量步进 → 折算成「上/下」按键事件（步进判定同 OpenCfMoto 的 HandlebarVolumeMath）；
//   2. 把按键经 CarPlay HID 媒体键通道发给本机 CarPlay 会话——iPhone 把它当作
//      CarPlay 硬件的媒体键按下，从而控制当前播放的音乐 App（下一曲/上一曲）；
//   3. 来电响铃或通话中按下按键 → 发 CarPlay HID 电话 hookSwitch（接听/挂断）；
//   4. 可选地把音量悄悄复位，避免音量随按键累积变化（MPVolumeView 滑块方式）。

import AVFoundation
import MediaPlayer
import CallKit

final class HandlebarMediaBridge {

    static let shared = HandlebarMediaBridge()

    private static let enabledKey = "handlebarEnabled"
    private static let swappedKey = "handlebarSwapped"
    private static let restoreKey = "handlebarRestoreVolume"

    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume
    /// 忽略音量变化的时间戳（复位音量会再触发 KVO，需自我抑制）。
    private var ignoreUntil: TimeInterval = 0
    private var volumeView: MPVolumeView?
    private var callObserver: CXCallObserver?
    private var incomingCall = false
    private var onGoingCall = false

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

    /// 按键事件的回调（用于日志与 UI 提示）。
    var onEvent: ((String) -> Void)?
    /// 命令回调：由 UI 层注入，转发给 NativeReceiver.press(.next/.previous/.hookSwitch)。
    var onCommand: ((CarPlayControl) -> Void)?

    private init() {}

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
        log("车把按键桥已启用（音量摇杆 → 切歌）")
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        callObserver = nil
        incomingCall = false
        onGoingCall = false
        if isEnabled { log("车把按键桥已停用") }
    }

    // MARK: - 音量步进 → 按键

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
        if incomingCall {
            onCommand?(.hookSwitch)
            onEvent?("车把「\(isUp ? "上" : "下")」键 → 接听来电")
        } else if onGoingCall {
            onCommand?(.hookSwitch)
            onEvent?("车把「\(isUp ? "上" : "下")」键 → 挂断通话")
        } else {
            let isNext = isUp != swapsDirection
            onEvent?("车把「\(isUp ? "上" : "下")」键 → \(isNext ? CWL("下一曲") : CWL("上一曲"))")
            onCommand?(isNext ? .next : .previous)
        }
        if restoresVolume { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.restoreVolume(to: old) } }
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
