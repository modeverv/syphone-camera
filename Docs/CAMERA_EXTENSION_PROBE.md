# 会社チームでの Camera Extension 開発検証

検証日: 2026-10-27（JST）

本書は初回の署名・有効化検証の記録。後続の実装と現在の動作は
[Native Camera の 30 fps 対応](NATIVE_CAMERA_30FPS.md)を参照。
同じ bundle ID の拡張は、その後 Native Camera 実装へ更新している。

## 検証範囲と結果

Dream Jack Inc. の会社チームを使い、既存の UniCamEx 経路とは独立した最小の Camera Extension を作成した。今回の検証は、利用者からの「会社チームで macOS プロファイルを用意し、最小の拡張を署名・有効化できるか確認する」という依頼に基づく。既存の UniCamEx を使う本体の実装方針は変更していない。

| 確認項目 | 結果 |
| --- | --- |
| 会社チームの開発証明書を使ったビルド | 成功 |
| System Extension インストール権限を含む macOS プロファイルの取得 | 成功 |
| ホストと拡張の署名検証 | 成功（同一 Team ID） |
| `/Applications` からの有効化要求 | 成功。利用者がシステム設定で承認 |
| macOS での有効化完了 | 成功。`COMPLETED` / `activated enabled` |
| AVFoundation からのカメラ列挙 | 成功。640×480 / BGRA / 30 fps |
| 映像取得・表示 | 今回は未実施 |
| 完全ゼロコピー | 今回の検証対象外 |

## 環境

- macOS: 27.0.1 / 26A434
- Xcode: 26.6 / 17F113
- Team: Dream Jack Inc. / `85LT3DSJ3L`
- 開発署名: 会社チームの Apple Development 証明書
- SIP: enabled。今回の検証でセキュリティ設定は緩和していない。

## 検証用アプリ

- プロジェクト: [`Tools/CameraExtensionProbe`](../Tools/CameraExtensionProbe/README.md)
- インストール先: `/Applications/SyphonCameraExtensionProbe.app`
- ホスト ID: `com.dream-jack.syphoncamera.probe`
- 拡張 ID: `com.dream-jack.syphoncamera.probe.camera`
- App Group: `85LT3DSJ3L.com.dream-jack.syphoncamera.probe`
- カメラ名: `Dream Jack Camera Probe`
- 出力: 640×480 / 30 fps の動く白帯（Xcode 付属テンプレート由来）

このパターン生成は CPU 書き込みを使用する。Syphon の IOSurface 共有やゼロコピーの性能を検証する実装ではない。

## プロファイルと署名

Xcode の自動署名で以下の macOS プロファイルを取得した。

- Name: `Mac Team Provisioning Profile: com.dream-jack.syphoncamera.probe`
- Team: Dream Jack Inc. / `85LT3DSJ3L`
- Platform: `OSX`
- 発行: 2026-10-27 04:24:48 UTC
- 期限: 2027-10-27 04:24:48 UTC
- 登録デバイス: 1
- `com.apple.developer.system-extension.install`: `true`

ホストと拡張の両方が会社チームの証明書で署名され、個別および配置後の `codesign --verify --deep --strict` が成功した。拡張の `CMIOExtensionMachServiceName` は `85LT3DSJ3L.com.dream-jack.syphoncamera.probe.camera` に展開された。

今回の Xcode 自動署名では、上記プロファイルはホストに埋め込まれた。拡張は sandbox と共通 App Group の entitlement を持ち、別の embedded provisioning profile は生成されていない。拡張用プロファイルも別に取得したという意味ではない。

## 実行記録

署名ビルド:

```sh
xcodebuild \
  -project Tools/CameraExtensionProbe/CameraExtensionProbe.xcodeproj \
  -scheme CameraExtensionProbe -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/camera-extension-probe-20261027/DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -hideShellScriptEnvironment build
```

13:26:07 JST、`/Applications` のホストから有効化要求を送った。delegate は `NEEDS_USER_APPROVAL` を記録し、`systemextensionsctl list` に以下の行が追加された。

```text
    * 85LT3DSJ3L com.dream-jack.syphoncamera.probe.camera (1.0/1) Dream Jack Camera Probe [activated waiting for user]
```

システム設定の「ログイン項目 → 機能拡張 → カメラ機能拡張」にも検証用アプリとオフ状態のスイッチが表示された。自動操作ツールでは承認用の子画面をフォーカスできなかったため、利用者がスイッチをオンにした。

13:28:45 JST、ホストの delegate が以下を記録した。

```text
REQUEST_FINISHED: COMPLETED, rawValue=0
```

その後、`systemextensionsctl list` の状態が以下に変わった。

```text
* * 85LT3DSJ3L com.dream-jack.syphoncamera.probe.camera (1.0/1) Dream Jack Camera Probe [activated enabled]
```

AVFoundation の読み取り専用 DiscoverySession でも `Dream Jack Camera Probe` が1台検出され、640×480 / BGRA / 30 fps の形式が取得できた。確認ツールは [`Verification/enumerate-camera.swift`](../Tools/CameraExtensionProbe/Verification/enumerate-camera.swift)。権限要求やキャプチャ開始は行っていないため、映像の取得・表示を確認したという意味ではない。

承認後も SIP は enabled。既存の UniCamEx・OBS・CameraGraph と3つの Driver Extension はすべて引き続き `activated enabled` だった。初回検証終了時はテスト用拡張を有効化状態で残した。今回、notarization や Developer ID による配布署名は実施していない。この結果は、この Mac での開発署名による有効化を実証したものであり、一般配布まで確認したものではない。

## 証跡

ローカルの詳細記録は git 管理対象外の `build/camera-extension-probe-20261027/` に保存している。
個人名を含む証明書名とプロファイル UUID は公開文書では省略し、ローカルの署名記録に保持する。

- `signed-build.log`: 会社チームでの署名ビルド記録（`BUILD SUCCEEDED`）
- `profile-summary.json`: プロファイルと署名済み entitlement の概要（秘密鍵や認証情報は含まない）
- `host-verify.txt`, `extension-verify.txt`, `installed-signature-verification.txt`: 署名検証
- `baseline-systemextensions.txt`, `baseline-security.txt`: 検証前の状態
- `activation.log`: 有効化完了までのホスト実行記録
- `after-approval-systemextensions.txt`, `after-approval-security.txt`: 承認後の有効化状態と SIP
- `camera-discovery.json`: AVFoundation による検証カメラの列挙結果

ホストの実行ログ:

```text
~/Library/Containers/com.dream-jack.syphoncamera.probe/Data/Library/Application Support/CameraExtensionProbe/activation.log
```

## この検証と後続実装の関係

会社チームで System Extension のインストール権限を含む macOS プロファイルを取得し、Camera Extension を署名し、SIP が有効なこの Mac で有効化してカメラとして列挙できることを実証できた。したがって「この環境は Personal Team だけなので自作拡張の署名・有効化に進めない」という前提は当てはまらない。

初回検証では映像転送やバッファ寿命までは確認していない。その後、直接描画した最終 IOSurface の
共有と保持中の不変性を[別の検証](NATIVE_ZERO_COPY_VERIFICATION.md)で確認した。
配布版 WMC の入力には[1 回の GPU 変換](NATIVE_CAMERA_30FPS.md)を使い、WMC 入力を含む完全ゼロコピーとは区別する。

## Apple の関連文書

- [Creating a camera extension with Core Media I/O](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
- [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)
