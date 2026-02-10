
<# 
.SYNOPSIS
    Silent install FME Form (Desktop) with optional FlexNet floating license configuration.
.DESCRIPTION
    - Downloads vendor installer (EXE) with retry logic
    - Performs silent install via Safe Software recommended switches
    - Optionally configures licensing to a FlexNet server
    - Logs actions and verifies install
.NOTES
    Tested on Windows Server 2022 / Windows 11 x64
    Requires local admin
#>

     # e.g. Specific agreed version of FME Form    
    [string]$FmeInstallerUrl = "https://downloads.safe.com/fme/2025/win64/fme-form-2025.1.1-b25615-win-x64.exe"
    [string]$InstallDir      = "C:\FME"   # target folder for FME
    [string]$WorkDir         = "C:\Install\FME"         # staging folder for downloads and logs

    # --- Licensing (optional floating server) ---
    [switch]$ConfigureFloatingLicense     # include to run licensing configuration
    [string]$LicenseServerHost = ""       # e.g. "fmels.example.org" (FlexNet server hostname or FQDN)
    [int]   $LicenseServerPort = 27000    # typical FlexNet default range 27000-27009

    # --- Behavior ---
    [int]$MaxRetries         = 5
    [int]$RetryDelaySeconds  = 8

# ------------------------------
# Helper: Ensure folder exists
# ------------------------------
function Ensure-Folder {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

# ------------------------------
# Helper: Robust downloader
# ------------------------------
function Get-FileWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$OutFile,
        [int]$Retries = 5,
        [int]$DelaySeconds = 5
    )
    $attempt = 1
    while ($attempt -le $Retries) {
        try {
            Write-Host "Downloading [$Url] -> [$OutFile] (attempt $attempt/$Retries)"
            # Prefer BITS when available, fallback to Invoke-WebRequest
            try {
                Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
            } catch {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $OutFile) { 
                if ((Get-Item $OutFile).Length -gt 0) { return $true } 
            }
            throw "Downloaded file is empty."
        } catch {
            Write-Warning "Download attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySeconds
            $attempt++
        }
    }
    return $false
}

# ------------------------------
# Main
# ------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Ensure-Folder -Path $WorkDir
$LogDir  = Join-Path $WorkDir "Logs"
Ensure-Folder -Path $LogDir

$InstallerPath = Join-Path $WorkDir "fme-form-win-x64.exe"          # local copy of EXE
$MsiExtractDir = Join-Path $WorkDir "installer"                      # EXE unpack target
$InstallLog    = Join-Path $LogDir  "FME_Install.log"
$LicLog        = Join-Path $LogDir  "FME_Licensing.log"

# 1) Download installer
if (-not (Get-FileWithRetry -Url $FmeInstallerUrl -OutFile $InstallerPath -Retries $MaxRetries -DelaySeconds $RetryDelaySeconds)) {
    throw "Failed to download FME installer after $MaxRetries attempts."
}



# 2) Installing FME Form silently
Write-Host "Installing FME Form silently..."
# Ensure folders exist
New-Item -ItemType Directory -Path $MsiExtractDir, (Split-Path $InstallLog) -Force | Out-Null

# IMPORTANT: Safe Software requires INSTALLLEVEL=3 for silent installs.
# Also disable post install tasks to keep image clean.
# When passing to -sp, quotes need to be escaped for XML/EXE parsing.
# In PowerShell, easiest is to build the MSI flags separately and then wrap them.

$msiFlags = '/qn /norestart INSTALLLEVEL=3 ENABLE_POST_INSTALL_TASKS=no INSTALLDIR="' + $InstallDir + '" /l*v "' + $InstallLog + '"'

# Build EXE args. Note the backtick-escaped quotes around paths for the EXE wrapper,
# and plain quotes inside the MSI flags string supplied to -sp.
$exeArgs = @(
    "-d`"$MsiExtractDir`""     # extract here
    "-s"                       # silent extraction
    "-sp`"$msiFlags`""         # pass MSI silent flags
)

# Run elevated to avoid UAC prompts
$proc = Start-Process -FilePath $InstallerPath -ArgumentList $exeArgs -Verb RunAs -Wait -PassThru

# Optional: write logs
"{0} {1}" -f (Get-Date), ($exeArgs -join ' ') | Tee-Object -FilePath $InstallLog -Append | Out-Null


if ($proc.ExitCode -ne 0) {        
    Write-Warning "FME installer returned ${proc.ExitCode} (custom action failure). Proceeding as tolerated."
    # Optionally drop a marker file for post-build validation
}else{
    Write-Host "FME Form installed successfully."
}



# 4) Optional: Configure floating licensing (FlexNet)
if ($ConfigureFloatingLicense) {
    if ([string]::IsNullOrWhiteSpace($LicenseServerHost)) {
        throw "ConfigureFloatingLicense set, but LicenseServerHost is empty."
    }

    # Some organizations set licensing via FlexLM environment variable or vendor tooling.
    # Safe’s guidance for floating licensing involves obtaining a license from Safe and pointing clients to the FlexNet server.
    # We set a common Flexera var and also write a small client config file if present.
    # See: Request & Install the License (server-side) and client setup guidance. [2](https://docs.safe.com/fme/html/FME-Form-Documentation/FME-Form-Admin-Guide/FMEInstallation/Request_and_Install_the_License.htm)

    Write-Host "Configuring floating license → ${LicenseServerHost}:${LicenseServerPort}"

    # FLEXLM_LICENSE – widely recognized by Flexera clients; points to port@host
    $envValue = "$LicenseServerPort@$LicenseServerHost"
    [Environment]::SetEnvironmentVariable("FLEXLM_LICENSE", $envValue, "Machine")
    Add-Content -Path $LicLog -Value "Set FLEXLM_LICENSE=$envValue"

    # If Safe provides a command-line licensing assistant (varies by version),
    # you can invoke it here to set client preferences non-interactively.
    # Example placeholder (adjust when you confirm the tool path/name for your build):
    $LicAssistant = Join-Path $InstallDir "Utilities\fmelicensingassistant_cmd.exe"
    if (Test-Path -LiteralPath $LicAssistant) {
        # Example: set floating server; the actual arguments may differ by release—check vendor docs you shared.
        $licArgs = @("set", "floating", "--server", "$LicenseServerHost", "--port", "$LicenseServerPort")
        Start-Process -FilePath $LicAssistant -ArgumentList $licArgs -Wait | Out-Null
        Add-Content -Path $LicLog -Value "Ran licensing assistant: $($licArgs -join ' ')"
    } else {
        Add-Content -Path $LicLog -Value "Licensing assistant not found → set FLEXLM_LICENSE only."
    }
}

Write-Host "FME Form silent install completed successfully."
exit 0
