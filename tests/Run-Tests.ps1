param(
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$appPath = Join-Path $repoRoot "ChromeProfilesManager.ps1"
$raw = Get-Content -LiteralPath $appPath -Raw -Encoding UTF8
$cut = $raw.IndexOf('$script:Form = New-Object')
if ($cut -lt 0) {
    throw "アプリ本体のフォーム開始位置を見つけられません。"
}

Invoke-Expression $raw.Substring(0, $cut)
$script:LogBox = $null

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("cpm_tests_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Initialize-AppLogging -BackupPath (Join-Path $testRoot "logs-root")

$script:Tests = New-Object System.Collections.Generic.List[object]
$script:Passed = 0
$script:Failed = 0

function Add-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )
    $script:Tests.Add([pscustomobject]@{ Name = $Name; Body = $Body }) | Out-Null
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message = "値が一致しません。"
    )
    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

function Write-Utf8Json {
    param(
        [string]$Path,
        [object]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function New-TestUserData {
    param(
        [int]$ProfileCount = 2,
        [switch]$NoLocalState,
        [switch]$NoPreferences,
        [string]$RootName = ""
    )

    if ([string]::IsNullOrWhiteSpace($RootName)) {
        $RootName = "userdata_" + [guid]::NewGuid().ToString("N")
    }
    $root = Join-Path $testRoot $RootName
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    $infoCache = [ordered]@{}
    for ($i = 0; $i -lt $ProfileCount; $i++) {
        $directoryName = if ($i -eq 0) { "Default" } else { "Profile $i" }
        $profilePath = Join-Path $root $directoryName
        New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profilePath ("file{0}.txt" -f $i)) -Value ("data-{0}" -f $i) -Encoding UTF8

        if (-not $NoPreferences) {
            $pref = [ordered]@{
                profile = [ordered]@{ name = "PrefName $i" }
                account_info = @([ordered]@{
                    email = "user$i@example.com"
                    full_name = "User Full $i"
                    given_name = "UserGiven$i"
                })
            }
            Write-Utf8Json -Path (Join-Path $profilePath "Preferences") -Value $pref
        }

        $infoCache[$directoryName] = [ordered]@{
            name = "Display $i"
            user_name = "local$i@example.com"
            gaia_name = "Gaia $i"
            avatar_icon = "chrome://theme/IDR_PROFILE_AVATAR_$i"
        }
    }

    if (-not $NoLocalState) {
        $localState = [ordered]@{
            profile = [ordered]@{
                info_cache = $infoCache
            }
        }
        Write-Utf8Json -Path (Join-Path $root "Local State") -Value $localState
    }

    return $root
}

function Get-WorkerFunctionText {
    $functionNames = @(
        "Write-UiLog",
        "Get-DirectorySizeBytes",
        "Get-LocalStateProfileInfo",
        "Get-PreferenceProfileInfo",
        "Get-ProfileIconPath",
        "Get-ProfileColorPalette",
        "Get-ProfileColorInfo",
        "Get-ProfileColorComboItemVisual",
        "Format-LastWriteTimeWithAge",
        "Get-ManagerDataPath",
        "Get-ProfileMetadataPath",
        "New-ProfileMetadataDocument",
        "ConvertTo-ProfileMetadataMap",
        "Read-ProfileMetadata",
        "Get-ChromeProfiles",
        "Test-ShouldWriteLogToUi",
        "Get-ImageMimeType",
        "Convert-FileToDataUri",
        "New-EmbeddedProfileIconHtml",
        "New-BackupProgressState",
        "Set-BackupProgressState",
        "Get-BackupProgressPercent",
        "Format-BackupRemainingTime",
        "Get-BackupEstimatedRemainingText",
        "Get-BackupProgressLabelText",
        "Read-Utf8JsonFile",
        "Write-Utf8JsonFile"
    )
    return (($functionNames | ForEach-Object {
        "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}"
    }) -join "`r`n")
}

function Get-BackupWorkerFunctionText {
    $functionNames = @(
        "Write-UiLog",
        "Test-ShouldWriteLogToUi",
        "ConvertTo-HtmlEncoded",
        "Get-ImageMimeType",
        "Convert-FileToDataUri",
        "New-EmbeddedProfileIconHtml",
        "Format-LastWriteTimeWithAge",
        "Get-ManagerDataPath",
        "Get-ProfileMetadataPath",
        "Add-FileToZip",
        "Set-BackupProgressState",
        "Get-BackupProgressPercent",
        "Format-BackupRemainingTime",
        "Get-BackupEstimatedRemainingText",
        "Get-BackupProgressLabelText",
        "New-ProfileIndexHtmlText",
        "New-ProfilesZipBackup"
    )
    return (($functionNames | ForEach-Object {
        "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}"
    }) -join "`r`n")
}

try {
    Add-Test "既定バックアップ先はデスクトップ" {
        Assert-Equal ([Environment]::GetFolderPath("Desktop")) $script:DefaultBackupPath "既定バックアップ先"
    }

    $encodeCases = @(
        @("", ""),
        @("abc", "abc"),
        @("<tag>", "&lt;tag&gt;"),
        @("a&b", "a&amp;b"),
        @('"quote"', "&quot;quote&quot;"),
        @("'", "&#39;"),
        @("日本語", "日本語"),
        @("Profile 1", "Profile 1"),
        @("a<b&c>d", "a&lt;b&amp;c&gt;d"),
        @("C:\Temp\User Data", "C:\Temp\User Data"),
        @("mail@example.com", "mail@example.com"),
        @("x`ny", "x`ny"),
        @("  space  ", "  space  "),
        @("chrome://theme/IDR_PROFILE_AVATAR_1", "chrome://theme/IDR_PROFILE_AVATAR_1"),
        @("1 > 0 && 2 < 3", "1 &gt; 0 &amp;&amp; 2 &lt; 3"),
        @("Profile ""Work""", "Profile &quot;Work&quot;"),
        @("A/B\C", "A/B\C"),
        @("こんにちは & goodbye", "こんにちは &amp; goodbye"),
        @("Default", "Default"),
        @("Profile_🚫", "Profile_🚫")
    )
    for ($i = 0; $i -lt $encodeCases.Count; $i++) {
        $case = $encodeCases[$i]
        Add-Test "HTMLエンコード $i" {
            Assert-Equal $case[1] (ConvertTo-HtmlEncoded $case[0]) "HTMLエンコード結果"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 15; $i++) {
        Add-Test "ログ出力 $i" {
            Write-UiLog "ログテスト $i" "DEBUG"
            Assert-True (Test-Path -LiteralPath $script:LogFilePath) "ログファイルが存在しません。"
            $log = [System.IO.File]::ReadAllText($script:LogFilePath, [System.Text.Encoding]::UTF8)
            Assert-True ($log.Contains("ログテスト $i")) "ログ内容が見つかりません。"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 20; $i++) {
        Add-Test "Local State解析 $i" {
            $root = New-TestUserData -ProfileCount $i -RootName "localstate_$i"
            $info = Get-LocalStateProfileInfo -UserDataPath $root
            Assert-Equal $i $info.Count "Local State件数"
            Assert-Equal "Display 0" $info["Default"].DisplayName "Default表示名"
        }.GetNewClosure()
    }

    for ($i = 0; $i -lt 20; $i++) {
        Add-Test "Preferences解析 $i" {
            $root = New-TestUserData -ProfileCount 1 -RootName "prefs_$i"
            $info = Get-PreferenceProfileInfo -ProfilePath (Join-Path $root "Default")
            Assert-Equal "PrefName 0" $info.ProfileName "ProfileName"
            Assert-Equal "user0@example.com" $info.UserName "UserName"
            Assert-Equal "User Full 0" $info.GaiaName "GaiaName"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "日本語JSON解析 $i" {
            $root = Join-Path $testRoot "jp_$i"
            $profilePath = Join-Path $root "Profile $i"
            New-Item -ItemType Directory -Path $profilePath -Force | Out-Null

            $displayName = "仕事用プロファイル $i"
            $profileName = "個別管理用 $i"
            $gaiaName = "日本語ユーザー $i"
            $email = "nihongo$i@example.com"

            $localState = [ordered]@{
                profile = [ordered]@{
                    info_cache = [ordered]@{
                        ("Profile $i") = [ordered]@{
                            name = $displayName
                            user_name = $email
                            gaia_name = $gaiaName
                            avatar_icon = "chrome://theme/IDR_PROFILE_AVATAR_$i"
                        }
                    }
                }
            }
            $pref = [ordered]@{
                profile = [ordered]@{ name = $profileName }
                account_info = @([ordered]@{
                    email = $email
                    full_name = $gaiaName
                    given_name = "日本語"
                })
            }
            Write-Utf8Json -Path (Join-Path $root "Local State") -Value $localState
            Write-Utf8Json -Path (Join-Path $profilePath "Preferences") -Value $pref

            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            Assert-Equal 1 $profiles.Count "日本語プロファイル件数"
            Assert-Equal $displayName $profiles[0].DisplayName "日本語表示名"
            Assert-Equal $profileName $profiles[0].ProfileName "日本語ProfileName"
            Assert-Equal $gaiaName $profiles[0].GaiaName "日本語Google名"
            Assert-True (-not $profiles[0].DisplayName.Contains("繝")) "表示名が文字化けしています。"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 5; $i++) {
        Add-Test "画面DEBUG抑制 $i" {
            $oldShowDebug = $script:ShowDebugLogsInUi
            try {
                $script:ShowDebugLogsInUi = $false
                Assert-True (-not (Test-ShouldWriteLogToUi -Level "DEBUG")) "DEBUGが画面ログ対象になっています。"
                Assert-True (Test-ShouldWriteLogToUi -Level "INFO") "INFOが画面ログ対象になっていません。"
                Assert-True (Test-ShouldWriteLogToUi -Level "WARN") "WARNが画面ログ対象になっていません。"
                Assert-True (Test-ShouldWriteLogToUi -Level "DEBUG" -ShowDebug $true) "DEBUG表示ONでもDEBUGが画面ログ対象になっていません。"
            } finally {
                $script:ShowDebugLogsInUi = $oldShowDebug
            }
        }.GetNewClosure()
    }

    $colorIds = @("", "red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink", "gray", "brown")
    for ($i = 0; $i -lt $colorIds.Count; $i++) {
        Add-Test "色パレット $i" {
            $info = Get-ProfileColorInfo -ColorId $colorIds[$i]
            Assert-Equal $colorIds[$i] $info.Id "色ID"
            if ($colorIds[$i]) {
                Assert-True ($info.Hex.StartsWith("#")) "色Hexがありません。"
                Assert-True ($info.DisplayName.Contains("#")) "色表示名にHexがありません。"
            }
        }.GetNewClosure()
    }

    for ($i = 0; $i -lt $colorIds.Count; $i++) {
        Add-Test "色プルダウン表示 $i" {
            $info = Get-ProfileColorInfo -ColorId $colorIds[$i]
            $visual = Get-ProfileColorComboItemVisual -Item $info
            Assert-Equal $info.Id $visual.Id "プルダウン色ID"
            Assert-Equal $info.DisplayName $visual.Text "プルダウン表示名"
            Assert-Equal $info.Hex $visual.Hex "プルダウンHex"
            Assert-Equal (-not [string]::IsNullOrWhiteSpace($info.Hex)) $visual.HasColor "プルダウン色有無"
            if ($info.Hex) {
                Assert-Equal ([System.Drawing.ColorTranslator]::FromHtml($info.Hex).ToArgb()) $visual.BackColor.ToArgb() "プルダウン背景色"
            }
        }.GetNewClosure()
    }

    Add-Test "色プルダウン表示 不明ID" {
        $visual = Get-ProfileColorComboItemVisual -Item "unknown"
        Assert-Equal "" $visual.Id "不明IDは未設定へ戻します。"
        Assert-Equal "未設定" $visual.Text "不明IDの表示名"
        Assert-True (-not $visual.HasColor) "不明IDに色が付いています。"
    }

    for ($i = 0; $i -le 10; $i++) {
        Add-Test "更新日時相対表示 $i" {
            $date = (Get-Date).Date.AddDays(-1 * $i).AddHours(12)
            $text = Format-LastWriteTimeWithAge -LastWriteTime $date
            Assert-True ($text.Contains("（${i}日前）")) "相対日付が含まれていません。"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 15; $i++) {
        Add-Test "メタ情報保存読込 $i" {
            $root = New-TestUserData -ProfileCount 1 -RootName "metadata_$i"
            Set-ProfileMetadataEntry -UserDataPath $root -DirectoryName "Default" -ColorId "blue" -Memo1 "メモ1-$i" -Memo2 "メモ2-$i"
            $metadata = Read-ProfileMetadata -UserDataPath $root
            $map = ConvertTo-ProfileMetadataMap -Metadata $metadata
            Assert-True ($map.ContainsKey("Default")) "メタ情報が保存されていません。"
            Assert-Equal "blue" $map["Default"].color_id "色ID"
            Assert-Equal "メモ1-$i" $map["Default"].memo1 "メモ1"
            Assert-Equal "メモ2-$i" $map["Default"].memo2 "メモ2"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "メタ情報プロファイル反映 $i" {
            $root = New-TestUserData -ProfileCount 1 -RootName "metadata_profiles_$i"
            Set-ProfileMetadataEntry -UserDataPath $root -DirectoryName "Default" -ColorId "green" -Memo1 "分類-$i" -Memo2 "確認-$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            Assert-Equal "green" $profiles[0].ColorId "色ID"
            Assert-Equal "分類-$i" $profiles[0].Memo1 "メモ1"
            Assert-Equal "確認-$i" $profiles[0].Memo2 "メモ2"
            Assert-True ($profiles[0].ColorHex.StartsWith("#")) "色Hex"
        }.GetNewClosure()
    }

    $iconNames = @("Google Profile Picture.png", "Google Profile Picture", "Profile Picture.png", "Account Avatar.png", "Avatar.png")
    for ($i = 0; $i -lt $iconNames.Count; $i++) {
        Add-Test "アイコンパス検出 $i" {
            $root = New-TestUserData -ProfileCount 1 -RootName "icon_$i"
            $profilePath = Join-Path $root "Default"
            $iconPath = Join-Path $profilePath $iconNames[$i]
            Set-Content -LiteralPath $iconPath -Value "not-an-image" -Encoding UTF8
            Assert-Equal $iconPath (Get-ProfileIconPath -ProfilePath $profilePath) "アイコンパス"
        }.GetNewClosure()
    }

    Add-Test "アイコン48px表示" {
        $root = New-TestUserData -ProfileCount 1 -RootName "icon_size"
        $profilePath = Join-Path $root "Default"
        $iconPath = Join-Path $profilePath "Google Profile Picture.png"
        $bitmap = New-Object System.Drawing.Bitmap(12, 12)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Red)
            $bitmap.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
        $image = Get-ProfileIconImage -ProfilePath $profilePath
        try {
            Assert-Equal 48 $image.Width "アイコン幅"
            Assert-Equal 48 $image.Height "アイコン高さ"
        } finally {
            if ($image) {
                $image.Dispose()
            }
        }
    }

    for ($i = 1; $i -le 20; $i++) {
        Add-Test "プロファイル検出 $i" {
            $root = New-TestUserData -ProfileCount $i -RootName "profiles_$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            Assert-Equal $i $profiles.Count "プロファイル件数"
            Assert-True (@($profiles | Where-Object DirectoryName -eq "Default").Count -eq 1) "Defaultが見つかりません。"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "Local Stateなし検出 $i" {
            $root = New-TestUserData -ProfileCount $i -NoLocalState -RootName "nolocal_$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            Assert-Equal $i $profiles.Count "Local Stateなしプロファイル件数"
            Assert-True (-not [string]::IsNullOrWhiteSpace($profiles[0].DisplayName)) "表示名が空です。"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "Preferencesなし検出 $i" {
            $root = New-TestUserData -ProfileCount $i -NoPreferences -RootName "noprefs_$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            Assert-Equal $i $profiles.Count "Preferencesなしプロファイル件数"
            Assert-Equal "Display 0" (($profiles | Where-Object DirectoryName -eq "Default").DisplayName) "表示名"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 15; $i++) {
        Add-Test "HTMLレポート $i" {
            $root = New-TestUserData -ProfileCount 2 -RootName "html_$i"
            $iconPath = Join-Path (Join-Path $root "Default") "Google Profile Picture.png"
            $bitmap = New-Object System.Drawing.Bitmap(8, 8)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.Clear([System.Drawing.Color]::Blue)
                $bitmap.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally {
                $graphics.Dispose()
                $bitmap.Dispose()
            }
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            $html = New-ProfileIndexHtmlText -Profiles $profiles -UserDataPath $root -Stage "stage-$i"
            Assert-True ($html.Contains("Chromeプロファイル確認レポート")) "HTMLタイトルなし"
            Assert-True ($html.Contains("ログインユーザー")) "ログインユーザー列なし"
            Assert-True ($html.Contains("メモ1")) "メモ1列なし"
            Assert-True ($html.Contains("メモ2")) "メモ2列なし"
            Assert-True ($html.Contains("stage-$i")) "ステージなし"
            Assert-True ($html.Contains("local0@example.com")) "ユーザー名なし"
            Assert-True ($html.Contains('<meta name="viewport"')) "viewportがありません。"
            Assert-True ($html.Contains('class="table-wrap"')) "テーブルラッパーがありません。"
            Assert-True ($html.Contains("min-width: 1680px")) "横スクロール用の最小幅がありません。"
            Assert-True (-not $html.Contains("background:;")) "空のbackground指定があります。"
            Assert-True (-not $html.Contains('<th style="width:')) "破綻しやすいth幅指定が残っています。"
            Assert-True ($html.Contains("data:image/png;base64,")) "プロフィール画像がdata URIで埋め込まれていません。"
            Assert-True ($html.Contains("class='profile-icon'")) "プロフィール画像タグがありません。"
            Assert-True (-not $html.Contains($iconPath)) "HTMLがローカル画像パスを参照しています。"
        }.GetNewClosure()
    }

    Add-Test "HTML画像DataURI MIME" {
        Assert-Equal "image/png" (Get-ImageMimeType -Path "a.png") "png MIME"
        Assert-Equal "image/jpeg" (Get-ImageMimeType -Path "a.jpg") "jpg MIME"
        Assert-Equal "image/jpeg" (Get-ImageMimeType -Path "a.jpeg") "jpeg MIME"
        Assert-Equal "image/webp" (Get-ImageMimeType -Path "a.webp") "webp MIME"
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "ZIP進捗計算 $i" {
            Assert-Equal 0 (Get-BackupProgressPercent -ProcessedFiles 0 -TotalFiles $i) "0%計算"
            Assert-Equal 100 (Get-BackupProgressPercent -ProcessedFiles $i -TotalFiles $i) "100%計算"
            Assert-Equal 0 (Get-BackupProgressPercent -ProcessedFiles 1 -TotalFiles 0) "0除算回避"
            $state = New-BackupProgressState
            Set-BackupProgressState -ProgressState $state -Phase "zipping" -Status "追加中" -IsIndeterminate $false -Percent 42 -ProcessedFiles $i -TotalFiles ($i * 2) -AddedFiles $i -SkippedFiles 1
            Assert-Equal "zipping" $state.Phase "進捗フェーズ"
            Assert-Equal "追加中" $state.Status "進捗状態"
            Assert-Equal 42 $state.Percent "進捗率"
            Assert-Equal $i $state.ProcessedFiles "処理数"
            Assert-Equal ($i * 2) $state.TotalFiles "総数"
            Assert-Equal $i $state.AddedFiles "追加数"
            Assert-Equal 1 $state.SkippedFiles "スキップ数"
        }.GetNewClosure()
    }

    $remainingCases = @(
        @([TimeSpan]::FromSeconds(0), "0秒"),
        @([TimeSpan]::FromSeconds(9.2), "10秒"),
        @([TimeSpan]::FromSeconds(59), "59秒"),
        @([TimeSpan]::FromSeconds(60), "1分00秒"),
        @([TimeSpan]::FromSeconds(200), "3分20秒"),
        @([TimeSpan]::FromSeconds(3900), "1時間05分"),
        @([TimeSpan]::FromSeconds(-5), "0秒")
    )
    for ($i = 0; $i -lt $remainingCases.Count; $i++) {
        Add-Test "ZIP残り時間表示 $i" {
            Assert-Equal $remainingCases[$i][1] (Format-BackupRemainingTime -Remaining $remainingCases[$i][0]) "残り時間表示"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 5; $i++) {
        Add-Test "ZIP進捗ラベル $i" {
            $state = New-BackupProgressState
            $start = (Get-Date).AddSeconds(-10)
            Set-BackupProgressState -ProgressState $state -Phase "zipping" -Status "ZIP作成中" -IsIndeterminate $false -Percent 50 -ProcessedFiles 10 -TotalFiles 20 -AddedFiles 9 -SkippedFiles 1 -ZipStartTimeTicks $start.Ticks -CurrentFile "Profiles\Default\VeryLongFileName-$i.txt" -CurrentProfile "Default"
            $text = Get-BackupProgressLabelText -ProgressState $state
            Assert-True ($text.Contains("ZIP進捗: 50%")) "進捗率がありません。"
            Assert-True ($text.Contains("10 / 20件")) "件数がありません。"
            Assert-True ($text.Contains("残り約")) "残り時間がありません。"
            Assert-True ($text.Contains("追加:9")) "追加数がありません。"
            Assert-True ($text.Contains("スキップ:1")) "スキップ数がありません。"
            Assert-True (-not $text.Contains("ZIPへ追加中")) "詳細追加メッセージが進捗ラベルに混入しています。"
            Assert-True (-not $text.Contains("VeryLongFileName")) "ファイル名が進捗ラベルに混入しています。"
            Assert-True (-not $text.Contains("Default")) "プロファイル名が進捗ラベルに混入しています。"
        }.GetNewClosure()
    }

    Add-Test "ZIP進捗ラベル 計算中" {
        $state = New-BackupProgressState
        Set-BackupProgressState -ProgressState $state -Phase "counting" -Status "ZIP対象ファイル確認中" -IsIndeterminate $true -AddedFiles 0 -SkippedFiles 0
        $text = Get-BackupProgressLabelText -ProgressState $state
        Assert-True ($text.Contains("進捗計算中")) "計算中表示がありません。"
        Assert-True ($text.Contains("残り約 計算中")) "残り時間計算中表示がありません。"
    }

    Add-Test "ZIP進捗ラベル 完了" {
        $state = New-BackupProgressState
        Set-BackupProgressState -ProgressState $state -Phase "completed" -Status "ZIPバックアップ作成完了" -IsIndeterminate $false -Percent 100 -ProcessedFiles 20 -TotalFiles 20 -AddedFiles 19 -SkippedFiles 1 -Completed $true
        $text = Get-BackupProgressLabelText -ProgressState $state
        Assert-True ($text.Contains("ZIP完了: 100%")) "完了表示がありません。"
        Assert-True ($text.Contains("残り約 0秒")) "完了時の残り時間が0秒ではありません。"
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "ZIPバックアップ $i" {
            $root = New-TestUserData -ProfileCount 2 -RootName "zip_$i"
            $backup = Join-Path $testRoot "zip_backups_$i"
            Set-ProfileMetadataEntry -UserDataPath $root -DirectoryName "Default" -ColorId "red" -Memo1 "zipメモ1-$i" -Memo2 "zipメモ2-$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            $progress = New-BackupProgressState
            $result = New-ProfilesZipBackup -Profiles $profiles -UserDataPath $root -BackupPath $backup -Stage "test$i" -ProgressState $progress
            Assert-True (Test-Path -LiteralPath $result.ZipPath) "ZIPがありません。"
            Assert-True $progress.Completed "進捗が完了になっていません。"
            Assert-Equal 100 $progress.Percent "進捗が100%ではありません。"
            Assert-Equal $result.AddedFiles $progress.AddedFiles "進捗の追加数"
            Assert-Equal $result.SkippedFiles $progress.SkippedFiles "進捗のスキップ数"
            Assert-Equal $result.TotalFiles $progress.TotalFiles "進捗の総数"
            Assert-Equal "0秒" (Get-BackupEstimatedRemainingText -ProcessedFiles $progress.ProcessedFiles -TotalFiles $progress.TotalFiles -ZipStartTimeTicks $progress.ZipStartTimeTicks) "完了後の残り時間"
            $zip = [System.IO.Compression.ZipFile]::OpenRead($result.ZipPath)
            try {
                $names = @($zip.Entries | ForEach-Object FullName)
                Assert-True ($names -contains "ChromeProfilesReport.html") "レポートがありません。"
                Assert-True ($names -contains "ChromeProfilesManager/profile_metadata.json") "メタ情報JSONがありません。"
                Assert-True ($names -contains "Profiles/Default/Preferences") "Default Preferencesがありません。"
                Assert-True ($names -contains "Profiles/Profile 1/Preferences") "Profile 1 Preferencesがありません。"
            } finally {
                $zip.Dispose()
            }
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 5; $i++) {
        Add-Test "ZIP Runspace非同期互換 $i" {
            $root = New-TestUserData -ProfileCount 2 -RootName "zip_async_$i"
            $backup = Join-Path $testRoot "zip_async_backups_$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            $progress = New-BackupProgressState
            $functionText = Get-BackupWorkerFunctionText
            $workerScript = @"
param([object[]]`$WorkerProfiles, [string]`$WorkerUserDataPath, [string]`$WorkerBackupPath, [hashtable]`$WorkerProgressState, [string]`$WorkerLogFilePath)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
`$script:LogBox = `$null
`$script:LogFilePath = `$WorkerLogFilePath
`$script:ShowDebugLogsInUi = `$false
$functionText
New-ProfilesZipBackup -Profiles `$WorkerProfiles -UserDataPath `$WorkerUserDataPath -BackupPath `$WorkerBackupPath -Stage "async$i" -ProgressState `$WorkerProgressState
"@
            $ps = [System.Management.Automation.PowerShell]::Create()
            [void]$ps.AddScript($workerScript).AddArgument($profiles).AddArgument($root).AddArgument($backup).AddArgument($progress).AddArgument($script:LogFilePath)
            $async = $ps.BeginInvoke()
            while (-not $async.IsCompleted) {
                Start-Sleep -Milliseconds 20
            }
            $result = $ps.EndInvoke($async) | Select-Object -First 1
            $ps.Dispose()
            Assert-True (Test-Path -LiteralPath $result.ZipPath) "Runspace ZIPがありません。"
            Assert-True $progress.Completed "Runspace進捗が完了になっていません。"
            Assert-Equal 100 $progress.Percent "Runspace進捗が100%ではありません。"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "ディレクトリサイズ $i" {
            $dir = Join-Path $testRoot "size_$i"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $dir "a.bin"), (New-Object byte[] $i))
            [System.IO.File]::WriteAllBytes((Join-Path $dir "b.bin"), (New-Object byte[] ($i * 2)))
            Assert-Equal ($i * 3) (Get-DirectorySizeBytes -Path $dir) "サイズ"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 5; $i++) {
        Add-Test "Runspace非同期互換 $i" {
            $root = New-TestUserData -ProfileCount $i -RootName "async_$i"
            $functionText = Get-WorkerFunctionText
            $workerScript = @"
param([string]`$WorkerUserDataPath, [string]`$WorkerLogFilePath)
`$script:LogBox = `$null
`$script:LogFilePath = `$WorkerLogFilePath
$functionText
Get-ChromeProfiles -UserDataPath `$WorkerUserDataPath -SkipIconImage
"@
            $ps = [System.Management.Automation.PowerShell]::Create()
            [void]$ps.AddScript($workerScript).AddArgument($root).AddArgument($script:LogFilePath)
            $async = $ps.BeginInvoke()
            while (-not $async.IsCompleted) {
                Start-Sleep -Milliseconds 20
            }
            $rawProfiles = @($ps.EndInvoke($async))
            $ps.Dispose()
            if ($rawProfiles.Count -eq 1 -and $rawProfiles[0] -is [System.Array]) {
                $profiles = @($rawProfiles[0])
            } else {
                $profiles = $rawProfiles
            }
            Assert-Equal $i $profiles.Count "Runspace結果件数"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "HTML保存 $i" {
            $root = New-TestUserData -ProfileCount 1 -RootName "savehtml_$i"
            $backup = Join-Path $testRoot "html_backups_$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            $path = Save-ProfileIndexHtml -Profiles $profiles -UserDataPath $root -BackupPath $backup -Stage "manual$i"
            Assert-True (Test-Path -LiteralPath $path) "HTMLファイルがありません。"
            $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            Assert-True ($text.Contains("manual$i")) "保存HTMLにステージがありません。"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 5; $i++) {
        Add-Test "存在しないUser Data $i" {
            $missing = Join-Path $testRoot "missing_$i"
            $profiles = Get-ChromeProfiles -UserDataPath $missing -SkipIconImage
            Assert-Equal 0 $profiles.Count "存在しないUser Dataは0件"
        }.GetNewClosure()
    }

    foreach ($test in $script:Tests) {
        try {
            & $test.Body
            $script:Passed++
            Write-Host ("PASS {0}" -f $test.Name)
        } catch {
            $script:Failed++
            Write-Host ("FAIL {0}: {1}" -f $test.Name, $_.Exception.Message)
        }
    }

    Write-Host ("TOTAL {0} / PASSED {1} / FAILED {2}" -f $script:Tests.Count, $script:Passed, $script:Failed)
    if ($script:Tests.Count -lt 100) {
        throw "テストケース数が100件未満です: $($script:Tests.Count)"
    }
    if ($script:Failed -gt 0) {
        throw "$script:Failed 件のテストが失敗しました。"
    }
} finally {
    if (-not $KeepTemp -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    } else {
        Write-Host "TEST_TEMP $testRoot"
    }
}
