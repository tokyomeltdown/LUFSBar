# LUFSBar コードレビュー

- 対象: リポジトリ全体（`main` = `9454266` 時点）。Swift ソース、同梱の libebur128、Info.plist / entitlements、Xcode プロジェクト、`build.sh` / `notarize.sh` / `make_pkg.sh`、README、`docs/`
- 方法: `/code-review max` による全ファイル精読と、セキュリティ観点の追加確認。コードは一切変更していません
- 検証: 同梱の `ebur128.c` を clang でビルドし、処理コストを実測しました（x86 Linux VM での値で、Mac 実機ではありません）。Swift のコードはこの環境ではビルドできないため、Swift 側の指摘はコードを読んだうえでの判断です

## 重要度の定義

| 重要度 | 意味 |
|---|---|
| **High** | 実運用で起こり得て、クラッシュ・誤計測・誤インストールなど利用者に直接影響するもの |
| **Medium** | 条件付きで発生する不具合、あるいは機能が黙って失われるもの |
| **Low** | 影響が限定的なもの、パフォーマンス、開発体験 |
| **Info** | 現状は問題ないが、把握しておくべきこと |

## サマリー

| # | 分類 | 重要度 | 概要 | 場所 |
|---|---|---|---|---|
| S1 | セキュリティ | Low | リリーススクリプトが予測可能な `/tmp` パスを使い、`make_pkg.sh` は中身を検証せずに署名・公証している | `notarize.sh:34-40`, `make_pkg.sh:31,44` |
| S2 | セキュリティ | Info | App Sandbox なし（Hardened Runtime と最小限の entitlement は適切） | `LUFSBar.entitlements`, `project.pbxproj:306,339` |
| B1 | バグ | **High** | ヒストグラムモードなしの libebur128 で、Integrated 計算が時間に比例して重くなり、メモリも増え続ける | `LoudnessMeter.swift:22,56` |
| B2 | バグ | **High** | `ebur128_init` が失敗すると `deinit` が NULL を参照してクラッシュする | `LoudnessMeter.swift:33` |
| B3 | バグ | **High** | pkg がデフォルトで relocatable になり、`/Applications` 以外にある既存コピーが更新される | `make_pkg.sh:76` |
| B4 | バグ | Medium | 同じデバイスのままサンプルレートが変わっても追従せず、M/S/I/TP がずれる | `SystemAudioTap.swift:68` |
| B5 | バグ | Medium | リアルタイム IO スレッドで NSLog・malloc・HAL プロパティ読み取りをしている | `SystemAudioTap.swift:216-242,304` |
| B6 | バグ | Medium | IOProc の作成に失敗してもエラーを表示せず、「--」のまま固まる | `SystemAudioTap.swift:116` |
| B7 | バグ | Medium | `os_unfair_lock` を Swift のプロパティに持たせ `&` で渡している。計測値の読み取りと `inputGainLinear` にデータ競合がある | `LoudnessMeter.swift:18`, `SystemAudioTap.swift:19,58`, `MeterState.swift:179-182` |
| B8 | バグ | Medium | Launch at Login のトグルが実際の SMAppService の状態とずれる | `SettingsView.swift:4` |
| B9 | バグ | Low | メニューバーに出す指標の選択が再起動で失われる | `MeterState.swift:76` |
| B10 | バグ | Low | 右クリックメニューを開いている間、10 Hz の更新タイマーが止まる | `MeterState.swift:134` |
| B11 | バグ | Low | `build.sh` はチーム外の人の環境では署名エラーでビルドできない | `build.sh:18` |
| B12 | バグ | Low | `notarize.sh` がビルドの失敗とコンパイルエラーを握りつぶす | `notarize.sh:62` |
| M1 | 保守性 | Low | 毎 IO コールバックで M/S/I/TP を全部計算している（必要なのは 10 Hz） | `LoudnessMeter.swift:44` |
| M2 | 保守性 | Low | `@Published` に毎回代入しているため、無音中も 10 Hz で再描画が走る | `MeterState.swift:179` |
| M3 | 保守性 | Low | 英訳コミットで、不変条件を説明するコメントが文の途中で切れている | `SystemAudioTap.swift:18,39` |
| M4 | 保守性 | Low | 署名 ID の読み込み処理と `VERSION="1.1"` が 2 つのスクリプトに重複している | `notarize.sh:16-29`, `make_pkg.sh:13-26` |

