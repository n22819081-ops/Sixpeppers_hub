# SixesHub MediaMaintenance patched v6.1 (auto-close console tasks; remove Press-Enter prompts)
# PATCHED_V5 - fixed $Tag: parsing issue; verify with Get-FileHash
param(
    [string]$AutoAction = ""
)


# Patched v4: fixed Tag-colon parsing issue
<#
    Sixes Hub - Media + Maintenance Edition (Safe Build)
    ----------------------------------------------------
    What this script does:
    - GUI hub (WinForms) for installing apps (winget)
    - Maintenance tools (updates, optimize, disk scan, repair)
    - Smart Boost (safe cleanup) in an elevated console window
    - Music tools:
        - Install Spotify (official) via winget
        - Install Spicetify (themes/extensions)
        - MP3 downloader (yt-dlp + ffmpeg)
        - Custom Script Runner (advanced)  <-- you paste your own command
    - Movies tools:
        - MP4 downloader (yt-dlp)
        - Mini-browser (embedded WebBrowser)
    - Convert tools (ffmpeg, imagemagick, libreoffice, poppler, pandoc, tesseract)
    - Unzip (zip + rar via WinRAR)

    Notes:
    - This build does NOT ship a one-click "Spotify ad bypass" installer.
      It DOES include a Custom Script Runner where YOU paste YOUR command.
      That makes this tool general-purpose and keeps distribution safe.

    Recommended run:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\SixesHub.ps1

#>

# ----------------------------
# Globals / Setup
# ----------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir     = Join-Path $ScriptDir "logs"
$ConfigPath = Join-Path $ScriptDir "config.json"

if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# App folders
$DownloadsRoot = Join-Path $ScriptDir "Downloads"
$MusicDir = Join-Path $DownloadsRoot "Music"
$MoviesDir = Join-Path $DownloadsRoot "Movies"
$ScriptsDir = Join-Path $ScriptDir "scripts"
foreach ($p in @($DownloadsRoot,$MusicDir,$MoviesDir,$ScriptsDir)) {
    if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$LogFile = Join-Path $LogDir ("Log_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Storage for Custom Script Runner (so we can hand it off to an elevated process)
$AppDataRoot = Join-Path $env:LOCALAPPDATA "SixesHub"
if (!(Test-Path $AppDataRoot)) { New-Item -ItemType Directory -Path $AppDataRoot -Force | Out-Null }
$CustomScriptPath = Join-Path $AppDataRoot "custom_script.txt"
function Write-Log {
    param([string]$Message)

    $ts   = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $Message"

    try {
        Add-Content -Path $LogFile -Value $line -ErrorAction Stop
    } catch {
        # If logging to file fails, still try to show it in the UI/console.
    }

    if ($global:txtLog -and -not $global:txtLog.IsDisposed) {
        $text = $line + "`r`n"
        $tb = $global:txtLog

        try {
            if ($tb.InvokeRequired) {
                $null = $tb.BeginInvoke([Action]{
                    try {
                        $tb.AppendText($text)
                        $tb.SelectionStart = $tb.TextLength
                        $tb.ScrollToCaret()
                    } catch { }
                })
            } else {
                $tb.AppendText($text)
                $tb.SelectionStart = $tb.TextLength
                $tb.ScrollToCaret()
            }
        } catch { }
    } else {
        Write-Host $line
    }
}

function Write-LogError {
    param([string]$Message)
    Write-Log ("ERROR: " + $Message)
}

function Write-LogWarn {
    param([string]$Message)
    Write-Log ("WARN: " + $Message)
}

function Invoke-UI {
    param([scriptblock]$Script)
    if ($global:MainForm -and -not $global:MainForm.IsDisposed) {
        try {
            if ($global:MainForm.InvokeRequired) {
                $sb = $Script
                $null = $global:MainForm.BeginInvoke([Action]{ & $sb })
            } else {
                & $Script
            }
        } catch {
            # Last resort: run without UI marshaling
            & $Script
        }
    } else {
        & $Script
    }
}

function Invoke-Safely {
    param(
        [scriptblock]$Script,
        [string]$Context = "Action"
    )
    try {
        & $Script
    } catch {
        $msg = $_.Exception.Message
        Write-LogError "$Context failed: $msg"
        try {
            [System.Windows.Forms.MessageBox]::Show("$Context failed.`r`n$msg","Error") | Out-Null
        } catch { }
    }
}

function Test-ValidUrl {
    param([string]$Url)
    try {
        $u = [Uri]$Url
        return ($u.Scheme -in @("http","https")) -and (-not [string]::IsNullOrWhiteSpace($u.Host))
    } catch {
        return $false
    }
}

function Start-ExternalProcessAsync {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = "",
        [string]$Tag = "process",
        [scriptblock]$OnExit
    )

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FilePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow = $true

        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

        $argListProp = $psi.GetType().GetProperty("ArgumentList")
if ($argListProp) {
    foreach ($a in $ArgumentList) {
        if ($null -ne $a -and $a -ne "") {
            [void]$psi.ArgumentList.Add([string]$a)
        }
    }
} else {
    # Windows PowerShell 5.1 fallback (no ArgumentList property)
    $parts = @()
    foreach ($a in $ArgumentList) {
        if ($null -eq $a -or $a -eq "") { continue }
        $s = [string]$a
        if ($s -match '\\s|"') {
            $s = '"' + ($s -replace '"','\"') + '"'
        }
        $parts += $s
    }
    $psi.Arguments = ($parts -join ' ')
}

        $p = [System.Diagnostics.Process]::new()
        $p.StartInfo = $psi
        $p.EnableRaisingEvents = $true

        $p.add_OutputDataReceived({
            param($s,$e)
            if ($e.Data) { Write-Log ("{0}: {1}" -f $Tag, $e.Data) }
        })

        $p.add_ErrorDataReceived({
            param($s,$e)
            if ($e.Data) { Write-LogWarn ("{0}: {1}" -f $Tag, $e.Data) }
        })

        $p.add_Exited({
            param($s,$e)
            $code = 0
            try { $code = $s.ExitCode } catch { }
            Write-Log "$Tag exited with code $code"
            if ($OnExit) {
                $cb = $OnExit
                Invoke-UI { & $cb $code }
            }
        })

        [void]$p.Start()
        $p.BeginOutputReadLine()
        $p.BeginErrorReadLine()

        return $p
    } catch {
        Write-LogError "$Tag could not start ($FilePath): $($_.Exception.Message)"
        return $null
    }
}


function Normalize-Config {
    param($Cfg)

    if ($null -eq $Cfg) { $Cfg = [pscustomobject]@{} }

    $names = @($Cfg.PSObject.Properties.Name)

    if ($names -notcontains "windowTitle")        { $Cfg | Add-Member -NotePropertyName windowTitle        -NotePropertyValue "Sixes Hub" -Force }
    if ($names -notcontains "darkMode")           { $Cfg | Add-Member -NotePropertyName darkMode           -NotePropertyValue $false -Force }
    if ($names -notcontains "enableChocolatey")   { $Cfg | Add-Member -NotePropertyName enableChocolatey   -NotePropertyValue $false -Force }
    if ($names -notcontains "wingetExclusions")   { $Cfg | Add-Member -NotePropertyName wingetExclusions   -NotePropertyValue @() -Force }
    if ($names -notcontains "apps")               { $Cfg | Add-Member -NotePropertyName apps               -NotePropertyValue @() -Force }
    if ($names -notcontains "websites")           { $Cfg | Add-Member -NotePropertyName websites           -NotePropertyValue @() -Force }
    if ($names -notcontains "movieSites")         { $Cfg | Add-Member -NotePropertyName movieSites         -NotePropertyValue @() -Force }

    return $Cfg
}

function Load-Config {
    if (!(Test-Path $ConfigPath)) {
        Write-Host "config.json not found at: $ConfigPath" -ForegroundColor Red
        Write-Host "Create config.json first (you can copy config.sample.json), then rerun."
        exit 1
    }

    try {
        $cfg = (Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json)
        return (Normalize-Config -Cfg $cfg)
    } catch {
        Write-Host "Error parsing config.json. Fix JSON syntax and rerun." -ForegroundColor Red
        exit 1
    }
}

function Save-Config {
    param($Cfg)
    try {
        ($Cfg | ConvertTo-Json -Depth 8) | Set-Content -Path $ConfigPath -Encoding UTF8
        Write-Log "Saved config.json"
    } catch {
        Write-Log "ERROR: Failed to save config.json"
    }
}

$script:Config = Load-Config

function Check-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Relaunch-Admin {
    param([string]$Action)
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Action) { $args += " -AutoAction `"$Action`"" }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args -WindowStyle Minimized | Out-Null
    } catch {
        Write-Log "Admin elevation cancelled."
    }
}

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    $wa = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    if ($env:Path -notlike "*$wa*") { $env:Path = "$wa;$env:Path" }
}

function Ensure-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }

    Write-Host "Winget is missing. Install 'App Installer' from Microsoft Store." -ForegroundColor Yellow
    Start-Process "ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1" | Out-Null
    return $false
}

function Install-WingetId {
    param(
        [Parameter(Mandatory=$true)][string]$WingetId
    )
    if (-not (Ensure-Winget)) { return $false }

    Write-Log "Winget install: $WingetId"
    $p = Start-Process winget -NoNewWindow -PassThru -Wait -ArgumentList @(
        "install","-e","--id",$WingetId,
        "--accept-package-agreements","--accept-source-agreements",
        "--silent"
    )

    Refresh-Path
    return ($p.ExitCode -eq 0)
}

function Ensure-Tool {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string]$Friendly,
        [Parameter(Mandatory=$true)][string]$WingetId
    )

    Refresh-Path
    if (Get-Command $Exe -ErrorAction SilentlyContinue) { return $true }

    $msg = "$Friendly is missing.`n`nSixes Hub can install it automatically.`nProceed?"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, "Install Required Tool", "YesNo", "Question")
    if ($r -ne "Yes") { return $false }

    $ok = Install-WingetId -WingetId $WingetId
    if (-not $ok) {
        [System.Windows.Forms.MessageBox]::Show("Winget failed installing $Friendly.", "Install Failed", "OK", "Error") | Out-Null
        return $false
    }

    Refresh-Path
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show(
            "$Friendly installed, but Windows did not expose it to this process yet.`n`nClose Sixes Hub and reopen it, then try again.",
            "Restart Needed","OK","Information"
        ) | Out-Null
        return $false
    }

    return $true
}

