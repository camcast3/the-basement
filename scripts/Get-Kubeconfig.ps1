<#
.SYNOPSIS
    Fetch kubeconfig from Omni for The Basement K8s cluster.

.DESCRIPTION
    Uses omnictl to pull a fresh kubeconfig from the Omni management plane.
    Safe to re-run anytime kubectl stops working (e.g., expired tokens).
    If your PGP key has expired, omnictl will open a browser for SAML re-auth.

.PARAMETER Cluster
    Cluster name (default: k8s-homelab)

.PARAMETER Output
    Output file path (default: ~/.kube/config)

.PARAMETER Force
    Overwrite existing kubeconfig without creating a backup

.EXAMPLE
    .\scripts\Get-Kubeconfig.ps1
    .\scripts\Get-Kubeconfig.ps1 -Cluster my-cluster
    .\scripts\Get-Kubeconfig.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Cluster = $env:OMNI_CLUSTER,
    [string]$Output = $env:KUBECONFIG_OUTPUT,
    [string]$OmniUrl = $env:OMNI_URL,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# --- Defaults ----------------------------------------------------------------
if (-not $Cluster) { $Cluster = "k8s-homelab" }
if (-not $Output) { $Output = Join-Path $env:USERPROFILE ".kube\config" }
if (-not $OmniUrl) { $OmniUrl = "https://omni.local.negativezone.cc" }

# --- Helpers -----------------------------------------------------------------
function Write-Info  { param($msg) Write-Host "==> $msg" -ForegroundColor Blue }
function Write-Ok    { param($msg) Write-Host " ✓  $msg" -ForegroundColor Green }
function Write-Err   { param($msg) Write-Host " ✗  $msg" -ForegroundColor Red }

# --- Ensure ~/.local/bin is in PATH (for omnictl and kubectl plugins) --------
$localBin = Join-Path $env:USERPROFILE ".local\bin"
if ($env:PATH -notlike "*$localBin*") {
    $env:PATH = "$localBin;$env:PATH"
}
# Persist to user PATH if not already there
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($userPath -and $userPath -notlike "*$localBin*") {
    [Environment]::SetEnvironmentVariable("PATH", "$localBin;$userPath", "User")
    Write-Info "Added $localBin to user PATH (restart terminal for other sessions)"
}

$omnictl = Get-Command omnictl -ErrorAction SilentlyContinue
if (-not $omnictl) {
    Write-Err "omnictl not found. Install it with: .\scripts\setup-k8s-tools.sh"
    exit 1
}

# --- Configure omnictl endpoint ----------------------------------------------
Write-Info "Omni endpoint: $OmniUrl"
Write-Info "Cluster: $Cluster"

& omnictl config url $OmniUrl 2>$null

# --- Backup existing kubeconfig ----------------------------------------------
if ((Test-Path $Output) -and -not $Force) {
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $backup = "$Output.bak.$timestamp"
    Copy-Item $Output $backup
    Write-Info "Backed up existing kubeconfig to $backup"
}

# --- Fetch kubeconfig --------------------------------------------------------
Write-Info "Fetching kubeconfig from Omni (browser may open for auth)..."
$outputDir = Split-Path $Output -Parent
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

& omnictl kubeconfig -c $Cluster --force $Output
if ($LASTEXITCODE -ne 0) {
    Write-Err "Failed to fetch kubeconfig. Ensure you are authenticated with Omni."
    exit 1
}

Write-Ok "Kubeconfig written to $Output"

# --- Verify connectivity -----------------------------------------------------
Write-Info "Verifying cluster connectivity..."
$result = & kubectl --kubeconfig $Output get nodes --request-timeout=10s 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Ok "kubectl is working — cluster nodes reachable"
    Write-Host ""
    & kubectl --kubeconfig $Output get nodes
} else {
    Write-Err "Could not reach cluster nodes. Kubeconfig was written but cluster may be unreachable."
    Write-Host "  Check: network connectivity, DNS for $OmniUrl, and cluster health in Omni."
    Write-Host "  If using oidc-login, ensure kubelogin is installed: kubectl-oidc_login.exe in PATH"
    exit 1
}
