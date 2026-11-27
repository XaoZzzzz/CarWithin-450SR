// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: CarWithin-450SR 二次开发
//
// 车把按键桥（HandlebarMediaBridge）
//
// 450SR 车把的上/下键在投屏状态下经车机蓝牙以 AVRCP 绝对音量命令送达 iPhone
// （每按一下系统音量变化 1 步，共 16 步）。iOS 不向第三方 App 开放「拦截音量键」的 API，
// 只能观察 AVAudioSession.outputVolume 的变化。本模块：
//   1. KVO 观察音量步进 → 判定短按/长按（实测车把按住时步进间隔可能大于 0.3 秒，
//      因此判定不依赖「步进是否连续」，而看窗口内的步进次数与总时长）：
//      单次步进（0.5 秒内无后续步进）→ CarPlay HID 媒体键切歌，并把音量复位；
//      0.5 秒内累计 ≥3 次步进视为「按住」：松手后音量保持（有意微调，不切歌不复位）；
//      按住且从首次步进起累计 ≥2 秒 → 音量调整模式，音量真实变化，松手 0.6 秒后结束；
//   2. 来电响铃或通话中按下按键 → CarPlay HID 电话 hookSwitch（接听/挂断）；
//   3. 短按确认后把音量一次性复位到按键前的值；复位引发的音量回调按「期望值」精确忽略，
//      不再使用时间静默窗（避免吞掉紧接着的下一次按键）；
//   4. ENT 键：AVRCP 播放/暂停命令由系统直接交给正在播放的音乐 App 处理，
//      本 App 的 MPRemoteCommandCenter 注册收不到，命令层无法拦截。若本 App 恰好是
//      正在播放的 App（罕见）则吞掉并改发 CarPlay HID 媒体键；
//   5. 车机抢占声音通道的自动恢复：监听路由变化，当输出被切到车机蓝牙——
//      原输出是扬声器则自动 override 回扬声器；原输出是蓝牙耳机则提示到控制中心
//      选回（iOS 无公开 API 可指定某个蓝牙设备输出）。10 秒内不反复抢，避免与
//      用户手动切换打架。

import AVFoundation
import MediaPlayer
import CallKit

final class HandlebarMediaBridge: NSObject {

    static let shared = HandlebarMediaBridge()

    private static let enabledKey = "handlebarEnabled"
    private static let swappedKey = "handlebarSwapped"
    private static let restoreKey = "handlebarRestoreVolume"
    private static let blockEntKey = "handlebarBlockEnt"
    private static let routeRestoreKey = "handlebarRouteRestore"

    /// 单次按键判定窗：最后一步进之后静默多久才算松手（需大于车把按住时的步进间隔）。
    private static let singleTapWindow: TimeInterval = 0.5
    /// 按住判定：窗口内累计多少次步进后视为按住（≥3 避免把一次按键的多次回调误判）。
    private static let holdStepCount = 3
    /// 长按阈值：从首次步进起累计多久后转入音量调整模式。
    private static let longPressThreshold: TimeInterval = 2.0
    /// 长按结束后静默多久退出音量调整模式。
    private static let longPressEndWindow: TimeInterval = 0.6

    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume
    /// 待确认的音量复位：回调值命中期望值就当作复位本身，不当作按键。
    private var pendingRestore: (value: Float, deadline: TimeInterval)?
    private var volumeView: MPVolumeView?
    private var callObserver: CXCallObserver?
    private var incomingCall = false
    private var onGoingCall = false

    // 短按/长按状态机
    private var windowStart: TimeInterval = 0
    private var baseVolume: Float = 0
    private var stepCount = 0
    private var holdPending = false
    private var lastStepUp = false
    private var volumeAdjusting = false
    private var pendingTap: DispatchWorkItem?

    // ENT（AVRCP 播放/暂停）转发
    private var entHandlers: [Any] = []

