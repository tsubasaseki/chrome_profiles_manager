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

function Write-Utf8JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $jsonText = $Value | ConvertTo-Json -Depth 20
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $jsonText, [System.Text.Encoding]::UTF8)
}

function Get-ProfileColorPalette {
    return @(
        [pscustomobject]@{ Id = ""; Name = "未設定"; DisplayName = "未設定"; Hex = "" },
        [pscustomobject]@{ Id = "red"; Name = "赤"; DisplayName = "赤 #FADBD8"; Hex = "#FADBD8" },
        [pscustomobject]@{ Id = "orange"; Name = "橙"; DisplayName = "橙 #FDEBD0"; Hex = "#FDEBD0" },
        [pscustomobject]@{ Id = "yellow"; Name = "黄"; DisplayName = "黄 #FCF3CF"; Hex = "#FCF3CF" },
        [pscustomobject]@{ Id = "green"; Name = "緑"; DisplayName = "緑 #D5F5E3"; Hex = "#D5F5E3" },
        [pscustomobject]@{ Id = "cyan"; Name = "水"; DisplayName = "水 #D6EAF8"; Hex = "#D6EAF8" },
        [pscustomobject]@{ Id = "blue"; Name = "青"; DisplayName = "青 #D6DBF5"; Hex = "#D6DBF5" },
        [pscustomobject]@{ Id = "purple"; Name = "紫"; DisplayName = "紫 #E8DAEF"; Hex = "#E8DAEF" },
        [pscustomobject]@{ Id = "pink"; Name = "桃"; DisplayName = "桃 #FADBD8"; Hex = "#FADBD8" },
        [pscustomobject]@{ Id = "gray"; Name = "灰"; DisplayName = "灰 #EAECEE"; Hex = "#EAECEE" },
        [pscustomobject]@{ Id = "brown"; Name = "茶"; DisplayName = "茶 #EAD7C0"; Hex = "#EAD7C0" }
    )
}

function Get-ProfileColorInfo {
    param([AllowNull()][string]$ColorId)

    $palette = Get-ProfileColorPalette
    $match = $palette | Where-Object { $_.Id -eq $ColorId } | Select-Object -First 1
    if ($null -eq $match) {
        return $palette[0]
    }
    return $match
}

function Get-ProfileColorComboItemVisual {
    param([AllowNull()]$Item)

    $id = ""
    $displayName = "未設定"
    $hex = ""

    if ($null -ne $Item) {
        if ($Item.PSObject.Properties.Name -contains "Id") {
            $id = [string]$Item.Id
        } else {
            $id = [string]$Item
        }

        $colorInfo = Get-ProfileColorInfo -ColorId $id
        $id = [string]$colorInfo.Id
        $displayName = [string]$colorInfo.DisplayName
        $hex = [string]$colorInfo.Hex
    }

    $backColor = [System.Drawing.Color]::White
    if (-not [string]::IsNullOrWhiteSpace($hex)) {
        $backColor = [System.Drawing.ColorTranslator]::FromHtml($hex)
    }

    return [pscustomobject]@{
        Id = $id
        Text = $displayName
        Hex = $hex
        BackColor = $backColor
        ForeColor = [System.Drawing.Color]::Black
        HasColor = (-not [string]::IsNullOrWhiteSpace($hex))
    }
}

function Set-ProfileColorComboBoxOwnerDraw {
    param([System.Windows.Forms.ComboBox]$ComboBox)

    if ($null -eq $ComboBox -or [string]$ComboBox.Tag -eq "ProfileColorOwnerDraw") {
        return
    }

    $ComboBox.Tag = "ProfileColorOwnerDraw"
    $ComboBox.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $ComboBox.ItemHeight = 24
    $ComboBox.Add_DrawItem({
        param($Sender, $EventArgs)

        if ($EventArgs.Index -lt 0) {
            return
        }

        $visual = Get-ProfileColorComboItemVisual -Item $Sender.Items[$EventArgs.Index]
        $bounds = $EventArgs.Bounds
        $backgroundBrush = New-Object System.Drawing.SolidBrush($visual.BackColor)
        $textBrush = New-Object System.Drawing.SolidBrush($visual.ForeColor)
        $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Silver)
        try {
            $EventArgs.Graphics.FillRectangle($backgroundBrush, $bounds)

            $swatch = New-Object System.Drawing.Rectangle(($bounds.Left + 4), ($bounds.Top + 4), 18, ([Math]::Max(12, $bounds.Height - 8)))
            if ($visual.HasColor) {
                $EventArgs.Graphics.FillRectangle($backgroundBrush, $swatch)
            } else {
                $EventArgs.Graphics.FillRectangle([System.Drawing.Brushes]::White, $swatch)
            }
            $EventArgs.Graphics.DrawRectangle($borderPen, $swatch)

            $textPoint = New-Object System.Drawing.PointF(($bounds.Left + 28), ($bounds.Top + 4))
            $EventArgs.Graphics.DrawString($visual.Text, $Sender.Font, $textBrush, $textPoint)
            $EventArgs.DrawFocusRectangle()
        } finally {
            $backgroundBrush.Dispose()
            $textBrush.Dispose()
            $borderPen.Dispose()
        }
    })
}

function Get-ManagerDataPath {
    param([string]$UserDataPath)
    return Join-Path $UserDataPath "_ChromeProfilesManager"
}

function Get-ProfileMetadataPath {
    param([string]$UserDataPath)
    return Join-Path (Get-ManagerDataPath -UserDataPath $UserDataPath) "profile_metadata.json"
}

function New-ProfileMetadataDocument {
    return [pscustomobject]@{
        version = 1
        updated_at = (Get-Date).ToString("o")
        profiles = [pscustomobject]@{}
    }
}

function ConvertTo-ProfileMetadataMap {
    param([AllowNull()][object]$Metadata)

    $map = @{}
    if ($null -eq $Metadata -or $null -eq $Metadata.profiles) {
        return $map
    }

    foreach ($property in $Metadata.profiles.PSObject.Properties) {
        $map[$property.Name] = [pscustomobject]@{
            color_id = [string]$property.Value.color_id
            memo1 = [string]$property.Value.memo1
            memo2 = [string]$property.Value.memo2
            updated_at = [string]$property.Value.updated_at
        }
    }
    return $map
}

