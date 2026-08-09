# Plan

## 次期機能: 別 Mac の WMC/Syphon 出力をネットワーク経由で受信し UniCamEx へ流す

### 目的

別の Mac で起動している Webcam Motion Capture (WMC) の Syphon 出力をネットワーク越しにこのアプリで受信し、現在のローカル Syphon 入力と同じフレーム経路で UniCamEx の仮想カメラへ供給する。送信側に Syphon のローカル共有を残しつつ、受信側では `BridgeEngine` と `UniCamExSender` を再利用する。

### 前提と制約

- Syphon は Mac 内の共有方式なので、Mac 間転送には送信側のキャプチャ兼エンコーダーが必要。Syphon 名をネットワーク越しに直接発見できる前提にはしない。
- 現行の標準目標は BGRA、1280x720、30 fps、最新フレーム優先の bounded buffer。入力解像度・fpsが異なる場合は受信側で明示的に正規化する。
- 主目的は低遅延で安定したカメラ出力。ロスレス転送や完全なゼロコピーは MVP の必須条件にしない。
- 既存のローカル Syphon 入力とテストパターン入力は退行させず、入力ソースを選択可能にする。
- Personal Team では System Extension の署名・有効化が別途ブロックされ得るため、実装検証と署名済みカメラ出力の検証を分けて記録する。

### Phase 0: 転送方式と契約を決める

- [x] 送信側の最小構成を定義する: `SyphonMetalClient` でフレーム取得 → GPU/VideoToolbox エンコード → ネットワーク送信。
- [x] 候補を比較する: WebRTC（低遅延・NAT/暗号化・依存が増える）、SRT/RIST（安定した映像転送）、RTP/UDP（最小遅延・実装/運用責任が大きい）、RTSP（ツール互換性優先）。
- [ ] まず同一 LAN・固定送信先・手動接続で PoC を行い、1280x720/30 fps の end-to-end 遅延、CPU、帯域、ドロップ、再接続時間を測る。
- [x] フレーム契約を文書化する: codec/profile、pixel format、width/height、fps/timebase、orientation、color metadata、keyframe interval、sequence/timestamp、audio は対象外。
- [x] MVP の方式と最低動作要件（macOS バージョン、Apple Silicon/Intel、同一 LAN、必要ポート、ファイアウォール）を ADR または計画更新として確定する。

### Phase 1: 送信側アダプター

- [ ] 送信側に Syphon source 設定（server name/app name）と送信先設定（host/portまたは signaling endpoint）を持つ独立した sender を用意する。
- [ ] Metal texture からエンコーダー入力への変換を実装し、不要な CPU readback を避ける。変換が必要な箇所は計測イベントで明示する。
- [ ] backpressure は「最新フレーム優先」とし、ネットワークが詰まった際に古いフレームを蓄積しない。
- [ ] 接続確立、codec format、送信 fps、送信 bytes、drop、再接続をログ/計測する。
- [ ] sender 単体で、既知のテストパターンと WMC の実 Syphon 出力を送信できることを確認する。

### Phase 2: 受信フレームソース

- [ ] `NetworkFrameSource`（仮称）を追加し、既存の `SyphonFrameSource` / `TestPatternFrameSource` と同じ入力ソース契約に適合させる。
- [ ] 受信スレッドと decode/render スレッドをカメラ送出から分離する。受信バッファは上限を設け、queue depth 1 の latest-frame-wins を基本とする。
- [ ] decoded frame を既存の `CVPixelBuffer` / `CMSampleBuffer` 生成経路へ正規化し、BGRA、解像度、fps、timestamp を検証する。
- [ ] 欠落・破損・format change・timeout 時の挙動を定義する（フレーム破棄、再接続、最後のフレーム保持または黒フレーム）。
- [ ] 切断中に `BridgeEngine` や UniCamEx sender がクラッシュせず、停止・再接続・入力切替を安全に行えるようにする。

### Phase 3: アプリ設定と既存パイプラインへの統合

- [ ] `AppModel` / `ContentView` に入力モード（Test Pattern / Local Syphon / Network）とネットワーク設定を追加する。
- [ ] 手動設定を MVP とし、Syphon server の自動発見や複数送信元管理は後続フェーズに分離する。
- [ ] `BridgeEngine` は入力ソースの差異を意識せず、既存の `LatestFrameStore`、`PipelineInstrumentation`、`UniCamExSender` を利用する。
- [ ] 入力ソース切替時の lifecycle（stop → drain/reset → start）と、解像度/fps変更時の sample buffer format 更新を実装する。
- [ ] 接続状態、受信 fps、decode latency、end-to-end latency、drop 数を UI または診断ログで確認できるようにする。

### Phase 4: 検証

- [ ] ローカルのテストパターンを送信し、受信側の色・向き・解像度・fps・timestamp が一致することを確認する。
- [ ] WMC → Syphon → network sender → network receiver → UniCamEx → Meet/QuickTime の実フローを同一 LAN で確認する。
- [ ] 5 分以上の連続運転で、受信 drop、UniCamEx enqueue drop、黒フレーム、メモリ増加、クラッシュがないか測定する。
- [ ] 帯域制限、遅延、パケットロス、送信停止、受信再起動、Wi-Fi 切断復帰を再現し、期待する再接続・フォールバックを確認する。
- [ ] CPU と end-to-end latency を送信側・受信側・UniCamEx の各区間で個別に記録する。OBS の表示値だけで end-to-end 性能を判断しない。
- [ ] 署名済み環境では実カメラアプリからの出力を確認し、未署名ビルドではビルド・パイプライン検証までと明確に区別する。

### 完了条件（MVP）

- [ ] 別 Mac の WMC Syphon 出力を、手動設定した同一 LAN の送信先へ安定して送れる。
- [ ] 受信側で 1280x720/30 fps の映像を最新フレーム優先で UniCamEx に流せる。
- [ ] 通常時の映像遅延・CPU・帯域の測定値と、切断時の再接続動作が記録されている。
- [ ] Local Syphon / Network / Test Pattern の各入力を切り替えても既存の UniCamEx 経路が壊れない。
- [ ] セキュリティ（認証・暗号化または LAN 内限定の明示）、必要ポート、既知の制約を README に追記する。

### 後続候補

- [ ] Bonjour による sender 発見と Syphon server 名の一覧化。
- [ ] 複数送信元、送信元の認証・暗号化、遠隔ネットワーク/NAT 対応。
- [ ] 動的な解像度/fps、帯域適応、ハードウェアエンコード設定の UI。
- [ ] 音声転送、録画、複数カメラ、リモート診断。
