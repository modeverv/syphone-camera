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
- [UniCamEx](https://github.com/creativeIKEP/UniCamEx)
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

初期状態では動く診断パターンが選択されます。QuickTime Playerで **ファイル > 新規ムービー収録** を開き、`UniCamEx`を選択してください。

Webcam Motion Captureを使う場合はSyphon出力を有効にし、ブリッジでSyphonソースを選択します。通常は `Webcam Motion Receiver/Webcam Motion Receiver` が検出されます。その後、QuickTime、Chrome、またはGoogle Meetで `UniCamEx` を選択します。Syphonサーバー停止時は診断パターンへフォールバックします。

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

基準測定では、30 fps時のブリッジCPU使用率は約16.8〜18.8%、RSSは約100 MB、Syphon公開からブリッジdispatchまでの平均時間は8.66 msでした。詳細は[`Docs/PERFORMANCE.md`](Docs/PERFORMANCE.md)と[`Docs/ZERO_COPY_AUDIT.md`](Docs/ZERO_COPY_AUDIT.md)を参照してください。

## ドキュメント

- [`Docs/BUILD_AND_RUN.md`](Docs/BUILD_AND_RUN.md) — ビルドと実行時確認
- [`Docs/DESIGN.md`](Docs/DESIGN.md) — アーキテクチャとトレードオフ
- [`Docs/RUNTIME_NOTES.md`](Docs/RUNTIME_NOTES.md) — 確認済み環境のメモ
- [`Docs/TEST_PLAN.md`](Docs/TEST_PLAN.md) — 受け入れ確認項目

## トラブルシューティング

- **`xcodegen`が見つからない:** `brew install xcodegen`でインストールします。
- **Syphonが見つからない:** `Vendor/Syphon-Framework`をビルドし、`project.yml`のパスを確認します。
- **UniCamExが表示されない:** UniCamExをインストール・承認し、カメラクライアントを再起動します。
- **黒いプレビュー:** ソースのフレーム生成、IOSurface、1920x1080 BGRA形式を確認します。

## コントリビューション

バグ報告とPull Requestを歓迎します。macOS、Xcode、Macアーキテクチャ、UniCamEx/Syphonのバージョン、入力ソース、出力先、関連ログを添えてください。

## ライセンス

このプロジェクトは[MITライセンス](LICENSE)のもとで公開します。