---

## ① セキュリティ

全体として攻撃面は小さいです。ネットワーク通信はなく、キャプチャした音声は保存も送信もせず、メモリ上でラウドネス計算に使うだけです。Hardened Runtime は有効で、entitlement は `com.apple.security.device.audio-input` だけです。tap は `isPrivate = true` で作っています。署名者情報は AGENTS.md の方針どおりソース外に置かれ、ランディングページの外部リンクにはすべて `rel="noopener"` が付いており、外部スクリプトも読み込んでいません。高リスクの問題は見つかりませんでした。

### S1. [Low] リリーススクリプトが予測可能な `/tmp` パスを使い、`make_pkg.sh` は中身を検証せずに署名・公証している

- **場所**: `notarize.sh:34-40`（`/tmp/LUFSBar-release-build`, `/tmp/LUFSBar_notarize`, `/tmp/LUFSBar_submit.zip`）、`make_pkg.sh:31,44`
- **内容**: `make_pkg.sh` は `/tmp/LUFSBar_notarize/LUFSBar.app` に「何かが存在する」ことしか確認していません。その中身を Developer ID Installer で署名し、公証に出し、`dist/LUFSBar.pkg` として配布物にします。`/tmp` は全ユーザーが書き込めて、パスは固定です。たとえば再起動で `/tmp` が空になった後に、同じ Mac の別ユーザーや別プロセスが先にこのパスを作っておけば、`notarize.sh` を経由していない `.app` が開発者名義の署名付き pkg に入ります（`notarize.sh` 側は `rm -rf` が失敗して `set -e` で止まりますが、`make_pkg.sh` を単独で実行した場合は止まりません）。
- **影響**: 開発機が一人用ならほぼ起こりません。ただ、配布物の完全性をパスの存在だけに頼っている点は、サプライチェーン上の弱点です。
- **推奨**:
  - 作業ディレクトリは `mktemp -d` で作るか、リポジトリ内の `build/`（`.gitignore` 済み）に置く
  - `make_pkg.sh` で、pkg を作る前に `codesign --verify --strict` と `codesign -dv` のチーム ID 照合、`xcrun stapler validate "$APP_TMP"` を必須にする

### S2. [Info] App Sandbox が無効

- **場所**: `LUFSBar/LUFSBar.entitlements`, `LUFSBar.xcodeproj/project.pbxproj:306,339`
- **内容**: Hardened Runtime は有効ですが、`com.apple.security.app-sandbox` はありません。システム全体の音声をキャプチャするメニューバー常駐アプリなので、万一 libebur128 などにメモリ破壊のバグがあった場合、プロセスはユーザー権限をすべて持ちます。プロセスタップと SMAppService がサンドボックス内でも動くかを確認したうえで、サンドボックス化を検討する価値があります（現状の動作で問題が出ているわけではありません）。

---

## ② バグ

### B1. [High] ヒストグラムモードなしの libebur128 で、Integrated 計算が時間に比例して重くなり、メモリも増え続ける

