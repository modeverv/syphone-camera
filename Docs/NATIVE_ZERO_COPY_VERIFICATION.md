# Native zero-copy verification — 2026-10-27

会社チームで署名・有効化した自作 Camera Extension に対し、最終 IOSurface に
直接描画する Metal producer から AVFoundation consumer まで、画像ストレージを
共有できることを実機で確認した。**配布版 WMC をこの経路に接続できたという結果ではない。**

対象は macOS 27.0.1 / 26A434、Xcode 26.6 / 17F113、SIP 有効、
1920×1080 BGRA / 30 fps。インストール先は
`/Applications/SyphonCameraExtensionProbe.app`、カメラ名は `Syphon Zero Copy Camera`。

## 結果

| 試験 | 受信フレーム | 同一 IOSurface + 厳密 PTS + 画像内連番 | 1秒保持の検査回数 | 保持中の変更 |
| --- | ---: | ---: | ---: | ---: |
| 約60秒の連続受信 | 1,815 | 1,815 / 1,815 | 165 | 0 |
| 約55秒中に送信停止・再開を2回 | 1,389 | 1,389 / 1,389 | 129 | 0 |
| 上記と同時に別プロセスで受信 | 252 | 252 / 252 | 24 | 0 |

全試験で未照合、連番不一致、IOSurface 不在、画素読み取りエラーは0。
検証アプリが報告した dropped frame は0。停止・再開試験の停止区間と、
producer が空きバッファ待ちで意図的に生成しなかった画像はこの dropped frame 数に含まれない。
同時受信中に pool の空き不足を1回検出し、コピーや使用中画像の上書きをせず1 tick を見送った。

停止・再開の前後で8個の surface ID 集合が同一だった。2回の
`CMIODeviceStopStream` はともに `noErr`。先に短時間の受信プロセスが終了した後も、
長時間の受信プロセスは送信再開後の画像を受け取った。
拡張が保持する直近128フレームの記録についても、連続試験と再開試験それぞれで
producer / extension / consumer の ID と PTS が128件すべて一致した。

連続試験後に pool の停止・再開間共有と停止結果の記録を追加した。
再開試験・同時受信試験は、その最終インストール済みビルドで実施した。
ソースと実行ファイルの SHA-256、集計、元証跡のパスと SHA-256 は
[機械可読の検証記録](evidence/native-zero-copy-2026-10-27.json)に保存した。

## 確認した境界

```text
Metal による元画像生成（最終 CVPixelBuffer / IOSurface に直接描画）
  -> CMSampleBuffer のメタデータ包装
  -> CMIO sink
  -> Camera Extension が受け取った同一 sample を source に送信
  -> AVFoundation device-native consumer
```

転送側には画像の CPU readback、memcpy、GPU blit、上下反転、形式変換を置かない。
CVPixelBufferPool と CMIO の共有寿命管理で、consumer が保持中の画像を再利用しない。
pool 上限は同一ホストプロセスで8枚。画素以外の sample wrapper、キュー、ログ等の
メタデータ割り当てまでゼロにする実装ではない。

consumer は `videoSettings = [:]` で device-native sample を要求する。
画像のハッシュ・連番確認・PNG 出力は検証 consumer 内だけで行う。
その診断用 readback を実際のカメラ転送処理には組み込んでいない。
受信画像の PNG を開き、グラデーションと移動する白線の描画も確認した。

他の consumer が行う BGRA → YUV 変換などは、この確認範囲に含まれない。
WMC の配布版は format 0 の単一 surface を更新し続け、retained texture でも
内容が変わるため、直接入力を許可していない。
[WMC の診断](../Tools/ZeroCopyDiagnostics/README.md)と
[実装・操作手順](../NativeCamera/README.md)を参照。

## 証跡と再照合

この Mac の `build/native-zero-copy-20261027/` に元データを保存している
（`build/` は Git の管理対象外）。主なファイル:

- `capture-sustained-verified.json` と `sustained2-source-trace.jsonl`
- `capture-restart-verified.json` と `restart-combined-source-trace.jsonl`
- `capture-second-consumer-verified.json`
- `sustained2-extension-telemetry.json` と `restart-final-extension-telemetry.json`
- `native-camera-frame.png`、`build.log`、`final-extension-state.json`

例えば連続試験は次で元の受信記録から再判定できる。

```sh
python3 Tools/ZeroCopyVerification/recheck-report.py \
  --recheck-report build/native-zero-copy-20261027/capture-sustained-raw2.json \
  --source-trace build/native-zero-copy-20261027/sustained2-source-trace.jsonl \
  --report build/native-zero-copy-20261027/rechecked-again.json
```

再照合は有理数として完全一致する PTS を使い、近似・許容誤差を設けない。
時刻だけ、surface ID だけの一致では合格にしない。受信・再照合ツールの自己テストは
異なる ID、丸めで近いだけの PTS、不正な連番、保持中の変更を検出することも確認済み。

## 修正した問題と終了時の状態

初回の353フレーム試験では画像と保持検査は成功したが、受信アプリから別アプリの
container の trace を読めず、厳密照合は未成立だった。以後は trace を証跡ディレクトリに
コピーしてオフライン照合する。CMIO が受信時刻を10 µs単位に正規化するため、
producer 側でその単位に表現可能な時刻を発行するようにした。

途中の0フレーム試験は、再起動時に window の `onAppear` が呼ばれず
producer が開始していなかったことによる。起動引数処理を app delegate に移し、
状態ファイルに記録時刻と running を追加して修正した。古い失敗レポートも保存している。

以前のホスト強制終了時に記録された consume error `OSStatus -7` が累積1件残る。
成功した連続・再開試験中にこの件数は増えず、拒否フレームは0だった。
この履歴を隠して「全実行でエラー0」とは扱わない。

終了時には producer を停止し、拡張の直接照会で `sinkActive=false`、
`sourceClients=0`、`consumePending=false` を確認した。カメラ拡張自体は
`activated enabled` のまま。ホストの「GPUテスト映像を開始」で再開できる。
