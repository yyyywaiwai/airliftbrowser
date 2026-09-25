# 開発者向けドキュメント

利用者向けの説明は [README.md](README.md) を参照してください。このファイルは、ビルド方法・テスト・実機検証の記録・内部構造をまとめます。

## 必要になるもの

| | 条件 |
| --- | --- |
| ビルド | macOS 14 以降、Xcode 15 以降（Command Line Tools ではなく Xcode 本体） |
| 実行 | iPhone / iPad（USB 接続、ロック解除、「この Mac を信頼」、開発者モード有効） |
| 実行 | `pymobiledevice3` が入った Python 3 |
| 通信 | USB のみ。`lockdown.create_using_usbmux` と `AMDeviceGetInterfaceType == 1` を使うため、Wi-Fi 経由の接続は対象外 |

`pymobiledevice3` は Homebrew の Python にインストールしてください。アプリが探すのは `/opt/homebrew/bin/python3` と `/usr/local/bin/python3` の2つだけです。pyenv、conda、venv、virtualenv の Python は検出されません。

```sh
brew install python
$(brew --prefix)/bin/python3 -m pip install pymobiledevice3
```

Swift 側はまず `/usr/bin/python3` で `Sources/AppManagement/manager.py` を起動し、その `ensure_python()` が上の 2 つのパスを順に調べて、`pymobiledevice3` を import できる Python で自分自身を起動し直します。DVT 一覧（`Browser.swift`）は同じ 2 つのパスを直接探します。

## ビルド

```sh
git submodule update --init --recursive
make        # dist/Airlift Browser.app を生成
make open   # ビルドして起動
make clean    # .build と dist を削除
make strings  # UI 文字列を Localization/Localizable.xcstrings に同期
```

`make` は `Scripts/build.sh` を実行します。Xcode プロジェクトは持たず、`Package.swift` を `swift build -c release` でビルドしてから `.app` を手作業で組み立てます。

### ビルドの内部で何をしているか

- **4 つのヘルパー**を `xcrun clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0` でコンパイルし、`Contents/Helpers/` に入れます。

  | 出力 | ソース | 使うフレームワーク |
  | --- | --- | --- |
  | `browser_bridge` | `Sources/BrowserBridge/main.m` | `MobileDevice.framework` |
  | `poc_device_helper` | `airlift/Sources/device_helper.m` | `MobileDevice.framework` |
  | `airtraffic_host` | `airlift/Sources/airtraffic_host.m` | `AirTrafficHost.framework` |
  | `mask_image` | `Sources/PoC/mask_image.m` | AppKit / ImageIO / CoreGraphics |

  `AirTrafficHost.framework` と `ATHostConnection*` シンボル群は `/System/Library/PrivateFrameworks/` 以下の非公開フレームワークで、公開 API には相当品がありません。

  > [!IMPORTANT]
  > ビルドする Mac と、端末をつなぐ Mac は同じである必要があります。別の Mac へ `.app` をコピーして動かすことはできません。

- **ソースパッチ**はビルド時にコピーへ当てるので、submodule 自体は書き換えません。

  - `device_helper.m`: `TargetGate` の iPhone 限定チェックを iPhone **または** iPad に広げます。iPad 対応は上流ではなくローカルパッチです。
  - `airtraffic_host.m`: `argc < 6` を `argc < 4` に、`pairCount > 4` を `> 6` に変更し、引数 1 組でも動くようにします。
  - `airtraffic_host.m` には `AIRLIFT_STEP` 環境変数のモードも追加します。資産ごとに stderr へ `AIRLIFT_STEP <n>` を出して stdin の 1 バイトを待つので、AirTraffic の同期が開いている間に呼び出し側が作業できます。`Sources/PoC/list_cards.py` の `run_steps` と `edit_card.py` の `exchange_file` がこれを前提にしています。パッチ箇所が見つからなければスクリプトが即座に失敗するので、上流を更新して合わなくなった場合はビルドがはっきり壊れます。

- **Python スクリプト**を `Contents/Resources/` 配下にコピーします（`AirliftPoC/`、`DeviceFiles/`、`AppManagement/`）。`airlift_target.h` は import 時に読まれるので、この配置が前提です。

- **アイコンと文字列**は `xcrun actool` で `AirliftBrowser.icon` から `.icns` と `Assets.car` を作り、`xcrun xcstringstool compile` で `Localizable.xcstrings` をコンパイルします。

