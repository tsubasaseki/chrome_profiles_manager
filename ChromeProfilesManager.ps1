Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = "ChromeProfilesManager"
$script:DefaultUserDataPath = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
$script:DefaultBackupPath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "ChromeProfilesManagerBackups"
$script:LogFilePath = $null
$script:ShowDebugLogsInUi = $false

function Initialize-AppLogging {
    param([string]$BackupPath = $script:DefaultBackupPath)

    try {
        $logRoot = Join-Path $BackupPath "logs"
        if (-not (Test-Path -LiteralPath $logRoot)) {
            New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        }
        $script:LogFilePath = Join-Path $logRoot ("ChromeProfilesManager_{0}.log" -f (Get-Date -Format "yyyyMMdd"))
        Write-UiLog "ログファイル: $script:LogFilePath"
    } catch {
        $script:LogFilePath = $null
    }
}

function Write-UiLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[$stamp][$Level] $Message"

    if (-not [string]::IsNullOrWhiteSpace($script:LogFilePath)) {
        try {
            [System.IO.File]::AppendAllText($script:LogFilePath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        } catch {
        }
    }

    if ($null -ne $script:LogBox -and (Test-ShouldWriteLogToUi -Level $Level)) {
        $uiLine = $line + "`r`n"
        if ($script:LogBox.InvokeRequired) {
            [void]$script:LogBox.BeginInvoke([Action[string]]{
                param($Text)
                $script:LogBox.AppendText($Text)
            }, $uiLine)
        } else {
            $script:LogBox.AppendText($uiLine)
        }
    }
}

function Test-ShouldWriteLogToUi {
    param(
        [string]$Level,
        [bool]$ShowDebug = $script:ShowDebugLogsInUi
    )

    return ($Level -ne "DEBUG" -or $ShowDebug)
}

function Read-Utf8JsonFile {
    param([string]$Path)

    $jsonText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $jsonText | ConvertFrom-Json
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()][string]$Value)
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-ChromeProcesses {
    return @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
}

function Test-ChromeRunning {
    return ((Get-ChromeProcesses).Count -gt 0)
}

function Get-DirectorySizeBytes {
    param([string]$Path)

    $total = [int64]0
    Write-UiLog "サイズ計算開始: $Path" "DEBUG"
    try {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $total += $_.Length }
    } catch {
        Write-UiLog "サイズ計算で警告: '$Path': $($_.Exception.Message)" "WARN"
    }
    Write-UiLog "サイズ計算完了: $Path = $total bytes" "DEBUG"
    return $total
}

function Get-LocalStateProfileInfo {
    param([string]$UserDataPath)

    $profiles = @{}
    $localStatePath = Join-Path $UserDataPath "Local State"
    Write-UiLog "Local State 読み込み開始: $localStatePath" "DEBUG"
    if (-not (Test-Path -LiteralPath $localStatePath)) {
        Write-UiLog "Local State が見つかりません: $localStatePath" "WARN"
        return $profiles
    }

    try {
        $json = Read-Utf8JsonFile -Path $localStatePath
        if ($json.profile -and $json.profile.info_cache) {
            foreach ($property in $json.profile.info_cache.PSObject.Properties) {
                $displayName = $property.Value.name
                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    $displayName = $property.Name
                }
                $profiles[$property.Name] = [pscustomobject]@{
                    DirectoryName = [string]$property.Name
                    DisplayName = [string]$displayName
                    UserName = [string]$property.Value.user_name
                    GaiaName = [string]$property.Value.gaia_name
                    AvatarIcon = [string]$property.Value.avatar_icon
                }
            }
        }
        Write-UiLog "Local State 読み込み完了: $($profiles.Count) 件" "DEBUG"
    } catch {
        Write-UiLog "Local State を読み込めませんでした: $($_.Exception.Message)" "WARN"
    }

    return $profiles
}

function Get-PreferenceProfileInfo {
    param([string]$ProfilePath)

    $info = [pscustomobject]@{
        ProfileName = ""
        UserName = ""
        GaiaName = ""
    }

    $preferencesPath = Join-Path $ProfilePath "Preferences"
    Write-UiLog "Preferences 読み込み開始: $preferencesPath" "DEBUG"
    if (-not (Test-Path -LiteralPath $preferencesPath)) {
        Write-UiLog "Preferences が見つかりません: $preferencesPath" "DEBUG"
        return $info
    }

    try {
        $json = Read-Utf8JsonFile -Path $preferencesPath
        if ($json.profile -and $json.profile.name) {
            $info.ProfileName = [string]$json.profile.name
        }
        if ($json.account_info) {
            $account = @($json.account_info)[0]
            if ($account) {
                if ($account.email) {
                    $info.UserName = [string]$account.email
                }
                if ($account.full_name) {
                    $info.GaiaName = [string]$account.full_name
                } elseif ($account.given_name) {
                    $info.GaiaName = [string]$account.given_name
                }
            }
        }
        Write-UiLog "Preferences 読み込み完了: $preferencesPath" "DEBUG"
    } catch {
        Write-UiLog "Preferences を読み込めませんでした: $ProfilePath - $($_.Exception.Message)" "WARN"
    }

    return $info
}