function Read-ProfileMetadata {
    param([string]$UserDataPath)

    $path = Get-ProfileMetadataPath -UserDataPath $UserDataPath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-UiLog "プロファイルメタ情報が未作成です: $path" "DEBUG"
        return New-ProfileMetadataDocument
    }

    try {
        $metadata = Read-Utf8JsonFile -Path $path
        if ($null -eq $metadata.profiles) {
            $metadata | Add-Member -MemberType NoteProperty -Name profiles -Value ([pscustomobject]@{}) -Force
        }
        return $metadata
    } catch {
        $brokenPath = "$path.broken.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        try {
            Copy-Item -LiteralPath $path -Destination $brokenPath -Force
        } catch {
        }
        Write-UiLog "プロファイルメタ情報を読み込めませんでした。退避して新規作成します: $brokenPath - $($_.Exception.Message)" "WARN"
        return New-ProfileMetadataDocument
    }
}

function Format-LastWriteTimeWithAge {
    param([DateTime]$LastWriteTime)

    $days = [int][Math]::Floor(((Get-Date).Date - $LastWriteTime.Date).TotalDays)
    if ($days -lt 0) {
        $days = 0
    }
    return "{0}（{1}日前）" -f $LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"), $days
}

function Save-ProfileMetadataMap {
    param(
        [string]$UserDataPath,
        [hashtable]$Map
    )

    $profiles = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object)) {
        $entry = $Map[$key]
        $profiles[$key] = [ordered]@{
            color_id = [string]$entry.color_id
            memo1 = [string]$entry.memo1
            memo2 = [string]$entry.memo2
            updated_at = [string]$entry.updated_at
        }
    }

    $document = [ordered]@{
        version = 1
        updated_at = (Get-Date).ToString("o")
        profiles = $profiles
    }
    $path = Get-ProfileMetadataPath -UserDataPath $UserDataPath
    Write-Utf8JsonFile -Path $path -Value $document
    Write-UiLog "プロファイルメタ情報を保存しました: $path" "INFO"
    return $path
}

function Set-ProfileMetadataEntry {
    param(
        [string]$UserDataPath,
        [string]$DirectoryName,
        [AllowNull()][string]$ColorId,
        [AllowNull()][string]$Memo1,
        [AllowNull()][string]$Memo2
    )

    $metadata = Read-ProfileMetadata -UserDataPath $UserDataPath
    $map = ConvertTo-ProfileMetadataMap -Metadata $metadata
    if ([string]::IsNullOrWhiteSpace($ColorId) -and [string]::IsNullOrWhiteSpace($Memo1) -and [string]::IsNullOrWhiteSpace($Memo2)) {
        if ($map.ContainsKey($DirectoryName)) {
            $map.Remove($DirectoryName)
        }
    } else {
        $map[$DirectoryName] = [pscustomobject]@{
            color_id = [string]$ColorId
            memo1 = [string]$Memo1
            memo2 = [string]$Memo2
            updated_at = (Get-Date).ToString("o")
        }
    }
    Save-ProfileMetadataMap -UserDataPath $UserDataPath -Map $map | Out-Null
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()][string]$Value)
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-ImageMimeType {
    param([AllowNull()][string]$Path)

    $extension = [System.IO.Path]::GetExtension([string]$Path).ToLowerInvariant()
    switch ($extension) {
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".gif" { return "image/gif" }
        ".bmp" { return "image/bmp" }
        ".webp" { return "image/webp" }
        default { return "image/png" }
    }
}

function Convert-FileToDataUri {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    try {
        $mimeType = Get-ImageMimeType -Path $Path
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $base64 = [Convert]::ToBase64String($bytes)
        return "data:$mimeType;base64,$base64"
    } catch {
        Write-UiLog "HTML埋め込み画像の読み込みに失敗しました: $Path - $($_.Exception.Message)" "WARN"
        return ""
    }
}

