<#
.SYNOPSIS
  Menu único para Export-SecurityBaselines.ps1 e Import-SecurityBaselines.ps1.

.DESCRIPTION
    Pergunta se você quer Exportar ou Importar Security Baselines e chama o
    script correspondente com os parâmetros informados. Não duplica a lógica
    de export/import — apenas repassa para os scripts originais, que devem
    estar na mesma pasta.

.PARAMETER Mode
    "Exportar" ou "Importar". Se omitido, o script pergunta interativamente.

.PARAMETER OutputPath
    (Export) Pasta de destino dos JSONs exportados.

.PARAMETER SourcePath
    (Import) Pasta com os JSONs a importar.

.PARAMETER GroupAssignmentId
    (Import) Object ID de um grupo do Entra ID para atribuir as políticas criadas.

.PARAMETER KeepAsBaseline
    (Import) Preserva o vínculo com o Security Baseline template original.

.PARAMETER OverwriteExisting
    (Import) Sobrescreve políticas com nome idêntico.

.PARAMETER AdminUPN
    UPN do administrador — usado como login hint no device code.

.PARAMETER ClientId
    Application (client) ID do app registrado no Entra ID.

.PARAMETER TenantId
    Directory (tenant) ID ou domínio (ex: contoso.onmicrosoft.com).

.EXAMPLE
  .\Manage-SecurityBaselines.ps1
  Pergunta Exportar/Importar e depois pede o restante interativamente.

.EXAMPLE
  .\Manage-SecurityBaselines.ps1 -Mode Importar -SourcePath ".\Exported-Baselines" -OverwriteExisting

.NOTES
  Version:  1.0.0
  Author:   Marcelo Gonçalves
  Date:     2026-08-12
  Requires: Export-SecurityBaselines.ps1 e Import-SecurityBaselines.ps1 na mesma pasta.
#>
[CmdletBinding()]
param(
    [ValidateSet("Exportar", "Importar", "")]
    [string]$Mode = "",

    # Export
    [string]$OutputPath = "",

    # Import
    [string]$SourcePath        = "",
    [string]$GroupAssignmentId = "",
    [switch]$KeepAsBaseline,
    [switch]$OverwriteExisting,

    # Comuns (autenticação)
    [string]$AdminUPN = "",
    [string]$ClientId = "",
    [string]$TenantId = ""
)

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$exportScript = Join-Path $scriptDir "Export-SecurityBaselines.ps1"
$importScript = Join-Path $scriptDir "Import-SecurityBaselines.ps1"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Security Baselines - Menu Export/Import                   " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $exportScript) -or -not (Test-Path $importScript)) {
    Write-Host "  ERRO: Export-SecurityBaselines.ps1 e Import-SecurityBaselines.ps1 precisam estar na mesma pasta deste script." -ForegroundColor Red
    exit 1
}

if (-not $Mode) {
    Write-Host "  O que você deseja fazer?" -ForegroundColor Cyan
    Write-Host "  [1] Exportar baselines do Intune para JSON" -ForegroundColor White
    Write-Host "  [2] Importar baselines de JSON para o Intune" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Opção (1 ou 2)"
    $Mode   = if ($choice -eq '2') { "Importar" } else { "Exportar" }
}

# ── Parâmetros comuns de autenticação ─────────────────────────────────────────
$commonParams = @{}
if ($AdminUPN) { $commonParams.AdminUPN = $AdminUPN }
if ($ClientId) { $commonParams.ClientId = $ClientId }
if ($TenantId) { $commonParams.TenantId = $TenantId }

if ($Mode -eq "Importar") {
    $params = $commonParams.Clone()
    if ($SourcePath)        { $params.SourcePath        = $SourcePath }
    if ($GroupAssignmentId) { $params.GroupAssignmentId = $GroupAssignmentId }
    if ($KeepAsBaseline)    { $params.KeepAsBaseline    = $true }
    if ($OverwriteExisting) { $params.OverwriteExisting = $true }

    Write-Host "  Modo: Importar" -ForegroundColor Green
    Write-Host ""
    & $importScript @params
}
else {
    $params = $commonParams.Clone()
    if ($OutputPath) { $params.OutputPath = $OutputPath }

    Write-Host "  Modo: Exportar" -ForegroundColor Green
    Write-Host ""
    & $exportScript @params
}