- `Info.plist` はスクリプトが直接書き出します。Bundle ID は `local.airlift.browser`、開発言語は `ja` で、`.airliftbackup` の UTType 宣言を含みます。ほかの言語は英語（`en`）と簡体字中国語（`zh-Hans`）です。

### コード署名

アドホック署名だけです。`codesign --force --sign -` を各バイナリに個別に当ててからアプリ本体に当て、`codesign --verify --strict` で確認します。

> [!IMPORTANT]
> Developer ID 署名と Apple の公証（notarization）は含みません。配布用のビルドには別の署名手順が要ります。

## テスト

### ローカル（実機不要）

```sh
python3 -B Scripts/test_app_management.py

# 旧上限（4 GB）を超える単一ファイルのストリーミング
AIRLIFT_TEST_BYTES=10737418257 python3 -B Scripts/test_app_management.py \
  Acceptance.test_streaming_exceeds_old_limit_without_large_buffers
```

形式の往復、編集履歴、上書き／置換、選択項目の取り出し、切断を模した失敗・中止時のロールバックを検証します。10 GiB 超のストリーミング往復も通っています。

Swift 側のテストは `Tests/AirliftBrowserTests/` にあり、`swift test` で実行します。ファイル一覧のキャッシュ（`AppFileIndexTests`）、複数選択の一括操作（`AppFileBatchActionTests`）、Finder へのドラッグと進捗（`AppFinderExportProgressTests`、`FinderPromiseProviderTests`、`FinderDragMonitorTests`）を扱います。

### 実機

```sh
# アプリ管理。アプリの tmp に新規ファイルを作り、往復照合・削除する（BYTES でサイズ指定）
python3 -B Scripts/smoke_app_containers.py DEVICE_UDID BUNDLE_ID [BYTES]

# 全領域のメタデータ列挙。本文読み取り 0 回・子階層一致・後片付けを確認
python3 -B Scripts/smoke_app_listing.py DEVICE_UDID BUNDLE_ID

# 取得した一覧で、フォルダ移動がヘルパー呼び出し 0 回になることを再利用テストで確認
AIRLIFT_LISTING_FIXTURE="$PWD/dist/listing-smoke-0.json" swift test \
  --filter AppFileIndexTests.liveDeviceMetadataNavigatesWithoutHelper

# 選択したファイル／フォルダの書き出しで本体全体をコピーしないことを確認
python3 -B Scripts/smoke_app_export.py DEVICE_UDID
```

上流のスモーク（AirTraffic PoC と階層 UI）は次のとおりです。

```sh
python3 Scripts/smoke.py
python3 Scripts/smoke.py DEVICE_UDID   # 別の USB デバイスを指定する場合
```

引数を省くと、USB 接続中の iPad Air M2（iPad14,8）を使います。作成した UUID 名のフォルダの中だけで、作成・送信・名前の変更・取得・完全一致の照合・削除を行います。日本語ファイル名、不正なパス、リモート／ローカルの上書き拒否、空でないフォルダの削除拒否もこの 1 本で確かめます。結果は標準出力に出るだけで、ファイルには残りません。

### 実機検証の記録

**2026-09-21** — iPad Air M2 / iPadOS 27.0 / USB。262,176 バイトの往復一致、生成ファイル・フォルダの削除後の不在まで確認。GUI でも端末検出・一覧・フォルダ作成・ダブルクリックでの移動・親フォルダへの復帰を確認。AirTraffic PoC も `/var/tmp` に対して新規 85 バイト canary の書き込み、Media 経由の完全一致回収、対象 canary と一時データの削除、既存 Books 同期 4 項目の復元を確認。実コンテナ列挙では 314 個の Application コンテナと 28 個の App Group を取得し、`Documents`・`Library`・`tmp` を実表示しました。DVT 列挙では `/var/tmp` の 589 項目を取得し、ディレクトリ 581 件を実機照会で判定しました。Bundle 一覧では Omnara を `com.omnara.app` として表示し、`SerializedPlaceholder.ipa` を 1,130,719 バイト抽出・完全一致照合後に元パスへ復元しました。

**2026-09-23** — iPhone 15 / iOS 27.2 / MioWidget 1.2.1。データ・App Group・本体の 25,550,599 バイトのバックアップ、データ・App Group の完全置換リストアと内容照合を確認。135,266,321 バイトの実機往復一致、テスト項目の削除、未完了操作 0 件も確認しました。詳細は `dist/app-container-smoke.json` です。

