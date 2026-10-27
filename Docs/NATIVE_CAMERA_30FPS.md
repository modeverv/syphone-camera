# Native Camera の 1080p / 720p・30 fps 対応

2026-10-27、開発版 `0.1.0`（Host build 6 / Camera Extension build 4）。配布版 Webcam Motion Receiver（WMC）の
Syphon 映像を、自作 Camera Extension の **Syphon Zero Copy Camera** に送れます。
既定の出力は **1920×1080 / 30 fps**、1280×720 / 30 fps は任意の選択肢です。
どちらも 30 fps を上限とします。
インストール先は `/Applications/SyphonCameraExtensionProbe.app`、実行ファイル名は
`SyphonZeroCopyCamera` です。ビルド・署名手順は [NativeCamera README](../NativeCamera/README.md) を参照してください。

## 映像の経路とコピーの範囲

```text
WMC の mutable Syphon texture
  → 30 Hz の採用判断と sink 空き確認
  → 最新 texture を取得
  → GPU で縮小＋上下反転を 1 回の dispatch で実行
  → 自前 pool の最終 IOSurface / CVPixelBuffer
  → CMIO sink
  → Camera Extension が同じ CMSampleBuffer を転送
  → カメラ受信アプリ
```

`SyphonResizingSource` は、採用されたフレームだけを変換します。1080p 出力でも上下反転が
必要なため、GPU 処理は 1 回です。720p では同じ処理に linear sampling による縮小を含めます。
最終バッファへ直接書き込み、GPU 完了を待ってから送信するので、中間画像バッファは不要です。
通常の転送処理に CPU の画像 readback / pixel-plane copy はありません。

最終 CVPixelBuffer の pool は 8 枚に制限し、保持されている出力を上書きせず、空きがなければ
その tick を捨てます。sink queue は 1 枚です。Camera Extension 自体は縮小・画像コピーを行いません。

`hasNewFrame` は入力取得の条件に使いません。WMC の texture 自体は更新され続けるため、
採用されたすべての tick で `newFrameImage()` を呼び、その時点の画像を GPU で最終バッファへ写します。
この動作で、1080p / 720p の比較をどちらも毎秒 30 回の GPU 変換に揃えます。
Syphon の実装上、`newFrameImage()` は `hasNewFrame` が false でも current texture を返せます。

`newFrameImage()` 自体が一時的に nil を返したときだけ、最後に完成した**自前の最終バッファ**を
新しい PTS で再送します。キャッシュとして保持する 1 枚も pool の 8 枚に含まれ、保持中は再利用されません。
初回画像の取得前は出力せず、入力サーバーの切断時はエラーで停止します。
毎秒 30 回の出力・GPU sampling は、毎秒 30 枚の異なる WMC 画像が得られるという意味ではありません。

**WMC 入力からの完全なゼロコピーではありません。** 配布版 WMC は同じ texture を更新し続けるため、
自前の最終バッファへ GPU で写す処理が必要です。入力 texture を次の tick まで保持することはしませんが、
GPU が読み取っている間にも WMC が書き換え得るという送信元の制約は残ります。
WMC のソースコードがないため、この制約を送信元で解消したとは扱いません。
背景は [WMC の診断記録](../Tools/ZeroCopyDiagnostics/README.md) にあります。

Metal 診断パターンは、引き続き最終 IOSurface に直接描画します。この経路の既存の
[同一 surface / PTS・保持中不変性の検証](NATIVE_ZERO_COPY_VERIFICATION.md) と、
WMC の GPU 変換経路は区別します。ブラウザの色変換・縮小・エンコード処理までゼロコピーとは主張しません。

## 実行と解像度の切り替え

先に WMC の Syphon 出力を有効にします。既定では、名前またはアプリ名が WMC に一致する
サーバーを一意に選びます。未検出・複数候補・切断時はエラーを表示し、別ソースや診断パターンへ
自動的に切り替えません。起動時には Syphon discovery のため 2 秒待ちます。

解像度を切り替えるときは、次の順序で行います。

1. Meet などでカメラをオフにし、QuickTime や検証ツールも停止して、この仮想カメラの受信を解放します。
2. 送信アプリを停止・終了します。既存プロセスを残したまま `open -n` で複数の送信元を起動しないでください。
3. 希望する解像度で送信アプリを起動します。
4. 受信アプリで **Syphon Zero Copy Camera** を選び、カメラをオンにします。

既定の 1080p / 30 fps 上限で WMC を送る例:

```sh
open -n /Applications/SyphonCameraExtensionProbe.app --args \
  --source syphon --resolution 1080p --benchmark
```

720p を使う場合は `--resolution 720p` に変更します。`--benchmark` はフレームごとの
trace 出力を抑える測定用オプションです。映像の内容やフレームレートは変更しません。
`--duration 60` を追加すると 60 秒で送信を停止します。

直接描画する診断パターンの例:

```sh
open -n /Applications/SyphonCameraExtensionProbe.app --args \
  --source pattern --test-pattern --resolution 1080p --transport zero-copy --benchmark
```

`--transport gpu-copy` は診断パターン専用の比較モードです。WMC の入力モードには使いません。
初回画像の取得待ち、queue / pool の空き不足、タイマーの遅延では実際の出力 fps が 30 を下回る場合があります。

