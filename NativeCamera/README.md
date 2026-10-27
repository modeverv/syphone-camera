# Native Camera Extension

2026-10-27: Host build 6 / Camera Extension build 4 の開発版。
自作 Camera Extension、配布版 WMC の Syphon 入力、最終 IOSurface に直接描画する
Metal 診断ソースに対応する。既定は **1920×1080 / BGRA / 30 fps**。
**1280×720 / 30 fps は任意のオプション**で、既定の解像度は変更しない。
最新の WMC 入力・解像度切り替え仕様は [30 fps 対応記録](../Docs/NATIVE_CAMERA_30FPS.md) を参照。
負荷と実送信の確認は [Meet 比較記録](../Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md) を参照。
既存の UniCamEx ブリッジとは別のアプリ・ビルド経路である。

Metal 診断ソースの転送境界は次のとおり。

```text
Metal が最終 CVPixelBuffer / IOSurface に直接描画
  -> NativeCameraSink が CMSampleBuffer で包む
  -> CoreMediaIO sink stream
  -> Camera Extension が受信した CMSampleBuffer 自体を source stream へ送る
  -> device-native 形式を要求する AVFoundation 検証受信アプリ
```

Metal 診断ソースの `zero-copy` モードのホスト転送処理と拡張に CPU readback、画像の memcpy、GPU blit、変換用の
CVPixelBuffer 再生成はない。Metal テスト映像の生成自体には GPU の描画処理がある。
プロセスをまたぐ同一ストレージ、保持中の不変性、映像内容は
[実測レポート](../Docs/NATIVE_ZERO_COPY_VERIFICATION.md)で確認した。
別のカメラアプリが独自に行う変換や、転送前の外部 producer の処理まで
コピーゼロとするものではない。

**配布版 Webcam Motion Receiver は、GPU 変換を 1 回行う入力経路に対応。**
GUI の「WMC映像を開始」または `--source syphon` で、既定の 1080p / 30 fps を送信する。
720p を選ぶ場合は `--resolution 720p` を追加する。
必要な縮小と上下反転を自前の最終 CVPixelBuffer へ同時に行い、その後は同じバッファを共有する。
通常経路に CPU の画像 readback / pixel-plane copy はない。
`hasNewFrame` の値にかかわらず、採用した 30 Hz の各 tick で `newFrameImage()` を呼び、
現在の texture を GPU で写す。これにより解像度比較の GPU 変換回数を揃える。
変換回数は、WMC が毎秒 30 枚の異なる画像を生成したことを示す数ではない。
WMC の mutable texture を直接共有する完全なゼロコピーには、producer 側の変更が必要である。
「Syphon入力の対応状況を確認」は、その直接共有の制約を表示する診断である。
詳細は [WMC の実測・ABI 調査](../Tools/ZeroCopyDiagnostics/README.md)を参照。

## 構成と識別子

| 項目 | 値 |
| --- | --- |
| プロジェクト / scheme | `NativeCamera/SyphonZeroCopyCamera.xcodeproj` / `SyphonZeroCopyCamera` |
| ビルド成果物 | `SyphonZeroCopyCamera.app` |
| 開発版 | `0.1.0` / Host build 6 / Camera Extension build 4 |
| この Mac のインストール先 | `/Applications/SyphonCameraExtensionProbe.app` |
| ホスト Bundle ID | `com.dream-jack.syphoncamera.probe` |
| 拡張 Bundle ID | `com.dream-jack.syphoncamera.probe.camera` |
| Team | Dream Jack Inc. / `85LT3DSJ3L` |
| App Group | `85LT3DSJ3L.com.dream-jack.syphoncamera.probe` |
| CMIO Mach service | `85LT3DSJ3L.com.dream-jack.syphoncamera.probe.camera` |
| カメラ表示名 | `Syphon Zero Copy Camera` |

