# Using AZCopy to copy ArcGIS Software.

param(
    [Parameter(Mandatory=$true)] [string] $StorageAccount,
    [Parameter(Mandatory=$true)] [string] $Container,
    [Parameter()]                 [string] $Prefix       = "ArcGIS",
    [Parameter()]                 [string] $DownloadDir  = "C:\Install"
    # Provide exactly one of: $UseManagedIdentity -or- $Sas
)


#$ResourceGroup  = "AIB"                       # your RG
#$StorageAccount = "stimagebuilderbsaib"       # from your screenshot
#$Container      = "software"                  # container name
#$Prefix         = "ArcGIS"                    # optional: folder/prefix under container
#$DownloadDir    = "C:\Install"         # local target folder

Write-Host "Starting ArcGIS Pro installation script…"
Write-Host "Storage Account : $StorageAccount and Container is $Container and prefix is $Prefix"

# Create target folder where the installers will be downloaded
New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null

#Downdload using AZCopuy (more robust for large files)
$ProgressPreference = 'SilentlyContinue'
$azCopyUrl = "https://aka.ms/downloadazcopy-v10-windows"
$zipPath   = "$env:TEMP\azcopy.zip"
Invoke-WebRequest -Uri $azCopyUrl -OutFile $zipPath -UseBasicParsing
Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\azcopy" -Force
$azcopyExe = Get-ChildItem "$env:TEMP\azcopy" -Recurse -Filter azcopy.exe | Select-Object -First 1 -Expand FullName
Write-Host "AzCopy at $azcopyExe"


$env:AZCOPY_MSI_CLIENT_ID = "e884b190-8b2a-49e3-851d-0b913de2e5df"

& $azcopyExe login --identity --identity-client-id "e884b190-8b2a-49e3-851d-0b913de2e5df"

& $azcopyExe copy "https://${StorageAccount}.blob.core.windows.net/${Container}/${prefix}?${sas}" $DownloadDir --recursive

<# 
    ArcGIS Pro install bootstrap
    - Installs Microsoft Edge WebView2 Runtime (x64)
    - Installs .NET Windows Desktop Runtime 8.0.22 (x64)
    - Installs ArcGIS Pro MSI (with CABs present in same folder)
    - Applies ArcGIS Pro MSP patch
    - Writes logs per step and handles 0/3010 exit codes
    - Idempotent checks: will skip already-installed components

    Run as: Admin/SYSTEM (e.g., AIB customization or provisioning step)
#>

# ========================
# Configurable parameters
# ========================
$SourceDir     = "C:\Install\ArcGIS"   # where you downloaded all binaries
$LogDir        = "C:\Install\\Logs"
$ArcGisMsi     = Join-Path $SourceDir "ArcGISPro.msi"
$ArcGisCab1    = Join-Path $SourceDir "ArcGISPro.cab"
$ArcGisCab2    = Join-Path $SourceDir "ArcGISPro1.cab"
$ArcGisPatch   = Join-Path $SourceDir "ArcGIS_Pro_361_198430.msp"  # adjust if your patch name differs

$WebView2Exe   = Join-Path $SourceDir "MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
$DotNetDesktop = Join-Path $SourceDir "windowsdesktop-runtime-8.0.22-win-x64.exe"

# MSI logging flags (verbose + status)
$MsiLogFlags   = "/l*v"

# Ensure logging directory
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null



# ---- Resolve msiexec robustly ----
function Get-MsiExecPath{
    try {
        $cmd = Get-Command msiexec.exe -ErrorAction Stop
        return $cmd.Source
    } catch {
        $paths = @(
            Join-Path $env:SystemRoot 'System32\msiexec.exe'),  # 64-bit native
            (Join-Path $env:SystemRoot 'SysWOW64\msiexec.exe'    # 32-bit fallback
        )
        foreach ($p in $paths) {
            if (Test-Path -LiteralPath $p) { return $p }
        }
        throw "msiexec.exe not found in PATH and not present at expected locations."
    }
}
$MsiExec = Get-MsiExecPath
$MsiLogFlags = '/l*v'  # verbose logging



# ========================
# Helper functions
# ========================

function Write-Info($msg)  { Write-Host "[INFO]  $msg" }
function Write-Warn($msg)  { Write-Warning "[WARN]  $msg" }
function Write-Err($msg)   { Write-Error "[ERROR] $msg" }

function Test-File($path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

# Return $true if product appears installed in registry (best-effort)
function Test-InstalledByDisplayName {
    param(
        [Parameter(Mandatory=$true)][string]$DisplayNamePattern
    )
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($p in $paths) {
        $items = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
        foreach ($it in $items) {
            if ($it.DisplayName -and ($it.DisplayName -like $DisplayNamePattern)) { return $true }
        }
    }
    return $false
}

# Run a process and accept 0 or 3010 (soft reboot) as success
function Invoke-Process {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Arguments,
        [Parameter(Mandatory=$true)][string]$LogName
    )
    Test-File $FilePath
    $logFile = Join-Path $LogDir $LogName
    Write-Info "Executing: `"$FilePath`" $Arguments"
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -Wait -NoNewWindow
    $code = $p.ExitCode
    if ($code -eq 0 -or $code -eq 3010) {
        if ($code -eq 3010) { Write-Warn "$LogName completed with 3010 (reboot recommended). Continuing." }
        Write-Info "$LogName finished successfully (code $code)."
    } else {
        throw "$LogName failed with exit code $code. See logs at $logFile (if MSI) or console output."
    }
}

# Install MSI with standard flags; ensures CABs are present

function Install-MSI {
    param(
        [Parameter(Mandatory)][string]$MsiPath,
        [hashtable]$Properties = @{},
        [string]$LogName = 'msi-install.log'
    )
    if (-not (Test-Path -LiteralPath $MsiPath)) {
        throw "MSI not found: $MsiPath"
    }
    $propArgs = ''
    foreach ($k in $Properties.Keys) {
        $v = $Properties[$k]
        $propArgs += " $k=`"$v`""
    }
    $logFile = Join-Path $LogDir $LogName
    $args = "/i `"$MsiPath`"$propArgs REBOOT=ReallySuppress $MsiLogFlags `"$logFile`" /qn"
    Invoke-Process -FilePath $MsiExec -Arguments $args -LogName $LogName
}

