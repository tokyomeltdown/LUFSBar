# LUFSBar

**Macで鳴る全ての音に、物差しを。**

LUFSBarは、macOSのメニューバーに常駐する無料・オープンソースのラウドネスメーターです。Apple Music、Spotify、YouTube、DAWの出力——Macで再生されている音すべてをリアルタイムに計測します。BlackHoleもLoopbackも仮想オーディオデバイスの設定も不要です。

[English README](README.md)

## 機能

- **メニューバーにLUFSをライブ表示** — Momentary / Short-term / Integrated（右クリックで切替）
- **クリックで詳細表示** — M / S / I LUFS と True Peak (dBTP)
- **リファレンス・スナップショット** — 再生中の音（例: 配信サービスのリファレンス曲）のラウドネスをワンクリック保存し、自分のミックスとの差分（Δ）をリアルタイム表示
- **配信ノーマライズ予測** — Apple Music (-16) / Spotify (-14) / YouTube (-14) で何dB下げられるかを表示
- **自動リセット** — 約2秒の無音でIntegratedを自動リセット

## 動作環境

- macOS 14.4 (Sonoma) 以降
- Apple silicon / Intel 両対応（Universal Binary）

## インストール

1. [Releases](../../releases/latest) から最新の `LUFSBar_x.x.pkg` をダウンロード
2. インストーラーを実行（Apple署名・公証済み）
3. アプリケーションからLUFSBarを起動
4. 「**システムオーディオ録音**」の許可を求められたら許可

> **補足:** 初回起動時にログイン項目へ自動登録されます（macOSが「バックグラウンド項目が追加されました」と通知します）。設定からいつでもオフにでき、オフにしたものを勝手にオンへ戻すことはありません。

## 仕組みとプライバシー

Core Audio process tap API (macOS 14.4+) でシステム音声を観測し、[libebur128](https://github.com/jiixyj/libebur128) による ITU-R BS.1770-4 / EBU R128 準拠の計測（K特性フィルタ・ゲーティング・4倍オーバーサンプリングTrue Peak）を行います。

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

Xcode 16以降が必要です。

## ライセンス

MIT — [LICENSE](LICENSE) 参照。同梱の [libebur128](https://github.com/jiixyj/libebur128) もMITライセンスです。

---

制作: [tokyomeltdown](https://x.com/tokyomeltdownJP)
