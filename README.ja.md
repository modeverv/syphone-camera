# Syphon UniCamEx Bridge

Syphon映像ストリームを[UniCamEx](https://github.com/creativeIKEP/UniCamEx)仮想カメラへ送る、実験的なmacOSブリッジです。

```text
Webcam Motion Capture -> Syphon -> 本ブリッジ -> UniCamEx -> Chrome / Google Meet
```

## ステータス

メンテナー環境では、動く診断パターンとWebcam Motion CaptureのSyphon出力をUniCamExカメラ経由でQuickTime Playerに表示できることを確認済みです。実効キュー深度は1です。

このリポジトリはソースコード中心の実験的な状態です。署名済み・notarization済みアプリは提供していません。利用するMacには、別途UniCamExをインストールする必要があります。

## 必要条件

- macOS 13以降
- XcodeおよびCommand Line Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- [UniCamEx](https://github.com/creativeIKEP/UniCamEx)の**リリースバイナリ**
  （ブリッジのビルド・実行前に別途インストールが必要）
- [Syphon Framework](https://github.com/Syphon/Syphon-Framework)
- Webcam Motion Captureなど、Syphon出力に対応したアプリ

Syphonフレームワークは `Vendor/Syphon-Framework/DerivedData/Build/Products/Release/Syphon.framework` に配置される想定です。

## クイックスタート

```bash
git clone <repository-url>
cd syphon-camera
./scripts/bootstrap.sh
xcodegen generate
make build
make run
```

ブリッジをビルドまたは実行する前に、対象MacへUniCamExのリリースバイナリを
インストールし、必要な承認手続きを完了してください。`bootstrap.sh`が用意する
UniCamExのソースチェックアウトは開発用の参照であり、仮想カメラをインストール
または有効化するものではありません。

初期状態では動く診断パターンが選択されます。QuickTime Playerで **ファイル > 新規ムービー収録** を開き、`UniCamEx`を選択してください。

Webcam Motion Captureを使う場合はSyphon出力を有効にし、ブリッジでSyphonソースを選択します。通常は `Webcam Motion Receiver/Webcam Motion Receiver` が検出されます。その後、QuickTime、Chrome、またはGoogle Meetで `UniCamEx` を選択します。Syphonサーバー停止時は診断パターンへフォールバックします。

## ネットワーク H.264 転送（実験的）

別 Mac から映像を送る場合、`SyphonUniCamExSender.app` と `SyphonUniCamExReceiver.app` を別々にビルド・起動します。既定は UDP/5001 です。送信アプリでは **Test Pattern** または **Syphon** を選択できます。Syphon は検出した WMC 系サーバーを優先し、なければ最初のサーバーを使用します。

受信側（UniCamEx をインストールした Mac）:

```bash
make run-receiver NETWORK_PORT=5001
```

送信側:

```bash
make run-sender NETWORK_HOST=192.168.1.42 NETWORK_PORT=5001
```

同一 Mac で送受信を同時に確認するには次を実行します。

```bash
make run-network
```

UDP は H.264 フレームを最大 1,200 byte の datagram に分割し、1 秒以内に揃わないフレームを破棄します。これにより Wi-Fi/LAN でのパケット損失時にも古いフレームの再送待ちを避けます。一方、現時点では暗号化・認証・輻輳制御・FEC/NACK・適応ビットレートを持たないため、信頼できる LAN 専用です。インターネット越しの運用には WebRTC への置換が必要です。

## ビルドオプション

Makefileはデフォルトでローカル用の未署名ビルドを行います。

```bash
make build
make build CONFIGURATION=Release DERIVED_DATA=build-release
```

`CODE_SIGNING_ALLOWED=NO`がデフォルトです。署名済み配布物には、利用者自身のApple Developer環境、Bundle ID、entitlement、配布手順が必要です。未署名ビルドでカメラ拡張を有効化できるとは限りません。

## アーキテクチャ

```text
FrameSource -> BridgeEngine -> UniCamExSender -> UniCamEx virtual camera
```

UniCamEx v1.2.0経路ではIOSurface対応の1920x1080 BGRAピクセルバッファとCoreMediaIO sink streamを使用します。SyphonテクスチャはGPU上で変換し、最新フレームだけを保持します。

## 性能メモ

既存の Syphon 経路の基準測定では、30 fps時のブリッジCPU使用率は約16.8〜18.8%、RSSは約100 MB、Syphon公開からブリッジdispatchまでの平均時間は8.66 msでした。

2026-08-09 に同一 Mac で測定した UDP H.264 loopback（1920x1080 / 30 fps / テストパターン）は、送信から UniCamEx enqueue まで平均 **10.5 ms**、実効 **30.3 fps**、**0.5〜0.7 Mbps** でした。receiver は約18% CPU、sender は約100% CPU・約109 MB RSSでした。sender CPU はCPUベースの1080pテストパターン生成を含むため、Syphon 入力の性能値ではありません。TCP 比較では約22 msでした。いずれも環境依存の参考値です。詳細は[`Docs/PERFORMANCE.md`](Docs/PERFORMANCE.md)と[`Docs/ZERO_COPY_AUDIT.md`](Docs/ZERO_COPY_AUDIT.md)を参照してください。

## ドキュメント

- [`Docs/BUILD_AND_RUN.md`](Docs/BUILD_AND_RUN.md) — ビルドと実行時確認
- [`Docs/DESIGN.md`](Docs/DESIGN.md) — アーキテクチャとトレードオフ
- [`Docs/RUNTIME_NOTES.md`](Docs/RUNTIME_NOTES.md) — 確認済み環境のメモ
- [`Docs/TEST_PLAN.md`](Docs/TEST_PLAN.md) — 受け入れ確認項目
- [`Docs/ADR-001-network-transport.md`](Docs/ADR-001-network-transport.md) — リモート Syphon 転送方式とフレーム契約

## トラブルシューティング

- **`xcodegen`が見つからない:** `brew install xcodegen`でインストールします。
- **Syphonが見つからない:** `Vendor/Syphon-Framework`をビルドし、`project.yml`のパスを確認します。
- **UniCamExが表示されない:** UniCamExをインストール・承認し、カメラクライアントを再起動します。
- **黒いプレビュー:** ソースのフレーム生成、IOSurface、1920x1080 BGRA形式を確認します。
- **リモート映像が出ない:** 受信側で UDP/5001 を許可し、`NETWORK_HOST` が受信Macの LAN IP であること、両側の `NETWORK_TRANSPORT` が一致することを確認します。

## コントリビューション

バグ報告とPull Requestを歓迎します。macOS、Xcode、Macアーキテクチャ、UniCamEx/Syphonのバージョン、入力ソース、出力先、関連ログを添えてください。

## ライセンス

このプロジェクトは[MITライセンス](LICENSE)のもとで公開します。