function Get-ProfileIconImage {
    param([string]$ProfilePath)

    $candidateNames = @(
        "Google Profile Picture.png",
        "Google Profile Picture",
        "Profile Picture.png",
        "Account Avatar.png",
        "Avatar.png"
    )

    foreach ($name in $candidateNames) {
        $path = Join-Path $ProfilePath $name
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            Write-UiLog "アイコン画像読み込み開始: $path" "DEBUG"
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $memory = New-Object System.IO.MemoryStream(,$bytes)
            $image = [System.Drawing.Image]::FromStream($memory)
            $bitmap = New-Object System.Drawing.Bitmap(24, 24)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($image, 0, 0, 24, 24)
            } finally {
                $graphics.Dispose()
                $image.Dispose()
                $memory.Dispose()
            }
            Write-UiLog "アイコン画像読み込み完了: $path" "DEBUG"
            return $bitmap
        } catch {
            Write-UiLog "アイコン画像を読み込めませんでした: $path - $($_.Exception.Message)" "WARN"
        }
    }

    return $null
}

function Get-ProfileIconPath {
    param([string]$ProfilePath)

    $candidateNames = @(
        "Google Profile Picture.png",
        "Google Profile Picture",
        "Profile Picture.png",
        "Account Avatar.png",
        "Avatar.png"
    )

    foreach ($name in $candidateNames) {
        $path = Join-Path $ProfilePath $name
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return ""
}

function Get-ChromeProfiles {
    param(
        [string]$UserDataPath,
        [switch]$SkipIconImage
    )

    if (-not (Test-Path -LiteralPath $UserDataPath)) {
        Write-UiLog "プロファイル検出対象が存在しません: $UserDataPath" "WARN"
        return @()
    }

    Write-UiLog "プロファイル検出開始: $UserDataPath" "INFO"
    $profileInfo = Get-LocalStateProfileInfo -UserDataPath $UserDataPath
    $candidateMap = @{}

    foreach ($key in $profileInfo.Keys) {
        $candidatePath = Join-Path $UserDataPath $key
        if (Test-Path -LiteralPath $candidatePath) {
            $candidateMap[$key] = $candidatePath
        }
    }

    Get-ChildItem -LiteralPath $UserDataPath -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "Default" -or
            $_.Name -like "Profile *" -or
            (Test-Path -LiteralPath (Join-Path $_.FullName "Preferences"))
        } |
        ForEach-Object {
            if (-not $candidateMap.ContainsKey($_.Name)) {
                $candidateMap[$_.Name] = $_.FullName
            }
        }

    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($directoryName in ($candidateMap.Keys | Sort-Object)) {
        $path = $candidateMap[$directoryName]
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            continue
        }

        $localStateInfo = $profileInfo[$directoryName]
        $preferenceInfo = Get-PreferenceProfileInfo -ProfilePath $path

        $displayName = $localStateInfo.DisplayName
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = $preferenceInfo.ProfileName
        }
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = $directoryName
        }

        $userName = $localStateInfo.UserName
        if ([string]::IsNullOrWhiteSpace($userName)) {
            $userName = $preferenceInfo.UserName
        }

        $gaiaName = $localStateInfo.GaiaName
        if ([string]::IsNullOrWhiteSpace($gaiaName)) {
            $gaiaName = $preferenceInfo.GaiaName
        }

        $sizeBytes = Get-DirectorySizeBytes -Path $path
        $profiles.Add([pscustomobject]@{
            DirectoryName = [string]$directoryName
            DisplayName = [string]$displayName
            ProfileName = [string]$preferenceInfo.ProfileName
            UserName = [string]$userName
            GaiaName = [string]$gaiaName
            AvatarIcon = [string]$localStateInfo.AvatarIcon
            IconPath = Get-ProfileIconPath -ProfilePath $path
            IconImage = if ($SkipIconImage) { $null } else { Get-ProfileIconImage -ProfilePath $path }
            Path = [string]$path
            SizeBytes = [int64]$sizeBytes
            SizeMB = [math]::Round($sizeBytes / 1MB, 2)
            LastWriteTime = $item.LastWriteTime
        })
        Write-UiLog "プロファイル検出: Directory=$directoryName DisplayName=$displayName User=$userName Path=$path Size=$sizeBytes" "DEBUG"
    }

    Write-UiLog "プロファイル検出完了: $($profiles.Count) 件" "INFO"
    return ,$profiles.ToArray()
}