# Convenience ensure functions
function Ensure-YtDlp       { return (Ensure-Tool -Exe "yt-dlp"   -Friendly "yt-dlp"       -WingetId "yt-dlp.yt-dlp") }
function Ensure-FFmpeg      { return (Ensure-Tool -Exe "ffmpeg"   -Friendly "FFmpeg"       -WingetId "Gyan.FFmpeg") }
function Ensure-ImageMagick { return (Ensure-Tool -Exe "magick"   -Friendly "ImageMagick"  -WingetId "ImageMagick.ImageMagick") }
function Ensure-Poppler     { return (Ensure-Tool -Exe "pdftotext"-Friendly "Poppler"      -WingetId "oschwartz10612.Poppler") }
function Ensure-Pandoc      { return (Ensure-Tool -Exe "pandoc"   -Friendly "Pandoc"       -WingetId "JohnMacFarlane.Pandoc") }
function Ensure-Tesseract   { return (Ensure-Tool -Exe "tesseract"-Friendly "Tesseract"    -WingetId "UB-Mannheim.TesseractOCR") }

# ----------------------------
# Winget Update with Exclusions (Console Action)
# ----------------------------
function Get-WingetUpgrades {
    if (-not (Ensure-Winget)) { return @() }

    $raw = & winget upgrade --accept-source-agreements 2>&1
    if (-not $raw) { return @() }

    $lines = @($raw)

    $sepIndex = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^-{5,}\s*$') { $sepIndex = $i; break }
    }
    if ($sepIndex -lt 0) { return @() }

    $items = @()
    for ($i = $sepIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match 'upgrades available' -or $line -match 'version numbers that cannot be determined' -or
            $line -match 'pins that prevent upgrade' -or $line -match 'No installed package') { continue }

        $parts = $line -split '\s{2,}'
        if ($parts.Count -lt 5) { continue }

        $obj = [pscustomobject]@{
            Name      = $parts[0]
            Id        = $parts[1]
            Version   = $parts[2]
            Available = $parts[3]
            Source    = $parts[4]
        }
        $items += $obj
    }

    return $items
}

function Run-UpdateConsole {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Sixes Hub - Update All Apps" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    $cfg = Load-Config
    $exclusions = @()
    if ($cfg.wingetExclusions) { $exclusions = @($cfg.wingetExclusions) }

    $up = Get-WingetUpgrades
    if ($up.Count -eq 0) {
        Write-Host "No upgrades found (or winget output could not be parsed)." -ForegroundColor Yellow
        # Auto-close: no "Press Enter" prompt
        return
    }

    Write-Host ("Found {0} upgrade(s)." -f $up.Count) -ForegroundColor Green
    if ($exclusions.Count -gt 0) {
        Write-Host ("Exclusions: {0}" -f ($exclusions -join ", ")) -ForegroundColor Yellow
    }
    Write-Host ""

    foreach ($pkg in $up) {
        if ($exclusions -contains $pkg.Id) {
            Write-Host ("SKIP (excluded): {0} ({1})" -f $pkg.Name, $pkg.Id) -ForegroundColor DarkYellow
            continue
        }

        Write-Host ""
        Write-Host ("Upgrading: {0} ({1})" -f $pkg.Name, $pkg.Id) -ForegroundColor White
        & winget upgrade -e --id $pkg.Id --accept-package-agreements --accept-source-agreements --silent
        $code = $LASTEXITCODE

        if ($code -eq 0) {
            Write-Host "OK" -ForegroundColor Green
        } else {
            Write-Host ("FAILED (exit {0}). Continuing..." -f $code) -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Cyan
    # Auto-close: no "Press Enter" prompt
}

function Run-OptimizeConsole {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Sixes Hub - Optimize Drives" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Running: defrag /C /O /U /V" -ForegroundColor White
    & defrag /C /O /U /V
    Write-Host ""
    Write-Host "Done." -ForegroundColor Cyan
    # Auto-close: no "Press Enter" prompt
}

function Run-DiskScanConsole {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Sixes Hub - Disk Scan" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    $drives = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Select-Object -ExpandProperty DriveLetter
    foreach ($d in $drives) {
        Write-Host ""
        Write-Host ("Running: chkdsk {0}: /scan" -f $d) -ForegroundColor White
        & chkdsk "$($d):" /scan
    }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Cyan
    # Auto-close: no "Press Enter" prompt
}

function Run-SystemRepairConsole {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Sixes Hub - System Repair" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Running: DISM RestoreHealth" -ForegroundColor White
    & DISM /Online /Cleanup-Image /RestoreHealth
    Write-Host ""
    Write-Host "Running: sfc /scannow" -ForegroundColor White
    & sfc /scannow

    Write-Host ""
    Write-Host "Done." -ForegroundColor Cyan
    # Auto-close: no "Press Enter" prompt
}

# Smart Boost (safe)
function Run-SmartBoostConsole {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Sixes Hub - Smart Boost" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "1) Cleaning temp folders..." -ForegroundColor Yellow
    $folders = @(
        [System.IO.Path]::GetTempPath(),
        "$env:SystemRoot\Temp",
        "$env:LOCALAPPDATA\Temp"
    )

    foreach ($f in $folders) {
        if (Test-Path $f) {
            try {
                Get-ChildItem -Path $f -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue } catch { }
                }
            } catch { }
        }
    }

    Write-Host "2) Clearing recycle bin..." -ForegroundColor Yellow
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue | Out-Null } catch { }

    Write-Host "3) Flushing DNS..." -ForegroundColor Yellow
    try { & ipconfig /flushdns | Out-Null } catch { }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    # Auto-close: no "Press Enter" prompt
}

# Spicetify installer (runs elevated or standard; button uses elevated by default)
function Run-SpicetifyConsole {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Sixes Hub - Spicetify Installer" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Installing Spicetify (official install scripts)..." -ForegroundColor Yellow
    Write-Host "NOTE: This customizes Spotify UI/themes. Close Spotify first." -ForegroundColor Yellow
    Write-Host ""

    $u1 = "https://raw.githubusercontent.com/spicetify/spicetify-cli/master/install.ps1"
    $u2 = "https://raw.githubusercontent.com/spicetify/spicetify-marketplace/main/resources/install.ps1"

    function Invoke-RemoteScriptText {
        param([string]$Url)

        if (-not (Test-ValidUrl $Url)) { throw "Invalid URL: $Url" }

        $uri = [Uri]$Url
        if ($uri.Host -ne "raw.githubusercontent.com") { throw "Blocked host (only raw.githubusercontent.com allowed): $($uri.Host)" }

        $resp = Invoke-WebRequest -Uri $Url -ErrorAction Stop
        $scriptText = $resp.Content
        if ([string]::IsNullOrWhiteSpace($scriptText)) { throw "Downloaded script was empty." }

        # Log a quick fingerprint for transparency
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($scriptText)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
        Write-Host ("Downloaded: {0}" -f $Url) -ForegroundColor DarkGray
        Write-Host ("SHA256: {0}" -f $hash) -ForegroundColor DarkGray

        $sb = [ScriptBlock]::Create($scriptText)
        & $sb
    }

    try {
        Invoke-RemoteScriptText -Url $u1
        Write-Host ""
        Write-Host "Installing Marketplace..." -ForegroundColor Yellow
        Invoke-RemoteScriptText -Url $u2
        Write-Host ""
        Write-Host "Next step (usually): spicetify backup apply" -ForegroundColor Green
    } catch {
        Write-Host "Error running Spicetify install." -ForegroundColor Red
        Write-Host $_ -ForegroundColor Red
    }

    Write-Host ""
    # Auto-close: no "Press Enter" prompt
}


# Custom Script Runner (advanced) - runs the script stored in $CustomScriptPath
function Run-CustomScriptConsole {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "Sixes Hub - Custom Script Runner" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    if (!(Test-Path $CustomScriptPath)) {
        Write-Host "No custom script was found at:" -ForegroundColor Yellow
        Write-Host "  $CustomScriptPath" -ForegroundColor Yellow
        # Auto-close: no "Press Enter" prompt
        return
    }

    $cmd = Get-Content -Path $CustomScriptPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        Write-Host "Custom script is empty." -ForegroundColor Yellow
        # Auto-close: no "Press Enter" prompt
        return
    }

    Write-Host "Running your custom script..." -ForegroundColor Yellow
    Write-Host "(It will run as a normal .ps1 file to avoid Invoke-Expression.)" -ForegroundColor DarkGray
    Write-Host ""

    $tmp = Join-Path $env:TEMP ("SixesHub_CustomScript_{0}.ps1" -f ([Guid]::NewGuid().ToString("N")))
    try {
        Set-Content -Path $tmp -Value $cmd -Encoding UTF8 -Force
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
        $code = $LASTEXITCODE
        Write-Host ""
        Write-Host "Finished. ExitCode: $code" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "ERROR running your script." -ForegroundColor Red
        Write-Host $_ -ForegroundColor Red
    } finally {
        try { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host ""
    # Auto-close: no "Press Enter" prompt
}


# ----------------------------
# AutoAction entry (no GUI)
# ----------------------------
if (-not [string]::IsNullOrWhiteSpace($AutoAction)) {
    if (-not (Check-Admin)) {
        Relaunch-Admin -Action $AutoAction
        exit
    }

    switch ($AutoAction) {
        "RunUpdate"       { Run-UpdateConsole; exit }
        "RunOptimize"     { Run-OptimizeConsole; exit }
        "RunDiskScan"     { Run-DiskScanConsole; exit }
        "RunSystemRepair" { Run-SystemRepairConsole; exit }
        "RunSmartBoost"   { Run-SmartBoostConsole; exit }
        "RunSpicetify"    { Run-SpicetifyConsole; exit }
        "RunCustomScript" { Run-CustomScriptConsole; exit }
        default           { exit }
    }
}

# ----------------------------
# App + Shortcut + Cleanup
# ----------------------------
function Install-SelectedApps {
    param($SelectedNames)

    if (-not (Ensure-Winget)) { return }

    foreach ($name in $SelectedNames) {
        $app = $script:Config.apps | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $app) { continue }

        Write-Log "Installing: $($app.name)"
        $id = $app.wingetId
        if ([string]::IsNullOrWhiteSpace($id)) {
            Write-Log "  Skipped: No wingetId in config."
            continue
        }

        $p = Start-Process winget -NoNewWindow -PassThru -Wait -ArgumentList @(
            "install","-e","--id",$id,
            "--accept-package-agreements","--accept-source-agreements",
            "--silent"
        )

        if ($p.ExitCode -eq 0) { Write-Log "  SUCCESS" }
        else { Write-Log "  ERROR: exit $($p.ExitCode)" }
    }

    [System.Windows.Forms.MessageBox]::Show("Install tasks finished.", "Done", "OK", "Information") | Out-Null
}

function Create-Shortcuts {
    Write-Log "Fixing Desktop shortcuts..."

    $WshShell = New-Object -ComObject WScript.Shell
    $DesktopPath = [Environment]::GetFolderPath("Desktop")

    foreach ($app in $script:Config.apps) {
        if ([string]::IsNullOrWhiteSpace($app.shortcutExe)) { continue }

        $expanded = [Environment]::ExpandEnvironmentVariables($app.shortcutExe)
        if (-not (Test-Path $expanded)) {
            Write-Log "  Skip: $($app.name) (not found: $expanded)"
            continue
        }

        $lnk = Join-Path $DesktopPath ($app.name + ".lnk")
        $sc = $WshShell.CreateShortcut($lnk)
        $sc.TargetPath = $expanded
        $sc.WorkingDirectory = Split-Path -Parent $expanded
        $sc.Save()

        Write-Log "  Shortcut: $($app.name)"
    }

    [System.Windows.Forms.MessageBox]::Show("Desktop shortcuts updated.", "Done", "OK", "Information") | Out-Null
}

