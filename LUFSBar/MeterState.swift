import Foundation
import Combine

// SystemAudioTapのLoudnessMeterを ~100ms 間隔でポーリングし、
// メニューバー表示用のテキストへ変換するObservableObject。
enum MenuBarMetric: Equatable {
    case momentary
    case shortTerm
    case integrated
}

/// ワンクリックで保存する、ある瞬間のI/S/TPのスナップショット。
/// (Momentaryは一瞬の値なので比較対象に含めない、仕様通り)
struct ReferenceSnapshot {
    let shortTermLUFS: Double
    let integratedLUFS: Double
    let truePeakDBTP: Double
}

/// 主要配信サービスのラウドネス正規化基準(LUFS)。
struct StreamingTarget {
    let name: String
    let targetLUFS: Double

    static let all: [StreamingTarget] = [
        StreamingTarget(name: "Apple Music", targetLUFS: -16),
        StreamingTarget(name: "Spotify", targetLUFS: -14),
        StreamingTarget(name: "YouTube", targetLUFS: -14)
    ]
}

final class MeterState: ObservableObject {
    static let shared = MeterState()

    @Published private(set) var menuBarText: String = MeterState.silentText
    @Published private(set) var momentaryLUFS: Double = -Double.infinity
    @Published private(set) var shortTermLUFS: Double = -Double.infinity
    @Published private(set) var integratedLUFS: Double = -Double.infinity
    @Published private(set) var truePeakDBTP: Double = -Double.infinity

    // リファレンス・スナップショット: ワンクリックで保存したI/S/TPとの差分を表示する。
    @Published private(set) var referenceSnapshot: ReferenceSnapshot?

    // SystemAudioTap.start()がtap/aggregate device作成やAudioDeviceStartで
    // 失敗した(典型的にはシステムオーディオへのアクセス許可が拒否/未許可)場合に立てる。
    @Published private(set) var audioAccessError = false

    // postinstallスクリプト(launchctl asuser経由)で自動起動された初回セッションは
    // インストーラーの文脈が残っており、ここでtapを作成するとTCC許可プロンプトが
    // 一度も出ないままtccdが抑制状態に入ることが実機で確認された。初回起動だけは
    // tapをすぐには作らず、ユーザー自身の明示的なクリックを起点にすることで
    // 正規の許可プロンプトが確実に出るようにする。
    static let hasCompletedFirstLaunchKey = "LUFSBar.hasCompletedFirstLaunchTapStart"
    @Published private(set) var needsManualStart = false

    func markNeedsManualStart() {
        needsManualStart = true
    }

    func startMeteringManually() {
        SystemAudioTap.shared.start()
        needsManualStart = false
        UserDefaults.standard.set(true, forKey: Self.hasCompletedFirstLaunchKey)
    }

    // tap/aggregate device自体は作成に成功していても、システムオーディオ録音の
    // 権限が無いとAPIはエラーを返さず無音データを流し続けることがある(実機で確認済み)。
    // 「起動してから一度も有効な音を検出できていない」状態が長時間続いたら、
    // 権限が無い可能性をヒントとして案内する(確実な検出はできないためヒューリスティック)。
    @Published private(set) var possiblyMissingAudioAccess = false
    private var hasEverCapturedRealAudio = false
    private var neverCapturedPollCount = 0
    private let possiblyMissingAudioAccessThresholdPolls = 900  // 0.1s間隔 × 900 = 約90秒

    // メニューバーにライブ表示する指標。右クリックメニューから切り替えられる。
    @Published var menuBarMetric: MenuBarMetric = .shortTerm {
        didSet {
            // 指標を切り替えた瞬間に古い値とブレンドした変な表示にならないよう、
            // 平滑化状態をリセットする。
            displaySmoothedValue = -Double.infinity
        }
    }

    // メニューバー表示のコンパクト化(" LUFS"サフィックスを省き数値のみ表示)。
    // SettingsViewのトグルと右クリックメニューの両方から変更でき、
    // 同じ@Publishedプロパティを見ているので自動的に同期する。
    private static let compactMenuBarKey = "compactMenuBar"
    @Published var compactMenuBar: Bool = false {
        didSet {
            guard oldValue != compactMenuBar else { return }
            UserDefaults.standard.set(compactMenuBar, forKey: Self.compactMenuBarKey)
            // ポーリングを待たず切替直後に反映する。
            menuBarText = Self.format(displaySmoothedValue, compact: compactMenuBar)
        }
    }

    // LUFS絶対ゲート相当(-70)を表示下限とし、無音直後の過渡的な異常値
    // (例: momentaryが-inf化する直前に-1000超の有限値を経由する)や
    // 桁数の変化によるメニューバー幅の揺れを防ぐ。
    private static let displayFloor: Double = -70

