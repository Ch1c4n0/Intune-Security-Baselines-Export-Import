<#
.SYNOPSIS
  Single menu for Export-SecurityBaselines.ps1 and Import-SecurityBaselines.ps1.

.DESCRIPTION
    Asks whether you want to Export or Import Security Baselines and calls the
    corresponding script with the given parameters. Does not duplicate the
    export/import logic — it just forwards to the original scripts, which must
    be in the same folder.

.PARAMETER Mode
    "Export" or "Import". If omitted, the script asks interactively.

.PARAMETER OutputPath
    (Export) Destination folder for the exported JSONs.

.PARAMETER SourcePath
    (Import) Folder with the JSONs to import.

.PARAMETER GroupAssignmentId
    (Import) Object ID of an Entra ID group to assign the created policies to.

.PARAMETER KeepAsBaseline
    (Import) Preserves the link to the original Security Baseline template.

.PARAMETER OverwriteExisting
    (Import) Overwrites policies with an identical name.

.PARAMETER AdminUPN
    Administrator UPN — used as login hint in the device code flow.

.PARAMETER ClientId
    Application (client) ID of the app registered in Entra ID.

.PARAMETER TenantId
    Directory (tenant) ID or domain (e.g. contoso.onmicrosoft.com).

.EXAMPLE
  .\Manage-SecurityBaselines.ps1
  Asks Export/Import and then prompts for the rest interactively.

.EXAMPLE
  .\Manage-SecurityBaselines.ps1 -Mode Import -SourcePath ".\Exported-Baselines" -OverwriteExisting

.NOTES
  Version:  1.0.0
  Author:   Marcelo Gonçalves
  Date:     2026-08-12
  Requires: Export-SecurityBaselines.ps1 and Import-SecurityBaselines.ps1 in the same folder.
#>
[CmdletBinding()]
param(
    [ValidateSet("Export", "Import", "")]
    [string]$Mode = "",

    # Export
    [string]$OutputPath = "",

    # Import
    [string]$SourcePath        = "",
    [string]$GroupAssignmentId = "",
    [switch]$KeepAsBaseline,
    [switch]$OverwriteExisting,

    # Common (authentication)
    [string]$AdminUPN = "",
    [string]$ClientId = "",
    [string]$TenantId = ""
)

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$exportScript = Join-Path $scriptDir "Export-SecurityBaselines.ps1"
$importScript = Join-Path $scriptDir "Import-SecurityBaselines.ps1"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Security Baselines - Export/Import Menu                   " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $exportScript) -or -not (Test-Path $importScript)) {
    Write-Host "  ERROR: Export-SecurityBaselines.ps1 and Import-SecurityBaselines.ps1 must be in the same folder as this script." -ForegroundColor Red
    exit 1
}

if (-not $Mode) {
    Write-Host "  What do you want to do?" -ForegroundColor Cyan
    Write-Host "  [1] Export baselines from Intune to JSON" -ForegroundColor White
    Write-Host "  [2] Import baselines from JSON into Intune" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Option (1 or 2)"
    $Mode   = if ($choice -eq '2') { "Import" } else { "Export" }
}

# ── Common authentication parameters ──────────────────────────────────────────
$commonParams = @{}
if ($AdminUPN) { $commonParams.AdminUPN = $AdminUPN }
if ($ClientId) { $commonParams.ClientId = $ClientId }
if ($TenantId) { $commonParams.TenantId = $TenantId }

if ($Mode -eq "Import") {
    $params = $commonParams.Clone()
    if ($SourcePath)        { $params.SourcePath        = $SourcePath }
    if ($GroupAssignmentId) { $params.GroupAssignmentId = $GroupAssignmentId }
    if ($KeepAsBaseline)    { $params.KeepAsBaseline    = $true }
    if ($OverwriteExisting) { $params.OverwriteExisting = $true }

    Write-Host "  Mode: Import" -ForegroundColor Green
    Write-Host ""
    & $importScript @params
}
else {
    $params = $commonParams.Clone()
    if ($OutputPath) { $params.OutputPath = $OutputPath }

    Write-Host "  Mode: Export" -ForegroundColor Green
    Write-Host ""
    & $exportScript @params
}