function New-ProfileIndexHtmlText {
    param(
        [object[]]$Profiles,
        [string]$UserDataPath,
        [string]$Stage
    )

    $createdAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $rows = New-Object System.Text.StringBuilder
    foreach ($profile in $Profiles) {
        [void]$rows.AppendLine("<tr>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.DirectoryName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.DisplayName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.ProfileName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.UserName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.GaiaName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.AvatarIcon))</td>")
        [void]$rows.AppendLine("<td class='number'>$($profile.SizeMB)</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded ($profile.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))))</td>")
        [void]$rows.AppendLine("<td><code>$((ConvertTo-HtmlEncoded $profile.Path))</code></td>")
        [void]$rows.AppendLine("</tr>")
    }

    return @"
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>Chromeプロファイル確認レポート</title>
<style>
body { font-family: "Segoe UI", Meiryo, sans-serif; margin: 32px; color: #1f2933; background: #f7f9fb; }
main { max-width: 1200px; margin: 0 auto; background: #fff; border: 1px solid #d9e2ec; padding: 24px; }
h1 { margin-top: 0; font-size: 24px; }
.meta { color: #52616b; line-height: 1.7; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; table-layout: fixed; }
th, td { border: 1px solid #d9e2ec; padding: 8px 10px; vertical-align: top; word-break: break-all; }
th { background: #eef3f8; text-align: left; }
.number { text-align: right; }
code { font-family: Consolas, "Courier New", monospace; }
</style>
</head>
<body>
<main>
<h1>Chromeプロファイル確認レポート</h1>
<div class="meta">
作成日時: $((ConvertTo-HtmlEncoded $createdAt))<br>
ステージ: $((ConvertTo-HtmlEncoded $Stage))<br>
User Data: <code>$((ConvertTo-HtmlEncoded $UserDataPath))</code><br>
プロファイル数: $($Profiles.Count)
</div>
<table>
<thead>
<tr>
<th style="width: 11%;">ディレクトリ</th>
<th style="width: 13%;">表示名</th>
<th style="width: 13%;">ProfileName</th>
<th style="width: 16%;">ログインユーザー</th>
<th style="width: 13%;">Google名</th>
<th style="width: 12%;">アイコン</th>
<th style="width: 8%;">サイズMB</th>
<th style="width: 14%;">更新日時</th>
<th>場所</th>
</tr>
</thead>
<tbody>
$($rows.ToString())
</tbody>
</table>
</main>
</body>
</html>
"@
}

function Save-ProfileIndexHtml {
    param(
        [object[]]$Profiles,
        [string]$UserDataPath,
        [string]$BackupPath,
        [string]$Stage
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    }

    $htmlPath = Join-Path $BackupPath ("ChromeProfilesReport_{0}_{1}.html" -f $Stage, (Get-Date -Format "yyyyMMdd_HHmmss"))
    $html = New-ProfileIndexHtmlText -Profiles $Profiles -UserDataPath $UserDataPath -Stage $Stage
    [System.IO.File]::WriteAllText($htmlPath, $html, [System.Text.Encoding]::UTF8)
    return $htmlPath
}

function Add-FileToZip {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$SourceFile,
        [string]$EntryName
    )

    try {
        Write-UiLog "ZIP追加開始: $EntryName <= $SourceFile" "DEBUG"
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Zip,
            $SourceFile,
            $EntryName.Replace("\", "/"),
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
        Write-UiLog "ZIP追加完了: $EntryName" "DEBUG"
        return $true
    } catch {
            Write-UiLog "ロック中または読み取り不可のためスキップしました: $SourceFile - $($_.Exception.Message)" "WARN"
        return $false
    }
}

function New-ProfilesZipBackup {
    param(
        [object[]]$Profiles,
        [string]$UserDataPath,
        [string]$BackupPath,
        [string]$Stage
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    }

    $zipPath = Join-Path $BackupPath ("ChromeProfilesBackup_{0}_{1}.zip" -f $Stage, (Get-Date -Format "yyyyMMdd_HHmmss"))
    Write-UiLog "ZIPバックアップ作成開始: Stage=$Stage Path=$zipPath ProfileCount=$($Profiles.Count)" "INFO"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    $html = New-ProfileIndexHtmlText -Profiles $Profiles -UserDataPath $UserDataPath -Stage $Stage
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    $added = 0
    $skipped = 0

    try {
        $htmlEntry = $zip.CreateEntry("ChromeProfilesReport.html", [System.IO.Compression.CompressionLevel]::Optimal)
        $writer = New-Object System.IO.StreamWriter($htmlEntry.Open(), [System.Text.Encoding]::UTF8)
        try {
            $writer.Write($html)
        } finally {
            $writer.Dispose()
        }

        $localState = Join-Path $UserDataPath "Local State"
        if (Test-Path -LiteralPath $localState) {
            if (Add-FileToZip -Zip $zip -SourceFile $localState -EntryName "Local State") {
                $added++
            } else {
                $skipped++
            }
        }

        foreach ($profile in $Profiles) {
            Write-UiLog "ZIPへ追加中: $($profile.DirectoryName)"
            $root = $profile.Path
            $rootLength = $root.TrimEnd("\").Length
            Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $relative = $_.FullName.Substring($rootLength).TrimStart("\")
                    $entryName = Join-Path ("Profiles\" + $profile.DirectoryName) $relative
                    if (Add-FileToZip -Zip $zip -SourceFile $_.FullName -EntryName $entryName) {
                        $added++
                    } else {
                        $skipped++
                    }
                }
        }
    } finally {
        $zip.Dispose()
    }

    Write-UiLog "ZIPバックアップ作成完了: Path=$zipPath Added=$added Skipped=$skipped" "INFO"
    return [pscustomobject]@{
        ZipPath = $zipPath
        AddedFiles = $added
        SkippedFiles = $skipped
    }
}

function Get-SelectedProfilesFromGrid {
    $script:ProfilesGrid.EndEdit()
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($row in $script:ProfilesGrid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        $checked = [bool]$row.Cells["SelectColumn"].Value
        if ($checked) {
            $selected.Add($row.Tag)
        }
    }
    return ,$selected.ToArray()
}

function Refresh-ChromeStatus {
    $processes = Get-ChromeProcesses
    if ($processes.Count -gt 0) {
        $script:ChromeStatusLabel.Text = "Chrome状態: 起動中 ($($processes.Count) プロセス)"
        $script:ChromeStatusLabel.ForeColor = [System.Drawing.Color]::DarkRed
    } else {
        $script:ChromeStatusLabel.Text = "Chrome状態: 停止中"
        $script:ChromeStatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    }
}

function Refresh-ZipList {
    $script:ZipListBox.Items.Clear()
    $backupPath = $script:BackupPathTextBox.Text.Trim()
    if (-not (Test-Path -LiteralPath $backupPath)) {
        return
    }

    Get-ChildItem -LiteralPath $backupPath -Filter "*.zip" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            [void]$script:ZipListBox.Items.Add($_.FullName)
        }
}

function Set-ProfileRefreshBusy {
    param([bool]$Busy)

    if ($script:RefreshButton) {
        $script:RefreshButton.Enabled = -not $Busy
    }
    if ($script:ProfileLoadStatusLabel) {
        if ($Busy) {
            $script:ProfileLoadStatusLabel.Text = "プロファイル読み込み中..."
            $script:ProfileLoadStatusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
        } else {
            $script:ProfileLoadStatusLabel.Text = "読み込み完了"
            $script:ProfileLoadStatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        }
    }
}

function Set-ProfilesGridRows {
    param([object[]]$Profiles)

    $script:ProfilesGrid.Rows.Clear()
    foreach ($profile in $Profiles) {
        $iconImage = $profile.IconImage
        if ($null -eq $iconImage -and -not [string]::IsNullOrWhiteSpace($profile.IconPath)) {
            $iconImage = Get-ProfileIconImage -ProfilePath $profile.Path
            $profile | Add-Member -MemberType NoteProperty -Name IconImage -Value $iconImage -Force
        }

        $rowIndex = $script:ProfilesGrid.Rows.Add(
            $false,
            $iconImage,
            $profile.DirectoryName,
            $profile.DisplayName,
            $profile.ProfileName,
            $profile.UserName,
            $profile.GaiaName,
            $profile.AvatarIcon,
            $profile.SizeMB,
            $profile.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"),
            $profile.Path
        )
        $script:ProfilesGrid.Rows[$rowIndex].Tag = $profile
    }
}

function Refresh-Profiles {
    $script:ProfilesGrid.Rows.Clear()
    $userDataPath = $script:UserDataTextBox.Text.Trim()

    if (-not (Test-Path -LiteralPath $userDataPath)) {
        Write-UiLog "User Data フォルダが見つかりません: $userDataPath"
        Refresh-ChromeStatus
        return
    }

    $profiles = Get-ChromeProfiles -UserDataPath $userDataPath
    Set-ProfilesGridRows -Profiles $profiles

    Write-UiLog "$($profiles.Count) 件のプロファイルを読み込みました。"
    Refresh-ChromeStatus
}

function Test-ProfileRefreshBusy {
    return ($script:ProfileRefreshState -and -not $script:ProfileRefreshState.AsyncResult.IsCompleted)
}

function Start-ProfileRefresh {
    if (Test-ProfileRefreshBusy) {
        Write-UiLog "プロファイル読み込みはすでに実行中です。"
        return
    }

    $userDataPath = $script:UserDataTextBox.Text.Trim()
    if (-not (Test-Path -LiteralPath $userDataPath)) {
        $script:ProfilesGrid.Rows.Clear()
        Write-UiLog "User Data フォルダが見つかりません: $userDataPath"
        Refresh-ChromeStatus
        return
    }

    $script:ProfilesGrid.Rows.Clear()
    Set-ProfileRefreshBusy -Busy $true
    Refresh-ChromeStatus

    $functionNames = @(
        "Get-DirectorySizeBytes",
        "Get-LocalStateProfileInfo",
        "Get-PreferenceProfileInfo",
        "Get-ProfileIconPath",
        "Get-ChromeProfiles",
        "Write-UiLog",
        "Test-ShouldWriteLogToUi",
        "Read-Utf8JsonFile"
    )
    $functionText = ($functionNames | ForEach-Object {
        "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}"
    }) -join "`r`n"

    $workerScript = @"
param([string]`$WorkerUserDataPath)
`$script:LogBox = `$null
`$script:LogFilePath = '$($script:LogFilePath -replace "'", "''")'
`$script:ShowDebugLogsInUi = `$false
$functionText
Get-ChromeProfiles -UserDataPath `$WorkerUserDataPath -SkipIconImage
"@

    $powerShell = [System.Management.Automation.PowerShell]::Create()
    [void]$powerShell.AddScript($workerScript).AddArgument($userDataPath)
    $asyncResult = $powerShell.BeginInvoke()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        if (-not $script:ProfileRefreshState -or -not $script:ProfileRefreshState.AsyncResult.IsCompleted) {
            return
        }

        $script:ProfileRefreshState.Timer.Stop()
        Set-ProfileRefreshBusy -Busy $false
        try {
            $rawProfiles = @($script:ProfileRefreshState.PowerShell.EndInvoke($script:ProfileRefreshState.AsyncResult))
            if ($rawProfiles.Count -eq 1 -and $rawProfiles[0] -is [System.Array]) {
                $profiles = @($rawProfiles[0])
            } else {
                $profiles = $rawProfiles
            }
            Set-ProfilesGridRows -Profiles $profiles
            Write-UiLog "$($profiles.Count) 件のプロファイルを読み込みました。"
            Refresh-ChromeStatus
        } catch {
            Write-UiLog "プロファイル読み込みに失敗しました: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("プロファイル読み込みに失敗しました:`r`n$($_.Exception.Message)", $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } finally {
            $script:ProfileRefreshState.PowerShell.Dispose()
            $script:ProfileRefreshState.Timer.Dispose()
            $script:ProfileRefreshState = $null
        }
    })

    $script:ProfileRefreshState = [pscustomobject]@{
        PowerShell = $powerShell
        AsyncResult = $asyncResult
        Timer = $timer
    }
    Write-UiLog "プロファイル読み込みを開始しました。"
    $timer.Start()
}

function Get-AllProfilesFromGrid {
    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($row in $script:ProfilesGrid.Rows) {
        if (-not $row.IsNewRow -and $null -ne $row.Tag) {
            $profiles.Add($row.Tag)
        }
    }
    return ,$profiles.ToArray()
}

function Confirm-BackupWhenChromeRunning {
    if (-not (Test-ChromeRunning)) {
        return $true
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Chrome が起動中です。ロック中のファイルが抜けたり、不整合なバックアップになる可能性があります。続行しますか？",
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Start-Backup {
    param([string]$Stage)

    if (Test-ProfileRefreshBusy) {
        [System.Windows.Forms.MessageBox]::Show("プロファイル読み込み中です。完了後に実行してください。", $script:AppName) | Out-Null
        return
    }

    $profiles = Get-AllProfilesFromGrid
    if ($profiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("プロファイルが見つかりません。再読み込み後に実行してください。", $script:AppName) | Out-Null
        return
    }

    if (-not (Confirm-BackupWhenChromeRunning)) {
        Write-UiLog "Chrome起動中のため、バックアップをキャンセルしました。"
        return
    }

    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:Form.Enabled = $false
    try {
        Write-UiLog "$Stage バックアップを開始します..."
        $result = New-ProfilesZipBackup -Profiles $profiles -UserDataPath $script:UserDataTextBox.Text.Trim() -BackupPath $script:BackupPathTextBox.Text.Trim() -Stage $Stage
        Write-UiLog "バックアップを作成しました: $($result.ZipPath)"
        Write-UiLog "追加ファイル: $($result.AddedFiles); スキップ: $($result.SkippedFiles)"
        Refresh-ZipList
        [System.Windows.Forms.MessageBox]::Show("バックアップを作成しました:`r`n$($result.ZipPath)", $script:AppName) | Out-Null
    } catch {
        Write-UiLog "バックアップに失敗しました: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("バックアップに失敗しました:`r`n$($_.Exception.Message)", $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $script:Form.Enabled = $true
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Move-SelectedProfilesToQuarantine {
    if (Test-ProfileRefreshBusy) {
        [System.Windows.Forms.MessageBox]::Show("プロファイル読み込み中です。完了後に実行してください。", $script:AppName) | Out-Null
        return
    }

    if (Test-ChromeRunning) {
        [System.Windows.Forms.MessageBox]::Show("隔離する前に Chrome を終了してください。", $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Refresh-ChromeStatus
        return
    }

    $backupPath = $script:BackupPathTextBox.Text.Trim()
    $existingBackups = @()
    if (Test-Path -LiteralPath $backupPath) {
        $existingBackups = @(Get-ChildItem -LiteralPath $backupPath -Filter "*.zip" -File -ErrorAction SilentlyContinue)
    }
    if ($existingBackups.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("隔離する前に ZIP バックアップを作成してください。", $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $selected = Get-SelectedProfilesFromGrid
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("先に隔離するプロファイルを選択してください。", $script:AppName) | Out-Null
        return
    }

    $names = ($selected | ForEach-Object { "$($_.DirectoryName) ($($_.DisplayName))" }) -join "`r`n"
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "次のプロファイルを隔離フォルダへ移動しますか？`r`n`r`n$names`r`n`r`n完全削除はしません。",
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $userDataPath = $script:UserDataTextBox.Text.Trim()
    $quarantineRoot = Join-Path $userDataPath "_ChromeProfilesManager_Quarantine"
    $quarantineStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $quarantineBatch = Join-Path $quarantineRoot $quarantineStamp
    $suffix = 1
    while (Test-Path -LiteralPath $quarantineBatch) {
        $quarantineBatch = Join-Path $quarantineRoot ("{0}_{1:D2}" -f $quarantineStamp, $suffix)
        $suffix++
    }
    New-Item -ItemType Directory -Path $quarantineBatch -Force | Out-Null
    Write-UiLog "隔離先フォルダ作成: $quarantineBatch" "INFO"

    foreach ($profile in $selected) {
        $destination = Join-Path $quarantineBatch $profile.DirectoryName
        if (Test-Path -LiteralPath $destination) {
            throw "隔離先に同名フォルダが既に存在します: $destination"
        }
        Write-UiLog "移動中: '$($profile.Path)' -> '$destination'"
        Move-Item -LiteralPath $profile.Path -Destination $destination -Force
    }

    Write-UiLog "隔離フォルダへ移動しました: $quarantineBatch"
    [System.Windows.Forms.MessageBox]::Show("隔離フォルダへ移動しました:`r`n$quarantineBatch", $script:AppName) | Out-Null
    Start-ProfileRefresh
}

function Inspect-SelectedZip {
    $script:ZipEntriesListBox.Items.Clear()
    $zipPath = [string]$script:ZipListBox.SelectedItem
    if ([string]::IsNullOrWhiteSpace($zipPath) -or -not (Test-Path -LiteralPath $zipPath)) {
        return
    }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $totalBytes = [int64]0
            foreach ($entry in ($zip.Entries | Sort-Object FullName)) {
                $totalBytes += $entry.Length
                [void]$script:ZipEntriesListBox.Items.Add(("{0} ({1:N0} bytes)" -f $entry.FullName, $entry.Length))
            }
            Write-UiLog "ZIP内容を確認しました: $zipPath; 項目数=$($zip.Entries.Count); 展開時=$([math]::Round($totalBytes / 1MB, 2)) MB"
        } finally {
            $zip.Dispose()
        }
    } catch {
        Write-UiLog "ZIP内容確認に失敗しました: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("ZIP内容を確認できませんでした:`r`n$($_.Exception.Message)", $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Open-PathInExplorer {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        if ($item.PSIsContainer) {
            Start-Process explorer.exe -ArgumentList "`"$Path`""
        } else {
            Start-Process -FilePath $Path
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("場所が見つかりません:`r`n$Path", $script:AppName) | Out-Null
    }
}

function Request-FolderPath {
    param(
        [string]$Description,
        [string]$InitialPath
    )

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    if (Test-Path -LiteralPath $InitialPath) {
        $dialog.SelectedPath = $InitialPath
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Close-ChromeGracefully {
    $processes = Get-ChromeProcesses
    if ($processes.Count -eq 0) {
        Refresh-ChromeStatus
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Chrome に終了を依頼しますか？未保存の作業がないか確認してください。",
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    foreach ($process in $processes) {
        try {
            [void]$process.CloseMainWindow()
        } catch {
        }
    }

    Start-Sleep -Seconds 3
    $remaining = Get-ChromeProcesses
    if ($remaining.Count -gt 0) {
        $force = [System.Windows.Forms.MessageBox]::Show(
            "Chrome がまだ起動中です。残っている Chrome プロセスを強制終了しますか？",
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($force -eq [System.Windows.Forms.DialogResult]::Yes) {
            $remaining | Stop-Process -Force
        }
    }

    Refresh-ChromeStatus
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = $script:AppName
$script:Form.StartPosition = "CenterScreen"
$script:Form.Size = New-Object System.Drawing.Size(1180, 760)
$script:Form.MinimumSize = New-Object System.Drawing.Size(1040, 680)

$rootPanel = New-Object System.Windows.Forms.TableLayoutPanel
$rootPanel.Dock = "Fill"
$rootPanel.ColumnCount = 1
$rootPanel.RowCount = 5
$rootPanel.Padding = New-Object System.Windows.Forms.Padding(10)
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 92)))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 48)))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 32)))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20)))
$script:Form.Controls.Add($rootPanel)

