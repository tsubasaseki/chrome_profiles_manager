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
        "Get-ChromeProfiles",
        "Test-ShouldWriteLogToUi",
        "Read-Utf8JsonFile"
    )
    return (($functionNames | ForEach-Object {
        "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}"
    }) -join "`r`n")
}

try {
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
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            $html = New-ProfileIndexHtmlText -Profiles $profiles -UserDataPath $root -Stage "stage-$i"
            Assert-True ($html.Contains("Chromeプロファイル確認レポート")) "HTMLタイトルなし"
            Assert-True ($html.Contains("ログインユーザー")) "ログインユーザー列なし"
            Assert-True ($html.Contains("stage-$i")) "ステージなし"
            Assert-True ($html.Contains("local0@example.com")) "ユーザー名なし"
        }.GetNewClosure()
    }

    for ($i = 1; $i -le 10; $i++) {
        Add-Test "ZIPバックアップ $i" {
            $root = New-TestUserData -ProfileCount 2 -RootName "zip_$i"
            $backup = Join-Path $testRoot "zip_backups_$i"
            $profiles = Get-ChromeProfiles -UserDataPath $root -SkipIconImage
            $result = New-ProfilesZipBackup -Profiles $profiles -UserDataPath $root -BackupPath $backup -Stage "test$i"
            Assert-True (Test-Path -LiteralPath $result.ZipPath) "ZIPがありません。"
            $zip = [System.IO.Compression.ZipFile]::OpenRead($result.ZipPath)
            try {
                $names = @($zip.Entries | ForEach-Object FullName)
                Assert-True ($names -contains "ChromeProfilesReport.html") "レポートがありません。"
                Assert-True ($names -contains "Profiles/Default/Preferences") "Default Preferencesがありません。"
                Assert-True ($names -contains "Profiles/Profile 1/Preferences") "Profile 1 Preferencesがありません。"
            } finally {
                $zip.Dispose()
            }
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