- **場所**: `LUFSBar/LoudnessMeter.swift:22`（init）、`:56`（resetIntegrated の再初期化）
- **内容**: `EBUR128_MODE_HISTOGRAM` を指定していないため、libebur128 は 400 ms のゲーティングブロックをすべて上限なし（`history = ULONG_MAX`）の連結リストに保持します。さらに `ebur128_loudness_global` は、IO コールバックのたびにこのリストを 2 回全走査します。
- **発生条件**: 2 秒以上の完全な無音が来なければ、`MeterState` の自動リセットは発動しません。ギャップレス再生、クロスフェードするプレイリスト、DJ ミックス、ライブ配信、環境音アプリなどがこれに当たります。
- **実測**（同梱の `ebur128.c`。global の 1 回あたりのコスト）:

  | 連続再生時間 | 1 回あたり |
  |---|---|
  | 10 分 | 0.019 ms |
  | 1 時間 | 0.12 ms |
  | 4 時間 | 0.51 ms |
  | 8 時間 | 1.11 ms |

  512 フレームのバッファ（約 94 回/秒）だと、8 時間後にはリアルタイムスレッドで CPU 1 コアの約 10% を使い、その後も線形に増えます。約 3 日続くとバッファ周期の 10.7 ms を超えます。メモリは約 0.6 MB/時ずつ増え、リセット時や deinit 時には、このリスト全体をメーターのロックを持ったまま解放します。
- **推奨**: 2 か所の mode に `EBUR128_MODE_HISTOGRAM` を追加します。実測では 1 回 0.002 ms で一定になり、計測値の差は 0.02 LU でした。

### B2. [High] `ebur128_init` が失敗すると `deinit` が NULL を参照してクラッシュする

- **場所**: `LUFSBar/LoudnessMeter.swift:33`
- **内容**: `deinit` は `ebur128_destroy(&state)` を無条件に呼びます。しかし `ebur128_destroy` は `*st` の NULL チェックをしません（`ebur128.c:557`）。`init?` の中で `ebur128_init` が NULL を返して `return nil` するときには、格納プロパティがすでに全部初期化済みなので、Swift は `deinit` を実行します。その結果、nil を返して終わるはずの場面で、IO スレッドが SIGSEGV で落ちます。
- **発生条件**: サンプルレートが 16 未満か 2,822,400 超の場合（aggregate から公称レート 0 Hz が返ってきたときなど）、65 チャンネル以上の場合、メモリ確保に失敗した場合。加えて、`resetIntegrated` での再初期化（60 行目）が失敗すると、`state = nil` のままメーターが黙って止まります。その後、デバイス切り替え時の `setLoudnessMeter(nil)`（`SystemAudioTap.swift:64`）か、終了時の `stop()`（151 行目）で解放されたときにクラッシュします。
- **推奨**: `if state != nil { ebur128_destroy(&state) }` のようにガードします。再初期化が失敗したことも検知して、エラーとして見えるようにします。

### B3. [High] pkg がデフォルトで relocatable になり、`/Applications` 以外にある既存コピーが更新される

- **場所**: `make_pkg.sh:76`
- **内容**: `pkgbuild --root` をコンポーネント plist なしで実行しているため、`BundleIsRelocatable=true` になります。Installer は LaunchServices が把握している同じバンドル ID（`com.tokyomeltdown.lufsbar`）のコピーを見つけると、そのコピーをその場で更新し、`/Applications/LUFSBar.app` は作成も更新もしません。
- **発生条件**: リリース用の Mac では `/tmp/LUFSBar_notarize/LUFSBar.app` や `/tmp/LUFSBar-build` の Debug ビルドが該当します。ユーザーの Mac では、`~/Applications` に移したコピーや Downloads に残ったコピーが該当します。こうした場合、postinstall の `open -a /Applications/LUFSBar.app` は失敗するか、古いバージョンを起動し直します。
- **推奨**: `pkgbuild --analyze` で plist を生成して `BundleIsRelocatable` を `false` にし、`--component-plist` で渡します。

### B4. [Medium] 同じデバイスのままサンプルレートが変わっても追従しない

