param(
    [string]$ProjectRoot = (Join-Path $env:USERPROFILE 'Downloads\watch_tube')
)

$ErrorActionPreference = 'Stop'
$SourceRoot = $PSScriptRoot
$TargetRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$SourceLib = Join-Path $SourceRoot 'lib'
$SourceTest = Join-Path $SourceRoot 'test'
$SourcePubspec = Join-Path $SourceRoot 'pubspec.yaml'

if (-not (Test-Path (Join-Path $TargetRoot 'lib\main.dart'))) {
    throw "Flutter project not found at '$TargetRoot'. Use -ProjectRoot with the correct existing project path."
}
if (-not (Test-Path $SourceLib) -or -not (Test-Path $SourcePubspec)) {
    throw "Patch files are missing beside this script. Extract the whole ZIP before running it."
}
if ($TargetRoot -eq [System.IO.Path]::GetFullPath($SourceRoot)) {
    throw 'Extract the patch to a separate folder, not over the project folder itself.'
}

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupRoot = Join-Path $TargetRoot "watch_tube_backup_$Stamp"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

try {
    foreach ($Name in @('lib', 'pubspec.yaml', 'test')) {
        $Existing = Join-Path $TargetRoot $Name
        if (Test-Path $Existing) {
            Move-Item -Path $Existing -Destination (Join-Path $BackupRoot $Name)
        }
    }

    $TargetLib = Join-Path $TargetRoot 'lib'
    New-Item -ItemType Directory -Path $TargetLib -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceLib '*') -Destination $TargetLib -Recurse -Force

    Copy-Item -Path $SourcePubspec -Destination (Join-Path $TargetRoot 'pubspec.yaml') -Force
    if (Test-Path $SourceTest) {
        $TargetTest = Join-Path $TargetRoot 'test'
        New-Item -ItemType Directory -Path $TargetTest -Force | Out-Null
        Copy-Item -Path (Join-Path $SourceTest '*') -Destination $TargetTest -Recurse -Force
    }

    Write-Host ''
    Write-Host 'Patch applied.' -ForegroundColor Green
    Write-Host "Backup: $BackupRoot"
    Write-Host 'Your existing android/ folder was not changed.'
    Write-Host 'Next run: flutter pub get; flutter test; flutter run -d 127.0.0.1:5556'
} catch {
    Write-Warning 'Patch failed. Restoring backed-up files where possible.'
    foreach ($Name in @('lib', 'pubspec.yaml', 'test')) {
        $TargetItem = Join-Path $TargetRoot $Name
        $BackupItem = Join-Path $BackupRoot $Name
        if (Test-Path $BackupItem) {
            if (Test-Path $TargetItem) { Remove-Item -Path $TargetItem -Recurse -Force }
            Move-Item -Path $BackupItem -Destination $TargetItem
        }
    }
    throw
}