$pathPanel = New-Object System.Windows.Forms.TableLayoutPanel
$pathPanel.Dock = "Fill"
$pathPanel.ColumnCount = 4
$pathPanel.RowCount = 2
$pathPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 115)))
$pathPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$pathPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 92)))
$pathPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 92)))
$pathPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$pathPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$rootPanel.Controls.Add($pathPanel, 0, 0)

$userDataLabel = New-Object System.Windows.Forms.Label
$userDataLabel.Text = "Chromeデータ"
$userDataLabel.Dock = "Fill"
$userDataLabel.TextAlign = "MiddleLeft"
$pathPanel.Controls.Add($userDataLabel, 0, 0)

$script:UserDataTextBox = New-Object System.Windows.Forms.TextBox
$script:UserDataTextBox.Text = $script:DefaultUserDataPath
$script:UserDataTextBox.Dock = "Fill"
$pathPanel.Controls.Add($script:UserDataTextBox, 1, 0)

$browseUserDataButton = New-Object System.Windows.Forms.Button
$browseUserDataButton.Text = "選択"
$browseUserDataButton.Dock = "Fill"
$browseUserDataButton.Add_Click({
    $path = Request-FolderPath -Description "Chrome の User Data フォルダを選択してください" -InitialPath $script:UserDataTextBox.Text
    if ($path) {
        $script:UserDataTextBox.Text = $path
        Start-ProfileRefresh
    }
})
$pathPanel.Controls.Add($browseUserDataButton, 2, 0)

