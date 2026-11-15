# NekoBox-Ohos · 构建脚本（本机命令行版，不开 DevEco GUI）
#   用法： powershell -NoProfile -ExecutionPolicy Bypass -File tools\build.ps1 [-Product neko|modern] [-Release]
#   产物： entry\build\<product>\outputs\<product>\entry-<product>-unsigned.hap
$ErrorActionPreference = 'Continue'   # 构建日志里 stderr 有 WARN，Stop 会误中断

param(
  [string]$Product = 'neko',
  [switch]$Release
)

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$env:DEVECO_SDK_HOME  = 'D:\command-line-tools\sdk'
$env:JAVA_HOME        = 'C:\Users\Administrator\Tools\jdk\jdk-17.0.2'
$env:PATH             = "$env:JAVA_HOME\bin;C:\Program Files\nodejs;$env:PATH"
$env:HVIGOR_USER_HOME = 'C:\Users\Administrator\Desktop\RzdProject\.buildcache\hvigor'
$env:npm_config_cache = 'C:\Users\Administrator\Desktop\RzdProject\.buildcache\npm'

$mode = if ($Release) { 'release' } else { 'debug' }
$log  = Join-Path $root ("_build-{0}-{1}.log" -f $Product, $mode)

# 注意：hvigor 用自带 node（D:\command-line-tools\tool\node）跑；用系统 node 24 会在
# 解析 @ohos/hvigor-ohos-plugin 时 MODULE_NOT_FOUND（本轮实测）。
& 'D:\command-line-tools\bin\hvigorw.bat' assembleHap --mode module -p "product=$Product" -p "buildMode=$mode" --no-daemon 2>&1 |
  Tee-Object -FilePath $log | Select-Object -Last 40

Write-Output "---- exit: $LASTEXITCODE   log: $log"
Get-ChildItem "entry\build\$Product\outputs\$Product" -ErrorAction SilentlyContinue |
  ForEach-Object { "{0}  {1:N0} B" -f $_.Name, $_.Length }
