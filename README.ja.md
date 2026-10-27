# Syphon Camera

Syphon 映像を仮想カメラへ送る実験的な macOS アプリです。自作 Camera Extension を含む
`NativeCamera` と、[UniCamEx](https://github.com/creativeIKEP/UniCamEx) を使う既存ブリッジがあります。
native 版の既定は **1080p / 30 fps**、**720p / 30 fps は任意のオプション**です。

```text
Webcam Motion Receiver -> Syphon -> NativeCamera -> Syphon Zero Copy Camera -> Meet / Zoom
                                  または BridgeApp -> UniCamEx             -> カメラ受信アプリ
```

## ステータス

2026-10-27: 自作 Camera Extension と最終 IOSurface に直接描画する native Metal
ソースを [`NativeCamera`](NativeCamera/README.md) に追加しました。会社チームでの
開発署名・最小拡張の有効化を確認できたため、以前の「Personal Team しか使えない」
という制約は解消しています。ビルド・署名・インストールは専用 README の手順を使います。

native 版は Host build 6 / Camera Extension build 4 です。
最終 CVPixelBuffer → CMIO sink → 同一 sample の拡張転送を実装しています。
配布版 WMC の入力に対応し、既定の 1080p、任意の 720p とも 30 fps 上限で送信できます。
WMC 入力は採用した各 tick で最新 texture を取得し、1 回の GPU 処理で必要な縮小・上下反転を行います。
通常経路に CPU の画像コピーはありませんが、WMC 入力を含む完全なゼロコピーではありません。
最終 IOSurface に直接描画する Metal 診断ソースも維持しています。
実行・解像度の切り替え・検証範囲は [`Docs/NATIVE_CAMERA_30FPS.md`](Docs/NATIVE_CAMERA_30FPS.md) を参照してください。

配布版 WMC は同じ surface を更新し続けるため、その画像を安全に直接共有する経路は未対応です。
WMC のソースコードは手元になく、配布版の native plugin 交換だけでは解決しません。
実測と制約は [`Tools/ZeroCopyDiagnostics`](Tools/ZeroCopyDiagnostics/README.md)、
検証範囲は [`Docs/ZERO_COPY_AUDIT.md`](Docs/ZERO_COPY_AUDIT.md) を参照してください。

メンテナー環境では、動く診断パターンとWebcam Motion CaptureのSyphon出力をUniCamExカメラ経由でQuickTime Playerに表示できることを確認済みです。実効キュー深度は1です。

既存の WMC → UniCamEx 経路は GPU で上下反転しながらコピーする
`METAL_FLIP_BLIT` と Core Image fallback を維持しています。この経路はゼロコピーではありません。
native 版と既存 UniCamEx 経路のビルド・起動手順は、以下で個別に説明します。

このリポジトリはソースコード中心の実験的な状態です。一般配布用の署名済み・notarization済みアプリは提供していません。既存ブリッジを利用するMacには、別途UniCamExをインストールする必要があります。

## Native Camera のビルドと利用

署名に使う Apple Developer チーム、識別子、Syphon framework の準備とインストールは
[`NativeCamera/README.md`](NativeCamera/README.md) を参照してください。リポジトリルートからビルドします。

```sh
xcodegen generate --spec NativeCamera/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project NativeCamera/SyphonZeroCopyCamera.xcodeproj \
  -scheme SyphonZeroCopyCamera -configuration Release \
  -derivedDataPath build/native-camera/DerivedData build
```

この Mac のインストール先は、先行した検証アプリの名前を引き継いでいます。
拡張を有効化し、WMC の Syphon 出力をオンにした後、既定の **1080p / 30 fps** で起動します。

```sh
open -n /Applications/SyphonCameraExtensionProbe.app --args --source syphon
```

受信側では **Syphon Zero Copy Camera** を選択します。720p にする場合は受信アプリのカメラを停止し、
送信アプリを終了してから `--source syphon --resolution 720p` で起動します。
`--resolution 1080p` で既定値を明示できます。複数の送信アプリを同時に起動しないでください。
GUI にも解像度選択と WMC の開始・停止があります。

native 版は入力が未検出・複数候補・切断の場合にエラーを表示します。
動的 Mach port を使う Syphon 通信のため Host は非 Sandbox、拡張は Sandbox 有効です。
両 target の Hardened Runtime と開発署名を維持しています。詳しい操作は
[`30 fps 対応記録`](Docs/NATIVE_CAMERA_30FPS.md) を参照してください。
UniCamEx は native 版には不要で、ルートの `make build` は既存 UniCamEx アプリ用です。

## UniCamEx 経路の必要条件

- macOS 13以降
- XcodeおよびCommand Line Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- [UniCamEx](https://github.com/creativeIKEP/UniCamEx)の**リリースバイナリ**
  （ブリッジのビルド・実行前に別途インストールが必要）
- [Syphon Framework](https://github.com/Syphon/Syphon-Framework)
- Webcam Motion Captureなど、Syphon出力に対応したアプリ

Syphonフレームワークは `Vendor/Syphon-Framework/DerivedData/Build/Products/Release/Syphon.framework` に配置される想定です。

## UniCamEx 経路のクイックスタート

```bash
git clone <repository-url>
cd syphon-camera
./scripts/bootstrap.sh
xcodegen generate
make build
make run
```

`make build` は `build/Build/Products/Debug/` に次の3つのアプリバンドルを生成します。

- `SyphonUniCamExBridge.app` — 1台のMacで使う統合版
- `SyphonUniCamExSender.app` — ネットワーク H.264 送信アプリ
- `SyphonUniCamExReceiver.app` — ネットワーク H.264 受信・UniCamEx 出力アプリ

各 `.app` バンドルには必要な Syphon.framework が内包されるため、ビルドディレクトリを
伴わずにアプリバンドル全体をコピーまたは移動して実行できます。ただし、仮想カメラを
公開する統合版と receiver には、対象Macで UniCamEx を別途インストール・承認しておく
必要があります。ローカルビルドは未署名なので、一般配布には署名と notarization が必要です。

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

## UniCamEx 経路のビルドオプション

Makefileはデフォルトでローカル用の未署名ビルドを行います。

```bash
make build
make build CONFIGURATION=Release DERIVED_DATA=build-release
```

`CODE_SIGNING_ALLOWED=NO`がデフォルトです。署名済み配布物には、利用者自身のApple Developer環境、Bundle ID、entitlement、配布手順が必要です。未署名ビルドでカメラ拡張を有効化できるとは限りません。

## UniCamEx 経路のアーキテクチャ

```text
FrameSource -> BridgeEngine -> UniCamExSender -> UniCamEx virtual camera
```

UniCamEx v1.2.0経路ではIOSurface対応の1920x1080 BGRAピクセルバッファとCoreMediaIO sink streamを使用します。SyphonテクスチャはGPU上で変換し、最新フレームだけを保持します。

## 性能メモ

native 版の WMC 比較は、両解像度とも GPU 変換・送出を約 30 fps に揃えました。
**720p 化による CPU 低下は確認できませんでした。** Host の GPU 変換コマンド時間は約 **21.8%**、
physical footprint は約 **8.22 MiB** 減少しました。Mac 全体の GPU 使用率や総メモリ削減の値ではありません。

別の Meet ネットワーク観測では、**1080p のカメラ入力から 720p・約 30 fps の実送受信**を確認しました。
720p 入力条件のネットワーク比較と、CPU 比較窓への RTP 統計の時刻照合は未完了です。
実通信負荷の低下は確定していません。条件・数値・制限は
[`比較記録`](Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md) を参照してください。
既定は 1080p のまま、720p は必要に応じて選べます。

既存の UniCamEx 経路の過去の基準測定では、30 fps 時のブリッジ CPU 使用率は約16.8〜18.8%、RSSは約100 MB、Syphon公開からブリッジdispatchまでの平均時間は8.66 msでした。

2026-08-09 に同一 Mac で測定した UDP H.264 loopback（1920x1080 / 30 fps / テストパターン）は、送信から UniCamEx enqueue まで平均 **10.5 ms**、実効 **30.3 fps**、**0.5〜0.7 Mbps** でした。receiver は約18% CPU、sender は約100% CPU・約109 MB RSSでした。sender CPU はCPUベースの1080pテストパターン生成を含むため、Syphon 入力の性能値ではありません。TCP 比較では約22 msでした。いずれも環境依存の参考値です。詳細は[`Docs/PERFORMANCE.md`](Docs/PERFORMANCE.md)と[`Docs/ZERO_COPY_AUDIT.md`](Docs/ZERO_COPY_AUDIT.md)を参照してください。

## ドキュメント

- [`NativeCamera/README.md`](NativeCamera/README.md) — 自作 Camera Extension のビルド・署名・実行と所有権契約
- [`Docs/NATIVE_CAMERA_30FPS.md`](Docs/NATIVE_CAMERA_30FPS.md) — 配布版 WMC 入力と 1080p / 720p・30 fps 対応、操作・検証範囲
- [`Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md`](Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md) — 30 fps を揃えた 1080p / 720p の負荷と Meet 実送信の確認
- [`Docs/NATIVE_ZERO_COPY_PERFORMANCE.md`](Docs/NATIVE_ZERO_COPY_PERFORMANCE.md) — コピーあり／なしのCPU・GPU・メモリ実測比較
- [`Tools/ZeroCopyDiagnostics/README.md`](Tools/ZeroCopyDiagnostics/README.md) — 配布版 WMC の直接共有を妨げる実測・実装上の制約
- [`Tools/ZeroCopyVerification/README.md`](Tools/ZeroCopyVerification/README.md) — 同一 IOSurface / PTS と保持中不変性の検証
- [`Docs/CAMERA_EXTENSION_PROBE.md`](Docs/CAMERA_EXTENSION_PROBE.md) — 会社チームでの署名・有効化の確認記録
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