**2026-09-24** — iPhone 15 / iOS 27.2 / iMons 2.1.03。2,547,400,653 バイトの全領域バックアップとデータ・App Group の完全置換リストアを確認しました。復元後の再バックアップは、データ・App Group・本体の全ファイルの内容が復元前と一致。変更前 127 秒、変更後 124 秒、リストア 222 秒でした。転送処理の変更に加え、リストアでは端末の全内容を読み戻す回数を 2 回から 1 回に減らしています。

同じ端末の X 12.27.1（`com.atebits.Tweetie2`）で、データ 12,049 項目・App Group 73 項目と 4 項目・本体 15,077 項目のメタデータ列挙を確認しました。本文読み取り 0 回、代表 22 フォルダの実機一覧一致、後片付け後の未完了操作 0 件を確認。取得した実機一覧を使った AppManager のテストでは、データの 1,237 フォルダを約 17 ms、本体の 6,237 フォルダを約 31 ms で移動でき、移動時のヘルパー呼び出しは 0 回でした。これは描画時間を含まない一覧切り替えの実測です。初回取得は比較テスト・後片付け込みでデータ約 18 秒、本体約 215 秒でした。詳細は `dist/app-listing-smoke.json` です。

同じ X で、`Info.plist`（19,889 バイト）、深い階層の plist（787 バイト）、ローカライズフォルダ（2 ファイル・136,032 バイト）を、それぞれ約 10 秒で取り出せました。本体全体のコピー 0 回、元の領域の状態維持、後片付け後の未完了操作 0 件を確認しました。データ領域の 80 バイトの plist も、コンテナを一時移動する方式で約 12 秒で取り出せました。詳細は `dist/app-export-smoke.json` です。

### 未検証の領域

> [!WARNING]
> 実機は空き容量約 5.6 GB のため、10 GB の実機転送は未検証です。ローカルでのみ確認しています。4 GB を超える単一ファイルも、実機では未確認です。

## 仕組み

役割の異なる 2 つの経路が、1 つのアプリに同居しています。

| スタック | ソース | 役割 |
| --- | --- | --- |
| アプリコンテナ管理 | `Sources/AppManagement/*.py` + `Sources/BrowserBridge/main.m` | アプリ一覧、一覧表示、バックアップ、復元、書き出し |
| Airlift PoC / Media / Apple Pay | `Sources/PoC/*.py`、`airlift/airlift.py` | Media ブラウザ、Wallet の券面、既知パスへの読み書き |

**アプリ管理は AirTraffic を「移動」手段としてだけ使い、実際のバイト列は普通の AFC 接続で流します。** この二段構えが全体の中核です。

### 各プロトコルの役割