# Apply MSP patch
function Patch-MSI {
    param(
        [Parameter(Mandatory=$true)][string]$MspPath,
        [Parameter()][string]$LogName = "msi-patch.log"
    )
   
      if (-not (Test-Path -LiteralPath $MspPath)) {
            throw "MSP not found: $MspPath"
        }
        $logFile = Join-Path $LogDir $LogName
        $args = "/update `"$MspPath`" REBOOT=ReallySuppress $MsiLogFlags `"$logFile`" /qn"
        Invoke-Process -FilePath $MsiExec -Arguments $args -LogName $LogName

}

# ========================
# 1) Prerequisites
# ========================

# WebView2 Runtime (required by many modern apps; ArcGIS uses Edge WebView for components)
if (-not (Test-InstalledByDisplayName -DisplayNamePattern "*Microsoft Edge WebView2 Runtime*")) {
    Write-Info "Installing Microsoft Edge WebView2 Runtime (x64)…"
    # Supported silent flags: /silent /install
    Invoke-Process -FilePath $WebView2Exe -Arguments "/silent /install -wait -verb RunAs" -LogName "webview2-install.log"

} else {
    Write-Info "WebView2 Runtime already installed. Skipping."
}

# .NET Windows Desktop Runtime 8.0.22 (x64)
if (-not (Test-InstalledByDisplayName -DisplayNamePattern "*Microsoft .NET*Desktop Runtime*8*")) {
    Write-Info "Installing .NET Windows Desktop Runtime 8.0.22 (x64)…"
    # Standard quiet flags: /quiet /norestart
    Invoke-Process -FilePath $DotNetDesktop -Arguments "/quiet /norestart" -LogName "dotnet-desktop-runtime-8.0.22.log"
} else {
    Write-Info ".NET Desktop Runtime 8.x already installed. Skipping."
}

# ========================
# 2) ArcGIS Pro base install
# The ArcGIS Pro base installation took about 15-20 minutes
# ========================

# Validate required files present
Test-File $ArcGisMsi
Test-File $ArcGisCab1
Test-File $ArcGisCab2

# Idempotent check for ArcGIS Pro
if (-not (Test-InstalledByDisplayName -DisplayNamePattern "*ArcGIS Pro*")) {
    Write-Info "Installing ArcGIS Pro base MSI…"
    # Example properties: ACCEPTEULA=Yes; ADDLOCAL=ALL; INSTALLDIR override if needed.
    # Consult Esri doc if you need license manager/server options (e.g., AUTHORIZATION_TYPE, etc.)
    $arcProps = @{
        "INSTALLDIR"="C:\ArcGIS\Pro"
        "ALLUSERS"="1"
        "ACCEPTEULA" = "Yes"
        "ADDLOCAL"   = "ALL"
        "ENABLEEUEI" = "0"
        "ENABLE_ERROR_REPORTS" = "0"
        "AUTHORIZATION_TYPE"="NAMED_USER"
        "LICENSE_URL" = "https://gss-aklc-gis-prod.aucklandcouncil.govt.nz/portal"    
    }
    Install-MSI -MsiPath $ArcGisMsi -Properties $arcProps -LogName "ArcGISPro-base.log"
} else {
    Write-Info "ArcGIS Pro already installed. Skipping base MSI."
}

# ========================
# 3) ArcGIS Pro patch (.msp)
# ========================

if (Test-Path -LiteralPath $ArcGisPatch) {
    Write-Info "Applying ArcGIS Pro patch MSP…"
    Patch-MSI -MspPath $ArcGisPatch -LogName "ArcGISPro-patch.log"
} else {
    Write-Warn "Patch file not found at $ArcGisPatch. Skipping MSP step."
}

# ========================
# 4) Final validation (best-effort)
# ========================
Write-Info "Final validation (best-effort)…"
$arcInstalled = Test-InstalledByDisplayName -DisplayNamePattern "*ArcGIS Pro*"
$webview2     = Test-InstalledByDisplayName -DisplayNamePattern "*Microsoft Edge WebView2 Runtime*"
$dotnet80     = Test-InstalledByDisplayName -DisplayNamePattern "*Microsoft .NET*Desktop Runtime*8*"

Write-Host "---- Validation Summary ----"
Write-Host ("ArcGIS Pro installed:       {0}" -f ($arcInstalled))
Write-Host ("WebView2 Runtime installed: {0}" -f ($webview2))
Write-Host (".NET Desktop 8.x installed: {0}" -f ($dotnet80))
Write-Host ("Logs directory:             {0}" -f ($LogDir))
Write-Host "----------------------------"

Write-Info "Installation script completed."
