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
//      当前输出不是车机蓝牙（如蓝牙耳机在用）时跳过复位，避免把耳机音量拽来拽去；
//   4. ENT 键：经车机蓝牙以 AVRCP 播放/暂停命令到达 iPhone，iOS 收到播放命令会自动把
//      音频路由切到车机蓝牙。本模块把命令拦截吞掉，改用 CarPlay HID 媒体键在手机上
//      执行播放/暂停——暂停功能保留，但不切换声音输出通道；蓝牙耳机的播放键也照常工作；
//   5. 蓝牙耳机冲突防护：音量步进只在当前输出是车机蓝牙（名称匹配过滤，与自动启动
//      共用「蓝牙名称包含」设置）时才被当作车把按键，耳机的音量键不会被误判为切歌。

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
    var forwardsEntKey: Bool {
        get { UserDefaults.standard.object(forKey: Self.blockEntKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.blockEntKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.blockEntKey) }
    }

    /// 按键事件的回调（用于日志与 UI 提示）。
    var onEvent: ((String) -> Void)?
    /// 命令回调：由 UI 层注入，转发给 NativeReceiver.press(.next/.previous/.hookSwitch)。
    var onCommand: ((CarPlayControl) -> Void)?
    /// 媒体键回调：ENT 播放/暂停经 CarPlay HID 精确下发（play/pause/playPause）。
    var onMediaKey: ((CarPlayInfo.MediaKey) -> Void)?

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
        if forwardsEntKey { installEntForward() }
        log("车把按键桥已启用（短按切歌 · 长按 2 秒调音量 · ENT 转 CarPlay）")
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
        removeEntForward()
        if isEnabled { log("车把按键桥已停用") }
    }

    // MARK: - 音量步进 → 短按/长按

    /// iOS 系统音量步长（1/16）。
    private static let stepSize: Float = 0.0625

    /// 蓝牙名称过滤，与自动启动的「蓝牙名称包含」共用同一个设置；留空匹配任意蓝牙。
    private var bikeAudioFilter: String {
        let name = UserDefaults.standard.string(forKey: "autoStartBluetoothName") ?? "CFMOTO"
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前输出里是否存在匹配过滤的蓝牙音频端口（车机蓝牙在用时才有）。
    /// 蓝牙耳机单独连接时，路由不在车机蓝牙上，这里返回 nil。
    private func currentBikeAudioName() -> String? {
        let filter = bikeAudioFilter
        for port in AVAudioSession.sharedInstance().currentRoute.outputs {
            switch port.portType {
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                if filter.isEmpty || port.portName.localizedCaseInsensitiveContains(filter) {
                    return port.portName
                }
            default:
                continue
            }
        }
        return nil
    }

    private func volumeChanged(from old: Float, to new: Float) {
        defer { lastVolume = new }
        // 自我抑制：复位音量引发的变化不当作按键。
        let now = ProcessInfo.processInfo.systemUptime
        if now < ignoreUntil { return }
        // 蓝牙耳机冲突防护：当前输出不在车机蓝牙上时，音量步进一律忽略——
        // 耳机自己的音量键、或车机音量键（不影响耳机路由）都不会被误判为切歌/接听。
        guard currentBikeAudioName() != nil else { return }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                // 当前输出已不是车机蓝牙（比如中途插上蓝牙耳机）就不复位：
                // MPVolumeView 写音量会触发路由重评估，可能把声音从耳机拽到车机。
                guard self.currentBikeAudioName() != nil else {
                    self.onEvent?("当前输出已不在车机蓝牙上，跳过音量复位")
                    return
                }
                self.restoreVolume(to: self.baseVolume)
            }
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

    // MARK: - ENT（AVRCP 播放/暂停）→ CarPlay 转发

    /// ENT 的 AVRCP 播放/暂停命令必须拦下来：iOS 收到播放命令会把音频路由切到车机蓝牙。
    /// 拦下后改用 CarPlay HID 媒体键按原始语义（play/pause/playPause）精确执行，
    /// 暂停功能保留，声音输出通道不动；蓝牙耳机的播放键同样经此转发，不受影响。
    private func installEntForward() {
        let center = MPRemoteCommandCenter.shared()
        entHandlers = [
            center.playCommand.addTarget { [weak self] _ in
                self?.forwardEnt(.play, name: CWL("播放")); return .success
            },
            center.pauseCommand.addTarget { [weak self] _ in
                self?.forwardEnt(.pause, name: CWL("暂停")); return .success
            },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                self?.forwardEnt(.playPause, name: CWL("播放/暂停")); return .success
            }
        ]
    }

    private func forwardEnt(_ key: CarPlayInfo.MediaKey, name: String) {
        onEvent?(CWL("车机 ENT 键 → CarPlay {1}（不动音频路由）", [name]))
        onMediaKey?(key)
    }

    private func removeEntForward() {
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
