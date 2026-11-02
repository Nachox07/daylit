# Builds Daylit.exe into %LOCALAPPDATA%\Programs\Daylit (needs the .NET 8 SDK).
# Plain framework-dependent publish: no single-file or runtime pack, so no NuGet download is needed.
$ErrorActionPreference = 'Stop'
$out = Join-Path $env:LOCALAPPDATA 'Programs\Daylit'
Get-Process Daylit -ErrorAction SilentlyContinue | Stop-Process -Force
dotnet publish "$PSScriptRoot\Daylit.csproj" -c Release -o $out --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "build failed" }
"built $out\Daylit.exe"
