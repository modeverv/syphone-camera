# WMC → Camera Extension → Google Meet の 30 fps 比較

2026-10-27。Host build 6 / Camera Extension build 4 の開発署名版。

**720p 化による CPU 負荷の低下は確認できなかった。** 一方、Host 内の GPU 変換時間は
約 21.8% 短くなり、Host の physical footprint は約 8.22 MiB 減った。
GPU の数値は画像変換コマンドの実行時間であり、Mac 全体の GPU 使用率ではない。
通常利用の既定は **1080p / 30 fps**、720p / 30 fps は任意の選択肢とする。

## 実装と比較条件

配布版 WMC の 1920×1080 Syphon texture を、30 Hz ごとに取得する。
GPU の 1 回の処理で上下反転と必要な縮小を行い、自前の最終 CVPixelBuffer に書き込む。
Camera Extension は同じ CMSampleBuffer を転送する。
WMC 入力を含む完全なゼロコピーではなく、通常経路の CPU 画像コピーは 0、GPU 変換は 1 回/出力である。
詳細と操作方法は [30 fps 対応記録](NATIVE_CAMERA_30FPS.md) を参照。

- Apple M4 Max、16 logical CPUs、macOS 27.0.1、Chrome 155.0.8059.85。
- 同じ WMC、同じ Meet 会議、同じ Mac 上の送信タブと受信タブを使用。
- 両参加者のマイクはオフ、受信側のカメラはオフ。受信側で送信者を大きく固定表示。
- Meet の送信・受信解像度の上限は 1080p に統一。カメラ入力だけを 1080p / 720p に変更。
- 1080p → 720p → 720p → 1080p の順で、各 40 秒を測定。各条件 2 回。
- 5 秒間隔で累積 CPU 時間を採取。Mac 全体は `host_statistics(HOST_CPU_LOAD_INFO)` の tick 差分。
- Host、Extension、WMC、Meet の 2 renderer、Chrome の main / GPU / network / storage /
  audio / capture サービス、cameracaptured を測定。

## CPU・GPU・メモリ

条件ごとの 2 回の平均。プロセス CPU は **1 コアを使い切る状態が 100%**。
Mac 全体の CPU は **全コア合計を 100%** とする別の尺度。

| 指標 | 1080p 入力 | 720p 入力 | 判断 |
| --- | ---: | ---: | --- |
| Host CPU | 5.05% | 5.10% | 低下を確認せず |
| 指定プロセスの CPU 合計（WMC 込み） | 117.10% | 118.31% | 低下を確認せず |
| Mac 全体の CPU | 26.53% | 26.92% | 低下を確認せず |
| Host GPU 変換時間 / 画像 | 0.06440 ms | 0.05033 ms | 約 21.8% 減 |
| Host physical footprint | 210.88 MiB | 202.66 MiB | 約 8.22 MiB 減 |

GPU 変換時間の削減は 2 組とも確認した（差 0.01384 / 0.01430 ms/画像）。
Host physical footprint も 2 組とも小さかった（差 7.58 / 8.86 MiB）。
RSS や共有バッファの単純合計をメモリ削減量には使用していない。
physical footprint は各測定窓内の中央値を取り、解像度ごとに 2 回分を平均した。
GPU の累積時間は Host の status snapshot 間で計算しており、CPU の測定境界とは
status 更新間隔の約 1 秒分ずれることがある。

全 4 回で画像取り込み・GPU 変換・送出が約 30 fps、キャッシュ画像の再送 0、
queue / pool 不足 0、拡張の拒否・consume error 0。8 枚の surface 上限を維持した。
GPU 変換回数は、WMC が独立した新しい画像を生成した回数を測ったものではない。

N=2 の観測であり、統計的有意差や解像度だけによる因果を示す実験ではない。
Chrome の共有サービスは他のタブでも使われ、Mac 全体には他のアプリの処理が含まれる。
同じ Mac 上で受信も行っているため、指定プロセスの合計を送信側だけの CPU と呼ばない。
CPU が少し高くなった値も、720p が原因で悪化したと断定するものではない。
消費電力・システム全体の GPU 使用率・全体メモリ削減は測定していない。

