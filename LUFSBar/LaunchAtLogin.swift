import Foundation
import ServiceManagement

// macOS 13+のSMAppService.mainAppを使い、ヘルパーバンドル不要で
// 自分自身をログイン項目として登録/解除する。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("[LUFSBar][LaunchAtLogin] 設定変更に失敗: %@", error.localizedDescription)
        }
    }

    // 初回起動時だけログイン項目をデフォルトでオンにする。ユーザーが設定画面で
    // 手動でオフにした後は、その選択を尊重し次回以降は勝手にオンへ戻さない。
    private static let hasConfiguredDefaultKey = "LaunchAtLogin.hasConfiguredDefault"

    static func enableByDefaultOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hasConfiguredDefaultKey) else { return }
        setEnabled(true)
        defaults.set(true, forKey: hasConfiguredDefaultKey)
    }
}