- **lockdown**（`create_using_usbmux`）— 端末名、iOS バージョン、機種の取得と、ほかのすべてのサービスの起点。
- **installation_proxy** — インストール済みアプリへの問い合わせ。アプリ一覧、表示名、バージョン、ユーザー／システムの区別に加え、データコンテナの UUID（`Container`）、App Group のパス（`GroupContainers`）、アプリ本体のパス（`Path`）はここからしか得ません。コンテナ UUID は**操作のたびに解決し直し、キャッシュしません**（`catalog.py` の `resolve`、`manager.py:182,264,439`）。
- **AFC** — バイト列を運ぶ唯一の手段。AirTraffic なしでは `/var/mobile/Media` しか見えません。`listdir` / `stat` / `mkdir` / `rm_single` / `rename` に加えて、転送は 4 MiB 単位の `fopen` / `fread` / `fwrite` / `fclose`、シンボリックリンクの作成は `afc.link`、空き容量の確認は `get_device_info()["FSFreeBytes"]` を使います。`TimedAFC`（`transport.py:70-80`）がすべての AFC 呼び出しに 120 秒のタイムアウトを掛け、応答がなければ再接続と「中断した処理を復旧」を促すエラーで止めます。
- **DVT / RSD ユーザースペーストンネル** — 開発者モードが必要です。`DeviceInfo.ls(path)` で実ディレクトリを列挙し（残存コンテナの検出、`/var` の閲覧、名前の推定。`catalog.py`、`Sources/DeviceFiles/dvt_files.py`）、`ProcessControl.kill(pid)` で対象アプリと、App Group を共有するプロセス・拡張機能をすべて止めます（`transport.py` の `quiesce`、83-114 行）。`ls()` は 30 秒、残存コンテナの推定は 45 秒で打ち切ります。失敗しても例外にはせず、利用者向けの `warnings` として返します。
- **SpringBoard サービス** — ホーム画面のアイコン PNG を読むだけです。接続は 15 秒、アイコンは 1 件 10 秒で打ち切り、まとめて取得します。タイムアウトしたらそのバッチ全体をやめます（途中で切れたストリームは再利用できないため）。操作ロックを通らない唯一の処理です。
- **AirTraffic** — サンドボックスを越える要です。AirTraffic は本来 `/var/mobile/Media` へしか同期しませんが、Airlift は次の 2 点を突きます。(1) Books の同期マニフェストを `Books/Sync/Books.plist` に書き、Persistent ID で「Book」資産として列挙させる。(2) `ATHostConnectionSendAssetCompleted(id, "Book", destinationPath)` の移動先が `/var/mobile/Media/` プレフィックスかどうかだけが文字列で確認され、ZIP 内の未検証シンボリックリンクが Media の外を指せる、という点です。

  `Lease.open`（`transport.py:390-453`）は次の順序で走ります。

  ```
  probe            (poc_device_helper。ビルド可否の判定に使う)
  snapshot-books   (端末の実際の Books 同期ファイル一式を Mac へ退避)
  stage            (poc_device_helper。com.apple.streaming_zip_conduit 経由で
                    /var/mobile/Media/airlift-src-<token>/ に極小 ZIP を配置。
                    p0/p1/p2/link が実際の対象を指すシンボリックリンク、
                    3 資産を名指しする Books.plist)
  relocate(link)   (airtraffic_host。配置済みの link を /var/mobile/Media/airlift-link-<token> へ移動
                    → link 越しに実コンテナを stat / list できる)
  relocate(target) (airtraffic_host。実コンテナを /var/mobile/Media/airlift-recovered-<token>/ へ移動
                    → 普通の AFC でコンテナ全体を読み書きできる)
  ... バイト列を AFC でストリーミング ...
  relocate(target back) (AirTraffic で元へ戻す)
  cleanup          (browser_bridge finish-delete。link と staging tree を削除し、
                    Books スナップショットをバイト単位で復元して確認)
  ```

  アプリ本体のボリューム（`/var/containers/Bundle/...`）だけは、**AirTraffic のボリューム跨ぎコピー**になります。コピー元には影響しません。`wait_for_copy`（`transport.py:468-498`）はルートのサイズと更新時刻が移動前の指紋に一致すること、加えて 2 回連続で `tree_fingerprint` が完全に一致することを最大 30 分待ちます。コピーが安定した領域は **読み取り専用** になり、`upload` / `replace` は「この領域は読み取り専用のコピーです」と拒否します。

- **com.apple.streaming_zip_conduit** と Books 状態の保護。`device_helper.m` の `Stage()` はバイナリ plist `{"MediaSubdir": source}` と生の ZIP（Zip64 なし・ZIP_STORED）を送ります。このとき端末の本物の `Books/Sync/Books.plist` を上書きしてしまうため、操作の前に追跡対象の 6 ファイル（`Books/Books.plist`、`Books/Sync/Books.plist`、`Books/Sync/Upload.plist`、`OutstandingAssets_4.sqlite{,-shm,-wal}`）と 3 ディレクトリ（`Books`、`Books/Sync`、`Books/Sync/Database`）を Mac へ退避します（合計 256 MiB まで）。操作の後に書き戻し、読み直してバイト単位で一致することを確かめます。

### 安全性（Lease とジャーナル）

`Operations/<20 hex token>/State.json` に状態を記録します。フェーズは `created → snapshotted → staging → linking → moving → open → returning → cleanup → complete`。`originalRoot` の指紋、変更系の全ステップを逆順にたどる `undo[]`、`copiedSource`、`selection`、`sourceIdentity` を保持します。

