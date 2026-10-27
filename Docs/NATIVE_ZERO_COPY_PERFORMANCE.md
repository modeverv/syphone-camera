# ゼロコピーの性能比較 — 2026-10-27

**GPU の描画・コピー時間と送信アプリのメモリ負担は減った。CPU 全体の差は小さい。**
同じ native カメラ経路で、GPU コピーを1回行う場合と、最終 IOSurface に直接描画する
場合を比較した。配布版 WMC / UniCamEx / Meet の変更前後比較ではない。

## 実測結果

1920×1080 BGRA / 30 fps。各方式4回、計8回の平均。
CPU の100%は1コアを使い切る値で、全コア合計に対する割合ではない。

| 項目 | GPUコピー1回 | ゼロコピー | 差 |
| --- | ---: | ---: | --- |
| 送信アプリ CPU | 4.533% | 4.253% | −0.280ポイント、約6.2%減 |
| カメラ拡張 CPU | 5.055% | 5.117% | +0.062ポイント |
| 受信アプリ CPU | 2.698% | 2.716% | +0.018ポイント |
| 上記3プロセスの CPU 合計 | 12.286% | 12.085% | −0.200ポイント、差は小さい |
| GPU command 実行時間 / frame | 0.1202 ms | 0.0531 ms | −0.0671 ms、約55.8%短縮 |
| 送信アプリ physical footprint | 198.419 MiB | 190.247 MiB | −8.172 MiB |
| 送信 fps | 29.9993 | 29.9992 | 同等 |
| 受信 fps | 29.9970 | 30.0009 | 同等 |

CPU 合計の試行範囲はコピーあり11.881〜12.833%、ゼロコピー11.783〜12.389%。
隣接試行の差は −0.508〜+0.622ポイントと符号も変わったため、CPU 全体の明確な
改善とは判断しない。送信アプリ単体の CPU は4組すべてでゼロコピー側が低かった
（0.090〜0.417ポイント減）。各1秒・5秒のサンプルを独立した反復として扱う統計的な
有意差の主張はしていない。

GPU 時間はゼロコピー0.0530〜0.0533 ms、コピーあり0.1156〜0.1316 msで、
4組すべてで短縮した。ただしこれは**元画像の描画と任意のコピーを含む command の
実行時間**であり、GPU全体の使用率が56%下がったという意味ではない。
CPU側で待機を含めて測った render 処理時間は0.8730→0.8444 msで、ばらつきが重なる。

メモリ値は macOS が送信アプリに計上した physical footprint の各試行中央値を平均した。
コピー側だけが持つ scratch surface 1枚は8,294,400 bytes。
観測した差は7.813〜8.391 MiBだった。共有 IOSurface を複数プロセスの RSS として
足し上げた値ではなく、マシン全体の実メモリ削減量とも区別する。
RSS 単体では安定した減少が見えないため、RSS の変化を改善の根拠にはしていない。

## 比較条件

- Apple M4 Max、macOS 27.0.1 / 26A434、Xcode 26.6 / 17F113、SIP有効。
- 同じ Release バイナリ（build 3）、同じ Camera Extension、同じ AVFoundation consumer。
- 通常側は最終 IOSurface に直接描画。比較側は同形式の IOSurface に同じ画像を描画し、
  最終出力に blit を1回行う。row stride と Metal storage mode の一致も検査する。
- 各回、新しい送信・受信プロセスを起動。双方の接続後8秒 warm-up、続く40秒を測定。
  順番は「コピー、ゼロ、ゼロ、コピー、ゼロ、コピー、コピー、ゼロ」。
- CPU は累積 user+system 時間の差。拡張など権限で直接読めないプロセスは
  `ps TIME` の累積値を使う（10 ms分解能）。`ps %CPU` の平滑値は使わない。
- メモリ等の採取間隔は5秒。計測器自身の CPU は1.136〜1.337%で、対象3プロセスの
  CPU 合計に含めず、観測負荷として別記した。
- 受信側の画素ハッシュ、stamp 検査、PNG、保持試験を無効化。
  送信側のフレームごとの trace を止め、累積値のみ記録。
  CPU 測定終了後まで受信を継続し、最終JSON保存・終了処理を計測区間から外す。
- GPU 時間は warm-up 後の累積 command 時間差 / フレーム数。
  producer は状態を1秒ごとに保存するため、この区間とCPU採取区間には1秒程度のずれがある。
- 8試行すべて送受信29.5〜30.5fpsの判定を通過。受信欠落、queue/pool不足、拡張拒否、
  拡張の consume error 増加は0。各測定の開始・終了時の thermal state は nominal。

WMCはバックグラウンドで動作したまま別計測した（CPU45.548〜49.033%）。
それと `cameracaptured`、観測ツールの値は比較対象3プロセスに足していない。
他のアプリを停止した無負荷環境ではない。消費電力は測定していない。

受信callback時刻−PTSの参考値も保存しているが、PTSはGPU完了後に発行されるため
描画・コピー時間を含まない。全経路の遅延改善の証拠としては扱わない。

## 測定中に修正した背景実行の問題

最初のシリーズではコピー側が起動約30秒後から約130 msの送信間隔を繰り返し、
約27fpsへ低下した。描画時間は短くqueue/pool不足もなかったが、この低CPUを
効率改善とは解釈できないため、4回完了・5回目途中でシリーズを中止した。

送信中だけ `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` を保持し、
停止時に解放する実装を追加した。その後、全8回を新しく測り直した。
修正後は両方式とも約30fpsを維持した。App Napによるタイマー抑制と整合する現象だが、
OS内部の原因を直接証明したという扱いにはしていない。
失敗シリーズは削除せず、最終集計へ混ぜずに保存している。

## 再現・証跡

[再現ツールと測定方法](../Tools/ZeroCopyBenchmark/README.md)を参照。
両方式の事前カメラ検査で各191フレームの surface / PTS / stamp 一致を確認した。
独立した renderer 検査では4種類の連番で全画素が一致した。

```sh
python3 Tools/ZeroCopyBenchmark/run-comparison.py --copy-first \
  --warmup 8 --duration 40 --output build/my-comparison
python3 Tools/ZeroCopyBenchmark/analyze.py build/my-comparison
```

このMacの全試行・生データ・集計:

```text
build/zero-copy-benchmark-20261027/comparison-activity/
```

`analysis.json`、`analysis.md`、各試行の `processes.json/csv`、
`producer-before/after.json`、`extension-before/after.json`、`capture.json` を保存。
失敗シリーズは隣の `comparison/`、使用ビルドの SHA-256 は `measured-build.json`。
Git 管理対象にも [全8試行の集計・証跡ハッシュ](evidence/native-zero-copy-performance-2026-10-27.json)
を保存した。
