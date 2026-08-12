# Collabo IDE — Windows 배포 패키징 (release 빌드 → zip)
#
# 사용법:  powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1
# 결과:    dist\CollaboIDE-<버전>-windows-<arch>.zip
#
# zip 은 최상위에 "Collabo IDE" 폴더 하나를 담아, 풀면 폴더째 나오게 한다.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$appName = 'Collabo IDE'
# pubspec.yaml 의 version(+빌드번호 제외)을 파일명에 쓴다.
$line = (Get-Content pubspec.yaml | Select-String '^version:' | Select-Object -First 1)
if (-not $line) { throw 'version not found in pubspec.yaml' }
$version = ($line.ToString() -replace '^version:\s*', '') -replace '\+.*', ''
$version = $version.Trim()

flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

# Flutter 버전/아키텍처에 따라 출력 경로가 다르다(x64 / arm64 / 구버전 공통).
$candidates = @(
  'build\windows\x64\runner\Release',
  'build\windows\arm64\runner\Release',
  'build\windows\runner\Release'
)
$rel = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $rel) { throw "release output not found (looked in: $($candidates -join ', '))" }
$arch = if ($rel -match 'arm64') { 'arm64' } else { 'x64' }

New-Item -ItemType Directory -Force dist | Out-Null
$zip = "dist\CollaboIDE-$version-windows-$arch.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

# 스테이징: zip 최상위에 "Collabo IDE" 폴더가 오도록 담는다.
$stage = Join-Path $env:TEMP ("collabo_pkg_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $stage $appName) | Out-Null
try {
  Copy-Item "$rel\*" (Join-Path $stage $appName) -Recurse
  Compress-Archive -Path (Join-Path $stage $appName) -DestinationPath $zip
} finally {
  Remove-Item $stage -Recurse -Force
}
Write-Host "Created: $zip"