    // 车机抢占声音通道的自动恢复
    private var routeObserver: NSObjectProtocol?
    private var lastRouteRestoreAt: TimeInterval = 0

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
    /// 声音通道被车机抢占后自动恢复（扬声器可自动切回；蓝牙耳机只能提示）。
    var restoresRoute: Bool {
        get { UserDefaults.standard.object(forKey: Self.routeRestoreKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.routeRestoreKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.routeRestoreKey) }
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
        installRouteWatch()
        log("车把按键桥已启用（短按切歌 · 按住微调音量 · 长按 2 秒调音量）")
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
        holdPending = false
        windowStart = 0
        removeEntForward()
        removeRouteWatch()
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

    private func bikeAudioName(in outputs: [AVAudioSessionPortDescription]) -> String? {
        let filter = bikeAudioFilter
        for port in outputs {
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
        let now = ProcessInfo.processInfo.systemUptime
        // 音量复位引发的回调：值命中期望值就当作复位本身，不当作按键。
        if let restore = pendingRestore {
            if now >= restore.deadline {
                pendingRestore = nil
            } else if abs(new - restore.value) < 0.005 {
                pendingRestore = nil
                return
            }
        }
        let delta = new - old
        guard abs(delta) >= Self.stepSize / 2 else { return }
        let isUp = delta > 0
        lastStepUp = isUp

        if incomingCall || onGoingCall {
            pendingTap?.cancel(); pendingTap = nil
            volumeAdjusting = false
            onCommand?(.hookSwitch)
            onEvent?("车把「\(isUp ? "上" : "下")」键 → \(incomingCall ? "接听来电" : "挂断通话")")
            return
        }

        // 步进序列开始：记录窗口起点与音量基准。
        if windowStart == 0 {
            windowStart = now
            baseVolume = old
            stepCount = 0
            holdPending = false
        }
        stepCount += 1
        let elapsed = now - windowStart
        Log.i("Handlebar", "音量步进 #\(stepCount)（\(isUp ? "+" : "-")1，窗口 \(String(format: "%.2f", elapsed))s）")
        if !holdPending && stepCount >= Self.holdStepCount {
            holdPending = true
            onEvent?("车把按住（窗口内第 \(stepCount) 次步进）")
        }

        if holdPending && !volumeAdjusting && elapsed >= Self.longPressThreshold {
            // 长按确认：转入音量调整模式，停止复位，音量开始真实变化。
            volumeAdjusting = true
            pendingTap?.cancel(); pendingTap = nil
            onEvent?("车把长按 → 音量调整模式（松手结束）")
        }

        pendingTap?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.windowEnded() }
        pendingTap = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (volumeAdjusting ? Self.longPressEndWindow : Self.singleTapWindow), execute: item)
    }

    /// 判定窗结束：按窗口内容决定切歌、保持音量还是结束音量调整。
    private func windowEnded() {
        pendingTap = nil
        if volumeAdjusting {
            volumeAdjusting = false
            windowStart = 0
            holdPending = false
            onEvent?("音量调整结束")
            return
        }
        if holdPending {
            // 多次步进但未到长按阈值：当作有意微调音量——保持现状，不切歌、不复位。
            let elapsed = ProcessInfo.processInfo.systemUptime - windowStart
            windowStart = 0
            holdPending = false
            onEvent?(CWL("车把多步进（{1} 步 / {2} 秒）→ 保持音量", [String(stepCount), String(format: "%.1f", elapsed)]))
            return
        }
        fireSingleTap(isUp: lastStepUp)
    }

    /// 短按确认：切歌一次，并把音量复位到按键前的值。
    private func fireSingleTap(isUp: Bool) {
        windowStart = 0
        holdPending = false
        let isNext = isUp != swapsDirection
        onEvent?("车把「\(isUp ? "上" : "下")」键 → \(isNext ? CWL("下一曲") : CWL("上一曲"))")
        onCommand?(isNext ? .next : .previous)
        if restoresVolume {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.restoreVolume(to: self?.baseVolume ?? 0) }
        }
    }

    // MARK: - ENT（AVRCP 播放/暂停）→ CarPlay 转发

    /// 注意：ENT 的 AVRCP 命令实际由系统交给正在播放的音乐 App，本注册通常收不到
    /// （仅当本 App 自己是正在播放的 App 时才会触发）。真正的通道抢占防护见路由监听。
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

    // MARK: - 车机抢占声音通道 → 自动恢复

    /// 车机蓝牙收到播放命令（ENT）时，iOS 会把音频路由切到车机蓝牙。
    /// 命令层拦不住，只能在路由变化后恢复：扬声器可自动 override 回去；
    /// 蓝牙耳机没有公开 API 可以指定，只能提示用户到控制中心选回。
    private func installRouteWatch() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.routeChanged(note)
        }
    }

    private func removeRouteWatch() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    private func routeChanged(_ note: Notification) {
        let session = AVAudioSession.sharedInstance()
        let oldOutputs = (note.userInfo?[AVAudioSessionRouteChangeOldRouteKey] as? AVAudioSessionRoute)?.outputs ?? []
        guard bikeAudioName(in: session.currentRoute.outputs) != nil,
              bikeAudioName(in: oldOutputs) == nil else { return }
        guard restoresRoute else { return }
        // 只处理路由重新配置（ENT 抢占 / 手动切换），蓝牙刚连上时（newDeviceAvailable）不抢戏。
        guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
              reason == .routeConfigurationChange || reason == .unknown else { return }

        let oldPrimary = oldOutputs.first
        let now = ProcessInfo.processInfo.systemUptime
        switch oldPrimary?.portType {
        case .builtInSpeaker:
            // 10 秒内不反复抢：如果这是用户自己的选择，不要和用户打架。
            guard now - lastRouteRestoreAt > 10 else { return }
            lastRouteRestoreAt = now
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.restoresRoute else { return }
                guard self.bikeAudioName(in: AVAudioSession.sharedInstance().currentRoute.outputs) != nil else { return }
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                self.onEvent?(CWL("车机抢占声音通道 → 已恢复扬声器输出"))
            }
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            onEvent?(CWL("车机抢占了声音通道（原输出：{1}）。iOS 无法自动切回蓝牙设备，请在控制中心选回", [oldPrimary?.portName ?? "?"]))
        default:
            break
        }
    }

    // MARK: - 音量复位（MPVolumeView 滑块方式）

    private func restoreVolume(to target: Float) {
        pendingRestore = (value: target, deadline: ProcessInfo.processInfo.systemUptime + 1.0)
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