function New-EmbeddedProfileIconHtml {
    param([AllowNull()][object]$Profile)

    if ($null -eq $Profile) {
        return ""
    }

    $avatarText = ConvertTo-HtmlEncoded $Profile.AvatarIcon
    $dataUri = Convert-FileToDataUri -Path $Profile.IconPath
    if (-not [string]::IsNullOrWhiteSpace($dataUri)) {
        $alt = ConvertTo-HtmlEncoded ("{0} アイコン" -f $Profile.DisplayName)
        $encodedDataUri = ConvertTo-HtmlEncoded $dataUri
        $caption = ""
        if (-not [string]::IsNullOrWhiteSpace($avatarText)) {
            $caption = "<div class='avatar-text'>$avatarText</div>"
        }
        return "<img class='profile-icon' src='$encodedDataUri' alt='$alt'>$caption"
    }

    return $avatarText
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
            $iconSize = 48
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $memory = New-Object System.IO.MemoryStream(,$bytes)
            $image = [System.Drawing.Image]::FromStream($memory)
            $bitmap = New-Object System.Drawing.Bitmap($iconSize, $iconSize)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($image, 0, 0, $iconSize, $iconSize)
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
    $profileMetadata = Read-ProfileMetadata -UserDataPath $UserDataPath
    $profileMetadataMap = ConvertTo-ProfileMetadataMap -Metadata $profileMetadata
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
        $metadataEntry = $profileMetadataMap[$directoryName]
        if ($null -eq $metadataEntry) {
            $metadataEntry = [pscustomobject]@{ color_id = ""; memo1 = ""; memo2 = ""; updated_at = "" }
        }
        $colorInfo = Get-ProfileColorInfo -ColorId $metadataEntry.color_id
        $profiles.Add([pscustomobject]@{
            DirectoryName = [string]$directoryName
            DisplayName = [string]$displayName
            ProfileName = [string]$preferenceInfo.ProfileName
            UserName = [string]$userName
            GaiaName = [string]$gaiaName
            AvatarIcon = [string]$localStateInfo.AvatarIcon
            ColorId = [string]$colorInfo.Id
            ColorName = [string]$colorInfo.Name
            ColorHex = [string]$colorInfo.Hex
            Memo1 = [string]$metadataEntry.memo1
            Memo2 = [string]$metadataEntry.memo2
            IconPath = Get-ProfileIconPath -ProfilePath $path
            IconImage = if ($SkipIconImage) { $null } else { Get-ProfileIconImage -ProfilePath $path }
            Path = [string]$path
            SizeBytes = [int64]$sizeBytes
            SizeMB = [math]::Round($sizeBytes / 1MB, 2)
            LastWriteTime = $item.LastWriteTime
        })
        Write-UiLog "プロファイル検出: Directory=$directoryName DisplayName=$displayName User=$userName Color=$($colorInfo.Id) Path=$path Size=$sizeBytes" "DEBUG"
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
        $colorStyle = ""
        if (-not [string]::IsNullOrWhiteSpace($profile.ColorHex)) {
            $colorStyle = " style='background-color:$((ConvertTo-HtmlEncoded $profile.ColorHex));'"
        }
        $iconHtml = New-EmbeddedProfileIconHtml -Profile $profile

        [void]$rows.AppendLine("<tr>")
        [void]$rows.AppendLine("<td class='directory'>$((ConvertTo-HtmlEncoded $profile.DirectoryName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.DisplayName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.ProfileName))</td>")
        [void]$rows.AppendLine("<td class='email'>$((ConvertTo-HtmlEncoded $profile.UserName))</td>")
        [void]$rows.AppendLine("<td>$((ConvertTo-HtmlEncoded $profile.GaiaName))</td>")
        [void]$rows.AppendLine("<td class='avatar'>$iconHtml</td>")
        [void]$rows.AppendLine("<td class='color'$colorStyle>$((ConvertTo-HtmlEncoded $profile.ColorName))</td>")
        [void]$rows.AppendLine("<td class='memo'>$((ConvertTo-HtmlEncoded $profile.Memo1))</td>")
        [void]$rows.AppendLine("<td class='memo'>$((ConvertTo-HtmlEncoded $profile.Memo2))</td>")
        [void]$rows.AppendLine("<td class='number'>$($profile.SizeMB)</td>")
        [void]$rows.AppendLine("<td class='updated'>$((ConvertTo-HtmlEncoded (Format-LastWriteTimeWithAge -LastWriteTime $profile.LastWriteTime)))</td>")
        [void]$rows.AppendLine("<td class='path'><code>$((ConvertTo-HtmlEncoded $profile.Path))</code></td>")
        [void]$rows.AppendLine("</tr>")
    }

    return @"
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chromeプロファイル確認レポート</title>
<style>
body { font-family: "Segoe UI", Meiryo, sans-serif; margin: 0; color: #1f2933; background: #f7f9fb; }
main { width: min(100% - 32px, 1440px); margin: 0 auto; background: #fff; border: 1px solid #d9e2ec; padding: 24px; box-sizing: border-box; min-height: 100vh; }
h1 { margin: 0 0 14px; font-size: 24px; }
.meta { color: #52616b; line-height: 1.7; overflow-wrap: anywhere; }
.table-wrap { margin-top: 20px; overflow-x: auto; border: 1px solid #d9e2ec; }
table { width: 100%; min-width: 1680px; border-collapse: collapse; table-layout: auto; }
th, td { border: 1px solid #d9e2ec; padding: 7px 9px; vertical-align: top; overflow-wrap: anywhere; word-break: normal; font-size: 13px; }
th { position: sticky; top: 0; z-index: 1; background: #eef3f8; text-align: left; white-space: nowrap; }
.directory { min-width: 120px; }
.email { min-width: 180px; }
.avatar { min-width: 190px; }
.profile-icon { display: block; width: 48px; height: 48px; object-fit: cover; border-radius: 6px; border: 1px solid #d9e2ec; background: #fff; }
.avatar-text { margin-top: 6px; color: #52616b; font-size: 12px; overflow-wrap: anywhere; }
.color { min-width: 78px; text-align: center; font-weight: 600; }
.memo { min-width: 160px; }
.updated { min-width: 190px; white-space: nowrap; }
.path { min-width: 360px; }
.number { min-width: 86px; text-align: right; white-space: nowrap; }
code { font-family: Consolas, "Courier New", monospace; white-space: normal; overflow-wrap: anywhere; }
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
<div class="table-wrap">
<table>
<colgroup>
<col style="width: 130px;">
<col style="width: 150px;">
<col style="width: 150px;">
<col style="width: 210px;">
<col style="width: 160px;">
<col style="width: 220px;">
<col style="width: 90px;">
<col style="width: 180px;">
<col style="width: 180px;">
<col style="width: 96px;">
<col style="width: 200px;">
<col style="width: 420px;">
</colgroup>
<thead>
<tr>
<th>ディレクトリ</th>
<th>表示名</th>
<th>ProfileName</th>
<th>ログインユーザー</th>
<th>Google名</th>
<th>アイコン</th>
<th>色</th>
<th>メモ1</th>
<th>メモ2</th>
<th>サイズMB</th>
<th>更新日時</th>
<th>場所</th>
</tr>
</thead>
<tbody>
$($rows.ToString())
</tbody>
</table>
</div>
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

function New-BackupProgressState {
    return [hashtable]::Synchronized(@{
        Phase = "idle"
        Status = "待機中"
        IsIndeterminate = $false
        Percent = 0
        CurrentProfile = ""
        CurrentFile = ""
        ProfileIndex = 0
        TotalProfiles = 0
        ProcessedFiles = 0
        TotalFiles = 0
        AddedFiles = 0
        SkippedFiles = 0
        StartTimeTicks = 0
        ZipStartTimeTicks = 0
        Completed = $false
        Failed = $false
        ErrorMessage = ""
        ZipPath = ""
    })
}

function Set-BackupProgressState {
    param(
        [AllowNull()][hashtable]$ProgressState,
        [string]$Phase,
        [string]$Status,
        [AllowNull()][object]$IsIndeterminate,
        [AllowNull()][object]$Percent,
        [string]$CurrentProfile,
        [string]$CurrentFile,
        [AllowNull()][object]$ProfileIndex,
        [AllowNull()][object]$TotalProfiles,
        [AllowNull()][object]$ProcessedFiles,
        [AllowNull()][object]$TotalFiles,
        [AllowNull()][object]$AddedFiles,
        [AllowNull()][object]$SkippedFiles,
        [AllowNull()][object]$StartTimeTicks,
        [AllowNull()][object]$ZipStartTimeTicks,
        [AllowNull()][object]$Completed,
        [AllowNull()][object]$Failed,
        [string]$ErrorMessage,
        [string]$ZipPath
    )

    if ($null -eq $ProgressState) {
        return
    }

    if ($PSBoundParameters.ContainsKey("Phase")) { $ProgressState.Phase = $Phase }
    if ($PSBoundParameters.ContainsKey("Status")) { $ProgressState.Status = $Status }
    if ($PSBoundParameters.ContainsKey("IsIndeterminate") -and $null -ne $IsIndeterminate) { $ProgressState.IsIndeterminate = [bool]$IsIndeterminate }
    if ($PSBoundParameters.ContainsKey("Percent") -and $null -ne $Percent) { $ProgressState.Percent = [Math]::Max(0, [Math]::Min(100, [int]$Percent)) }
    if ($PSBoundParameters.ContainsKey("CurrentProfile")) { $ProgressState.CurrentProfile = $CurrentProfile }
    if ($PSBoundParameters.ContainsKey("CurrentFile")) { $ProgressState.CurrentFile = $CurrentFile }
    if ($PSBoundParameters.ContainsKey("ProfileIndex") -and $null -ne $ProfileIndex) { $ProgressState.ProfileIndex = [int]$ProfileIndex }
    if ($PSBoundParameters.ContainsKey("TotalProfiles") -and $null -ne $TotalProfiles) { $ProgressState.TotalProfiles = [int]$TotalProfiles }
    if ($PSBoundParameters.ContainsKey("ProcessedFiles") -and $null -ne $ProcessedFiles) { $ProgressState.ProcessedFiles = [int]$ProcessedFiles }
    if ($PSBoundParameters.ContainsKey("TotalFiles") -and $null -ne $TotalFiles) { $ProgressState.TotalFiles = [int]$TotalFiles }
    if ($PSBoundParameters.ContainsKey("AddedFiles") -and $null -ne $AddedFiles) { $ProgressState.AddedFiles = [int]$AddedFiles }
    if ($PSBoundParameters.ContainsKey("SkippedFiles") -and $null -ne $SkippedFiles) { $ProgressState.SkippedFiles = [int]$SkippedFiles }
    if ($PSBoundParameters.ContainsKey("StartTimeTicks") -and $null -ne $StartTimeTicks) { $ProgressState.StartTimeTicks = [int64]$StartTimeTicks }
    if ($PSBoundParameters.ContainsKey("ZipStartTimeTicks") -and $null -ne $ZipStartTimeTicks) { $ProgressState.ZipStartTimeTicks = [int64]$ZipStartTimeTicks }
    if ($PSBoundParameters.ContainsKey("Completed") -and $null -ne $Completed) { $ProgressState.Completed = [bool]$Completed }
    if ($PSBoundParameters.ContainsKey("Failed") -and $null -ne $Failed) { $ProgressState.Failed = [bool]$Failed }
    if ($PSBoundParameters.ContainsKey("ErrorMessage")) { $ProgressState.ErrorMessage = $ErrorMessage }
    if ($PSBoundParameters.ContainsKey("ZipPath")) { $ProgressState.ZipPath = $ZipPath }
}

function Get-BackupProgressPercent {
    param(
        [int]$ProcessedFiles,
        [int]$TotalFiles
    )

    if ($TotalFiles -le 0) {
        return 0
    }
    return [Math]::Max(0, [Math]::Min(100, [int][Math]::Floor(($ProcessedFiles / $TotalFiles) * 100)))
}

function Format-BackupRemainingTime {
    param([TimeSpan]$Remaining)

    if ($Remaining.TotalSeconds -lt 0) {
        $Remaining = [TimeSpan]::Zero
    }

    if ($Remaining.TotalHours -ge 1) {
        return "{0}時間{1:D2}分" -f [int][Math]::Floor($Remaining.TotalHours), $Remaining.Minutes
    }
    if ($Remaining.TotalMinutes -ge 1) {
        return "{0}分{1:D2}秒" -f [int][Math]::Floor($Remaining.TotalMinutes), $Remaining.Seconds
    }
    return "{0}秒" -f [Math]::Max(0, [int][Math]::Ceiling($Remaining.TotalSeconds))
}

function Get-BackupEstimatedRemainingText {
    param(
        [int]$ProcessedFiles,
        [int]$TotalFiles,
        [Int64]$ZipStartTimeTicks,
        [DateTime]$Now = (Get-Date)
    )

    if ($TotalFiles -le 0 -or $ProcessedFiles -le 0 -or $ZipStartTimeTicks -le 0) {
        return "計算中"
    }
    if ($ProcessedFiles -ge $TotalFiles) {
        return "0秒"
    }

    $start = New-Object DateTime($ZipStartTimeTicks)
    $elapsed = $Now - $start
    if ($elapsed.TotalSeconds -le 0) {
        return "計算中"
    }

    $secondsPerFile = $elapsed.TotalSeconds / $ProcessedFiles
    $remainingFiles = [Math]::Max(0, $TotalFiles - $ProcessedFiles)
    return (Format-BackupRemainingTime -Remaining ([TimeSpan]::FromSeconds($secondsPerFile * $remainingFiles)))
}

function Get-BackupProgressLabelText {
    param([AllowNull()][hashtable]$ProgressState)

    if ($null -eq $ProgressState) {
        return "ZIP待機中"
    }
    if ($ProgressState.Failed) {
        return "ZIP失敗: $($ProgressState.ErrorMessage)"
    }
    if ($ProgressState.Completed) {
        return "ZIP完了: 100%（$($ProgressState.ProcessedFiles) / $($ProgressState.TotalFiles)件） 残り約 0秒 / 追加:$($ProgressState.AddedFiles) スキップ:$($ProgressState.SkippedFiles)"
    }
    if ($ProgressState.IsIndeterminate -or [int]$ProgressState.TotalFiles -le 0) {
        return "$($ProgressState.Status): 進捗計算中 / 残り約 計算中 / 追加:$($ProgressState.AddedFiles) スキップ:$($ProgressState.SkippedFiles)"
    }

    $remaining = Get-BackupEstimatedRemainingText -ProcessedFiles ([int]$ProgressState.ProcessedFiles) -TotalFiles ([int]$ProgressState.TotalFiles) -ZipStartTimeTicks ([int64]$ProgressState.ZipStartTimeTicks)
    return "ZIP進捗: $($ProgressState.Percent)%（$($ProgressState.ProcessedFiles) / $($ProgressState.TotalFiles)件） 残り約 $remaining / 追加:$($ProgressState.AddedFiles) スキップ:$($ProgressState.SkippedFiles)"
}

function New-ProfilesZipBackup {
    param(
        [object[]]$Profiles,
        [string]$UserDataPath,
        [string]$BackupPath,
        [string]$Stage,
        [AllowNull()][hashtable]$ProgressState = $null
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    }

    $zipPath = Join-Path $BackupPath ("ChromeProfilesBackup_{0}_{1}.zip" -f $Stage, (Get-Date -Format "yyyyMMdd_HHmmss"))
    Write-UiLog "ZIPバックアップ作成開始: Stage=$Stage Path=$zipPath ProfileCount=$($Profiles.Count)" "INFO"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    $backupStartTicks = (Get-Date).Ticks
    Set-BackupProgressState -ProgressState $ProgressState -Phase "counting" -Status "ZIP対象ファイル確認中" -IsIndeterminate $true -TotalProfiles $Profiles.Count -ProcessedFiles 0 -TotalFiles 0 -AddedFiles 0 -SkippedFiles 0 -StartTimeTicks $backupStartTicks -ZipPath $zipPath

    $fileTasks = New-Object System.Collections.Generic.List[object]
    $localState = Join-Path $UserDataPath "Local State"
    if (Test-Path -LiteralPath $localState) {
        $fileTasks.Add([pscustomobject]@{ SourceFile = $localState; EntryName = "Local State"; ProfileName = ""; ProfileIndex = 0 }) | Out-Null
    }

    $metadataPath = Get-ProfileMetadataPath -UserDataPath $UserDataPath
    if (Test-Path -LiteralPath $metadataPath) {
        $fileTasks.Add([pscustomobject]@{ SourceFile = $metadataPath; EntryName = "ChromeProfilesManager/profile_metadata.json"; ProfileName = ""; ProfileIndex = 0 }) | Out-Null
    }

    $profileIndex = 0
    foreach ($profile in $Profiles) {
        $profileIndex++
        Write-UiLog "ZIP対象確認中: $($profile.DirectoryName) ($profileIndex / $($Profiles.Count))" "INFO"
        Set-BackupProgressState -ProgressState $ProgressState -Phase "counting" -Status "ZIP対象ファイル確認中" -CurrentProfile $profile.DirectoryName -ProfileIndex $profileIndex
        $root = $profile.Path
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            Write-UiLog "ZIP対象プロファイルが見つかりません: $($profile.DirectoryName) Path=$root" "WARN"
            continue
        }
        $rootLength = $root.TrimEnd("\").Length
        Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $relative = $_.FullName.Substring($rootLength).TrimStart("\")
                $entryName = Join-Path ("Profiles\" + $profile.DirectoryName) $relative
                $fileTasks.Add([pscustomobject]@{ SourceFile = $_.FullName; EntryName = $entryName; ProfileName = $profile.DirectoryName; ProfileIndex = $profileIndex }) | Out-Null
            }
    }

    $html = New-ProfileIndexHtmlText -Profiles $Profiles -UserDataPath $UserDataPath -Stage $Stage
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    $added = 0
    $skipped = 0
    $processed = 0
    $totalFiles = $fileTasks.Count + 1
    $zipStartTicks = (Get-Date).Ticks

    try {
        Write-UiLog "ZIPへ追加中: ChromeProfilesReport.html" "DEBUG"
        Set-BackupProgressState -ProgressState $ProgressState -Phase "zipping" -Status "ZIP作成中" -IsIndeterminate $false -Percent 0 -ProcessedFiles 0 -TotalFiles $totalFiles -ZipStartTimeTicks $zipStartTicks -CurrentProfile "" -CurrentFile "ChromeProfilesReport.html"
        $htmlEntry = $zip.CreateEntry("ChromeProfilesReport.html", [System.IO.Compression.CompressionLevel]::Optimal)
        $writer = New-Object System.IO.StreamWriter($htmlEntry.Open(), [System.Text.Encoding]::UTF8)
        try {
            $writer.Write($html)
        } finally {
            $writer.Dispose()
        }
        $added++
        $processed++
        Set-BackupProgressState -ProgressState $ProgressState -Phase "zipping" -Status "ZIP作成中" -Percent (Get-BackupProgressPercent -ProcessedFiles $processed -TotalFiles $totalFiles) -ProcessedFiles $processed -TotalFiles $totalFiles -AddedFiles $added -SkippedFiles $skipped

        foreach ($task in $fileTasks) {
            $currentProfile = [string]$task.ProfileName
            $currentFile = [string]$task.EntryName
            Write-UiLog "ZIPへ追加中: $currentFile" "DEBUG"

            if (Add-FileToZip -Zip $zip -SourceFile $task.SourceFile -EntryName $task.EntryName) {
                $added++
            } else {
                $skipped++
            }
            $processed++
            Set-BackupProgressState -ProgressState $ProgressState -Phase "zipping" -Status "ZIP作成中" -CurrentProfile $currentProfile -CurrentFile $currentFile -ProfileIndex ([int]$task.ProfileIndex) -Percent (Get-BackupProgressPercent -ProcessedFiles $processed -TotalFiles $totalFiles) -ProcessedFiles $processed -TotalFiles $totalFiles -AddedFiles $added -SkippedFiles $skipped
        }
    } finally {
        $zip.Dispose()
    }

    Write-UiLog "ZIPバックアップ作成完了: Path=$zipPath Added=$added Skipped=$skipped" "INFO"
    Set-BackupProgressState -ProgressState $ProgressState -Phase "completed" -Status "ZIPバックアップ作成完了" -IsIndeterminate $false -Percent 100 -ProcessedFiles $processed -TotalFiles $totalFiles -AddedFiles $added -SkippedFiles $skipped -Completed $true -ZipPath $zipPath
    return [pscustomobject]@{
        ZipPath = $zipPath
        AddedFiles = $added
        SkippedFiles = $skipped
        TotalFiles = $totalFiles
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

function Select-ZipListItem {
    param([string]$ZipPath)

    if ($null -eq $script:ZipListBox -or [string]::IsNullOrWhiteSpace($ZipPath)) {
        return $false
    }

    for ($i = 0; $i -lt $script:ZipListBox.Items.Count; $i++) {
        if ([string]$script:ZipListBox.Items[$i] -eq $ZipPath) {
            $script:ZipListBox.SelectedIndex = $i
            return $true
        }
    }
    return $false
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
            $profile.ColorId,
            $profile.Memo1,
            $profile.Memo2,
            $profile.SizeMB,
            (Format-LastWriteTimeWithAge -LastWriteTime $profile.LastWriteTime),
            $profile.Path
        )
        $script:ProfilesGrid.Rows[$rowIndex].Tag = $profile
        Apply-ProfileRowStyle -Row $script:ProfilesGrid.Rows[$rowIndex]
    }
}

function Apply-ProfileRowStyle {
    param([System.Windows.Forms.DataGridViewRow]$Row)

    if ($null -eq $Row -or $null -eq $Row.Tag) {
        return
    }

    $colorInfo = Get-ProfileColorInfo -ColorId $Row.Tag.ColorId
    if ([string]::IsNullOrWhiteSpace($colorInfo.Hex)) {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
        $Row.Cells["ColorId"].Style.BackColor = [System.Drawing.Color]::White
    } else {
        $color = [System.Drawing.ColorTranslator]::FromHtml($colorInfo.Hex)
        $Row.DefaultCellStyle.BackColor = $color
        $Row.Cells["ColorId"].Style.BackColor = $color
    }
}

function Save-ProfileMetadataFromRow {
    param([System.Windows.Forms.DataGridViewRow]$Row)

    if ($null -eq $Row -or $Row.IsNewRow -or $null -eq $Row.Tag) {
        return
    }

    $profile = $Row.Tag
    $colorId = [string]$Row.Cells["ColorId"].Value
    $memo1 = [string]$Row.Cells["Memo1"].Value
    $memo2 = [string]$Row.Cells["Memo2"].Value
    $colorInfo = Get-ProfileColorInfo -ColorId $colorId

    $profile.ColorId = [string]$colorInfo.Id
    $profile.ColorName = [string]$colorInfo.Name
    $profile.ColorHex = [string]$colorInfo.Hex
    $profile.Memo1 = $memo1
    $profile.Memo2 = $memo2
    Apply-ProfileRowStyle -Row $Row

    Set-ProfileMetadataEntry -UserDataPath $script:UserDataTextBox.Text.Trim() -DirectoryName $profile.DirectoryName -ColorId $profile.ColorId -Memo1 $memo1 -Memo2 $memo2
}

function Set-SelectedProfileColor {
    param([AllowNull()][string]$ColorId)

    if ($null -eq $script:ProfilesGrid.CurrentRow -or $null -eq $script:ProfilesGrid.CurrentRow.Tag) {
        [System.Windows.Forms.MessageBox]::Show("色を設定するプロファイル行を選択してください。", $script:AppName) | Out-Null
        return
    }

    $row = $script:ProfilesGrid.CurrentRow
    $row.Cells["ColorId"].Value = [string]$ColorId
    Save-ProfileMetadataFromRow -Row $row
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

function Test-BackupBusy {
    return ($script:BackupState -and -not $script:BackupState.AsyncResult.IsCompleted)
}

function Set-BackupBusy {
    param([bool]$Busy)

    foreach ($button in @($script:InitialBackupButton, $script:PostCleanupBackupButton)) {
        if ($button) {
            $button.Enabled = -not $Busy
        }
    }

    if ($script:BackupProgressBar) {
        if ($Busy) {
            $script:BackupProgressBar.Visible = $true
        } else {
            $script:BackupProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $script:BackupProgressBar.Value = 0
        }
    }

    if ($script:BackupProgressLabel -and -not $Busy) {
        $script:BackupProgressLabel.Text = "ZIP待機中"
        $script:BackupProgressLabel.ForeColor = [System.Drawing.Color]::DimGray
    }
}

function Update-BackupProgressUi {
    param([AllowNull()][hashtable]$ProgressState)

    if ($null -eq $ProgressState) {
        return
    }

    if ($script:BackupProgressBar) {
        if ($ProgressState.IsIndeterminate) {
            $script:BackupProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $script:BackupProgressBar.MarqueeAnimationSpeed = 30
        } else {
            $script:BackupProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $script:BackupProgressBar.MarqueeAnimationSpeed = 0
            $value = [int]$ProgressState.Percent
            $script:BackupProgressBar.Value = [Math]::Max($script:BackupProgressBar.Minimum, [Math]::Min($script:BackupProgressBar.Maximum, $value))
        }
    }

    if ($script:BackupProgressLabel) {
        $script:BackupProgressLabel.Text = Get-BackupProgressLabelText -ProgressState $ProgressState
        if ($ProgressState.Failed) {
            $script:BackupProgressLabel.ForeColor = [System.Drawing.Color]::DarkRed
        } elseif ($ProgressState.Completed) {
            $script:BackupProgressLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $script:BackupProgressLabel.ForeColor = [System.Drawing.Color]::DarkOrange
        }
    }
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
        "Get-ProfileColorPalette",
        "Get-ProfileColorInfo",
        "Get-ManagerDataPath",
        "Get-ProfileMetadataPath",
        "New-ProfileMetadataDocument",
        "ConvertTo-ProfileMetadataMap",
        "Read-ProfileMetadata",
        "Get-ChromeProfiles",
        "Write-UiLog",
        "Test-ShouldWriteLogToUi",
        "Read-Utf8JsonFile",
        "Write-Utf8JsonFile"
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
    if (Test-BackupBusy) {
        [System.Windows.Forms.MessageBox]::Show("ZIPバックアップ作成中です。完了後に実行してください。", $script:AppName) | Out-Null
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
    Set-BackupBusy -Busy $true

    $userDataPath = $script:UserDataTextBox.Text.Trim()
    $backupPath = $script:BackupPathTextBox.Text.Trim()
    $progressState = New-BackupProgressState
    Set-BackupProgressState -ProgressState $progressState -Phase "starting" -Status "$Stage バックアップを開始しています..." -IsIndeterminate $true -TotalProfiles $profiles.Count
    Update-BackupProgressUi -ProgressState $progressState

    $workerProfiles = @($profiles | ForEach-Object {
        [pscustomobject]@{
            DirectoryName = [string]$_.DirectoryName
            DisplayName = [string]$_.DisplayName
            ProfileName = [string]$_.ProfileName
            UserName = [string]$_.UserName
            GaiaName = [string]$_.GaiaName
            AvatarIcon = [string]$_.AvatarIcon
            ColorId = [string]$_.ColorId
            ColorName = [string]$_.ColorName
            ColorHex = [string]$_.ColorHex
            Memo1 = [string]$_.Memo1
            Memo2 = [string]$_.Memo2
            IconPath = [string]$_.IconPath
            Path = [string]$_.Path
            SizeBytes = [int64]$_.SizeBytes
            SizeMB = $_.SizeMB
            LastWriteTime = $_.LastWriteTime
        }
    })

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
    $functionText = ($functionNames | ForEach-Object {
        "function $_ {`r`n$((Get-Command $_ -CommandType Function).Definition)`r`n}"
    }) -join "`r`n"

    $workerScript = @"
param([object[]]`$WorkerProfiles, [string]`$WorkerUserDataPath, [string]`$WorkerBackupPath, [string]`$WorkerStage, [hashtable]`$WorkerProgressState, [string]`$WorkerLogFilePath)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
`$script:LogBox = `$null
`$script:LogFilePath = `$WorkerLogFilePath
`$script:ShowDebugLogsInUi = `$false
$functionText
try {
    New-ProfilesZipBackup -Profiles `$WorkerProfiles -UserDataPath `$WorkerUserDataPath -BackupPath `$WorkerBackupPath -Stage `$WorkerStage -ProgressState `$WorkerProgressState
} catch {
    Set-BackupProgressState -ProgressState `$WorkerProgressState -Phase "failed" -Status "ZIPバックアップに失敗しました" -IsIndeterminate `$false -Failed `$true -ErrorMessage `$_.Exception.Message
    throw
}
"@

    $powerShell = [System.Management.Automation.PowerShell]::Create()
    [void]$powerShell.AddScript($workerScript).AddArgument($workerProfiles).AddArgument($userDataPath).AddArgument($backupPath).AddArgument($Stage).AddArgument($progressState).AddArgument($script:LogFilePath)
    $asyncResult = $powerShell.BeginInvoke()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        if (-not $script:BackupState) {
            return
        }

        Update-BackupProgressUi -ProgressState $script:BackupState.ProgressState
        if (-not $script:BackupState.AsyncResult.IsCompleted) {
            return
        }

        $script:BackupState.Timer.Stop()
        try {
            $result = $script:BackupState.PowerShell.EndInvoke($script:BackupState.AsyncResult) | Select-Object -First 1
            Update-BackupProgressUi -ProgressState $script:BackupState.ProgressState
            Write-UiLog "バックアップを作成しました: $($result.ZipPath)"
            Write-UiLog "追加ファイル: $($result.AddedFiles); スキップ: $($result.SkippedFiles); 対象: $($result.TotalFiles)"
            Refresh-ZipList
            [void](Select-ZipListItem -ZipPath $result.ZipPath)
            $inspectResult = [System.Windows.Forms.MessageBox]::Show(
                "バックアップを作成しました:`r`n$($result.ZipPath)`r`n`r`nこのZIPの内容を確認しますか？",
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            if ($inspectResult -eq [System.Windows.Forms.DialogResult]::Yes) {
                Inspect-SelectedZip
            }
        } catch {
            Set-BackupProgressState -ProgressState $script:BackupState.ProgressState -Phase "failed" -Status "ZIPバックアップに失敗しました" -IsIndeterminate $false -Failed $true -ErrorMessage $_.Exception.Message
            Update-BackupProgressUi -ProgressState $script:BackupState.ProgressState
            Write-UiLog "バックアップに失敗しました: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("バックアップに失敗しました:`r`n$($_.Exception.Message)", $script:AppName, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } finally {
            $script:BackupState.PowerShell.Dispose()
            $script:BackupState.Timer.Dispose()
            $script:BackupState = $null
            Set-BackupBusy -Busy $false
            $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $script:BackupState = [pscustomobject]@{
        PowerShell = $powerShell
        AsyncResult = $asyncResult
        Timer = $timer
        ProgressState = $progressState
    }
    Write-UiLog "$Stage バックアップを開始しました。進捗は画面に表示します。"
    $timer.Start()
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

function Open-SelectedZipFile {
    $zipPath = [string]$script:ZipListBox.SelectedItem
    if ([string]::IsNullOrWhiteSpace($zipPath) -or -not (Test-Path -LiteralPath $zipPath)) {
        [System.Windows.Forms.MessageBox]::Show("開くZIPを選択してください。", $script:AppName) | Out-Null
        return
    }
    Open-PathInExplorer -Path $zipPath
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
$rootPanel.RowCount = 3
$rootPanel.Padding = New-Object System.Windows.Forms.Padding(10)
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 92)))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
$rootPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
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
$actionPanel.WrapContents = $true
$rootPanel.Controls.Add($actionPanel, 0, 1)

$script:MainSplit = New-Object System.Windows.Forms.SplitContainer
$script:MainSplit.Dock = "Fill"
$script:MainSplit.Orientation = "Horizontal"
$script:MainSplit.SplitterWidth = 6
$script:MainSplit.Panel1MinSize = 160
$script:MainSplit.Panel2MinSize = 160
$script:MainSplit.SplitterDistance = 420
$rootPanel.Controls.Add($script:MainSplit, 0, 2)

$script:BottomSplit = New-Object System.Windows.Forms.SplitContainer
$script:BottomSplit.Dock = "Fill"
$script:BottomSplit.Orientation = "Horizontal"
$script:BottomSplit.SplitterWidth = 6
$script:BottomSplit.Panel1MinSize = 100
$script:BottomSplit.Panel2MinSize = 70
$script:BottomSplit.SplitterDistance = 260
$script:MainSplit.Panel2.Controls.Add($script:BottomSplit)

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

$script:InitialBackupButton = New-Object System.Windows.Forms.Button
$script:InitialBackupButton.Text = "初回ZIP保存"
$script:InitialBackupButton.Width = 115
$script:InitialBackupButton.Add_Click({ Start-Backup -Stage "initial" })
$actionPanel.Controls.Add($script:InitialBackupButton)

$script:PostCleanupBackupButton = New-Object System.Windows.Forms.Button
$script:PostCleanupBackupButton.Text = "清掃後ZIP保存"
$script:PostCleanupBackupButton.Width = 125
$script:PostCleanupBackupButton.Add_Click({ Start-Backup -Stage "post-cleanup" })
$actionPanel.Controls.Add($script:PostCleanupBackupButton)

$script:BackupProgressBar = New-Object System.Windows.Forms.ProgressBar
$script:BackupProgressBar.Width = 180
$script:BackupProgressBar.Height = 18
$script:BackupProgressBar.Minimum = 0
$script:BackupProgressBar.Maximum = 100
$script:BackupProgressBar.Value = 0
$script:BackupProgressBar.Margin = New-Object System.Windows.Forms.Padding(10, 9, 4, 0)
$actionPanel.Controls.Add($script:BackupProgressBar)

$script:BackupProgressLabel = New-Object System.Windows.Forms.Label
$script:BackupProgressLabel.Text = "ZIP待機中"
$script:BackupProgressLabel.AutoSize = $true
$script:BackupProgressLabel.Margin = New-Object System.Windows.Forms.Padding(4, 10, 10, 0)
$script:BackupProgressLabel.ForeColor = [System.Drawing.Color]::DimGray
$actionPanel.Controls.Add($script:BackupProgressLabel)

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

$colorLabel = New-Object System.Windows.Forms.Label
$colorLabel.Text = "選択行の色:"
$colorLabel.AutoSize = $true
$colorLabel.Margin = New-Object System.Windows.Forms.Padding(12, 10, 4, 0)
$actionPanel.Controls.Add($colorLabel)

foreach ($colorInfo in (Get-ProfileColorPalette)) {
    $colorButton = New-Object System.Windows.Forms.Button
    $colorButton.Width = if ([string]::IsNullOrWhiteSpace($colorInfo.Id)) { 48 } else { 30 }
    $colorButton.Height = 24
    $colorButton.Text = if ([string]::IsNullOrWhiteSpace($colorInfo.Id)) { "なし" } else { $colorInfo.Name }
    $colorButton.Tag = $colorInfo.Id
    $colorButton.Margin = New-Object System.Windows.Forms.Padding(2, 7, 2, 0)
    if (-not [string]::IsNullOrWhiteSpace($colorInfo.Hex)) {
        $colorButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml($colorInfo.Hex)
        $colorButton.FlatStyle = "Flat"
    }
    $colorButton.Add_Click({
        param($Sender, $EventArgs)
        Set-SelectedProfileColor -ColorId ([string]$Sender.Tag)
    })
    $actionPanel.Controls.Add($colorButton)
}

$script:ProfilesGrid = New-Object System.Windows.Forms.DataGridView
$script:ProfilesGrid.Dock = "Fill"
$script:ProfilesGrid.AllowUserToAddRows = $false
$script:ProfilesGrid.AllowUserToDeleteRows = $false
$script:ProfilesGrid.RowHeadersVisible = $false
$script:ProfilesGrid.SelectionMode = "FullRowSelect"
$script:ProfilesGrid.MultiSelect = $false
$script:ProfilesGrid.AutoSizeColumnsMode = "Fill"
$script:ProfilesGrid.EditMode = "EditOnEnter"
$script:ProfilesGrid.RowTemplate.Height = 54

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
$iconColumn.FillWeight = 14
[void]$script:ProfilesGrid.Columns.Add($iconColumn)
[void]$script:ProfilesGrid.Columns.Add("DirectoryName", "ディレクトリ")
[void]$script:ProfilesGrid.Columns.Add("DisplayName", "表示名")
[void]$script:ProfilesGrid.Columns.Add("ProfileName", "ProfileName")
[void]$script:ProfilesGrid.Columns.Add("UserName", "ログインユーザー")
[void]$script:ProfilesGrid.Columns.Add("GaiaName", "Google名")
[void]$script:ProfilesGrid.Columns.Add("AvatarIcon", "アイコン情報")
$colorColumn = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colorColumn.Name = "ColorId"
$colorColumn.HeaderText = "色"
$colorColumn.ValueMember = "Id"
$colorColumn.DisplayMember = "DisplayName"
$colorColumn.DataSource = [System.Collections.ArrayList](Get-ProfileColorPalette)
$colorColumn.DisplayStyle = "DropDownButton"
$colorColumn.FlatStyle = "Flat"
[void]$script:ProfilesGrid.Columns.Add($colorColumn)
[void]$script:ProfilesGrid.Columns.Add("Memo1", "メモ1")
[void]$script:ProfilesGrid.Columns.Add("Memo2", "メモ2")
[void]$script:ProfilesGrid.Columns.Add("SizeMB", "サイズMB")
[void]$script:ProfilesGrid.Columns.Add("LastWriteTime", "更新日時")
[void]$script:ProfilesGrid.Columns.Add("Path", "場所")
$script:ProfilesGrid.Columns["DirectoryName"].FillWeight = 16
$script:ProfilesGrid.Columns["DisplayName"].FillWeight = 18
$script:ProfilesGrid.Columns["ProfileName"].FillWeight = 18
$script:ProfilesGrid.Columns["UserName"].FillWeight = 24
$script:ProfilesGrid.Columns["GaiaName"].FillWeight = 18
$script:ProfilesGrid.Columns["AvatarIcon"].FillWeight = 22
$script:ProfilesGrid.Columns["ColorId"].FillWeight = 10
$script:ProfilesGrid.Columns["Memo1"].FillWeight = 22
$script:ProfilesGrid.Columns["Memo2"].FillWeight = 22
$script:ProfilesGrid.Columns["SizeMB"].FillWeight = 10
$script:ProfilesGrid.Columns["LastWriteTime"].FillWeight = 18
$script:ProfilesGrid.Columns["Path"].FillWeight = 46
foreach ($column in $script:ProfilesGrid.Columns) {
    $column.ReadOnly = $true
}
$script:ProfilesGrid.Columns["SelectColumn"].ReadOnly = $false
$script:ProfilesGrid.Columns["ColorId"].ReadOnly = $false
$script:ProfilesGrid.Columns["Memo1"].ReadOnly = $false
$script:ProfilesGrid.Columns["Memo2"].ReadOnly = $false
$script:ProfilesGrid.Add_CurrentCellDirtyStateChanged({
    if ($script:ProfilesGrid.IsCurrentCellDirty) {
        $script:ProfilesGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})
$script:ProfilesGrid.Add_CellValueChanged({
    param($Sender, $EventArgs)
    if ($EventArgs.RowIndex -lt 0 -or $EventArgs.ColumnIndex -lt 0) {
        return
    }
    $columnName = $script:ProfilesGrid.Columns[$EventArgs.ColumnIndex].Name
    if ($columnName -in @("ColorId", "Memo1", "Memo2")) {
        Save-ProfileMetadataFromRow -Row $script:ProfilesGrid.Rows[$EventArgs.RowIndex]
    }
})
$script:ProfilesGrid.Add_EditingControlShowing({
    param($Sender, $EventArgs)

    if ($null -eq $script:ProfilesGrid.CurrentCell) {
        return
    }

    $columnName = $script:ProfilesGrid.Columns[$script:ProfilesGrid.CurrentCell.ColumnIndex].Name
    if ($columnName -eq "ColorId" -and $EventArgs.Control -is [System.Windows.Forms.ComboBox]) {
        Set-ProfileColorComboBoxOwnerDraw -ComboBox $EventArgs.Control
    }
})
$script:ProfilesGrid.Add_DataError({
    param($Sender, $EventArgs)
    Write-UiLog "プロファイル一覧のセル編集でエラー: $($EventArgs.Exception.Message)" "WARN"
    $EventArgs.ThrowException = $false
})
$script:MainSplit.Panel1.Controls.Add($script:ProfilesGrid)

$zipSplit = New-Object System.Windows.Forms.SplitContainer
$zipSplit.Dock = "Fill"
$zipSplit.Orientation = "Vertical"
$zipSplit.SplitterDistance = 390
$script:BottomSplit.Panel1.Controls.Add($zipSplit)

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

$openZipButton = New-Object System.Windows.Forms.Button
$openZipButton.Text = "ZIPを開く"
$openZipButton.Width = 82
$openZipButton.Add_Click({ Open-SelectedZipFile })
$zipHeaderPanel.Controls.Add($openZipButton)

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
$script:BottomSplit.Panel2.Controls.Add($script:LogBox)

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