- **場所**: `LUFSBar/SystemAudioTap.swift:68`
- **内容**: メーターのサンプルレートは一度読むだけで、作り直すのはデフォルト出力デバイスが変わったときだけです。aggregate の `kAudioDevicePropertyNominalSampleRate` にも `kAudioTapPropertyFormat` にもリスナーを登録していません。
- **発生条件**: Audio MIDI 設定でデバイスを 44.1 kHz から 96 kHz に変えた場合や、Audirvana・Roon のようなビットパーフェクトのプレーヤーが曲ごとにレートを切り替える場合です。62-63 行目のコメントにあるとおり tap がデバイスのレートに追従するなら、96 kHz の音声が 44.1 kHz 設定のまま処理されます。このとき 400 ms の momentary 窓は実際には約 184 ms しか見ておらず、K 特性フィルタと True Peak のオーバーサンプラも別のレート向けの係数のままになります。デバイスを切り替えるか再起動するまで、M/S/I/TP はすべて誤った値になります。
- **推奨**: サンプルレートやフォーマットの変更リスナーを追加して、メーターを作り直します。もしくは IO コールバックで受け取ったフォーマットとメーターの設定を比べて、違っていたら作り直します。

### B5. [Medium] リアルタイム IO スレッドでブロックし得る処理をしている

- **場所**: `LUFSBar/SystemAudioTap.swift:304`（定期 NSLog）、`:216-242`（`setupLoudnessMeter`）
- **内容**:
  - 40 コールバックごとの NSLog が Release ビルドでも動き続けます。48 kHz / 512 フレームだと約 2.3 回/秒、1 日で約 20 万行が unified log に出ます。
  - 起動直後とデバイス切り替え後の最初のコールバックで、IOProc の中から自分自身の aggregate に `AudioObjectGetPropertyData` をかけています。さらに `ebur128_init`（3 秒 × 48 kHz × 2ch の double とインターポレータ、約 2.3 MB の確保とゼロ埋め）と NSLog（231 行目）も実行します。
  - 置き換えられた古いメーターの `deinit`（libebur128 の状態をすべて解放する処理）が、IO スレッド上で走ることがあります。メインスレッドのリスナーがコールバックの途中で参照を外した場合です。
- **影響**: IO サイクルに間に合わず、キャプチャした音声がドロップする可能性があります。
- **推奨**: 定期ログは `#if DEBUG` に限るか、`os_log` の debug レベルにします。メーターの作成と破棄はメインスレッドか専用キューで行い、IO スレッドにはできあがった参照を渡すだけにします。

### B6. [Medium] IOProc の作成に失敗してもエラーを表示しない

- **場所**: `LUFSBar/SystemAudioTap.swift:116`
- **内容**: `AudioDeviceCreateIOProcIDWithBlock` が失敗しても、`start()` は `reportAudioAccessError()` を呼ばずに return します。また `MeterState.refresh()` は `loudnessMeter` が nil だと早期 return するので、権限ヒントのカウンタ（`MeterState.swift:191-195`）も進みません。
- **影響**: メニューバーは「-- LUFS」、ポップオーバーは「--」が並んだまま、エラーも権限のヒントも出ません。tap と aggregate は確保されたまま残ります。
- **推奨**: 失敗したら `reportAudioAccessError()` を呼び、tap と aggregate を破棄します。

### B7. [Medium] `os_unfair_lock` の保持方法と、ロックなしの読み取り（データ競合）

- **場所**: `LUFSBar/LoudnessMeter.swift:18`、`LUFSBar/SystemAudioTap.swift:19,58`、`LUFSBar/MeterState.swift:179-182`
- **内容**:
  - `os_unfair_lock` をクラスの格納プロパティに置き、`&unfairLock` で渡しています。Swift はこの変換でアドレスが一定になることを保証していません。いまは `final` クラスでオブザーバもないので動いていますが、プロパティにオブザーバが付く、クラスが非 final や `@objc` になる、コード生成が変わる、といった変化があると一時コピーに対してロックされる可能性があります。そうなるとコメントにある過去の SIGSEGV（`resetIntegrated` と `addInterleavedFrames` の間の use-after-free）が再発します。
  - `MeterState` は、IO スレッドがロック内で書き込む M/S/I/TP をロックなしで読んでいます。
  - `inputGainLinear` はメインスレッドのリスナー（58 行目）で書き込まれ、IO スレッドで同期なしに読まれています。
  - いずれも TSan が報告するデータ競合です。
