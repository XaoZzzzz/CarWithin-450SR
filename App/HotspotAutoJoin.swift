import Foundation
import NetworkExtension

/// 通过 NEHotspotConfiguration 让 iPhone 记住并自动加入车机热点（DIRECT-go-CFMOTO-xxxx）。
/// 配置持续生效（joinOnce = false），车机通电后系统会自动回连，无需每次手动选择。
enum HotspotAutoJoin {
    private static let key = "hotspotAutoJoinSSID"

    /// 当前已写入系统配置的车机热点 SSID（我们自己记账；读取系统配置本身不需要额外权限）。
    static var configuredSSID: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 写入自动加入配置。返回 nil 表示成功，否则为错误描述。
    /// 注意：iOS 会弹出系统确认框，用户确认后生效。
    static func apply(ssid: String, password: String?, open: Bool) async -> String? {
        guard !ssid.isEmpty else { return "SSID 为空" }
        let manager = NEHotspotConfigurationManager.shared
        // 换了热点时清掉旧配置，避免配置越积越多。
        if !configuredSSID.isEmpty, configuredSSID != ssid {
            manager.removeConfiguration(forSSID: configuredSSID)
        }
        let configuration: NEHotspotConfiguration
        if open || (password ?? "").isEmpty {
            configuration = NEHotspotConfiguration(ssid: ssid)
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password!, isWEP: false)
        }
        configuration.joinOnce = false
        do {
            try await manager.apply(configuration)
        } catch {
            return error.localizedDescription
        }
        configuredSSID = ssid
        return nil
    }

    static func remove(ssid: String) {
        guard !ssid.isEmpty else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        if configuredSSID == ssid { configuredSSID = "" }
    }
}
