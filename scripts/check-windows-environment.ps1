# Run manually in Windows PowerShell on the intended Windows machine.
# Read-only toolchain checks. Does not inspect or operate WeChat.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run on Windows; a Mac .NET installation is not Windows evidence.' }
$os = Get-CimInstance Win32_OperatingSystem
[pscustomobject]@{ Caption = $os.Caption; Version = $os.Version; Build = $os.BuildNumber; Architecture = $os.OSArchitecture }
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) { & dotnet --list-sdks } else { 'BLOCKED: .NET SDK missing' }
$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$makeappx = @()
$signtool = @()
if (Test-Path $kits) {
    $makeappx = @(Get-ChildItem $kits -Filter makeappx.exe -Recurse | Where-Object { $_.FullName -match '\\x64\\' })
    $signtool = @(Get-ChildItem $kits -Filter signtool.exe -Recurse | Where-Object { $_.FullName -match '\\x64\\' })
}
if ($makeappx.Count) { $makeappx | Select-Object -ExpandProperty FullName } else { 'BLOCKED: x64 MakeAppx not found' }
if ($signtool.Count) { $signtool | Select-Object -ExpandProperty FullName } else { 'BLOCKED: x64 SignTool not found' }
# Print counts only; no private key, certificate subject, or account identifiers.
$signing = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
    @($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId.Value -eq '1.3.6.1.5.5.7.3.3' }).Count -gt 0
})
'Current-user unexpired code-signing certificates with private key: ' + $signing.Count
'NOT VERIFIED: certificate trust, publisher match, MSIX install, Share Target registration, actual WeChat menu and cold/hot receiving.'
'Enter WeChat version manually later. This script does not detect it.'