$openUserDataButton = New-Object System.Windows.Forms.Button
$openUserDataButton.Text = "開く"
$openUserDataButton.Dock = "Fill"
$openUserDataButton.Add_Click({ Open-PathInExplorer -Path $script:UserDataTextBox.Text.Trim() })
$pathPanel.Controls.Add($openUserDataButton, 3, 0)

$backupLabel = New-Object System.Windows.Forms.Label
$backupLabel.Text = "バックアップ先"
$backupLabel.Dock = "Fill"
$backupLabel.TextAlign = "MiddleLeft"
$pathPanel.Controls.Add($backupLabel, 0, 1)

$script:BackupPathTextBox = New-Object System.Windows.Forms.TextBox
$script:BackupPathTextBox.Text = $script:DefaultBackupPath
$script:BackupPathTextBox.Dock = "Fill"
$pathPanel.Controls.Add($script:BackupPathTextBox, 1, 1)

$browseBackupButton = New-Object System.Windows.Forms.Button
$browseBackupButton.Text = "選択"
$browseBackupButton.Dock = "Fill"
$browseBackupButton.Add_Click({
    $path = Request-FolderPath -Description "バックアップ先フォルダを選択してください" -InitialPath $script:BackupPathTextBox.Text
    if ($path) {
        $script:BackupPathTextBox.Text = $path
        Initialize-AppLogging -BackupPath $path
        Refresh-ZipList
    }
})
$pathPanel.Controls.Add($browseBackupButton, 2, 1)