function Run-Cleanup {
    Write-Log "Cleanup started..."
    $deleted = 0

    $t = [System.IO.Path]::GetTempPath()
    Write-Log "Cleaning temp: $t"
    Get-ChildItem -Path $t -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; $deleted++ } catch { }
    }

    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Recycle Bin emptied."
    } catch {
        Write-Log "Recycle Bin: skipped."
    }

    Write-Log "Cleanup done. Removed about $deleted items."
    [System.Windows.Forms.MessageBox]::Show("Cleanup complete.", "Done", "OK", "Information") | Out-Null
}

function Launch-ElevatedAction {
    param([string]$ActionName)
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AutoAction `"$ActionName`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args -WindowStyle Minimized | Out-Null
}

# ----------------------------
# Unzip tools
# ----------------------------
function Find-WinRARExe {
    $paths = @(
        "$env:ProgramFiles\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe"
    )

    foreach ($p in $paths) { if (Test-Path $p) { return $p } }

    $reg = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WinRAR.exe"
    try {
        $v = (Get-ItemProperty -Path $reg -ErrorAction Stop)."(default)"
        if ($v -and (Test-Path $v)) { return $v }
    } catch { }

    return $null
}

function Ensure-WinRAR {
    $exe = Find-WinRARExe
    if ($exe) { return $true }

    $ok = Ensure-Tool -Exe "WinRAR" -Friendly "WinRAR" -WingetId "RARLab.WinRAR"
    if (-not $ok) { return $false }

    return [bool](Find-WinRARExe)
}

