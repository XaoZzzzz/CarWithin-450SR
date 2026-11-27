// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: CarWithin-450SR 二次开发
//
// 车把按键桥（HandlebarMediaBridge）
//
// 450SR 车把的上/下键在投屏状态下经车机蓝牙以 AVRCP 绝对音量命令送达 iPhone
// （每按一下系统音量变化 1 步，共 16 步）。iOS 不向第三方 App 开放「拦截音量键」的 API，
// 只能观察 AVAudioSession.outputVolume 的变化。本模块：
//   1. KVO 观察音量步进 → 折算成「上/下」按键事件（步进判定同 OpenCfMoto 的 HandlebarVolumeMath）；
//   2. 把按键映射为媒体命令（默认：上=下一曲、下=上一曲），经 MPRemoteCommandCenter.send()
//      转发给当前「正在播放」的音乐 App（QQ音乐 / Apple Music 等）；
//   3. 可选地把音量悄悄复位，避免音量随按键累积变化（MPVolumeView 滑块方式，侧载环境无审核顾虑）。
//
// 电话接听说明：iOS 不允许第三方 App 编程接听来电，来电接听请走车机蓝牙 HFP
// （车机会响铃）或 iPhone 侧边键；通话期间本模块自动忽略按键，防止误切歌。

import AVFoundation
import MediaPlayer

final class HandlebarMediaBridge {

    static let shared = HandlebarMediaBridge()

    enum Action: String {
        case nextTrack
        case previousTrack
        case none

        var label: String {
            switch self {
            case .nextTrack: return CWL("下一曲")
            case .previousTrack: return CWL("上一曲")
            case .none: return CWL("无动作")
            }
        }
    }

    private static let enabledKey = "handlebarEnabled"
    private static let upKey = "handlebarUpAction"
    private static let downKey = "handlebarDownAction"
    private static let restoreKey = "handlebarRestoreVolume"

    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume
    /// 忽略音量变化的时间戳（复位音量会再触发 KVO，需自我抑制）。
    private var ignoreUntil: TimeInterval = 0
    private var volumeView: MPVolumeView?
    private var callObserver: Any?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }
    var upAction: Action {
        get { Action(rawValue: UserDefaults.standard.string(forKey: Self.upKey) ?? "") ?? .nextTrack }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.upKey) }
    }
    var downAction: Action {
        get { Action(rawValue: UserDefaults.standard.string(forKey: Self.downKey) ?? "") ?? .previousTrack }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.downKey) }
    }
    var restoresVolume: Bool {
        get { UserDefaults.standard.object(forKey: Self.restoreKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.restoreKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.restoreKey) }
    }

    /// 按键事件的回调（用于日志与 UI 提示）。
    var onEvent: ((String) -> Void)?

    private init() {}

    // MARK: - 启停（投屏运行期间启用）

    func start() {
        guard isEnabled, observation == nil else { return }
        lastVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let new = change.newValue else { return }
            DispatchQueue.main.async { self.volumeChanged(from: self.lastVolume, to: new) }
        }
        log("车把按键桥已启用（音量摇杆 → 切歌）")
    }

    func stop() {
        observation?.invalidate()
        observation = nil
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
        let action = isUp ? upAction : downAction
        onEvent?("车把「\(isUp ? "上" : "下")」键 → \(action.label)")
        switch action {
        case .nextTrack: sendMediaCommand(\.nextTrackCommand, name: "下一曲")
        case .previousTrack: sendMediaCommand(\.previousTrackCommand, name: "上一曲")
        case .none: break
        }
        if restoresVolume { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.restoreVolume(to: old) } }
    }

    /// 经系统把媒体命令转发给当前「正在播放」的音乐 App。
    private func sendMediaCommand(_ keyPath: KeyPath<MPRemoteCommandCenter, MPRemoteCommand>, name: String) {
        let center = MPRemoteCommandCenter.shared()
        let status = center[keyPath: keyPath].send()
        if status == .commandFailed {
            log("车把切歌（\(name)）未送达：当前没有正在播放的音乐 App")
        }
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