- `selection`（アプリ本体から項目を 1 つ書き出す場合）→ 変更は一切禁止。
- `copiedSource`（アプリ本体のボリューム）→ 読み取り専用。cleanup はコピー完了を待ってからで、削除しません。
- `close()` は `undo[]` を逆に適用し、期待される名前とサイズを記録して AirTraffic でコンテナを戻し、配置済みの link 越しに元を stat し直して到着を確認します。疑いがあるときは復旧記録をディスク上に**残し**、ユーザーに Recover を促します。
- `remove_tree()` は、AFC の `rm` がシンボリックリンクをたどるおそれがあるため、`lstat` + `unlink` を明示的に使って帰りがけ順に消していきます。制限時間は 30 分です。
- 利用者の操作は `flock` で 1 つずつ実行します（`~/Library/Application Support/Airlift Browser/manager.lock`）。例外はアイコン取得だけです。
- 中止は `cancelPath` に置く目印ファイルで伝えます。ただしロールバック・コンテナ復帰・Books 復元中は**意図的に無視**します。端末を中途半端な移動状態に残さないためです。
- 切断や異常終了で残ったジャーナルは、再接続後の「中断した処理を復旧」（`pending` / `recover`）で処理します。

### 転送と検証

- 大きなファイルは分割も事前 ZIP 生成もせず、同じ AFC 接続とファイルハンドルを保ったまま連続転送します。4 MiB 単位です。ローカルで 10 GiB 超、実機で 135 MB と 2.5 GB を確認済みです。
- バックアップ（`pull`）は 1 ファイルごとに読み取り後に size と mtime を再 stat します。変わっていれば「読み取り中にファイルが変わりました」で失敗します。ディレクトリの列挙は 2 回行って比較します（「バックアップ中にフォルダが変わりました」）。
- `AFC` ステータス 1（UNKNOWN_ERROR）または 10（PERM_DENIED）で `fopen` に失敗したファイルは、**バックアップ時のみ**読み取り不可の保護ファイルとしてスキップし `manifest.issues` に記録します。結果としてバックアップは「一部を保存できず」になります。タイムアウト・切断・ディスクエラーは致命的なのでスキップしません。
- `BACKUP_EXCLUDED_TREES` は丸ごと飛ばし、エラーではなく情報として記録します。対象は `Library/Caches/WebKit`、`Library/WebKit`、`SystemData/com.apple.SafariViewService/Library/WebKit`。
- リストア（`push`）はシンボリックリンクを `afc.link` で再構成してリンク先を確認し、送信中に入力ファイルが変わっていないことを確認し、端末上のサイズを確認し、端末側で再ハッシュします。
- `verify_restore` はリストア後に端末の全ファイルを読み戻し、ファイル集合と SHA-256（およびリンク先）を比較します。復元を信用できる根拠です。
- 一覧取得は `list-tree`（`tree_fingerprint`）でメタデータのみを走査し、ファイル本文は 1 バイトも読みません。シンボリックリンクはたどりません。lease が端末内コピーの完了を待っている場合はその結果を再利用するので、追加通信は 0 です。取得した一覧はメモリ上に保持され、子階層・親階層への移動や同じ領域の再表示は端末通信なしで描画されます。書き込み・復元・復旧・アプリ一覧更新・再接続で古い一覧を破棄します。
- 書き出し（`get`）は、データと App Group ならコンテナを一時移動して**選択項目だけ**を流します。アプリ本体ならまず端末内で選択項目をコピーし（`sourceIdentity` 指紋を開始・完了で再確認）、その後で選択項目だけを流します。**コンテナが元に戻り後片付けが成功するまで、Mac 側のパスは確定しません**（`download_destination` コンテキストマネージャ）。
- `mutate` の `delete` / `rename` / `mkdir` / `upload` は、`selection` 中、コピー読み取り専用中、コンテナの最上位、`MANAGED_NAMES`（`.com.apple.mobile_container_manager.metadata.plist`）のいずれかで拒否されます。
- 一覧は OS 全体の原子的スナップショットではありません。関連プロセスを停止してから順に領域をコピーします。マニフェストの `consistency` には `per-region; processes quiesced, not an OS snapshot` と残ります。

### バックアップの形式

`.airliftbackup` は ZIP ではなく**ただのディレクトリ**です。Finder でそのまま開けます。

```
<UUID>.airliftbackup/
  Manifest.json
  Payload/Data/                  # データコンテナ
  Payload/Bundle/                # アプリ本体
  Payload/Groups/<sha256(id)>/   # App Group
```

`Manifest.json` の主なフィールドは `format` / `version` / `id` / `created`(UTC ISO) / `app` / `device` / `origin`（`device` | `edited` | `imported` | `xcappdata`）/ `status`（`incomplete` | `complete` | `partial`）/ `regions[]` / `issues[]` / `totalBytes` / `fileAttributes` / `consistency` です。ファイルごとに `{path, size, mode, modifiedNS, kind: file|directory|link, sha256 | target}` を記録します。

