[CmdletBinding()]
param([string]$Version = '2.8.0', [switch]$SkipPublish)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $root '.cache'
$dist = Join-Path $root 'dist'
$package = Join-Path $dist 'Jethriki'
$tools = Join-Path $package 'tools'
$licenses = Join-Path $package 'licenses'
$lock = Get-Content (Join-Path $root 'dependencies.lock.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force $cache,$dist | Out-Null
if (Test-Path $package) { Remove-Item $package -Recurse -Force }
New-Item -ItemType Directory -Force $package,$tools,$licenses | Out-Null
if (-not $SkipPublish) {
    dotnet publish (Join-Path $root 'App/YtdlpStudio.Windows.csproj') -c Release -r win-x64 --self-contained true -p:Version=$Version -p:PublishTrimmed=false -o $package
    if ($LASTEXITCODE -ne 0) { throw 'App publishing failed.' }
}
function Get-Verified([string]$Url, [string]$Hash, [string]$Name) {
    $path = Join-Path $cache $Name
    if (-not (Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
        Invoke-WebRequest -Uri $Url -OutFile $path
    }
    if ((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) { Remove-Item $path; throw "Checksum mismatch for $Name" }
    return $path
}
$yt = Get-Verified $lock.ytDlp.url $lock.ytDlp.sha256 "yt-dlp-$($lock.ytDlp.version).exe"
Copy-Item $yt (Join-Path $tools 'yt-dlp.exe')
$ff = Get-Verified $lock.ffmpeg.url $lock.ffmpeg.sha256 "ffmpeg-$($lock.ffmpeg.version).zip"
$ffdir = Join-Path $cache "ffmpeg-$($lock.ffmpeg.version)"
if (-not (Test-Path $ffdir)) { Expand-Archive -Path $ff -DestinationPath $ffdir }
foreach ($name in @('ffmpeg.exe','ffprobe.exe')) {
    $file = Get-ChildItem $ffdir -Recurse -File -Filter $name | Select-Object -First 1
    if (-not $file) { throw "$name missing in FFmpeg archive." }
    Copy-Item $file.FullName (Join-Path $tools $name)
}
$ffroot = Get-ChildItem $ffdir -Directory | Select-Object -First 1
foreach ($name in @('LICENSE','README.txt','doc')) { $path = Join-Path $ffroot.FullName $name; if (Test-Path $path) { Copy-Item $path (Join-Path $licenses "ffmpeg-$name") -Recurse } }
$deno = Get-Verified $lock.deno.url $lock.deno.sha256 "deno-$($lock.deno.version).zip"
$denodir = Join-Path $cache "deno-$($lock.deno.version)"
if (-not (Test-Path $denodir)) { Expand-Archive $deno $denodir }
Copy-Item (Join-Path $denodir 'deno.exe') (Join-Path $tools 'deno.exe')
$documents = @{
    'yt-dlp-LICENSE.txt' = "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$($lock.ytDlp.version)/LICENSE"
    'yt-dlp-THIRD-PARTY.txt' = "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$($lock.ytDlp.version)/THIRD_PARTY_LICENSES.txt"
    'deno-LICENSE.txt' = "https://raw.githubusercontent.com/denoland/deno/v$($lock.deno.version)/LICENSE.md"
    'dotnet-LICENSE.txt' = 'https://raw.githubusercontent.com/dotnet/runtime/v10.0.10/LICENSE.TXT'
    'dotnet-THIRD-PARTY.txt' = 'https://raw.githubusercontent.com/dotnet/runtime/v10.0.10/THIRD-PARTY-NOTICES.TXT'
    'windows-forms-LICENSE.txt' = 'https://raw.githubusercontent.com/dotnet/winforms/v10.0.10/LICENSE.TXT'
}
foreach ($entry in $documents.GetEnumerator()) { Invoke-WebRequest -Uri $entry.Value -OutFile (Join-Path $licenses $entry.Key) }
Copy-Item (Join-Path $root 'dependencies.lock.json') (Join-Path $licenses 'dependencies.lock.json')
Copy-Item (Join-Path $root 'THIRD-PARTY-NOTICES.md') (Join-Path $licenses 'THIRD-PARTY-NOTICES.md')
Copy-Item (Join-Path $root 'README.md') (Join-Path $package 'README.md')
@"
Jethriki $Version for Windows x64

Extract this entire folder before starting Jethriki.exe. Do not move the EXE away from the other files.
.NET, yt-dlp, FFmpeg, ffprobe, and Deno are bundled; no separate installation or PATH configuration is required.
Downloads default to your Downloads folder. Settings are saved under %LOCALAPPDATA%\YTDLPStudio.
Bundled tools and their licenses/source references are listed in licenses/dependencies.lock.json and licenses/THIRD-PARTY-NOTICES.md.
"@ | Set-Content (Join-Path $package 'START-HERE.txt') -Encoding utf8
foreach ($name in @('yt-dlp','ffmpeg','ffprobe','deno')) {
    $exe = Join-Path $tools "$name.exe"
    if ($name -eq 'yt-dlp') { & $exe --version } elseif ($name -eq 'deno') { & $exe --version } else { & $exe -version | Select-Object -First 1 }
    if ($LASTEXITCODE -ne 0) { throw "Bundled $name did not start." }
}
# Preserve a manifest of installed files so the delivered package can be audited.
$manifest = Get-ChildItem $package -File -Recurse | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($package.Length + 1).Replace('\','/'); sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $package 'SHA256-MANIFEST.json') -Encoding utf8
Write-Host "Built package: $package"