Bundle ID とインストール先の `probe` は、先に有効化した最小検証アプリの識別子を
引き継いだもの。NativeCamera はその拡張を更新するため、旧
`Tools/CameraExtensionProbe` と同時に別カメラとしてインストールする構成ではない。
旧 probe は 640×480 の CPU パターン、現在の native 版は 1080p / 720p の
sink/source 転送と Metal / Syphon ソースである。ビルド成果物の名前だけを見て
`/Applications` の別アプリへ重複配置しないこと。

[会社チームの検証記録](../Docs/CAMERA_EXTENSION_PROBE.md)で、開発署名、承認、
カメラ列挙まで確認済み。ホストのプロファイルは
`Mac Team Provisioning Profile: com.dream-jack.syphoncamera.probe`。
`com.apple.developer.system-extension.install` を含み、ホストに埋め込まれる。
拡張は同一チームの署名、sandbox、共通 App Group を持つ。
Host は Syphon の動的 Mach port 通信のため非 sandbox で動作する。
両 target の Hardened Runtime は有効である。
最小検証時には拡張側に別の embedded profile は生成されなかった。
プロファイルを秘密鍵・認証情報とともにリポジトリへ配布する手順は含まない。

## ビルドと署名

必要条件は macOS 13 以降、Xcode、XcodeGen、Syphon Release framework、
対象チームの有効な開発証明書と macOS 開発プロファイル。
以下はすべてリポジトリルートから実行する。

初回は Syphon のソースを取得する。`scripts/bootstrap.sh` などで取得済みなら、この操作は不要。
NativeCamera の利用に UniCamEx のインストールは不要である。

```sh
mkdir -p Vendor
git clone https://github.com/Syphon/Syphon-Framework.git Vendor/Syphon-Framework
```

Syphon framework が未ビルドの場合:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Vendor/Syphon-Framework/Syphon.xcodeproj -scheme Syphon \
  -configuration Release -derivedDataPath Vendor/Syphon-Framework/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Native プロジェクト生成と開発署名ビルド:

```sh
xcodegen generate --spec NativeCamera/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project NativeCamera/SyphonZeroCopyCamera.xcodeproj \
  -scheme SyphonZeroCopyCamera -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/native-camera/DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM=85LT3DSJ3L build
```

`-allowProvisioningUpdates` は Xcode にチームの識別子・プロファイル更新を許可する。
別のチームでは `project.yml` と entitlement の Bundle ID / App Group も
そのチームに合わせる。更新対象 target の `CURRENT_PROJECT_VERSION` を増やす。
Host のみの変更では拡張の版を独立して維持できる。性能比較には Release build を使う。
ローカルでコンパイルだけ確認する場合は署名更新オプションを外し
`CODE_SIGNING_ALLOWED=NO` を付けられるが、その成果物で拡張の有効化は確認できない。
ルートの `make build` は既存 UniCamEx アプリ用で、このターゲットをビルドしない。

## インストール・有効化・実行

カメラ受信と起動中のホストを停止・終了してから `.app` 全体を置き換える。以下は既存 bundle を
バックアップし、旧ファイルを merge しない配置例。バックアップ先または staging 先
（`.next.app`）が既にある場合は、空いている別名にする。

```sh
ditto build/native-camera/DerivedData/Build/Products/Release/SyphonZeroCopyCamera.app \
  /Applications/SyphonCameraExtensionProbe.next.app
if [ -d /Applications/SyphonCameraExtensionProbe.app ]; then
  mv /Applications/SyphonCameraExtensionProbe.app \
    build/native-camera/previous-SyphonCameraExtensionProbe.app
fi
mv /Applications/SyphonCameraExtensionProbe.next.app \
  /Applications/SyphonCameraExtensionProbe.app
codesign --verify --deep --strict /Applications/SyphonCameraExtensionProbe.app
open /Applications/SyphonCameraExtensionProbe.app --args --activate
```

アプリの「カメラ拡張を有効化・更新」ボタンも同じ要求を送る。承認要求が出た場合は
macOS のシステム設定でカメラ機能拡張を承認する。SIP 無効化や system-extension
developer mode の有効化はこの手順に含まれない。`COMPLETED` は要求の完了を示すため、
次の状態と実際の受信も確認する。