## Meet の実送信

**CPU 主比較 4 窓と同時刻の RTP 証拠は得られなかった。720p 入力条件の実送受信値も未確認。**
RTP の履歴には 1 系列あたり約 1000 点の保持上限があり、保存済み dump では
主比較の時間帯が失われていた。別途 08:27 / 08:29 UTC に各 30 秒測定した
補足 CPU 窓についても、対応する RTP dump は今回の証跡に含まれていない。
HTML video の寸法と再生時刻だけではネットワーク fps を確定しない。

一方、同じ Host build 6 の **08:24 UTC の非同期参考観測**では、
Chrome への 1080p 入力と、Meet の 720p 実送受信を確認できた。
送信は `framesSent` と `bytesSent`、受信は `framesDecoded` と `bytesReceived` の
増分で検証した。これは上記 CPU 主比較や補足 CPU 窓と同じ時刻の測定ではない。

| 08:24 UTC の参考観測 | 確認値 |
| --- | ---: |
| Chrome のカメラ入力 | 1920×1080、29.982 fps |
| Meet の送信エンコード | 1280×720、29.982 fps |
| 相手側の受信デコード | 1280×720、29.984 fps |
| 送信 / 受信の映像 payload bitrate | 0.913 / 0.913 Mbps |
| Codec / encoder | VP9 / libvpx |
| 受信側の `framesDropped` 増分 | 0 |
| 送信側の `qualityLimitationReason` | 全 59 点で `none` |

送信窓は 08:24:00.367426〜08:24:58.368569 UTC、
受信窓は 08:24:00.372734〜08:24:58.403501 UTC。
bitrate は RTP payload のカウンターから求めた値で、IP/UDP ヘッダーや音声を含む
ネットワーク全体の通信量ではない。`none` という記録だけから、720p となった理由を
アカウント制限・帯域・CPU のいずれかに特定しない。

**1080p の実送信、および 1080p / 720p 入力のネットワーク負荷差は、この証跡では未確認。**
公開 JSON は主比較の `actualNetworkSendingVerified: false` を維持し、
上記参考値と未確認の 720p 条件を `networkSupplement` に分けて記録した。

## 除外した測定

- 最初の Chrome 全体測定は、他の renderer の終了で PID 一覧が変わったため全体合計を無効とした。
- 初期の WMC 入力は新フレーム通知を待つ tick で欠落し、29.5〜29.8 fps になったため除外。
- Host build 5 のキャッシュ再送方式は出力 30 fps でも GPU 変換回数が条件間で異なり、除外。
  最終 Host build 6 は通知フラグにかかわらず、採用 tick ごとに最新 texture を取り込み、
  両条件で GPU 変換回数も約 30 回/秒に揃えた。
- 履歴期限を過ぎた RTP 窓を、送信失敗や送信成功のどちらにも推測で分類していない。

## 証跡と再現

[公開用の集計データ](evidence/native-camera-meet-30fps-2026-10-27.json) に、環境・測定版の hash・
CPU 主比較の各窓と条件平均を保存した。

ローカルの `build/meet-30fps-20261027/` に以下を保存した。

- `fixed-01-1080p/`、`fixed-02-720p/`、`fixed-03-720p/`、`fixed-04-1080p/`：CPU 主比較の生データ。
- `cpu-fixed-comparison.json` / `.md`：平均・範囲・組ごとの差、固定処理量の検査。
- `measured-fixed-sampling-build.json`：測定 binary / source hash、署名版の構成。
- `receiver-fixed-dom.json`：受信側で実際に再生された動画の寸法と時刻。
- `network-check-1080p/`、`network-check-720p/`：各 30 秒の補足 CPU 窓。RTP は未照合。
- `network-final-latest-observation.json`：08:24 UTC の非同期ネットワーク参考値。
- 生の WebRTC dump：Git 管理外。公開用の要約に IP・会議 URL・デバイス ID を含めない。

[測定ツールと手順](../Tools/MeetBenchmark/README.md) を参照。
旧 [GPU コピーあり／なしの比較](NATIVE_ZERO_COPY_PERFORMANCE.md) は別の実験であり、
今回の解像度比較へ数値を流用していない。
