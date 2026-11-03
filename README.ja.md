# LUFSBar

**Macで鳴る全ての音に、物差しを。**

LUFSBarは、macOSのメニューバーに常駐する無料・オープンソースのラウドネスメーターです。Apple Music、Spotify、YouTube、DAWの出力——Macのサウンド出力から鳴る音すべてをリアルタイムに計測します。BlackHoleもLoopbackも仮想オーディオデバイスの設定も不要です。

[English README](README.md)

## 機能

- **メニューバーにLUFSをライブ表示** — Momentary / Short-term / Integrated（右クリックで切替）
- **クリックで詳細表示** — M / S / I LUFS と True Peak (dBTP)
- **リファレンス・スナップショット** — 再生中の音（例: 配信サービスのリファレンス曲）のラウドネスをワンクリック保存し、自分のミックスとの差分（Δ）をリアルタイム表示
- **配信ノーマライズ予測** — Apple Music (-16) / Spotify (-14) / YouTube (-14) で何dB下げられるかを表示
- **自動リセット** — 約2秒の無音（−100 LUFS 未満）でIntegratedを自動リセット

## 何を測るか

LUFSBarが測るのは、Macの**今のサウンド出力**（システム設定 › サウンド › 出力）に向かう音です。

- **別のデバイスに出しているアプリの音は測りません。** DAWをオーディオインターフェースに出していて、Macの出力が内蔵スピーカーのときは、Macの出力もインターフェースに合わせてください。
- **出力に追従します。** サウンド出力を切り替えると、新しいデバイスで測り直します（Integratedは最初からになります）。
- **デバイスのステレオペアを測ります。** 多チャンネルのインターフェースでは、Audio MIDI設定 ›「スピーカーを構成」でステレオに割り当てた出力を測ります（変えていなければ1-2ch）。

1.1までは全デバイスの音をまとめて取り、今の出力から推測して音量を補正していたため、アプリごとに出力先が違うと約14dBずれることがありました。1.1.1からは1つのデバイスを本来の音量のまま測ります。

## 動作環境

- macOS 14.4 (Sonoma) 以降
- Apple silicon / Intel 両対応（Universal Binary）

## インストール

1. 最新の [Release](../../releases/latest) から `LUFSBar.pkg` をダウンロード
2. インストーラーを実行（Apple署名・公証済み）
3. アプリケーションからLUFSBarを起動
4. 「**システムオーディオ録音**」の許可を求められたら許可

> **補足:** 初回起動時にログイン項目へ自動登録されます（macOSが「バックグラウンド項目が追加されました」と通知します）。設定からいつでもオフにでき、オフにしたものを勝手にオンへ戻すことはありません。

## 仕組みとプライバシー

Core Audio process tap API (macOS 14.4+) で今の出力デバイスに向かう音を観測し、[libebur128](https://github.com/jiixyj/libebur128) による ITU-R BS.1770-4 / EBU R128 準拠の計測（K特性フィルタ・ゲーティング・4倍オーバーサンプリングTrue Peak）を行います。

- ネットワーク通信なし
- テレメトリなし
- アカウント不要
- 音声はメモリ上で解析されるだけで、録音・保存は一切しません

## ソースからビルド

```
git clone https://github.com/tokyomeltdown/LUFSBar.git
cd LUFSBar
bash build.sh
```

Xcode 16以降が必要です。作者の署名証明書がない環境では `build.sh` がアドホック署名でビルドするため、ビルドし直すたびに「システムオーディオ録音」の許可を求められます。

## ライセンス

MIT — [LICENSE](LICENSE) 参照。同梱の [libebur128](https://github.com/jiixyj/libebur128) もMITライセンスで、一緒にビルドしている `queue.h` は3条項BSDライセンスです（アプリに両方の表示を同梱しています）。

---

制作: [tokyomeltdown](https://x.com/tokyomeltdownJP)