function Extract-ArchiveToDownloads {
    param([string]$FilePath)

    $downloads = [Environment]::GetFolderPath("UserProfile") + "\Downloads"
    $baseName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    $dest = Join-Path $downloads $baseName

    if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

    $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()

    if ($ext -eq ".zip") {
        Write-Log "Extracting ZIP to: $dest"
        try {
            Expand-Archive -Path $FilePath -DestinationPath $dest -Force
            [System.Windows.Forms.MessageBox]::Show("Extracted to:`n$dest", "Done") | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show("ZIP extract failed.", "Error", "OK", "Error") | Out-Null
        }
        return
    }

    if ($ext -eq ".rar") {
        if (-not (Ensure-WinRAR)) { return }

        $wr = Find-WinRARExe
        if (-not $wr) {
            [System.Windows.Forms.MessageBox]::Show("WinRAR installed but not found on disk.", "Error") | Out-Null
            return
        }

        Write-Log "Extracting RAR to: $dest"
        $args = @("x","-o+","-ibck","-y", "`"$FilePath`"", "`"$dest\`"")
        Start-Process -FilePath $wr -ArgumentList $args -Wait | Out-Null

        [System.Windows.Forms.MessageBox]::Show("Extracted to:`n$dest", "Done") | Out-Null
        return
    }

    [System.Windows.Forms.MessageBox]::Show("Unsupported archive type. Use .zip or .rar.", "Not Supported") | Out-Null
}

# ----------------------------
# Convert tools
# ----------------------------
function Ensure-LibreOffice {
    $paths = @(
        "$env:ProgramFiles\LibreOffice\program\soffice.exe",
        "${env:ProgramFiles(x86)}\LibreOffice\program\soffice.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { $global:LibreOfficeExe = $p; return $true } }

    $ok = Ensure-Tool -Exe "soffice" -Friendly "LibreOffice" -WingetId "TheDocumentFoundation.LibreOffice"
    if (-not $ok) { return $false }

    foreach ($p in $paths) { if (Test-Path $p) { $global:LibreOfficeExe = $p; return $true } }
    return $false
}

function Ensure-Calibre {
    $paths = @(
        "$env:ProgramFiles\Calibre2\ebook-convert.exe",
        "${env:ProgramFiles(x86)}\Calibre2\ebook-convert.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { $global:EbookConvertExe = $p; return $true } }

    $ok = Ensure-Tool -Exe "ebook-convert" -Friendly "Calibre" -WingetId "calibre.calibre"
    if (-not $ok) { return $false }

    foreach ($p in $paths) { if (Test-Path $p) { $global:EbookConvertExe = $p; return $true } }
    return $false
}

function Convert-PdfToDocxExperimental {
    param(
        [string]$PdfPath,
        [string]$OutDocx,
        [switch]$ForceOCR
    )

    if (-not (Ensure-Poppler)) { return }
    if (-not (Ensure-Pandoc))  { return }

    $work = Join-Path $env:TEMP ("SixesHub_PDF_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work | Out-Null

    try {
        $txtOut = Join-Path $work "out.txt"
        $needOCR = $ForceOCR

        if (-not $needOCR) {
            Write-Log "PDF -> text (pdftotext)"
            Start-Process pdftotext -NoNewWindow -Wait -ArgumentList @("-layout", "`"$PdfPath`"", "`"$txtOut`"")
            $len = 0
            try { $len = (Get-Content $txtOut -Raw).Trim().Length } catch { $len = 0 }

            if ($len -lt 200) {
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "This PDF looks like a scan (very little text extracted).`nEnable OCR?",
                    "OCR Recommended","YesNo","Question"
                )
                if ($r -eq "Yes") { $needOCR = $true } else { return }
            }
        }

        if ($needOCR) {
            if (-not (Ensure-Tesseract)) { return }

            Write-Log "OCR path: PDF -> images -> tesseract -> combined text"

            $prefix = Join-Path $work "page"
            Start-Process pdftoppm -NoNewWindow -Wait -ArgumentList @("-png","-r","300","`"$PdfPath`"","`"$prefix`"")

            $sb = New-Object System.Text.StringBuilder
            Get-ChildItem $work -Filter "page-*.png" | Sort-Object Name | ForEach-Object {
                $base = Join-Path $work ($_.BaseName + "_ocr")
                Start-Process tesseract -NoNewWindow -Wait -ArgumentList @("`"$($_.FullName)`"", "`"$base`"", "-l", "eng")
                $tfile = "$base.txt"
                if (Test-Path $tfile) { $sb.AppendLine((Get-Content $tfile -Raw)) | Out-Null }
            }
            Set-Content -Path $txtOut -Value $sb.ToString() -Encoding UTF8
        }

        Write-Log "Text -> DOCX (pandoc)"
        Start-Process pandoc -NoNewWindow -Wait -ArgumentList @("`"$txtOut`"","-o","`"$OutDocx`"")

        if (Test-Path $OutDocx) {
            [System.Windows.Forms.MessageBox]::Show("Converted:`n$OutDocx", "Done") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("DOCX output was not created.", "Error") | Out-Null
        }
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Run-Convert {
    param(
        [string]$InputPath,
        [string]$Mode,
        [switch]$ForceOCR
    )

    $dir  = [IO.Path]::GetDirectoryName($InputPath)
    $base = [IO.Path]::GetFileNameWithoutExtension($InputPath)

    switch ($Mode) {
        "Audio/Video -> MP3" {
            if (-not (Ensure-FFmpeg)) { return }
            $out = Join-Path $dir ($base + ".mp3")
            Write-Log "FFmpeg -> MP3: $out"
            & ffmpeg -y -i "`"$InputPath`"" "`"$out`"" 2>&1 | ForEach-Object { Write-Log $_ }
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "Audio/Video -> WAV" {
            if (-not (Ensure-FFmpeg)) { return }
            $out = Join-Path $dir ($base + ".wav")
            Write-Log "FFmpeg -> WAV: $out"
            & ffmpeg -y -i "`"$InputPath`"" "`"$out`"" 2>&1 | ForEach-Object { Write-Log $_ }
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "Video -> MP4" {
            if (-not (Ensure-FFmpeg)) { return }
            $out = Join-Path $dir ($base + ".mp4")
            Write-Log "FFmpeg -> MP4: $out"
            & ffmpeg -y -i "`"$InputPath`"" "`"$out`"" 2>&1 | ForEach-Object { Write-Log $_ }
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "Image -> PNG" {
            if (-not (Ensure-ImageMagick)) { return }
            $out = Join-Path $dir ($base + ".png")
            Write-Log "ImageMagick -> PNG: $out"
            & magick "`"$InputPath`"" "`"$out`"" 2>&1 | ForEach-Object { Write-Log $_ }
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "Image -> JPG" {
            if (-not (Ensure-ImageMagick)) { return }
            $out = Join-Path $dir ($base + ".jpg")
            Write-Log "ImageMagick -> JPG: $out"
            & magick "`"$InputPath`"" "`"$out`"" 2>&1 | ForEach-Object { Write-Log $_ }
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "Document -> PDF" {
            if (-not (Ensure-LibreOffice)) { return }
            Write-Log "LibreOffice headless convert -> PDF"
            Start-Process -NoNewWindow -Wait -FilePath $global:LibreOfficeExe -ArgumentList @(
                "--headless","--nologo","--nolockcheck",
                "--convert-to","pdf",
                "--outdir", "`"$dir`"",
                "`"$InputPath`""
            )
            $out = Join-Path $dir ($base + ".pdf")
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "Ebook -> PDF" {
            if (-not (Ensure-Calibre)) { return }
            $out = Join-Path $dir ($base + ".pdf")
            Write-Log "Calibre ebook-convert -> PDF: $out"
            & $global:EbookConvertExe "`"$InputPath`"" "`"$out`"" 2>&1 | ForEach-Object { Write-Log $_ }
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "PDF -> TXT" {
            if (-not (Ensure-Poppler)) { return }
            $out = Join-Path $dir ($base + ".txt")
            Write-Log "Poppler pdftotext -> TXT: $out"
            Start-Process pdftotext -NoNewWindow -Wait -ArgumentList @("-layout", "`"$InputPath`"", "`"$out`"")
            [System.Windows.Forms.MessageBox]::Show("Done:`n$out", "Convert") | Out-Null
        }

        "PDF -> Images (PNG)" {
            if (-not (Ensure-Poppler)) { return }
            $outFolder = Join-Path $dir ($base + "_pages")
            if (!(Test-Path $outFolder)) { New-Item -ItemType Directory -Path $outFolder | Out-Null }
            $prefix = Join-Path $outFolder "page"
            Write-Log "Poppler pdftoppm -> PNG pages: $outFolder"
            Start-Process pdftoppm -NoNewWindow -Wait -ArgumentList @("-png","-r","300","`"$InputPath`"","`"$prefix`"")
            [System.Windows.Forms.MessageBox]::Show("Done:`n$outFolder", "Convert") | Out-Null
        }

        "PDF -> DOCX (Experimental)" {
            $out = Join-Path $dir ($base + ".docx")
            Convert-PdfToDocxExperimental -PdfPath $InputPath -OutDocx $out -ForceOCR:$ForceOCR
        }
    }
}

function Get-ConvertOptions {
    param([string]$InputPath)

    if (-not $InputPath) { return @() }

    $ext = [IO.Path]::GetExtension($InputPath).ToLowerInvariant()

    $audioVideo = @(".mp3",".wav",".m4a",".aac",".flac",".ogg",".mp4",".mkv",".mov",".avi",".wmv",".webm")
    $images     = @(".png",".jpg",".jpeg",".webp",".gif",".bmp",".tif",".tiff")
    $docs       = @(".doc",".docx",".ppt",".pptx",".xls",".xlsx",".odt",".rtf")
    $ebooks     = @(".epub",".mobi",".azw3")
    $pdf        = @(".pdf")

    if ($audioVideo -contains $ext) { return @("Audio/Video -> MP3","Audio/Video -> WAV","Video -> MP4") }
    if ($images -contains $ext)     { return @("Image -> PNG","Image -> JPG") }
    if ($docs -contains $ext)       { return @("Document -> PDF") }
    if ($ebooks -contains $ext)     { return @("Ebook -> PDF") }
    if ($pdf -contains $ext)        { return @("PDF -> TXT","PDF -> Images (PNG)","PDF -> DOCX (Experimental)") }

    return @()
}

# ----------------------------
# Media Download Helpers (yt-dlp)
# ----------------------------
function Get-DownloadsFolder {
    return (Join-Path $ScriptDir "Downloads")
}
function Open-FolderPath {
    param([Parameter(Mandatory=$true)][string]$Path)

    Invoke-Safely -Context "Open folder" -Script {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        if (!(Test-Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        Start-Process explorer.exe -ArgumentList $Path
        Write-Log "Opened folder: $Path"
    }
}

function Download-AudioMp3 {
    param([Parameter(Mandatory=$true)][string]$Url)

    if (-not (Test-ValidUrl $Url)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a valid http(s) URL.","MP3 Download","OK","Warning") | Out-Null
        Write-LogWarn "Invalid URL for MP3: $Url"
        return
    }

    if (-not (Ensure-YtDlp))  { return }
    if (-not (Ensure-FFmpeg)) { return }

    $root = Get-DownloadsFolder
    $dest = Join-Path $root "Music"
    if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

    Write-Log "MP3 download: $Url"
    Write-Log "Saving to: $dest"
    Write-Log "Starting yt-dlp (async)..."

    $args = @(
        "--extract-audio",
        "--audio-format","mp3",
        "--audio-quality","0",
        "--add-metadata",
        "--embed-thumbnail",
        "--no-playlist",
        "-o", (Join-Path $dest "%(title)s.%(ext)s"),
        $Url
    )

    $null = Start-ExternalProcessAsync -FilePath "yt-dlp" -ArgumentList $args -Tag "yt-dlp mp3" -OnExit {
        param($exitCode)
        if ($exitCode -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Done.`nSaved to:`n$dest","MP3 Download","OK","Information") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("Download failed (exit $exitCode). See log for details.","MP3 Download","OK","Error") | Out-Null
        }
    }
}
function Download-VideoMp4 {
    param([Parameter(Mandatory=$true)][string]$Url)

    if (-not (Test-ValidUrl $Url)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a valid http(s) URL.","MP4 Download","OK","Warning") | Out-Null
        Write-LogWarn "Invalid URL for MP4: $Url"
        return
    }

    if (-not (Ensure-YtDlp))  { return }
    if (-not (Ensure-FFmpeg)) { return }

    $root = Get-DownloadsFolder
    $dest = Join-Path $root "Movies"
    if (!(Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

    Write-Log "MP4 download: $Url"
    Write-Log "Saving to: $dest"
    Write-Log "Starting yt-dlp (async)..."

    $outTmpl = (Join-Path $dest "%(title)s.%(ext)s")

    $args = @(
        $Url,
        "-f", "bestvideo+bestaudio/best",
        "--merge-output-format","mp4",
        "-o", $outTmpl
    )

    $null = Start-ExternalProcessAsync -FilePath "yt-dlp" -ArgumentList $args -Tag "yt-dlp mp4" -OnExit {
        param($exitCode)
        if ($exitCode -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Done.`nSaved to:`n$dest","MP4 Download","OK","Information") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("Download failed (exit $exitCode). See log for details.","MP4 Download","OK","Error") | Out-Null
        }
    }
}


# Custom Script Runner helpers
function Save-CustomScriptPayload {
    param([string]$Text)
    try {
        Set-Content -Path $CustomScriptPath -Value $Text -Encoding UTF8 -Force
        Write-Log "Saved custom script payload."
    } catch {
        Write-Log "ERROR: Failed to save custom script payload."
    }
}

function Run-CustomScriptInUserWindow {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        [System.Windows.Forms.MessageBox]::Show("Script is empty.","Custom Script","OK","Information") | Out-Null
        return
    }

    # Create a temporary PS1 so quoting is not a nightmare
    $tmp = Join-Path $env:TEMP ("SixesHub_Custom_" + [guid]::NewGuid().ToString("N") + ".ps1")
    $content = @"
`$ErrorActionPreference = 'Stop'
try {
$Text
} catch {
    Write-Host ''
    Write-Host 'ERROR:' -ForegroundColor Red
    Write-Host `$_ -ForegroundColor Red
}
Write-Host ''
# Auto-close: no "Press Enter" prompt
"@
    Set-Content -Path $tmp -Value $content -Encoding UTF8 -Force

    Write-Log "Launching custom script (standard user) in a new window..."
    Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$tmp) | Out-Null
}

# ----------------------------
# Theme
# ----------------------------
function Build-Theme([bool]$isDark) {
    if ($isDark) {
        return @{
            FormBack     = [System.Drawing.Color]::FromArgb(18,18,18)
            HeaderBack   = [System.Drawing.Color]::FromArgb(25,35,55)
            TitleFore    = [System.Drawing.Color]::FromArgb(120,180,255)
            SubtitleFore = [System.Drawing.Color]::FromArgb(200,200,200)

            TabBack      = [System.Drawing.Color]::FromArgb(24,24,24)
            TextFore     = [System.Drawing.Color]::FromArgb(235,235,235)

            ButtonBack   = [System.Drawing.Color]::FromArgb(35,35,35)
            ButtonFore   = [System.Drawing.Color]::FromArgb(235,235,235)

            InputBack    = [System.Drawing.Color]::FromArgb(30,30,30)
            InputFore    = [System.Drawing.Color]::FromArgb(235,235,235)
            Placeholder  = [System.Drawing.Color]::FromArgb(140,140,140)
        }
    } else {
        return @{
            FormBack     = [System.Drawing.Color]::FromArgb(245,246,250)
            HeaderBack   = [System.Drawing.Color]::FromArgb(30,45,75)
            TitleFore    = [System.Drawing.Color]::White
            SubtitleFore = [System.Drawing.Color]::Gainsboro

            TabBack      = [System.Drawing.Color]::White
            TextFore     = [System.Drawing.Color]::Black

            ButtonBack   = [System.Drawing.Color]::White
            ButtonFore   = [System.Drawing.Color]::Black

            InputBack    = [System.Drawing.Color]::White
            InputFore    = [System.Drawing.Color]::Black
            Placeholder  = [System.Drawing.Color]::Gray
        }
    }
}

function Start-SixesHub {
    $global:IsDarkMode = [bool]$script:Config.darkMode
    $global:Theme = Build-Theme -isDark $global:IsDarkMode

    $windowTitle = [string]$script:Config.windowTitle
    if ([string]::IsNullOrWhiteSpace($windowTitle)) { $windowTitle = "Sixes Hub" }

    $Form = New-Object System.Windows.Forms.Form
    $global:MainForm = $Form
    $Form.Text = $windowTitle + $(if (Check-Admin) { " (ADMIN)" } else { "" })
    $Form.StartPosition = "CenterScreen"
    $Form.Size = New-Object System.Drawing.Size(960, 760)
    $Form.MinimumSize = New-Object System.Drawing.Size(960, 760)

    $Root = New-Object System.Windows.Forms.TableLayoutPanel
    $Root.Dock = "Fill"
    $Root.ColumnCount = 1
    $Root.RowCount = 2
    $null = $Root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $Root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 78)))
    $null = $Root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $Form.Controls.Add($Root)

    $hdr = New-Object System.Windows.Forms.Panel
    $hdr.Dock = "Fill"
    $hdr.Height = 78

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $windowTitle
    $title.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(18, 12)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Sixpepper tools - install apps, maintenance, media, convert, unzip"
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(22, 48)

    $hdr.Controls.Add($title)
    $hdr.Controls.Add($subtitle)
    $Root.Controls.Add($hdr, 0, 0)

    $Split = New-Object System.Windows.Forms.SplitContainer
    $Split.Dock = "Fill"
    $Split.Orientation = "Horizontal"
    $Split.SplitterWidth = 6
    $Split.Panel1MinSize = 1
    $Split.Panel2MinSize = 1
    $Root.Controls.Add($Split, 0, 1)

    $Tabs = New-Object System.Windows.Forms.TabControl
    $Tabs.Dock = "Fill"
    $Tabs.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $Split.Panel1.Controls.Add($Tabs)

    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = "Fill"
    $logPanel.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
    $Split.Panel2.Controls.Add($logPanel)

    $logLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $logLayout.Dock = "Fill"
    $logLayout.ColumnCount = 1
    $logLayout.RowCount = 2
    $null = $logLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $logLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    $null = $logLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $logPanel.Controls.Add($logLayout)

    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = "Status Log"
    $lblLog.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblLog.Dock = "Fill"
    $lblLog.TextAlign = "MiddleLeft"
    $logLayout.Controls.Add($lblLog, 0, 0)

    $global:txtLog = New-Object System.Windows.Forms.TextBox
    $global:txtLog.Multiline = $true
    $global:txtLog.ReadOnly = $true
    $global:txtLog.ScrollBars = "Vertical"
    $global:txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
    $global:txtLog.BackColor = [System.Drawing.Color]::Black
    $global:txtLog.ForeColor = [System.Drawing.Color]::Lime
    $global:txtLog.Dock = "Fill"
    $logLayout.Controls.Add($global:txtLog, 0, 1)

    # ---- Tabs ----
    # 1) Install Apps
    $TabApps = New-Object System.Windows.Forms.TabPage
    $TabApps.Text = "Install Apps"
    $Tabs.Controls.Add($TabApps)

    $appsLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $appsLayout.Dock = "Fill"
    $appsLayout.ColumnCount = 2
    $appsLayout.RowCount = 3
    $null = $appsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60)))
    $null = $appsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40)))
    $null = $appsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $null = $appsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $appsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 55)))
    $TabApps.Controls.Add($appsLayout)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Dock = "Fill"

    $global:SearchPlaceholderText = "Search apps..."
    $global:SearchPlaceholderActive = $true
    $txtSearch.Text = $global:SearchPlaceholderText

    $btnRefreshApps = New-Object System.Windows.Forms.Button
    $btnRefreshApps.Text = "Reload config"
    $btnRefreshApps.Dock = "Fill"
    $btnRefreshApps.FlatStyle = "Flat"

    $chkApps = New-Object System.Windows.Forms.CheckedListBox
    $chkApps.Dock = "Fill"
    $chkApps.CheckOnClick = $true
    $chkApps.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "Install Selected"
    $btnInstall.Dock = "Fill"
    $btnInstall.FlatStyle = "Flat"

    $appsLayout.Controls.Add($txtSearch, 0, 0)
    $appsLayout.Controls.Add($btnRefreshApps, 1, 0)
    $appsLayout.Controls.Add($chkApps, 0, 1)
    $appsLayout.SetColumnSpan($chkApps, 2)
    $appsLayout.Controls.Add($btnInstall, 0, 2)
    $appsLayout.SetColumnSpan($btnInstall, 2)

    function Populate-AppsList {
        $chkApps.Items.Clear()
        foreach ($a in $script:Config.apps) { [void]$chkApps.Items.Add($a.name) }
    }
    Populate-AppsList

    $txtSearch.Add_GotFocus({
        if ($global:SearchPlaceholderActive) {
            $this.Text = ""
            $this.ForeColor = $global:Theme.InputFore
            $global:SearchPlaceholderActive = $false
        }
    })

    $txtSearch.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $global:SearchPlaceholderActive = $true
            $this.Text = $global:SearchPlaceholderText
            $this.ForeColor = $global:Theme.Placeholder
        }
    })

    $txtSearch.Add_TextChanged({
        $q = ""
        if (-not $global:SearchPlaceholderActive) { $q = $this.Text.Trim().ToLowerInvariant() }

        $chkApps.Items.Clear()
        foreach ($a in $script:Config.apps) {
            if ($q -eq "" -or $a.name.ToLowerInvariant().Contains($q)) {
                [void]$chkApps.Items.Add($a.name)
            }
        }
    })

    $btnInstall.Add_Click({
        if ($chkApps.CheckedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Select at least one app.", "Install") | Out-Null
            return
        }
        $names = @()
        foreach ($i in $chkApps.CheckedItems) { $names += [string]$i }
        Install-SelectedApps -SelectedNames $names
    })

    # 2) Maintenance tab (with Live Dashboard + Smart Boost)
    $TabTools = New-Object System.Windows.Forms.TabPage
    $TabTools.Text = "Maintenance"
    $Tabs.Controls.Add($TabTools)



    $maintLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $maintLayout.Dock = "Fill"
    $maintLayout.ColumnCount = 2
    $maintLayout.RowCount = 4
    $maintLayout.Padding = New-Object System.Windows.Forms.Padding(12)
    $null = $maintLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $null = $maintLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $null = $maintLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
    $null = $maintLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $null = $maintLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $null = $maintLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
    $TabTools.Controls.Add($maintLayout)

    $grpDash = New-Object System.Windows.Forms.GroupBox
    $grpDash.Text = "Live System Dashboard"
    $grpDash.Dock = "Fill"
    $maintLayout.Controls.Add($grpDash, 0, 0)
    $maintLayout.SetColumnSpan($grpDash, 2)

    $lblCPU = New-Object System.Windows.Forms.Label
    $lblCPU.AutoSize = $true
    $lblCPU.Location = New-Object System.Drawing.Point(14, 28)

    $lblRAM = New-Object System.Windows.Forms.Label
    $lblRAM.AutoSize = $true
    $lblRAM.Location = New-Object System.Drawing.Point(14, 52)

    $lblDisk = New-Object System.Windows.Forms.Label
    $lblDisk.AutoSize = $true
    $lblDisk.Location = New-Object System.Drawing.Point(14, 76)

    $grpDash.Controls.Add($lblCPU)
    $grpDash.Controls.Add($lblRAM)
    $grpDash.Controls.Add($lblDisk)

    $timerStats = New-Object System.Windows.Forms.Timer
    $timerStats.Interval = 1500
    $timerStats.Add_Tick({
        try {
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $lblCPU.Text = "CPU Load:  $($cpu.LoadPercentage)%"

            $os = Get-CimInstance Win32_OperatingSystem
            $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024, 0)
            $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            $usedMB  = $totalMB - $freeMB
            $perc    = [math]::Round(($usedMB / $totalMB) * 100, 0)
            $lblRAM.Text = "RAM Usage: $usedMB MB / $totalMB MB ($perc%)"

            $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            if ($c) {
                $freeGB = [math]::Round($c.FreeSpace / 1GB, 1)
                $sizeGB = [math]::Round($c.Size / 1GB, 1)
                $lblDisk.Text = "Disk C: Free $freeGB GB / $sizeGB GB"
            } else {
                $lblDisk.Text = "Disk C: unavailable"
            }
        } catch {
            $lblCPU.Text  = "CPU Load: unavailable"
            $lblRAM.Text  = "RAM Usage: unavailable"
            $lblDisk.Text = "Disk C: unavailable"
        }
    })
    # timerStats is started/stopped by tab-activation handler
    $timerStats.Stop()

# Start live stats ONLY when the Maintenance tab is active (prevents background WMI/CIM polling from stuttering the UI)
$Tabs.Add_SelectedIndexChanged({
    Invoke-Safely -Context "Tab switch" -Script {
        if ($Tabs.SelectedTab -eq $TabTools) {
            if (-not $timerStats.Enabled) { $timerStats.Start() }
        } else {
            if ($timerStats.Enabled) { $timerStats.Stop() }
        }
    }
})


    function Nice-Button($text) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Dock = "Fill"
        $b.FlatStyle = "Flat"
        $b.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        return $b
    }

    $btnSmartBoost = Nice-Button "Smart Boost (Admin)"
    $btnUpdate = Nice-Button "Update Apps (Safe Window)"
    $btnClean  = Nice-Button "Quick Cleanup (Temp + Bin)"
    $btnShort  = Nice-Button "Fix Desktop Shortcuts"
    $btnOpt    = Nice-Button "Optimize Drives (Admin)"
    $btnScan   = Nice-Button "Disk Scan (Admin)"
    $btnRepair = Nice-Button "System Repair (Admin)"

    $btnOpenDownloads = Nice-Button "Open Downloads Folder"
    $btnOpenLogs = Nice-Button "Open Logs Folder"

    $maintLayout.Controls.Add($btnSmartBoost, 0, 1)
    $maintLayout.Controls.Add($btnUpdate,     1, 1)
    $maintLayout.Controls.Add($btnClean,      0, 2)
    $maintLayout.Controls.Add($btnShort,      1, 2)
    $maintLayout.Controls.Add($btnOpt,        0, 3)
    $maintLayout.Controls.Add($btnScan,       1, 3)

    # Put repair at bottom full width
    $maintLayout.RowStyles[3].Height = 0
    $maintLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
    $maintLayout.RowCount = 5
    $maintLayout.Controls.Add($btnRepair, 0, 4)
    $maintLayout.SetColumnSpan($btnRepair, 2)

    $maintLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
    $maintLayout.RowCount = 6
    $maintLayout.Controls.Add($btnOpenDownloads, 0, 5)
    $maintLayout.Controls.Add($btnOpenLogs, 1, 5)

    $btnSmartBoost.Add_Click({
        Write-Log "Launching Smart Boost window (Admin)..."
        Launch-ElevatedAction -ActionName "RunSmartBoost"
    })
    $btnUpdate.Add_Click({ Write-Log "Launching Update window (Admin)..."; Launch-ElevatedAction -ActionName "RunUpdate" })
    $btnClean.Add_Click({ Run-Cleanup })
    $btnShort.Add_Click({ Create-Shortcuts })
    $btnOpt.Add_Click({ Write-Log "Launching Optimize Drives window (Admin)..."; Launch-ElevatedAction -ActionName "RunOptimize" })
    $btnScan.Add_Click({ Write-Log "Launching Disk Scan window (Admin)..."; Launch-ElevatedAction -ActionName "RunDiskScan" })
    $btnRepair.Add_Click({ Write-Log "Launching System Repair window (Admin)..."; Launch-ElevatedAction -ActionName "RunSystemRepair" })

    $btnOpenDownloads.Add_Click({
        $p = Get-DownloadsFolder
        Open-FolderPath -Path $p
    })

    $btnOpenLogs.Add_Click({
        $p = Join-Path $ScriptDir "logs"
        Open-FolderPath -Path $p
    })

    # 3) Convert tab
    $TabConvert = New-Object System.Windows.Forms.TabPage
    $TabConvert.Text = "Convert"
    $Tabs.Controls.Add($TabConvert)

    $convLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $convLayout.Dock = "Fill"
    $convLayout.ColumnCount = 2
    $convLayout.RowCount = 6
    $null = $convLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 70)))
    $null = $convLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30)))
    $null = $convLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $null = $convLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $null = $convLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $null = $convLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $null = $convLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))
    $null = $convLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $TabConvert.Controls.Add($convLayout)

    $btnPickFile = New-Object System.Windows.Forms.Button
    $btnPickFile.Text = "Choose File..."
    $btnPickFile.Dock = "Fill"
    $btnPickFile.FlatStyle = "Flat"

    $lblFile = New-Object System.Windows.Forms.Label
    $lblFile.Text = "No file selected"
    $lblFile.Dock = "Fill"
    $lblFile.AutoEllipsis = $true

    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Text = "Convert to:"
    $lblMode.Dock = "Fill"

    $comboMode = New-Object System.Windows.Forms.ComboBox
    $comboMode.Dock = "Fill"
    $comboMode.DropDownStyle = "DropDownList"

    $chkOCR = New-Object System.Windows.Forms.CheckBox
    $chkOCR.Text = "Force OCR (PDF -> DOCX only)"
    $chkOCR.Dock = "Fill"

    $btnConvert = New-Object System.Windows.Forms.Button
    $btnConvert.Text = "Convert"
    $btnConvert.Dock = "Fill"
    $btnConvert.FlatStyle = "Flat"

    $convLayout.Controls.Add($btnPickFile, 0, 0)
    $convLayout.Controls.Add($lblFile, 1, 0)
    $convLayout.Controls.Add($lblMode, 0, 1)
    $convLayout.Controls.Add($comboMode, 1, 1)
    $convLayout.Controls.Add($chkOCR, 0, 2)
    $convLayout.SetColumnSpan($chkOCR, 2)
    $convLayout.Controls.Add($btnConvert, 0, 4)
    $convLayout.SetColumnSpan($btnConvert, 2)

    $global:ConvPath = ""

    $btnPickFile.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "All Files|*.*"
        if ($dlg.ShowDialog() -eq "OK") {
            $global:ConvPath = $dlg.FileName
            $lblFile.Text = $dlg.FileName

            $comboMode.Items.Clear()
            $opts = Get-ConvertOptions -InputPath $global:ConvPath
            foreach ($o in $opts) { [void]$comboMode.Items.Add($o) }
            if ($comboMode.Items.Count -gt 0) { $comboMode.SelectedIndex = 0 }
        }
    })

    $btnConvert.Add_Click({
        if (-not $global:ConvPath) { return }
        if ($comboMode.SelectedItem -eq $null) {
            [System.Windows.Forms.MessageBox]::Show("No compatible conversion options found for this file type.", "Convert") | Out-Null
            return
        }
        Run-Convert -InputPath $global:ConvPath -Mode ([string]$comboMode.SelectedItem) -ForceOCR:$chkOCR.Checked
    })

    # 4) Unzip tab
    $TabZip = New-Object System.Windows.Forms.TabPage
    $TabZip.Text = "Unzip"
    $Tabs.Controls.Add($TabZip)

    $zipLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $zipLayout.Dock = "Fill"
    $zipLayout.ColumnCount = 1
    $zipLayout.RowCount = 5
    $null = $zipLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))
    $null = $zipLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $null = $zipLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))
    $null = $zipLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $null = $zipLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $TabZip.Controls.Add($zipLayout)

    $zipTitle = New-Object System.Windows.Forms.Label
    $zipTitle.Text = "Pick a .zip or .rar and Sixes Hub will extract it into Downloads automatically."
    $zipTitle.Dock = "Fill"
    $zipTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)

    $btnPickArc = New-Object System.Windows.Forms.Button
    $btnPickArc.Text = "Choose Archive..."
    $btnPickArc.Dock = "Fill"
    $btnPickArc.FlatStyle = "Flat"

    $lblArc = New-Object System.Windows.Forms.Label
    $lblArc.Text = "No archive selected"
    $lblArc.Dock = "Fill"
    $lblArc.AutoEllipsis = $true

    $btnExtract = New-Object System.Windows.Forms.Button
    $btnExtract.Text = "Extract to Downloads"
    $btnExtract.Dock = "Fill"
    $btnExtract.FlatStyle = "Flat"

    $zipLayout.Controls.Add($zipTitle, 0, 0)
    $zipLayout.Controls.Add($btnPickArc, 0, 1)
    $zipLayout.Controls.Add($lblArc, 0, 2)
    $zipLayout.Controls.Add($btnExtract, 0, 3)

    $global:ArcPath = ""

    $btnPickArc.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Archives (*.zip;*.rar)|*.zip;*.rar"
        if ($dlg.ShowDialog() -eq "OK") {
            $global:ArcPath = $dlg.FileName
            $lblArc.Text = $dlg.FileName
        }
    })

    $btnExtract.Add_Click({
        if (-not $global:ArcPath) { return }
        Extract-ArchiveToDownloads -FilePath $global:ArcPath
    })

    # 5) Reading tab
    $TabRead = New-Object System.Windows.Forms.TabPage
    $TabRead.Text = "Reading"
    $Tabs.Controls.Add($TabRead)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = "Fill"
    $flow.AutoScroll = $true
    $flow.WrapContents = $true
    $flow.Padding = New-Object System.Windows.Forms.Padding(10)
    $TabRead.Controls.Add($flow)

    function Populate-ReadingButtons {
        $flow.Controls.Clear()
        foreach ($site in $script:Config.websites) {
            $b = New-Object System.Windows.Forms.Button
            $b.Text = $site.name
            $b.Width = 360
            $b.Height = 50
            $b.FlatStyle = "Flat"
            $b.Tag = $site.url
            $b.Add_Click({
                $u = $this.Tag
                Start-Process $u
                Write-Log "Opened: $u"
            })
            $flow.Controls.Add($b)
        }
    }
    Populate-ReadingButtons

    # 6) Music tab (Spotify + Spicetify + MP3 + Custom Script Runner)
    $TabMusic = New-Object System.Windows.Forms.TabPage
    $TabMusic.Text = "Music"
    $Tabs.Controls.Add($TabMusic)

    $musicLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $musicLayout.Dock = "Fill"
    $musicLayout.ColumnCount = 2
    $musicLayout.RowCount = 5
    $musicLayout.Padding = New-Object System.Windows.Forms.Padding(12)
    $null = $musicLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $null = $musicLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    $null = $musicLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
    $null = $musicLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
    $null = $musicLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
    $null = $musicLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
    $null = $musicLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$TabMusic.Controls.Add($musicLayout)

    $lblMusic = New-Object System.Windows.Forms.Label
    $lblMusic.Text = "Spotify + Music Tools"
    $lblMusic.Dock = "Fill"
    $lblMusic.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $musicLayout.Controls.Add($lblMusic, 0, 0)
    $musicLayout.SetColumnSpan($lblMusic, 2)

    $btnInstallSpotify = New-Object System.Windows.Forms.Button
    $btnInstallSpotify.Text = "Install Spotify (Official)"
    $btnInstallSpotify.Dock = "Fill"
    $btnInstallSpotify.FlatStyle = "Flat"
    $btnInstallSpotify.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $musicLayout.Controls.Add($btnInstallSpotify, 0, 1)

    $btnInstallSpicetify = New-Object System.Windows.Forms.Button
    $btnInstallSpicetify.Text = "Install Spicetify (Themes)"
    $btnInstallSpicetify.Dock = "Fill"
    $btnInstallSpicetify.FlatStyle = "Flat"
    $btnInstallSpicetify.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $musicLayout.Controls.Add($btnInstallSpicetify, 1, 1)

    $btnSpotXInfo = New-Object System.Windows.Forms.Button
    $btnSpotXInfo.Text = "Open SpotX Info Page"
    $btnSpotXInfo.Dock = "Fill"
    $btnSpotXInfo.FlatStyle = "Flat"
    $btnSpotXInfo.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $musicLayout.Controls.Add($btnSpotXInfo, 0, 2)

    $btnDummy = New-Object System.Windows.Forms.Button
    $btnDummy.Text = " "
    $btnDummy.Dock = "Fill"
    $btnDummy.Enabled = $false
    $musicLayout.Controls.Add($btnDummy, 1, 2)

    # MP3 Downloader group
    $grpMp3 = New-Object System.Windows.Forms.GroupBox
    $grpMp3.Text = "MP3 Downloader (yt-dlp + ffmpeg)"
    $grpMp3.Dock = "Fill"
    $musicLayout.Controls.Add($grpMp3, 0, 3)
    $musicLayout.SetColumnSpan($grpMp3, 2)

    $txtMp3Url = New-Object System.Windows.Forms.TextBox
    $txtMp3Url.Width = 650
    $txtMp3Url.Location = New-Object System.Drawing.Point(14, 32)
    $grpMp3.Controls.Add($txtMp3Url)

    $btnMp3 = New-Object System.Windows.Forms.Button
    $btnMp3.Text = "Download MP3"
    $btnMp3.Width = 150
    $btnMp3.Height = 30
    $btnMp3.Location = New-Object System.Drawing.Point(14, 66)
    $grpMp3.Controls.Add($btnMp3)