## Host の Sandbox と署名

Syphon は `info.v002.Syphon.<UUID>` という動的な Mach port 名で通信します。
Sandbox を有効にした Host ではサーバー名が見えて `client.isValid` が true でも、
フレームは受信できませんでした。稼働中 Host に対する read-only の `sandbox_check` では、
Syphon prefix の診断用 port 名への `mach-register` / `mach-lookup` が拒否され、
同じ Host の App Group prefix は許可されました。これは Sandbox policy の検査であり、
WMC の実 port に対する拒否ログを採取したものではありません。

Host target のみ App Sandbox を無効にして署名し直した後、実 WMC の受信・転送を確認しました。
Camera Extension の App Sandbox、両 target の Hardened Runtime、会社チームでの署名は有効です。
Apple は [Camera Extension 側の Sandbox を必須と説明しています](https://developer.apple.com/videos/play/wwdc2022/10022/)。
この構成はローカル開発用で、App Store 配布の成立を確認したものではありません。

診断出力は既存の測定ツールとの互換性を保ち、次の場所に保存します。

```text
~/Library/Containers/com.dream-jack.syphoncamera.probe/Data/Library/Application Support/SyphonZeroCopyCamera/
```

`producer-status.json` の `sourceKind` / `sourceServer` / `sourceTransformPasses` と
出力寸法を確認すると、WMC 入力・変換回数・解像度を識別できます。
`freshRenderedFrames`（既存の `renderedFrames` と同じ）は新たに行った GPU 変換数で、
異なる入力画像の数ではありません。`repeatedOutputFrames` は texture が一時的に取得できず
完成済み画像を再送した数、`totalOutputFrames` は両者の合計です。
GPU 時間・`sourceTransformPasses` は GPU 変換だけを数えます。
`noNewFrameTicks` は `hasNewFrame` が false だった参考値で、GPU 変換を省略した数ではありません。
`samplingMode` は `latest-texture-every-admitted-tick` です。

## 機能検証の記録

実 WMC → 自作カメラ → device-native AVFoundation 受信の確認結果:

| 出力 | 受信フレーム | 保持中の画像検査 | 画像変化 | 形式不一致 |
| --- | ---: | ---: | ---: | ---: |
| 1280×720 / 30 fps | 358 | 268 | 0 | 0 |
| 1920×1080 / 30 fps | 240 | 180 | 0 | 0 |

検証用受信側で pixel hash を調べ、保持した最終バッファの画像が変わらないことを確認しました。
この CPU readback は検証用で、通常の送信経路には含みません。720p のキャプチャ画像では、
上下が正しい WMC アバターを確認しています。この結果は Meet のネットワーク送信量や負荷削減を証明しません。

ローカル証跡（`build/` 配下は Git 管理外）:

- `build/meet-30fps-20261027/wmc-720p-capture.json`
- `build/meet-30fps-20261027/wmc-1080p-capture.json`
- `build/meet-30fps-20261027/wmc-720p.png`
- `build/meet-30fps-20261027/measured-build.json` — 測定対象のソース・Host binary hash、拡張 build 4 の状態
- `build/resolution-renderer-20261027/sandbox-check.json` — Host の Sandbox policy 検査
- `build/resolution-renderer-20261027/check-1080p.json` / `check-720p.json` — 診断 renderer の全画素一致、pool 上限・復帰確認
- `build/resolution-renderer-20261027/sampling-cadence-check.json` — 毎 tick の GPU 変換、120 tick の出力、保持した画像の不変性

Host build 5 では、`hasNewFrame` が false の tick に完成済み画像を再送する実験も行いました。
`cadence-check.json` はその再送の安全性を確認した記録です。しかし、1080p / 720p で GPU 変換を省略する
割合が異なり、解像度だけの比較にならないため、build 6 で毎 tick の最新画像取得に変更しました。
build 5 の測定を現在の解像度比較の結果として扱いません。

## 負荷・実送信の比較

Host build 6 で、GPU 変換と送出をどちらも約 30 fps に揃えた 4 回の比較を行いました。
CPU 低下は確認できず、Host の GPU 変換時間は約 21.8%、physical footprint は約 8.22 MiB 減りました。
条件・制限・Meet の実送信の確認状況は [比較記録](NATIVE_CAMERA_MEET_PERFORMANCE.md) を参照してください。
720p の出力画素数は 1080p の約 44% ですが、CPU やシステム全体の負荷が同じ割合で下がるとは限りません。
WMC 自身の撮影・認識・描画設定は、この出力解像度の変更では変わりません。

受信参加者がいる Meet 会議で測定しましたが、CPU 主比較と同時刻の RTP 証拠は
保存履歴に残りませんでした。別時刻の参考観測では 1080p 入力から 720p の実送受信を確認しました。
720p 入力条件の実送受信値と、2 条件のネットワーク負荷差は今回の証跡では確認できていません。
プレビュー表示だけを実送信の証拠にはしていません。
既存の [GPU コピーあり／なしの比較](NATIVE_ZERO_COPY_PERFORMANCE.md) は別の実験であり、
この 1080p / 720p 比較の結果として流用しません。
