# ChromeProfilesManager

Chrome のプロファイル整理を安全寄りに進めるための Windows GUI アプリです。PowerShell + WinForms で動くため、`.NET SDK` のビルドは不要です。

GitHub repository:

`https://github.com/tsubasaseki/chrome_profiles_manager`

## 起動

`Start-ChromeProfilesManager.vbs` をダブルクリックします。

この起動方法では、黒い console 画面を表示せずにアプリを起動します。

## 詳細ドキュメント

詳細なドキュメントは `docs` フォルダにあります。

- `docs/01_conversation_history.md` / `docs/01_conversation_history.html`: 会話履歴
- `docs/02_user_guide.md` / `docs/02_user_guide.html`: ユーザーガイド
- `docs/03_development_notes.md` / `docs/03_development_notes.html`: 開発メモ
- `docs/04_quality_report.md` / `docs/04_quality_report.html`: 品質向上レポート
- `docs/README.md` / `docs/README.html`: docs 目次

## 主な機能

- `%LOCALAPPDATA%\Google\Chrome\User Data` から Chrome プロファイルを一覧表示
- `Local State` と `Preferences` から表示名、ProfileName、ログインユーザー、Google名、アバター情報を取得
- ローカルに保存されているプロフィール画像がある場合はアイコンとして表示
- プロフィール画像は一覧で見やすい48px相当の大きさにリサイズして表示
- Chrome の起動状態を表示
- Chrome の終了要求
- プロファイル一覧の HTML レポート作成
- HTML レポートを含む zip バックアップ作成
- zip の内容一覧表示
- User Data フォルダ、バックアップフォルダ、個別プロファイルフォルダを Explorer で開く
- 選択したプロファイルを完全削除せず、`_ChromeProfilesManager_Quarantine` に移動
- 起動直後のプロファイル読み込みをバックグラウンド化
- 画面ログに加えて、バックアップ先の `logs` フォルダへ詳細ログを保存
- Chrome の `Local State` と `Preferences` を UTF-8 固定で読み込み、日本語プロファイル名の文字化けを防止
- 画面ログでは DEBUG を非表示にし、詳細 DEBUG はファイルログに保存
- アプリ専用の10色分類、メモ1、メモ2をプロファイルごとに保存
- 色とメモは Chrome User Data 配下の `_ChromeProfilesManager\profile_metadata.json` に保存
- 色選択は一覧の色付きドロップダウンに加え、選択行へ直接反映できる10色ボタンでも操作可能
- 更新日時は `yyyy-MM-dd HH:mm:ss（n日前）` の形式で表示
- メタ情報JSONをバックアップZIPへ同梱
- プロファイル一覧、バックアップZIP、ログ出力エリアの高さをドラッグで調整
- ZIP保存はバックグラウンドで実行し、全体の進捗率と推定残り時間を表示
- ZIP追加中の詳細ファイル名はログへ出力し、進捗表示とは分離
- 完成したZIPは一覧で選択され、内容確認やExplorerで開く操作が可能
- HTMLレポートは横スクロール可能な表として生成し、長いパスやメールでも崩れにくく表示
- HTMLレポートにはローカルに保存されているプロフィール画像をData URIで埋め込み、SingleFileHTMLとして閲覧可能

## テスト

自己完結のテストランナーは `tests/Run-Tests.ps1` です。

実行例:

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

現在のテストケース数は 281 件です。

## 推奨作業手順

1. `再読み込み` で現在のプロファイルを確認します。
2. `初回ZIP保存` で最初のバックアップを作成します。
3. 不要なプロファイルにチェックを入れ、`選択を隔離` で隔離します。
4. CCleaner などでキャッシュを削除します。
5. `清掃後ZIP保存` で移行作業用の原本バックアップを作成します。

## 表示できるプロフィール情報

- ディレクトリ名: `Default`, `Profile 1` など
- Chrome表示名: `Local State` の `profile.info_cache` から取得
- ProfileName: 各プロファイルの `Preferences` から取得
- ログインユーザー: 取得できる場合はメールアドレスなどを表示
- Google名: 取得できる場合はGoogleアカウント名を表示
- アイコン: `Google Profile Picture.png` などが保存されている場合に48px相当で画像表示し、HTMLレポートにも埋め込み表示
- アイコン情報: Chrome内蔵アバターの場合は `avatar_icon` の識別子を表示

## 安全設計

- Chrome 起動中の隔離操作はブロックします。
- バックアップ zip がない状態では隔離操作をブロックします。
- 隔離は完全削除ではなく移動です。
- zip には `ChromeProfilesReport.html` を同梱します。
