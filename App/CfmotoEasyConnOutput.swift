import CoreImage
import Foundation
import VideoToolbox

/// 春风 EasyConn 输出（OpenCfMoto PXC 协议栈移植版）。
///
/// 协议层来自 OpenCfMoto iOS（Kevinparra535/opencfmoto-ios，AGPL-3.0-or-later），
/// 完整移植在 `Sources/TDSCarKitCore/Vendor/OpenCfMoto/`，已在一台 2024 款春风 450SR
/// （5 寸 MotoPlay 仪表，SDK 0.9.23.4）上按 1.0.86 融合版验证可用。
/// 视频管线沿用 CarWithin 的方案：CarPlay H.264 → 解码 → 缩放 → 重编码 → 仪表逐帧拉取。
///
/// 对外接口与 `CfmotoOutput` 保持一致，可在 `NativeReceiver` 中直接互换。
final class CfmotoEasyConnOutput {
    private let queue: DispatchQueue
    private var session: Session?

    init(name: String = "cfmoto-easyconn") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, phone: TailingPhoneInfo, profile: CfmotoProfile,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           phone: phone, profile: profile,
                           onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    /// 持久化的 RSA-1024 身份（复刻 OpenCfMoto Android 的已验证身份方案）。
    /// p/q 不持久化（私钥指数足够），签名走纯 Swift 实现，无 Keychain 依赖。
    private static func loadOrCreateIdentity() -> RSAKeyMaterial? {
        let defaults = UserDefaults.standard
        let storageKey = "cfmoto.opencfmoto.rsa.identity.v1"
        if let encoded = defaults.string(forKey: storageKey),
           let data = Data(base64Encoded: encoded),
           let parts = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let n = Data(base64Encoded: parts["n"] ?? ""),
           let e = Data(base64Encoded: parts["e"] ?? ""),
           let d = Data(base64Encoded: parts["d"] ?? "") {
            return try? RSAKeyMaterial(modulus: n, publicExponent: e, privateExponent: d)
        }
        let key = RSAKeyMaterial.generate(bits: 1024)
        let parts: [String: String] = [
            "n": key.modulus.base64EncodedString(),
            "e": key.publicExponent.base64EncodedString(),
            "d": key.privateExponent.base64EncodedString(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: parts) {
            defaults.set(data.base64EncodedString(), forKey: storageKey)
        }
        return key
    }

    // MARK: - 会话

    private final class Session: @unchecked Sendable, VideoFrameSource {
        let queue: DispatchQueue
        let profile: CfmotoProfile
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?
        private var forceIDR = true

        private var encodeWidth: Int
        private var encodeHeight: Int
        private var encodeFps: Int
        private var encodeBitrate: Int
        private var link: EasyConnLink?
        private var eventTask: Task<Void, Never>?
        private var logSubscription: UUID?
        private var reportedState = ""
        private var lastStatsLog = 0.0
        private var frameSequence: UInt64 = 0

        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var status = ""

        init(queue: DispatchQueue, localAddress: String, targetAddress: String, phone: TailingPhoneInfo,
             profile: CfmotoProfile, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.profile = profile
            self.encodeWidth = profile.pxcWidth
            self.encodeHeight = profile.pxcHeight
            self.encodeFps = profile.fps
            self.encodeBitrate = profile.bitrate
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
            self.localAddress = localAddress
            self.targetAddress = targetAddress
            self.phoneInfo = phone
        }

        let localAddress: String
        let targetAddress: String
        let phoneInfo: TailingPhoneInfo

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true } }

        // MARK: 启动链路

        func start() {
            report("正在连接\(profile.label)仪表（EasyConn）…")
            let signer: PureSwiftHuidSigner
            if let key = CfmotoEasyConnOutput.loadOrCreateIdentity() {
                signer = PureSwiftHuidSigner(key: key)
            } else {
                report("\(profile.label)RSA 身份生成失败")
                return
            }
            var configuration = LinkConfiguration()
            configuration.profileOverride = .legacy
            configuration.localHost = localAddress.isEmpty ? nil : localAddress
            configuration.dashHost = targetAddress.isEmpty ? nil : targetAddress
            configuration.phone = PhoneIdentity(
                phoneUUID: UUID().uuidString.lowercased(),
                phoneBrand: "Apple",
                phoneModel: "iPhone",
                phoneOsVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                bluetoothName: "CarWithin")
            var options = LinkOptions()
            options.forceNonTouch = false
            let next = EasyConnLink(configuration: configuration, network: POSIXNetworkProvider(),
                                    frameSource: self, signer: signer, discovery: nil, gateway: nil,
                                    options: options)
            lock.lock(); link = next; lock.unlock()
            // OpenCfMoto 协议栈日志接入 CarWithin 日志视图。
            logSubscription = Log.shared.subscribe { [weak self] line in
                guard let self, self.active else { return }
                self.onLog("[EasyConn:\(line.tag)] \(line.message)")
            }
            eventTask = Task { [weak self] in
                guard let self else { return }
                for await event in next.events {
                    guard self.active else { return }
                    self.handle(event)
                }
            }
            next.start()
        }

