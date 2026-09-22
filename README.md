# Airlift Browser

USB接続したiPad / iPhoneをDVT / CoreDevice / AFCで階層表示・操作するSwiftUI製macOSアプリ。
macOS 14以降。ビルドにはXcode / Swift 6、端末全体のDVT列挙には`pymobiledevice3`が必要です。

## 起動

```sh
git submodule update --init --recursive
make        # .app生成 (dist/Airlift Browser.app)
make open   # ビルドしてアプリを起動
```

`Package.swift` をXcodeで開いてソースを編集できます。ヘルパーの同梱と署名を含む
実行用アプリは上記スクリプトで作成してください。ローカル用アドホック署名です。
配布用のDeveloper ID署名・公証は含みません。

## 操作

- iPad / iPhoneをUSB接続し、ロック解除してこのMacを信頼する。
- サイドバーでデバイスを選択。未検出なら「USB端末を再検索」。
- ダブルクリック / 「開く」でフォルダ移動。パス欄はMediaを `/` としたパス。
- ツールバーから更新、フォルダ作成、単一ファイル送信、Macに保存。
- 右クリックから名前変更・削除。削除は確認付きで、空のフォルダのみ対象。
- 検索は現在のフォルダ内の名前を絞り込みます。
- 「端末ファイル」はDVTが公開する実項目をFinder風の階層として表示します。
  パス欄に絶対パスを貼り付けて Return または「移動」で、その場所を一覧に表示します。
  ファイルパスの場合は親フォルダを開き、その項目を選択します。ダブルクリック、戻る・進む・上へでも移動できます。
- `Containers/Data/Application`はDVTの全実コンテナ、`Containers/Shared/AppGroup`は
  CoreDeviceで参照可能な実コンテナを列挙し、各コンテナ内も実項目を表示します。
- `/var/containers/Bundle/Application`はUUIDにアプリ名とBundle IDを併記し、
  UUID内の`.app`にも同じ情報を表示します。
- 端末ファイルの通常ファイルも「Macに保存」で抽出できます。AirTrafficでMediaへ一時回収し、
  AFC保存データを全バイト照合してから元パスへ戻します。
- 端末ファイル表示でも「送信」を使えます。入力元のファイル名のまま新規ファイルを書込み、
  Mediaへ回収して全バイトを照合した後、同じ場所へ戻してBooks同期状態を復元します。
- 端末ファイルで実表示された通常ファイルは、右クリックまたはツールバーの「削除」から
  AirTrafficでMediaへ回収して完全削除できます。ディレクトリ削除は対象外です。
- サイドバーの「AirTraffic PoCを実行…」では、Media外の絶対ディレクトリを指定し、
  canaryの新規書き込み・Mediaへの回収・完全一致・削除までをGUIから検証できます。
  端末ファイル表示中はツールバーの「このフォルダを検証」で現在地が自動入力されます。

## 範囲とデータ保護

- 端末ファイルはDVTが公開する`/`・`/var`・`/var/tmp`・Application/Bundleコンテナ等を
  動的列挙します。DVTが公開しない`/var/mobile/Library`等は既知の親階層だけ表示します。
- Mediaルートは通常 `/var/mobile/Media` に対応します。階層列挙のために既存項目を
  一時移動する処理は行いません。
- 同名項目は上書きしません。保存先に既存ファイルがある場合も別名が必要です。
- Media外への送信も入力元のファイル名を保持します。送信直前に実機一覧を再取得し、
  同名項目がある場合は上書きせず中止します。一覧を取得できないディレクトリへの送信も中止します。
- 転送は1ファイル128 MiBまで。送信はUUID一時ファイルへの書き込み後、
  実機から全バイトを読み戻して照合し、最後に名前を確定します。
- ダウンロード後もローカル保存データを照合します。フォルダ一括転送は未実装。
- 接続処理はUIスレッド外で実行。AFCのタイムアウトに加え、ヘルパーは120秒で終了。
  転送中の切断・強制終了では `.airlift-upload-*` が残る場合があります。
  再接続後に内容を確認し、不要な一時ファイルを削除してください。
- Finder等との同時書き込みは避けてください。AFCには排他的な最終rename保証がないため、
  上書き検査とrename間に別プロセスが同名ファイルを作る競合は防げません。
- MobileDeviceはmacOSの非公開フレームワークのため、将来のOS更新で互換性が変わり得ます。

## 元プロジェクトとの関係

[0xjohnnydev/airlift](https://github.com/0xjohnnydev/airlift) を `airlift/` に
submoduleとしてcloneし、コミット `c684cd41ca0ded2d1ab780c15f6ead05509ce062` に固定。
`Sources/BrowserBridge/main.m` は元の `device_helper.m` をincludeして、ペアリング・
AFC接続・読み書きの関数を再利用しています。元ソースは変更していません。
上流MITライセンスはアプリにも同梱します。

上流はAirTrafficによる既知パスへの書き込みと、一時移動による読み戻しを検証するPoCです。
一般的なルートディレクトリ一覧APIではありません。GUIの「AirTraffic PoCを実行…」は
上流と同じ処理を実行し、通常のファイル画面だけAFCを使います。iPad対応は上流の
iPhone限定チェックをローカルビルド時にiPadへ広げたもので、実機結果を下記に記録します。

## 最小の実機テスト

```sh
python3 Scripts/smoke.py
# 別のUSBデバイスを指定する場合:
python3 Scripts/smoke.py DEVICE_UDID
```

デフォルトはUSB接続中のiPad Air M2（iPad14,8）。生成したUUIDフォルダ内だけで
作成・送信・リネーム・取得・完全一致照合・削除を行います。
日本語ファイル名、不正パス、リモート/ローカル上書き拒否、非空フォルダ削除拒否も
この1本のスモークチェックに含めています。テストフレームワークは追加していません。

2026-09-21実行結果: iPad Air M2 / iPadOS 27.0 / USB、262,176バイト往復一致、
生成ファイル・フォルダの削除後の不在まで確認。GUIでも端末検出・一覧・フォルダ作成・
ダブルクリックでの移動・親フォルダへの復帰を確認。
詳細JSONはビルド成果物と同じ `dist/smoke-result.json` に保存しています。

AirTraffic PoCも同じ実機の `/var/tmp` に対して実行し、新規85バイトcanaryの書込み、
Media経由の完全一致回収、対象canaryと一時データの削除、既存Books同期4項目の復元を確認。
GUIからの再実行でも「読み戻し: 完全一致」「後片付け: 完了」を確認しています。
詳細JSONは `dist/poc-ipad-result.json` です。

階層UIは `/var → mobile → Library` のダブルクリック移動、戻る・進む・上へ、
現在地 `/var/mobile` のPoC画面への自動入力を確認。同画面から実機検証を実行し、
85バイトcanaryの完全一致と後片付け完了も確認しています。

実コンテナ列挙ではiPad Air M2から314個のApplicationコンテナと28個のApp Groupを取得し、
コンテナ内の`Documents`・`Library`・`tmp`を実表示しました。Media外書込みは`/var/tmp`へ
32バイトのローカルファイルをGUIから送り、回収時の完全一致、最終配置、後片付け完了を確認。

DVT列挙では`/var/tmp`の589項目を実取得し、ディレクトリ581件を実機照会で判定しました。

Bundle一覧ではOmnaraを`com.omnara.app`として表示し、`SerializedPlaceholder.ipa`を
1,130,719バイト抽出・完全一致照合後に元パスへ復元、一時データ不在まで確認しました。