- **推奨**: デプロイメントターゲットが 14.4 なので `OSAllocatedUnfairLock` が使えます。4 つの値はロックの内側でまとめてスナップショットとして読み出します。`inputGainLinear` はロックの内側に移すか atomic にします。

### B8. [Medium] Launch at Login のトグルが実際の状態とずれる

- **場所**: `LUFSBar/SettingsView.swift:4`
- **内容**: トグルは `LaunchAtLogin.isEnabled` で `@State` を 1 回初期化するだけで、`setEnabled` は失敗しても NSLog に出すだけです。設定ウィンドウとビューは AppDelegate が作ってキャッシュし続けます（`LUFSBarApp.swift:145-157`）。
- **発生条件**: `register()` が throw した場合、トグルは ON なのにログイン項目には登録されていません。ユーザーがシステム設定 > ログイン項目から LUFSBar を外した場合も、設定画面を開き直すと ON のままです。
- **推奨**: 表示されるたびと `setEnabled` の後に `SMAppService.mainApp.status` を読み直し、失敗したらトグルを戻します。

### B9. [Low] メニューバーに出す指標の選択が再起動で失われる

- **場所**: `LUFSBar/MeterState.swift:76`
- **内容**: `compactMenuBar` は UserDefaults に保存していますが、`menuBarMetric` は保存していません。右クリックで Integrated を選んでも、次のログイン（ログイン項目で自動起動する場合）や再起動で Short-term に戻ります。
- **推奨**: String の rawValue を持つ enum にして、専用のキーで保存します。

### B10. [Low] 右クリックメニューを開いている間、更新タイマーが止まる

- **場所**: `LUFSBar/MeterState.swift:134`
- **内容**: `Timer.scheduledTimer` は default モードでしか動きません。`showMetricMenu`（`LUFSBarApp.swift:131`）のメニューを開いている間は run loop が event-tracking モードになるので、メニューバーの値が止まり、無音の自動リセットと権限ヒントの判定も止まります。
- **推奨**: `RunLoop.main.add(timer, forMode: .common)` を使います。

### B11. [Low] `build.sh` はチーム外の人の環境では署名エラーでビルドできない

- **場所**: `build.sh:18`
- **内容**: README（`README.md:42-46`）がソースからのビルド方法として案内している `bash build.sh` は、プロジェクトの自動署名設定（`DEVELOPMENT_TEAM = WDFKYGRKRW`）をそのまま使います。そのため、このチームのアカウントや証明書がない人の環境では署名エラーで止まり、`.app` は作られません。
- **推奨**: `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` を渡してアドホック署名でビルドするか、`notarize.sh` と同じく `CODE_SIGNING_ALLOWED=NO` を渡します。

### B12. [Low] `notarize.sh` がビルドの失敗とコンパイルエラーを握りつぶす

- **場所**: `notarize.sh:62`
- **内容**: `xcodebuild ... | grep -E "^(Build|error:|warning:|\*\*)" || true` は pipefail なしで実行されます。Swift のコンパイルエラーは `/path/File.swift:12:5: error: ...` の形で出力され、行頭が `error:` ではないので grep で落ちます。さらに `|| true` があるので、スクリプトは止まりません。Xcode はコンパイルとリンクの前に `.app` の外枠（Info.plist やアセット）を作るので、`-d "$APP_BUILT"` のチェックも通ってしまいます。結果として、実行ファイルのない bundle が codesign で失敗し、原因とは関係のない署名エラーが表示されます。
- **推奨**: `set -o pipefail` を付けて `|| true` を外し、grep を `error:` を含む行にマッチするようにします。あるいはログを全部ファイルに保存して、失敗したら末尾を表示します。