$btnOpenMusic = New-Object System.Windows.Forms.Button
$btnOpenMusic.Text = "Open Music Folder"
$btnOpenMusic.Width = 170
$btnOpenMusic.Height = 30
$btnOpenMusic.Location = New-Object System.Drawing.Point(172, 66)
$grpMp3.Controls.Add($btnOpenMusic)

    $lblMp3Hint = New-Object System.Windows.Forms.Label
    $lblMp3Hint.AutoSize = $true
    $lblMp3Hint.Location = New-Object System.Drawing.Point(14, 98)
    $lblMp3Hint.Text = "Paste a link (YouTube/SoundCloud/etc). Saves to Downloads\Music."
    $grpMp3.Controls.Add($lblMp3Hint)

    # Custom Script Runner group (NEW)

$grpCustom = New-Object System.Windows.Forms.GroupBox
$grpCustom.Text = "Custom Script Runner (Advanced)"
$grpCustom.Dock = "Fill"
$musicLayout.Controls.Add($grpCustom, 0, 4)
$musicLayout.SetColumnSpan($grpCustom, 2)

$ScriptsDir = Join-Path $ScriptDir "scripts"
if (!(Test-Path $ScriptsDir)) { New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null }

$customLayout = New-Object System.Windows.Forms.TableLayoutPanel
$customLayout.Dock = "Fill"
$customLayout.AutoScroll = $true
$customLayout.ColumnCount = 3
$customLayout.RowCount = 5
$customLayout.Padding = New-Object System.Windows.Forms.Padding(10,12,10,10)
$null = $customLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60)))
$null = $customLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 15)))
$null = $customLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 25)))
$null = $customLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
$null = $customLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
$null = $customLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$null = $customLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
$null = $customLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
$grpCustom.Controls.Add($customLayout)