$openBackupButton = New-Object System.Windows.Forms.Button
$openBackupButton.Text = "開く"
$openBackupButton.Dock = "Fill"
$openBackupButton.Add_Click({ Open-PathInExplorer -Path $script:BackupPathTextBox.Text.Trim() })
$pathPanel.Controls.Add($openBackupButton, 3, 1)

$actionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$actionPanel.Dock = "Fill"
$actionPanel.FlowDirection = "LeftToRight"
$actionPanel.WrapContents = $false
$rootPanel.Controls.Add($actionPanel, 0, 1)

$script:RefreshButton = New-Object System.Windows.Forms.Button
$script:RefreshButton.Text = "再読み込み"
$script:RefreshButton.Width = 105
$script:RefreshButton.Add_Click({ Start-ProfileRefresh })
$actionPanel.Controls.Add($script:RefreshButton)

$script:ChromeStatusLabel = New-Object System.Windows.Forms.Label
$script:ChromeStatusLabel.Text = "Chrome状態: 未確認"
$script:ChromeStatusLabel.AutoSize = $true
$script:ChromeStatusLabel.Margin = New-Object System.Windows.Forms.Padding(18, 10, 12, 0)
$actionPanel.Controls.Add($script:ChromeStatusLabel)

$script:ProfileLoadStatusLabel = New-Object System.Windows.Forms.Label
$script:ProfileLoadStatusLabel.Text = "未読み込み"
$script:ProfileLoadStatusLabel.AutoSize = $true
$script:ProfileLoadStatusLabel.Margin = New-Object System.Windows.Forms.Padding(12, 10, 12, 0)
$actionPanel.Controls.Add($script:ProfileLoadStatusLabel)