    // 通常のスペース(U+0020)はレイアウト側で幅を詰められることがあり、
    // 桁数が変わるたびにメニューバー全体の幅がわずかに揺れる原因になる。
    // 詰められないノーブレークスペース(U+00A0)で固定5文字幅にパディングする。
    private static let nbsp: Character = "\u{00A0}"

    private static func padded(_ raw: String) -> String {
        guard raw.count < 5 else { return raw }
        return String(repeating: nbsp, count: 5 - raw.count) + raw
    }

    private static let silentText: String = padded("--") + String(nbsp) + "LUFS"

    private var timer: Timer?

    // メニューバー表示だけに使う平滑化値。数値自体(shortTermLUFS等)は
    // 生の値のまま保持し、チラつき対策はテキスト生成の直前だけにかける。
    private var displaySmoothedValue: Double = -Double.infinity

    // 無音(momentaryが-inf、つまり完全なデジタル無音)が一定時間続いたら
    // 「再生が止まった」とみなしIntegratedを自動リセットする。曲間の一瞬の
    // 無音では誤反応しないよう、連続無音時間で判定する。1エピソードにつき
    // 1回だけリセットし、音が戻ってきたらフラグを解除する。
    private var silentPollCount = 0
    private var hasAutoResetForCurrentSilence = false
    private let silenceResetThresholdPolls = 20  // 0.1s間隔 × 20 = 約2秒

    init() {
        compactMenuBar = UserDefaults.standard.bool(forKey: Self.compactMenuBarKey)
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func saveReferenceSnapshot() {
        referenceSnapshot = ReferenceSnapshot(
            shortTermLUFS: shortTermLUFS,
            integratedLUFS: integratedLUFS,
            truePeakDBTP: truePeakDBTP
        )
    }

    func clearReferenceSnapshot() {
        referenceSnapshot = nil
    }

    func reportAudioAccessError() {
        audioAccessError = true
    }

    func clearAudioAccessError() {
        audioAccessError = false
    }

    /// 現在値とリファレンスの差分(Δ)。どちらかが無音(-inf)の場合など比較不能ならnil。
    static func delta(current: Double, reference: Double?) -> Double? {
        guard let reference, current.isFinite, reference.isFinite else { return nil }
        return current - reference
    }

    private func refresh() {
        guard let meter = SystemAudioTap.shared.loudnessMeter else {
            displaySmoothedValue = -Double.infinity
            let silentDisplay = compactMenuBar ? Self.padded("--") : Self.silentText
            if menuBarText != silentDisplay {
                menuBarText = silentDisplay
            }
            return
        }
        momentaryLUFS = meter.momentaryLUFS
        shortTermLUFS = meter.shortTermLUFS
        integratedLUFS = meter.integratedLUFS
        truePeakDBTP = meter.truePeakDBTP

        if momentaryLUFS.isFinite {
            hasEverCapturedRealAudio = true
            neverCapturedPollCount = 0
            possiblyMissingAudioAccess = false
            silentPollCount = 0
            hasAutoResetForCurrentSilence = false
        } else {
            if !hasEverCapturedRealAudio {
                neverCapturedPollCount += 1
                if neverCapturedPollCount >= possiblyMissingAudioAccessThresholdPolls {
                    possiblyMissingAudioAccess = true
                }
            }
            silentPollCount += 1
            if silentPollCount >= silenceResetThresholdPolls && !hasAutoResetForCurrentSilence {
                SystemAudioTap.shared.resetIntegrated()
                hasAutoResetForCurrentSilence = true
            }
        }

        let selectedValue: Double
        switch menuBarMetric {
        case .momentary: selectedValue = momentaryLUFS
        case .shortTerm: selectedValue = shortTermLUFS
        case .integrated: selectedValue = integratedLUFS
        }

        if selectedValue.isFinite {
            if displaySmoothedValue.isFinite {
                // 指数移動平均で表示だけを滑らかにする(応答性と落ち着きのバランスを取った係数)。
                displaySmoothedValue += (selectedValue - displaySmoothedValue) * 0.2
            } else {
                displaySmoothedValue = selectedValue
            }
        } else {
            displaySmoothedValue = -Double.infinity
        }

        // 表示文字列が実際に変わる時だけ@Publishedを更新し、無駄な再描画を避ける。
        let newText = Self.format(displaySmoothedValue, compact: compactMenuBar)
        if newText != menuBarText {
            menuBarText = newText
        }
    }

    static func format(_ value: Double, compact: Bool = false) -> String {
        guard value.isFinite else { return compact ? padded("--") : silentText }
        let clamped = max(value, displayFloor)
        let raw = String(format: "%.1f", clamped)
        let numberPart = padded(raw)
        return compact ? numberPart : numberPart + String(nbsp) + "LUFS"
    }

    /// ポップオーバーなど、メニューバーの固定幅制約を受けない箇所向けの単純な数値表示。
    static func displayString(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let clamped = max(value, displayFloor)
        return String(format: "%.1f", clamped)
    }
}