$cmbScripts = New-Object System.Windows.Forms.ComboBox
$cmbScripts.Dock = "Fill"
$cmbScripts.DropDownStyle = "DropDownList"
$cmbScripts.DisplayMember = "Name"
$customLayout.Controls.Add($cmbScripts, 0, 0)

$btnLoadScript = New-Object System.Windows.Forms.Button
$btnLoadScript.Text = "Load"
$btnLoadScript.Dock = "Fill"
$customLayout.Controls.Add($btnLoadScript, 1, 0)

$btnOpenScripts = New-Object System.Windows.Forms.Button
$btnOpenScripts.Text = "Open Scripts Folder"
$btnOpenScripts.Dock = "Fill"
$customLayout.Controls.Add($btnOpenScripts, 2, 0)

$lblCustomWarn = New-Object System.Windows.Forms.Label
$lblCustomWarn.Text = "Pick an approved script or paste your own. Only run scripts you trust."
$lblCustomWarn.Dock = "Fill"
$customLayout.Controls.Add($lblCustomWarn, 0, 1)
$customLayout.SetColumnSpan($lblCustomWarn, 3)

$txtCustom = New-Object System.Windows.Forms.TextBox
$txtCustom.Multiline = $true
$txtCustom.ScrollBars = "Vertical"
$txtCustom.MinimumSize = New-Object System.Drawing.Size(0, 140)
$txtCustom.Height = 140
$txtCustom.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtCustom.Dock = "Fill"
$customLayout.Controls.Add($txtCustom, 0, 2)
$customLayout.SetColumnSpan($txtCustom, 3)

$btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$btnPanel.Dock = "Fill"
$btnPanel.FlowDirection = "LeftToRight"
$btnPanel.WrapContents = $false
$customLayout.Controls.Add($btnPanel, 0, 3)
$customLayout.SetColumnSpan($btnPanel, 3)

$btnRunCustomUser = New-Object System.Windows.Forms.Button
$btnRunCustomUser.Text = "Run (Standard User)"
$btnRunCustomUser.Width = 170
$btnRunCustomUser.Height = 34
$btnPanel.Controls.Add($btnRunCustomUser)

$btnRunCustomAdmin = New-Object System.Windows.Forms.Button
$btnRunCustomAdmin.Text = "Run (Admin)"
$btnRunCustomAdmin.Width = 120
$btnRunCustomAdmin.Height = 34
$btnPanel.Controls.Add($btnRunCustomAdmin)