```sh
systemextensionsctl list
```

対象 ID が `activated enabled` になったら「GPUテスト映像を開始」を押し、受信側で
`Syphon Zero Copy Camera` を選ぶ。起動時に有効化と有限時間の送信を行うこともできる。

```sh
open /Applications/SyphonCameraExtensionProbe.app --args \
  --activate --test-pattern --duration 30
```

起動引数は新規起動時だけ処理される。既に起動している場合は UI を使用するか、
ホストを終了してから実行する。`--duration` は送信を停止し、ホストは開いたまま残る。
UI の「停止」またはアプリ終了でも送信を止められる。

WMC の Syphon 出力を有効にして、既定の 1080p / 30 fps を送る例:

```sh
open -n /Applications/SyphonCameraExtensionProbe.app --args --source syphon
```

任意の 720p 設定を使う例:

```sh
open -n /Applications/SyphonCameraExtensionProbe.app --args --source syphon --resolution 720p
```

解像度を切り替える前に、Meet などのカメラ受信を停止して仮想カメラを解放し、送信アプリも終了する。
新しい設定で送信を開始してから受信を再開する。起動済みの送信アプリを残したまま `open -n` で重複起動しない。
`--resolution 1080p` は既定値を明示する。WMC 入力は未検出・複数候補・切断時にエラーとなり、
別ソースや診断パターンへ自動的に切り替えない。

Metal 診断ソースの性能比較用に `--transport gpu-copy` を指定すると、同じ形式の IOSurface に描画して
最終出力へ GPU blit を1回行う。これは明示的な比較モードで、ゼロコピーではない。
診断ソースで省略時または `--transport zero-copy` は直接描画経路。`gpu-copy` は WMC 入力には指定できない。
`--benchmark` は毎フレームの送信 trace を止め、累積 GPU 時間・送信数等を1秒ごとに
記録する。比較モードだけ scratch surface を1枚追加する（1080p では 8,294,400 bytes）。
[再現用ツール](../Tools/ZeroCopyBenchmark/README.md)を参照。

## 性能確認の範囲

両解像度で GPU 変換・送出を約 30 fps に揃えた WMC 比較では、**720p 化による CPU 低下は未確認**。
Host の GPU 変換コマンド時間は約 **21.8%**、physical footprint は約 **8.22 MiB** 減少した。
この GPU 時間は Mac 全体の GPU 使用率ではなく、メモリの値も Host の指標である。

別のネットワーク観測で、1080p のカメラ入力から Meet が **720p・約 30 fps** を実際に送受信したことを確認した。
720p 入力条件の送受信値と、CPU 主比較の測定窓に対応する RTP 統計は未確認であり、
実通信負荷が減ったという結論には至っていない。
数値・条件・制限は [Meet 比較記録](../Docs/NATIVE_CAMERA_MEET_PERFORMANCE.md) を参照。

## 所有権、上限、バックプレッシャー

- `SurfacePatternRenderer` は IOSurface-backed BGRA の `CVPixelBufferPool` を使い、
  8 個を同時に warm-up した後は恒久的に保持しない。各取得に allocation threshold
  8 を指定する。取得不能ならその tick を破棄し、使用中バッファを上書きしない。
  同じ解像度・transport の送信停止・再開では同じ pool を維持し、renderer はホスト終了時に
  解放する。`poolPressureDrops` はその renderer の生存期間を通じた累計である。
- Metal は取得したバッファに直接生成し、command buffer の完了成功を確認してから
  submit する。共有後は producer が書き込まない。
- `SyphonResizingSource` も上限 8 枚の pool を使う。最新の完成済み出力 1 枚をその pool 内に保持し、
  `newFrameImage()` が一時的に nil の場合だけ再送する。入力サーバーの切断時はエラーで停止する。
  `freshRenderedFrames` は GPU 変換数、`repeatedOutputFrames` は再送数、`totalOutputFrames` は両者の合計。
  `noNewFrameTicks` は参考値で、GPU 変換を省略した数ではない。