- `inventory()` は再帰します。4 番目のファイル種別（FIFO・socket・device）が出たら「保存できないファイル種別です」で**バックアップを中断**します。
- `mismatches()` はソートした `(path, kind, sha256, target, size)` を突き合わせ、復元の可否を判定します。
- `finish()` は `issues` が空なら `complete`、あれば `partial` にします。
- `clone()` がすべてのオフライン編集の土台です。転送元を検証して新しいバックアップへコピーし（`origin: "edited"`、`parentID` 付き、ラベルは保持）、編集を適用して `inventory()` をやり直します。**元のバックアップは変更されません。**
- `import_backup()` は `.xcappdata`（`AppData/` と `AppDataInfo.plist` を読む）と既存の `.airliftbackup`（clone して `origin: "imported"`）を受け取ります。
- `export_backup()` はディレクトリまるごとの書き出しと、`.xcappdata`（データ領域のみ。`AppData/` と合成した `AppDataInfo.plist`）に対応します。隠蔽名の tmp に書いてから `os.rename` し、上書きを拒否し、エラー時はロールバックします。
- バックアップの削除は Python 側ではなく Swift の `FileManager.trashItem` で行うので、macOS のゴミ箱に入ります。

### Media と Apple Pay 側の別系統

Media と Apple Pay の経路はアプリ管理とは別の実装で、上限も別です。

- Media 経由の送受信は 1 回 128 MiB の上限があります。アプリ管理のストリーミングとは無関係です。
- `write_file.py` は全体 128 MiB、深さ 40、シンボリックリンク拒否、上書き拒否を持ち、回収して照合します。
- `list_cards.py` は `/var/mobile/Library/Passes/Cards` を Media へ移動し、`pass.json` に `paymentCard` を含む `*.pkpass` ディレクトリのうち**画像ファイルだけ**をコピーします。`pass.json` はサニタイズしたスタブ（`paymentCard`、`organizationName`、`description`、下 4 桁の `primaryAccountNumberSuffix` のみ）として書き直します。**証明書・署名・カード番号全体は決してコピーされません。**
- `edit_card.py` は `sips` で差し替え画像をカードの形に合わせて整形し（元画像が透過を持つ場合は `mask_image` で元の角丸アルファを引き継ぐ）、AirTraffic の 1 回の同期で差し替え、表示キャッシュを消し、`xcrun devicectl` で Wallet を再起動します。

## 上流プロジェクトとの関係

[0xjohnnydev/airlift](https://github.com/0xjohnnydev/airlift) を `airlift/` に submodule として clone し、コミット `c684cd41ca0ded2d1ab780c15f6ead05509ce062` に固定しています。

`Sources/BrowserBridge/main.m` は `#define main AirliftPoCMain` + `#include "../../airlift/Sources/device_helper.m"` + `#undef main` という形で上流の `device_helper.m` を読み込み、ペアリング・AFC 接続・読み書きの関数を再利用しています。上流の `main` は呼ばれません。元ソースは submodule 内のものを含めて変更していません。上流の MIT ライセンスは `Airlift-LICENSE.txt` としてアプリに同梱します。

上流は AirTraffic による既知パスへの書き込みと、一時移動による読み戻しを検証する PoC です。汎用のルートディレクトリ一覧 API ではありません。設定画面の「書き込みテスト」と、デバイス画面（`scope == .system`）の「このフォルダをテスト」は上流と同じ処理を実行します。アプリ管理の新しい経路は上流の小さなリンク生成用アーカイブを再利用し、コンテナの実データは Python の AFC 接続でストリーミングします。

`airlift/Sources/airlift_target.h` の `AIRLIFT_TESTED_BUILDS` は iOS 27.0（24A435）と 27.0（24A5390f）の 2 つだけです。それ以外のビルドでも警告付きで動きますが、上流では検証されていません（本アプリの実機検証は上の記録のとおり iOS 27.2 でも行っています）。

## クレジット

- [airlift](https://github.com/0xjohnnydev/airlift) — Johnny Franks（[@0xjohnnydev](https://github.com/0xjohnnydev)）、MIT。AirTraffic 経由の端末読み書き。
- [Airlift Cards](https://github.com/licht-jb/AirliftCards) — MIT。Apple Pay 券面の読み出しと差し替え。