$btnClearCustom = New-Object System.Windows.Forms.Button
$btnClearCustom.Text = "Clear"
$btnClearCustom.Width = 90
$btnClearCustom.Height = 34
$btnPanel.Controls.Add($btnClearCustom)

$btnRefreshScripts = New-Object System.Windows.Forms.Button
$btnRefreshScripts.Text = "Refresh List"
$btnRefreshScripts.Width = 120
$btnRefreshScripts.Height = 34
$btnPanel.Controls.Add($btnRefreshScripts)

$lblCustomTip = New-Object System.Windows.Forms.Label
$lblCustomTip.Text = "Approved scripts live in .\scripts. 'Load' copies the selected script into the box."
$lblCustomTip.Dock = "Fill"
$customLayout.Controls.Add($lblCustomTip, 0, 4)
$customLayout.SetColumnSpan($lblCustomTip, 3)

function Refresh-ApprovedScripts {
    $cmbScripts.Items.Clear()

    $items = @()
    if (Test-Path $ScriptsDir) {
        $items = Get-ChildItem $ScriptsDir -File -Filter *.ps1 | Sort-Object Name | ForEach-Object {
            [PSCustomObject]@{ Name = $_.Name; Path = $_.FullName }
        }
    }

    if ($items.Count -eq 0) {
        $null = $cmbScripts.Items.Add([PSCustomObject]@{ Name="(No scripts found)"; Path="" })
        $cmbScripts.SelectedIndex = 0
    } else {
        foreach ($it in $items) { $null = $cmbScripts.Items.Add($it) }
        $cmbScripts.SelectedIndex = 0
    }
}

Refresh-ApprovedScripts

# Wire Music tab actions
    $btnInstallSpotify.Add_Click({
        Write-Log "Installing Spotify (Official)..."
        Install-WingetId -WingetId "Spotify.Spotify" | Out-Null
    })

    $btnInstallSpicetify.Add_Click({
        $msg = "This will run the Spicetify installer in an Admin window.`nClose Spotify first.`n`nContinue?"
        $r = [System.Windows.Forms.MessageBox]::Show($msg, "Install Spicetify", "YesNo", "Question")
        if ($r -eq "Yes") {
            Write-Log "Launching Spicetify installer..."
            Launch-ElevatedAction -ActionName "RunSpicetify"
        }
    })

    $btnSpotXInfo.Add_Click({
        Start-Process "https://github.com/SpotX-Official/SpotX" | Out-Null
        Write-Log "Opened SpotX info page."
    })

    $btnMp3.Add_Click({
        $u = $txtMp3Url.Text.Trim()
        if ($u -match '^https?://') { Download-AudioMp3 -Url $u }
        else { [System.Windows.Forms.MessageBox]::Show("Paste a valid URL starting with http(s).","MP3 Downloader") | Out-Null }
    })

    $btnOpenMusic.Add_Click({
        $p = Join-Path (Get-DownloadsFolder) "Music"
        Open-FolderPath -Path $p
    })

    $btnRunCustomUser.Add_Click({
        $cmd = $txtCustom.Text
        $msg = "You are about to run a custom script as STANDARD USER.`nOnly run scripts you trust.`n`nContinue?"
        $r = [System.Windows.Forms.MessageBox]::Show($msg, "Custom Script Runner", "YesNo", "Warning")
        if ($r -eq "Yes") {
            Run-CustomScriptInUserWindow -Text $cmd
        }
    })

    $btnRunCustomAdmin.Add_Click({
        $cmd = $txtCustom.Text
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            [System.Windows.Forms.MessageBox]::Show("Script is empty.","Custom Script Runner") | Out-Null
            return
        }

        $msg = "You are about to run a custom script as ADMIN in a separate elevated window.`nOnly run scripts you trust.`n`nContinue?"
        $r = [System.Windows.Forms.MessageBox]::Show($msg, "Custom Script Runner", "YesNo", "Warning")
        if ($r -eq "Yes") {
            Save-CustomScriptPayload -Text $cmd
            Write-Log "Launching custom script as Admin..."
            Launch-ElevatedAction -ActionName "RunCustomScript"
        }
    })

    $btnClearCustom.Add_Click({ $txtCustom.Text = "" })

$btnRefreshScripts.Add_Click({
    Refresh-ApprovedScripts
    Write-Log "Refreshed scripts list."
})

$btnLoadScript.Add_Click({
    $sel = $cmbScripts.SelectedItem
    if ($sel -and $sel.Path -and (Test-Path $sel.Path)) {
        try {
            $txtCustom.Text = Get-Content -Path $sel.Path -Raw
            Write-Log "Loaded script: $($sel.Name)"
        } catch {
            Write-LogError "Failed to load script: $($sel.Path) :: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Failed to load the selected script.","Load Script","OK","Error") | Out-Null
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("No script selected (or file missing).","Load Script","OK","Warning") | Out-Null
    }
})

    $btnOpenScripts.Add_Click({
        $p = Join-Path $ScriptDir "scripts"
        Open-FolderPath -Path $p
    })

    
# 7) Movies tab (video downloader only - browser removed for speed)
$TabMovies = New-Object System.Windows.Forms.TabPage
$TabMovies.Text = "Movies"
$Tabs.Controls.Add($TabMovies)

$movLayout = New-Object System.Windows.Forms.TableLayoutPanel
$movLayout.Dock = "Fill"
$movLayout.ColumnCount = 1
$movLayout.RowCount = 2
$movLayout.Padding = New-Object System.Windows.Forms.Padding(12)
$null = $movLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
$null = $movLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$TabMovies.Controls.Add($movLayout)

$grpVid = New-Object System.Windows.Forms.GroupBox
$grpVid.Text = "Video Downloader (MP4)"
$grpVid.Dock = "Fill"
$movLayout.Controls.Add($grpVid, 0, 0)

$txtVidUrl = New-Object System.Windows.Forms.TextBox
$txtVidUrl.Location = New-Object System.Drawing.Point(14, 32)
$txtVidUrl.Width = 720
$grpVid.Controls.Add($txtVidUrl)

$btnVid = New-Object System.Windows.Forms.Button
$btnVid.Text = "Download MP4"
$btnVid.Location = New-Object System.Drawing.Point(14, 58)
$btnVid.Width = 150
$btnVid.Height = 28
$grpVid.Controls.Add($btnVid)

$btnOpenMovies = New-Object System.Windows.Forms.Button
$btnOpenMovies.Text = "Open Movies Folder"
$btnOpenMovies.Location = New-Object System.Drawing.Point(172, 58)
$btnOpenMovies.Width = 170
$btnOpenMovies.Height = 28
$grpVid.Controls.Add($btnOpenMovies)

$lblVidHint = New-Object System.Windows.Forms.Label
$lblVidHint.AutoSize = $true
$lblVidHint.Location = New-Object System.Drawing.Point(14, 90)
$lblVidHint.Text = "Paste a link (YouTube/etc). Saves to Downloads\Movies."
$grpVid.Controls.Add($lblVidHint)

$grpVidInfo = New-Object System.Windows.Forms.GroupBox
$grpVidInfo.Text = "Notes"
$grpVidInfo.Dock = "Fill"
$movLayout.Controls.Add($grpVidInfo, 0, 1)

$vidInfoLayout = New-Object System.Windows.Forms.TableLayoutPanel
$vidInfoLayout.Dock = "Fill"
$vidInfoLayout.ColumnCount = 1
$vidInfoLayout.RowCount = 2
$null = $vidInfoLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 64)))
$null = $vidInfoLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$grpVidInfo.Controls.Add($vidInfoLayout)

$movSitesFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$movSitesFlow.Dock = "Fill"
$movSitesFlow.AutoScroll = $true
$movSitesFlow.WrapContents = $false
$movSitesFlow.FlowDirection = "LeftToRight"
$movSitesFlow.Padding = New-Object System.Windows.Forms.Padding(8)
$global:movSitesFlow = $movSitesFlow
$vidInfoLayout.Controls.Add($movSitesFlow, 0, 0)

$lblVidInfo = New-Object System.Windows.Forms.Label
$lblVidInfo.Dock = "Fill"
$lblVidInfo.Padding = New-Object System.Windows.Forms.Padding(10)
$lblVidInfo.Text = "Use your normal browser to find links, then paste them above."
$vidInfoLayout.Controls.Add($lblVidInfo, 0, 1)

function Populate-MovieSiteButtons {
    if (-not $global:movSitesFlow) { return }
    $global:movSitesFlow.Controls.Clear()

    $sites = @()
    if ($script:Config.movieSites -and $script:Config.movieSites.Count -gt 0) {
        $sites = $script:Config.movieSites
    } else {
        $sites = @(
            [pscustomobject]@{ name="Netflix"; url="https://www.netflix.com/" },
            [pscustomobject]@{ name="Tubi"; url="https://tubitv.com/" },
            [pscustomobject]@{ name="Prime Video"; url="https://www.amazon.com/Prime-Video/b?node=2676882011" },
            [pscustomobject]@{ name="Disney+"; url="https://www.disneyplus.com/" },
            [pscustomobject]@{ name="Hulu"; url="https://www.hulu.com/" },
            [pscustomobject]@{ name="Max"; url="https://www.max.com/" }
        )
    }

    foreach ($site in $sites) {
        if (-not $site.name -or -not $site.url) { continue }
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $site.name
        $b.Width = 110
        $b.Height = 34
        $b.FlatStyle = "Flat"
        $b.Tag = $site.url
        $b.Add_Click({
            $u = $this.Tag
            if ($u) {
                Start-Process $u
                Write-Log "Opened: $u"
            }
        })
        $global:movSitesFlow.Controls.Add($b)
    }
}
Populate-MovieSiteButtons

$btnVid.Add_Click({
    $u = $txtVidUrl.Text.Trim()
    if ($u -match '^https?://') { Download-VideoMp4 -Url $u }
    else { [System.Windows.Forms.MessageBox]::Show("Paste a valid URL starting with http(s).","MP4 Downloader") | Out-Null }
})

$btnOpenMovies.Add_Click({
    $p = Join-Path (Get-DownloadsFolder) "Movies"
    Open-FolderPath -Path $p
})