$closeChromeButton = New-Object System.Windows.Forms.Button
$closeChromeButton.Text = "Chrome終了"
$closeChromeButton.Width = 105
$closeChromeButton.Add_Click({ Close-ChromeGracefully })
$actionPanel.Controls.Add($closeChromeButton)

$htmlButton = New-Object System.Windows.Forms.Button
$htmlButton.Text = "HTML作成"
$htmlButton.Width = 105
$htmlButton.Add_Click({
    $profiles = Get-AllProfilesFromGrid
    if ($profiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("プロファイルが見つかりません。再読み込み後に実行してください。", $script:AppName) | Out-Null
        return
    }
    $path = Save-ProfileIndexHtml -Profiles $profiles -UserDataPath $script:UserDataTextBox.Text.Trim() -BackupPath $script:BackupPathTextBox.Text.Trim() -Stage "manual"
    Write-UiLog "HTMLレポートを作成しました: $path"
    Open-PathInExplorer -Path $path
})
$actionPanel.Controls.Add($htmlButton)

$initialBackupButton = New-Object System.Windows.Forms.Button
$initialBackupButton.Text = "初回ZIP保存"
$initialBackupButton.Width = 115
$initialBackupButton.Add_Click({ Start-Backup -Stage "initial" })
$actionPanel.Controls.Add($initialBackupButton)

$postCleanupBackupButton = New-Object System.Windows.Forms.Button
$postCleanupBackupButton.Text = "清掃後ZIP保存"
$postCleanupBackupButton.Width = 125
$postCleanupBackupButton.Add_Click({ Start-Backup -Stage "post-cleanup" })
$actionPanel.Controls.Add($postCleanupBackupButton)

$quarantineButton = New-Object System.Windows.Forms.Button
$quarantineButton.Text = "選択を隔離"
$quarantineButton.Width = 105
$quarantineButton.Add_Click({ Move-SelectedProfilesToQuarantine })
$actionPanel.Controls.Add($quarantineButton)

$openSelectedProfileButton = New-Object System.Windows.Forms.Button
$openSelectedProfileButton.Text = "選択を開く"
$openSelectedProfileButton.Width = 105
$openSelectedProfileButton.Add_Click({
    if ($script:ProfilesGrid.CurrentRow -and $script:ProfilesGrid.CurrentRow.Tag) {
        Open-PathInExplorer -Path $script:ProfilesGrid.CurrentRow.Tag.Path
    }
})
$actionPanel.Controls.Add($openSelectedProfileButton)

$script:ProfilesGrid = New-Object System.Windows.Forms.DataGridView
$script:ProfilesGrid.Dock = "Fill"
$script:ProfilesGrid.AllowUserToAddRows = $false
$script:ProfilesGrid.AllowUserToDeleteRows = $false
$script:ProfilesGrid.RowHeadersVisible = $false
$script:ProfilesGrid.SelectionMode = "FullRowSelect"
$script:ProfilesGrid.MultiSelect = $false
$script:ProfilesGrid.AutoSizeColumnsMode = "Fill"

$selectColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$selectColumn.Name = "SelectColumn"
$selectColumn.HeaderText = ""
$selectColumn.Width = 38
$selectColumn.FillWeight = 8
[void]$script:ProfilesGrid.Columns.Add($selectColumn)
$iconColumn = New-Object System.Windows.Forms.DataGridViewImageColumn
$iconColumn.Name = "IconImage"
$iconColumn.HeaderText = "アイコン"
$iconColumn.ImageLayout = "Zoom"
$iconColumn.FillWeight = 9
[void]$script:ProfilesGrid.Columns.Add($iconColumn)
[void]$script:ProfilesGrid.Columns.Add("DirectoryName", "ディレクトリ")
[void]$script:ProfilesGrid.Columns.Add("DisplayName", "表示名")
[void]$script:ProfilesGrid.Columns.Add("ProfileName", "ProfileName")
[void]$script:ProfilesGrid.Columns.Add("UserName", "ログインユーザー")
[void]$script:ProfilesGrid.Columns.Add("GaiaName", "Google名")
[void]$script:ProfilesGrid.Columns.Add("AvatarIcon", "アイコン情報")
[void]$script:ProfilesGrid.Columns.Add("SizeMB", "サイズMB")
[void]$script:ProfilesGrid.Columns.Add("LastWriteTime", "更新日時")
[void]$script:ProfilesGrid.Columns.Add("Path", "場所")
$script:ProfilesGrid.Columns["DirectoryName"].FillWeight = 16
$script:ProfilesGrid.Columns["DisplayName"].FillWeight = 18
$script:ProfilesGrid.Columns["ProfileName"].FillWeight = 18
$script:ProfilesGrid.Columns["UserName"].FillWeight = 24
$script:ProfilesGrid.Columns["GaiaName"].FillWeight = 18
$script:ProfilesGrid.Columns["AvatarIcon"].FillWeight = 22
$script:ProfilesGrid.Columns["SizeMB"].FillWeight = 10
$script:ProfilesGrid.Columns["LastWriteTime"].FillWeight = 18
$script:ProfilesGrid.Columns["Path"].FillWeight = 46
$rootPanel.Controls.Add($script:ProfilesGrid, 0, 2)

$zipSplit = New-Object System.Windows.Forms.SplitContainer
$zipSplit.Dock = "Fill"
$zipSplit.Orientation = "Vertical"
$zipSplit.SplitterDistance = 390
$rootPanel.Controls.Add($zipSplit, 0, 3)

$zipLeftPanel = New-Object System.Windows.Forms.TableLayoutPanel
$zipLeftPanel.Dock = "Fill"
$zipLeftPanel.RowCount = 2
$zipLeftPanel.ColumnCount = 1
$zipLeftPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
$zipLeftPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$zipSplit.Panel1.Controls.Add($zipLeftPanel)

$zipHeaderPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$zipHeaderPanel.Dock = "Fill"
$zipHeaderPanel.FlowDirection = "LeftToRight"
$zipHeaderPanel.WrapContents = $false
$zipLeftPanel.Controls.Add($zipHeaderPanel, 0, 0)

$zipLabel = New-Object System.Windows.Forms.Label
$zipLabel.Text = "バックアップZIP"
$zipLabel.Width = 170
$zipLabel.TextAlign = "MiddleLeft"
$zipHeaderPanel.Controls.Add($zipLabel)

$refreshZipButton = New-Object System.Windows.Forms.Button
$refreshZipButton.Text = "更新"
$refreshZipButton.Width = 82
$refreshZipButton.Add_Click({ Refresh-ZipList })
$zipHeaderPanel.Controls.Add($refreshZipButton)

$inspectZipButton = New-Object System.Windows.Forms.Button
$inspectZipButton.Text = "内容確認"
$inspectZipButton.Width = 82
$inspectZipButton.Add_Click({ Inspect-SelectedZip })
$zipHeaderPanel.Controls.Add($inspectZipButton)

$script:ZipListBox = New-Object System.Windows.Forms.ListBox
$script:ZipListBox.Dock = "Fill"
$script:ZipListBox.HorizontalScrollbar = $true
$script:ZipListBox.Add_DoubleClick({ Inspect-SelectedZip })
$zipLeftPanel.Controls.Add($script:ZipListBox, 0, 1)

$script:ZipEntriesListBox = New-Object System.Windows.Forms.ListBox
$script:ZipEntriesListBox.Dock = "Fill"
$script:ZipEntriesListBox.HorizontalScrollbar = $true
$zipSplit.Panel2.Controls.Add($script:ZipEntriesListBox)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Dock = "Fill"
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = "Vertical"
$script:LogBox.ReadOnly = $true
$rootPanel.Controls.Add($script:LogBox, 0, 4)

$script:Form.Add_Shown({
    if (-not (Test-Path -LiteralPath $script:BackupPathTextBox.Text)) {
        New-Item -ItemType Directory -Path $script:BackupPathTextBox.Text -Force | Out-Null
    }
    Initialize-AppLogging -BackupPath $script:BackupPathTextBox.Text
    Write-UiLog "アプリ起動: Version=PowerShell $($PSVersionTable.PSVersion) UserData=$($script:UserDataTextBox.Text) Backup=$($script:BackupPathTextBox.Text)" "INFO"
    Start-ProfileRefresh
    Refresh-ZipList
})

try {
    [void]$script:Form.ShowDialog()
} catch {
    Write-UiLog "未処理エラー: $($_.Exception.ToString())" "ERROR"
    [System.Windows.Forms.MessageBox]::Show("未処理エラーが発生しました:`r`n$($_.Exception.Message)", $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}