- CoreVideo と CMIO の IOSurface / Mach-port による所有権追跡を使う。
  producer のローカル参照解放や sink のスケジュール通知を、全 consumer の解放と
  同一視しない。生の surface ID を受け渡して手動で ring を再利用する設計ではない。
- `NativeCameraSink` は serial queue 上で操作し、キュー容量を確認してから
  sample の retained reference を CMIO に渡す。enqueue 失敗時は保持を解放する。
  source は30 fpsで tick し、満杯時はスキップする。90 tick 連続の満杯では接続を再試行する。
- 拡張の sink queue size は1。consume は同時に1件だけとし、完了を provider の
  serial queue に戻す。producer は同時に1クライアントだけ受け付ける。
  受信側がないときは入力を消費して破棄し、最終画像を永久保持しない。
- 拡張は ready な1サンプル、選択した 1920×1080 または 1280×720 BGRA、IOSurface の形式、非負で単調増加する
  PTS を検査する。適合しないフレームを変換して救済する処理はない。

これらは producer が所有権契約に従うことを前提とする。format の検査だけでは
外部 producer の書き込みを防げない。stock Syphon texture の retain はこの契約を満たさない。

## 独自 producer との接続

`Host/NativeCameraSink.swift` の `connect(width:height:)`、`hasCapacity`、
`submit(_:timestamp:)`、`close()` を同一の serial queue から使用する。
これはホストに組み込む Swift クラスであり、一般公開済みの外部 SDK ではない。

呼び出し側は最終形式の IOSurface-backed CVPixelBuffer を所有し、元の描画をその
Metal texture に行い、GPU 完了後に `submit` する。返り値 `false` は容量不足等に
よる未投入なので、そのフレームを破棄する。投入成功後は書き込みを止め、
CoreVideo/CMIO の consumer lifetime を尊重する pool に解放を任せる。
`notifyScheduledOutputChanged` や enqueue 成功をバッファの再利用許可にしてはいけない。

PTS は host clock 基準でセッション内単調増加とする。検証用ソースは CMIO の
時刻表現に合わせ10 µs単位に正規化してから記録し、受信側と有理数として厳密照合する。
既存画像からの blit、上下反転、サイズ変更が必要な producer は、その処理を含む
区間について「コピーゼロ」と呼ばない。最終的な向きは元の描画時に確定する。

## 記録と検証

ホストの記録先:

```text
~/Library/Containers/com.dream-jack.syphoncamera.probe/Data/Library/Application Support/SyphonZeroCopyCamera/
```

- `activation.log`: 更新・承認要求結果。
- `source-trace.jsonl`: 送信した sequence / IOSurface ID / PTS。送信開始ごとにリセット、上限10,000行。
- `producer-status.json`: pool 上限、surface IDs、送信数、queue/pool pressure drops。
- `extension-telemetry.json`: CMIO custom property `zcpy` のスナップショット。
  拡張は直近128フレームの ID / PTS、転送・拒否・consumer不在件数を保持する。
- `host-status.json`: 現在のホスト状態。

カメラ列挙や `transportPixelCopies: 0` の自己申告だけで実証としない。
[検証 consumer](../Tools/ZeroCopyVerification/README.md)は device-native samples を要求し、
source trace と同一 IOSurface ID **かつ同一 PTS** を照合する。必要に応じて
sequence stamp、保持中の hash 不変性、最初の画像を検査する。
hash / stamp / PNG のための CPU 読み取りは診断 consumer 内だけで行われる。
macOS が別アプリの container 読み取りを拒否した場合は、送信終了後に trace を
証跡ディレクトリへコピーし、`recheck-report.py` で保存済み受信レポートを再照合する。

会社チームでの開発署名・最小拡張の有効化は確認済みだが、一般配布用の
Developer ID 署名、notarization、別 Mac での配布検証は別の工程である。
実際の転送検証結果と対象条件は [ゼロコピー監査](../Docs/ZERO_COPY_AUDIT.md)に記録する。