---

## ③ 保守性

### M1. [Low] 毎 IO コールバックで M/S/I/TP を全部計算している

- **場所**: `LUFSBar/LoudnessMeter.swift:44`
- **内容**: 値を使うのは 10 Hz でポーリングしている `MeterState` だけなのに、約 94 回/秒すべてで momentary・short-term・integrated・true peak を計算しています。実測では momentary と short-term の 2 つで 1 回 0.41 ms かかり、512 フレームの `ebur128_add_frames_float` 本体（0.079 ms）の 5 倍以上でした。リアルタイムスレッドで毎秒約 38 ms を使っていて、UI に必要な量の約 9 倍です。常駐アプリなので、無音中も含めてずっとこのコストがかかります。
- **推奨**: 新しいフレームが 100 ms 分たまったときだけ計算するか、`MeterState` のポーリング時にロック内で計算します（B1 を直したうえで）。

### M2. [Low] `@Published` に毎回代入しているため、無音中も 10 Hz で再描画が走る

- **場所**: `LUFSBar/MeterState.swift:179`
- **内容**: `refresh()` は値が変わっていなくても 4 つの `@Published` に毎回代入します。そのため無音中でも 100 ms ごとに `objectWillChange` が 4 回発火し、NSPopover が保持している `PopoverContentView` も、`compactMenuBar` しか使わない `SettingsView` も、毎秒 10 回 invalidate されます。`menuBarText`（222-226 行目）では、すでに変化があるときだけ代入するようになっています。
- **推奨**: 同じように比較してから代入するか、計測値を別の `ObservableObject` に分けて、`SettingsView` が監視しないようにします。

### M3. [Low] 英訳コミットで、不変条件を説明するコメントが文の途中で切れている

- **場所**: `LUFSBar/SystemAudioTap.swift:18-19`、`:39`
- **内容**: コミット `a8c85a8` で、`(The os_unfair_lock inside` と `The correction gain is derived from the channel count` が文の途中で終わっています。日本語の元のコメントには、次の 2 点が書かれていました。
  - LoudnessMeter 内部の `os_unfair_lock` は state ポインタを守るための別のロックで、`loudnessMeterLock` とは独立していること
  - ゲインはデフォルト出力デバイスから検出し、キャプチャしたサンプルに掛けていること

  このロックまわりは過去に一度クラッシュしているので、不変条件の説明が途中で切れているのは危険です。
- **推奨**: 文の後半を復元します。

### M4. [Low] リリーススクリプトの設定が重複している

- **場所**: `notarize.sh:16-29`、`make_pkg.sh:13-26`
- **内容**: 署名 ID を読み込むブロック、`NOTARY_PROFILE`、`VERSION="1.1"` がそれぞれのスクリプトにコピーされています。`VERSION` は Xcode の `MARKETING_VERSION` とも別々に管理されているので、リリースのたびに 3 か所を手で揃える必要があり、pkg のバージョンとアプリのバージョンがずれやすくなっています。
- **推奨**: 共通部分を `scripts/common.sh` などにまとめて `source` し、バージョンはビルドした `.app` の Info.plist から `defaults read` / `PlistBuddy` で読み取ります。

---

## 推奨する対応順

1. **B2**（NULL 参照によるクラッシュ）と **B1**（ヒストグラムモード）: どちらも 1〜2 行の修正で、効果が大きいです
2. **B3**（pkg の relocatable）: 次のリリース前に対応します
3. **B5 / B7**: リアルタイムスレッドの安全性。過去にクラッシュしている領域です
4. **B4 / B6 / B8**: 計測の正しさと、状態の表示
5. **S1** と、残りの Low・保守性の項目