# 8) Settings tab
    $TabSettings = New-Object System.Windows.Forms.TabPage
    $TabSettings.Text = "Settings"
    $Tabs.Controls.Add($TabSettings)

    $setLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $setLayout.Dock = "Fill"
    $setLayout.ColumnCount = 2
    $setLayout.RowCount = 6
    $null = $setLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 70)))
    $null = $setLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30)))
    $TabSettings.Controls.Add($setLayout)

    $chkChoco = New-Object System.Windows.Forms.CheckBox
    $chkChoco.Text = "Enable Chocolatey (optional, advanced)"
    $chkChoco.Checked = [bool]$script:Config.enableChocolatey
    $chkChoco.Dock = "Fill"
    $setLayout.Controls.Add($chkChoco, 0, 0)
    $setLayout.SetColumnSpan($chkChoco, 2)

    $chkDark = New-Object System.Windows.Forms.CheckBox
    $chkDark.Text = "Dark Mode"
    $chkDark.Checked = [bool]$script:Config.darkMode
    $chkDark.Dock = "Fill"
    $setLayout.Controls.Add($chkDark, 0, 1)
    $setLayout.SetColumnSpan($chkDark, 2)

    $lblEx = New-Object System.Windows.Forms.Label
    $lblEx.Text = "Winget exclusions (IDs). One per line:"
    $lblEx.Dock = "Fill"
    $setLayout.Controls.Add($lblEx, 0, 2)
    $setLayout.SetColumnSpan($lblEx, 2)

    $txtEx = New-Object System.Windows.Forms.TextBox
    $txtEx.Multiline = $true
    $txtEx.ScrollBars = "Vertical"
    $txtEx.Dock = "Fill"
    $txtEx.Height = 200
    if ($script:Config.wingetExclusions) { $txtEx.Text = ($script:Config.wingetExclusions -join "`r`n") }
    $setLayout.Controls.Add($txtEx, 0, 3)
    $setLayout.SetColumnSpan($txtEx, 2)

    $btnSaveSettings = New-Object System.Windows.Forms.Button
    $btnSaveSettings.Text = "Save Settings"
    $btnSaveSettings.Dock = "Fill"
    $btnSaveSettings.FlatStyle = "Flat"
    $setLayout.Controls.Add($btnSaveSettings, 0, 4)
    $setLayout.SetColumnSpan($btnSaveSettings, 2)

    function Apply-Theme {
        $Form.BackColor = $global:Theme.FormBack
        $Root.BackColor = $global:Theme.FormBack

        $hdr.BackColor = $global:Theme.HeaderBack
        $title.ForeColor = $global:Theme.TitleFore
        $subtitle.ForeColor = $global:Theme.SubtitleFore

        $Tabs.BackColor = $global:Theme.TabBack
        $Tabs.ForeColor = $global:Theme.TextFore
        foreach ($tp in $Tabs.TabPages) {
            $tp.BackColor = $global:Theme.TabBack
            $tp.ForeColor = $global:Theme.TextFore
        }

        $lblLog.ForeColor = $global:Theme.TextFore

        $txtSearch.BackColor = $global:Theme.InputBack
        if ($global:SearchPlaceholderActive) { $txtSearch.ForeColor = $global:Theme.Placeholder }
        else { $txtSearch.ForeColor = $global:Theme.InputFore }

        $btnRefreshApps.BackColor = $global:Theme.ButtonBack
        $btnRefreshApps.ForeColor = $global:Theme.ButtonFore
        $chkApps.BackColor = $global:Theme.InputBack
        $chkApps.ForeColor = $global:Theme.InputFore
        $btnInstall.BackColor = $global:Theme.ButtonBack
        $btnInstall.ForeColor = $global:Theme.ButtonFore

        foreach ($b in @(
            $btnSmartBoost,$btnUpdate,$btnClean,$btnShort,$btnOpt,$btnScan,$btnRepair,$btnOpenDownloads,$btnOpenLogs,
            $btnPickFile,$btnConvert,$btnPickArc,$btnExtract,$btnSaveSettings,
            $btnInstallSpotify,$btnInstallSpicetify,$btnSpotXInfo,$btnMp3,$btnOpenMusic,$btnOpenScripts,$btnRunCustomUser,$btnRunCustomAdmin,$btnClearCustom,
            $btnVid,$btnOpenMovies,$btnGo,$btnBack,$btnFwd,$btnHome
        )) {
            if ($b) {
                $b.BackColor = $global:Theme.ButtonBack
                $b.ForeColor = $global:Theme.ButtonFore
            }
        }

        $comboMode.BackColor = $global:Theme.InputBack
        $comboMode.ForeColor = $global:Theme.InputFore
        $chkOCR.BackColor = $global:Theme.TabBack
        $chkOCR.ForeColor = $global:Theme.TextFore

        $lblFile.ForeColor = $global:Theme.TextFore
        $lblMode.ForeColor = $global:Theme.TextFore

        $zipTitle.ForeColor = $global:Theme.TextFore
        $lblArc.ForeColor = $global:Theme.TextFore

        foreach ($ctrl in $flow.Controls) {
            if ($ctrl -is [System.Windows.Forms.Button]) {
                $ctrl.BackColor = $global:Theme.ButtonBack
                $ctrl.ForeColor = $global:Theme.ButtonFore
            }

        if ($global:movSitesFlow) {
            foreach ($ctrl in $global:movSitesFlow.Controls) {
                try {
                    $ctrl.BackColor = $global:Theme.ButtonBack
                    $ctrl.ForeColor = $global:Theme.ButtonFore
                    $ctrl.FlatStyle = "Flat"
                    $ctrl.FlatAppearance.BorderColor = $global:Theme.Border
                } catch { }
            }
        }

        }

        $chkChoco.BackColor = $global:Theme.TabBack
        $chkChoco.ForeColor = $global:Theme.TextFore
        $chkDark.BackColor = $global:Theme.TabBack
        $chkDark.ForeColor = $global:Theme.TextFore
        $lblEx.ForeColor = $global:Theme.TextFore
        $txtEx.BackColor = $global:Theme.InputBack
        $txtEx.ForeColor = $global:Theme.InputFore

        # Music tab input theme
        $txtMp3Url.BackColor = $global:Theme.InputBack
        $txtMp3Url.ForeColor = $global:Theme.InputFore
        $txtCustom.BackColor = $global:Theme.InputBack
        $txtCustom.ForeColor = $global:Theme.InputFore
        $txtVidUrl.BackColor = $global:Theme.InputBack
        $txtVidUrl.ForeColor = $global:Theme.InputFore
        if ($txtNav) {
            try { $txtNav.BackColor = $global:Theme.InputBack } catch { }
            try { $txtNav.ForeColor = $global:Theme.InputFore } catch { }
        }

        $lblMusic.ForeColor = $global:Theme.TextFore
        $lblMp3Hint.ForeColor = $global:Theme.TextFore
        $lblCustomWarn.ForeColor = $global:Theme.TextFore
        $lblCustomTip.ForeColor = $global:Theme.TextFore
        $lblVidHint.ForeColor = $global:Theme.TextFore
        $lblCPU.ForeColor = $global:Theme.TextFore
        $lblRAM.ForeColor = $global:Theme.TextFore
        $lblDisk.ForeColor = $global:Theme.TextFore
    }

    $btnSaveSettings.Add_Click({
        $script:Config = Normalize-Config -Cfg $script:Config

        $script:Config.enableChocolatey = [bool]$chkChoco.Checked
        $script:Config.darkMode = [bool]$chkDark.Checked

        $lines = @()
        foreach ($l in ($txtEx.Text -split "`r?`n")) {
            $t = $l.Trim()
            if ($t) { $lines += $t }
        }
        $script:Config.wingetExclusions = $lines

        Save-Config -Cfg $script:Config

        $global:IsDarkMode = [bool]$script:Config.darkMode
        $global:Theme = Build-Theme -isDark $global:IsDarkMode
        Apply-Theme

        [System.Windows.Forms.MessageBox]::Show("Saved to config.json.", "Settings") | Out-Null
    })

    $btnRefreshApps.Add_Click({
        $script:Config = Load-Config
        Populate-AppsList
        Populate-ReadingButtons

        $chkChoco.Checked = [bool]$script:Config.enableChocolatey
        $chkDark.Checked  = [bool]$script:Config.darkMode
        if ($script:Config.wingetExclusions) { $txtEx.Text = ($script:Config.wingetExclusions -join "`r`n") } else { $txtEx.Text = "" }

        $global:IsDarkMode = [bool]$script:Config.darkMode
        $global:Theme = Build-Theme -isDark $global:IsDarkMode
        Apply-Theme

        Write-Log "Reloaded config.json"
    })

    Write-Log "Sixes Hub initialized."
    Write-Log ("Mode: " + $(if (Check-Admin) { "Administrator" } else { "Standard User" }))
    Write-Log "Ready."

    Apply-Theme

    $Form.Add_Shown({
        Refresh-Path
        
        # Safe min sizes after layout exists
        $avail = $Split.Height - $Split.SplitterWidth
        if ($avail -gt 0) {
            $p1 = 300
            $p2 = 160
            if ($avail -lt ($p1 + $p2)) {
                $p1 = [Math]::Max(100, [int]($avail * 0.70))
                $p2 = [Math]::Max(80, $avail - $p1)
            }
            try {
                $Split.Panel1MinSize = $p1
                $Split.Panel2MinSize = $p2
            } catch {
                Write-Log ("WARN: Split min sizes not applied: " + $_.Exception.Message)
            }
        }


        # Safe splitter distance after layout exists
        $min = $Split.Panel1MinSize
        $max = $Split.Height - $Split.Panel2MinSize - $Split.SplitterWidth
        if ($max -gt $min) {
            $desired = [int]($Split.Height * 0.78)
            if ($desired -lt $min) { $desired = $min }
            if ($desired -gt $max) { $desired = $max }
            $Split.SplitterDistance = $desired
        }
    })

    [void]$Form.ShowDialog()
}

Start-SixesHub | Out-Null

###############################################################################
# USER GUIDE (built into the script)
###############################################################################
# Install Apps:
#   - Make sure you have winget installed (Microsoft "App Installer").
#   - Select apps and click Install Selected.
#
# Maintenance:
#   - Smart Boost (Admin) runs safe cleanup + flushdns in an elevated console.
#   - Update Apps (Safe Window) uses winget upgrade and respects exclusions.
#   - Disk Scan / Repair / Optimize run in elevated windows.
#
# Music:
#   - Spotify (Official): installs the official Spotify package via winget.
#   - Spicetify: installs Spicetify + Marketplace in an elevated window.
#   - MP3 Downloader: paste a URL and it saves to Downloads\Music.
#   - Custom Script Runner:
#       - Paste any PowerShell commands you want.
#       - Run Standard User: runs in a new non-elevated PowerShell window.
#       - Run Admin: saves the script to:
#             %LOCALAPPDATA%\SixesHub\custom_script.txt
#         then launches an elevated window that runs it.
#       - Only run scripts you trust.
#
# Movies:
#   - MP4 Downloader: paste URL and it saves to Downloads\Movies.
#   - Mini-browser: quick embedded browser (IE-based WebBrowser control).
#
# Convert:
#   - Choose a file then select a conversion mode.
#   - Tools auto-install with winget when missing (with confirmation).
#
# Unzip:
#   - ZIP extracts with Expand-Archive
#   - RAR extracts with WinRAR (auto-install supported).
#
###############################################################################
# EXTRA NOTES
###############################################################################
# - The embedded browser is Windows Forms WebBrowser (legacy). For modern sites,
#   consider upgrading to WebView2 in the future.
# - If a tool installs but isn't detected, close Sixes Hub and reopen.
###############################################################################