        private func handle(_ event: LinkEvent) {
            switch event {
            case .state(let state):
                stateChanged(state)
            case .dashIdentified(let info):
                onLog("仪表身份：\(info.huName) · SDK \(info.sdkVersion) · 触控=\(info.supportsScreenTouch ? "是" : "否") · profile=\(info.profile.rawValue)")
            case .canvas(let canvas):
                onLog("画布协商：\(canvas.width)×\(canvas.height)（请求 \(canvas.requestedWidth)×\(canvas.requestedHeight)）")
            case .mediaStarted:
                onLog("仪表已请求开流")
            case .touch(let touch):
                onLog("仪表触控事件（未启用）：\(touch)")
            case .stats(let stats):
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastStatsLog >= 5 {
                    lastStatsLog = now
                    onLog(String(format: "链路统计：已送 %d 帧 · %.1f 次/秒 · 未应答拉取 %d", stats.framesSent, stats.pullRate, stats.missedPulls))
                }
            }
        }

        private func stateChanged(_ state: LinkState) {
            let message: String
            switch state {
            case .idle: message = "待机"
            case .startingServers: message = "监听 10920-10922…"
            case .probing(let attempt): message = "探测仪表（第 \(attempt) 次）…"
            case .awaitingCallback: message = "等待仪表回连…"
            case .handshaking: message = "握手中…"
            case .awaitingMedia: message = "等待仪表开流…"
            case .streaming: message = "正在投屏 · \(profile.title) · H.264"
            case .reconnecting(let attempt): message = "重连中（第 \(attempt) 次）…"
            case .failed(let failure): message = "连接失败：\(failure.description)"
            case .stopped: message = "已停止"
            }
            report(message)
            if case .failed = state { onLog("\(profile.label)EasyConn \(message)") }
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            if let id = logSubscription { Log.shared.unsubscribe(id) }
            eventTask?.cancel()
            eventTask = nil
            lock.lock(); let current = link; link = nil; lock.unlock()
            current?.stop()
            queue.sync {
                decoder?.invalidate()
                decoder = nil
                encoder?.invalidate()
                encoder = nil
                latest = nil
            }
        }

        // MARK: CarPlay 帧输入（与 CfmotoOutput 相同的节流/解码策略）

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        // MARK: VideoFrameSource（仪表拉帧侧）

        func prepare(canvas: VideoCanvas, parameters params: EncoderParameters) {
            queue.sync {
                encodeWidth = canvas.width
                encodeHeight = canvas.height
                encodeFps = params.frameRate
                encodeBitrate = params.bitrate
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                forceIDR = true
            }
        }

        func resynchronize() {
            queue.sync {
                forceIDR = true
                waitingForIDR = true
            }
            requestKeyframe()
        }

        func mediaStopped() {
            queue.sync {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                forceIDR = true
            }
        }

        func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while active {
                let ready = queue.sync { latest != nil }
                if !ready {
                    if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    continue
                }
                let now = ProcessInfo.processInfo.systemUptime
                let force = queue.sync { forceIDR }
                guard let frame = queue.sync(execute: { () -> H264EncodedFrame? in
                    guard active, let image = latest else { return nil }
                    return encode(image, at: now, forceKeyframe: force)
                }) else {
                    if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continue
                }
                queue.sync { forceIDR = false }
                let sequence = lock.withLock { () -> UInt64 in
                    frameSequence += 1
                    return frameSequence
                }
                return EncodedFrame(accessUnit: frame.data, isKeyframe: frame.isKeyframe,
                                    presentationTime: now, sequence: sequence)
            }
            return nil
        }

        // MARK: 编码（与 CfmotoOutput 相同的引擎）

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: encodeWidth, height: encodeHeight,
                                              fps: encodeFps, bitrate: encodeBitrate) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                let stamp = CMTime(seconds: now, preferredTimescale: 1_000_000)
                try encoder.encode(try fittedImage(image), presentationTime: stamp,
                                   forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                let frame = try result?.get()
                if frame?.isKeyframe == true { lastKeyframe = now }
                return frame
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                lock.withLock { encoded = nil }
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = encodeWidth, height = encodeHeight
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw ConfigurationError("无法分配\(profile.label)缩放画面（\(status)）")
            }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("\(profile.label)\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }
    }
}
