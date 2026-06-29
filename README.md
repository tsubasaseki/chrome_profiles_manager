# ChromeProfilesManager

Chrome のプロファイル整理を安全寄りに進めるための Windows GUI アプリです。PowerShell + WinForms で動くため、`.NET SDK` のビルドは不要です。

## 起動

`Start-ChromeProfilesManager.vbs` をダブルクリックします。

この起動方法では、黒い console 画面を表示せずにアプリを起動します。

## 詳細ドキュメント

詳細なドキュメントは `docs` フォルダにあります。

- `docs/01_conversation_history.md` / `docs/01_conversation_history.html`: 会話履歴
- `docs/02_user_guide.md` / `docs/02_user_guide.html`: ユーザーガイド
- `docs/03_development_notes.md` / `docs/03_development_notes.html`: 開発メモ
- `docs/README.md` / `docs/README.html`: docs 目次

## 主な機能

- `%LOCALAPPDATA%\Google\Chrome\User Data` から Chrome プロファイルを一覧表示
- `Local State` と `Preferences` から表示名、ProfileName、ログインユーザー、Google名、アバター情報を取得
- ローカルに保存されているプロフィール画像がある場合はアイコンとして表示
- Chrome の起動状態を表示
- Chrome の終了要求
- プロファイル一覧の HTML レポート作成
- HTML レポートを含む zip バックアップ作成
- zip の内容一覧表示
- User Data フォルダ、バックアップフォルダ、個別プロファイルフォルダを Explorer で開く
- 選択したプロファイルを完全削除せず、`_ChromeProfilesManager_Quarantine` に移動
- 起動直後のプロファイル読み込みをバックグラウンド化

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
- アイコン: `Google Profile Picture.png` などが保存されている場合に画像表示
- アイコン情報: Chrome内蔵アバターの場合は `avatar_icon` の識別子を表示

## 安全設計

- Chrome 起動中の隔離操作はブロックします。
- バックアップ zip がない状態では隔離操作をブロックします。
- 隔離は完全削除ではなく移動です。
- zip には `ChromeProfilesReport.html` を同梱します。
