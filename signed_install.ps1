# 拾音鸿蒙版：编译签名包 → 安装 → 启动
# 前提：DevEco 已为本工程（com.shiyin.player）配置自动签名（signingConfigs 非空）
$ErrorActionPreference = 'Stop'
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"

Write-Host "[1/3] hvigor 编译..."
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
Set-Location $PSScriptRoot
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
if ($LASTEXITCODE -ne 0) { Write-Error "编译失败"; exit 1 }

$hap = Join-Path $PSScriptRoot "entry\build\default\outputs\default\entry-default-signed.hap"
if (-not (Test-Path $hap)) {
  $hap = Join-Path $PSScriptRoot "entry\build\default\outputs\default\entry-default-unsigned.hap"
  Write-Warning "没有签名包，尝试未签名（大概率安装失败，请先在 DevEco 配置签名）"
}

Write-Host "[2/3] 安装到手机..."
& $hdc install -r $hap
if ($LASTEXITCODE -ne 0) { Write-Error "安装失败"; exit 1 }

Write-Host "[3/3] 启动..."
& $hdc shell aa start -a EntryAbility -b com.shiyin.player
Write-Host "完成。日志查看: & `"$hdc`" hilog | Select-String Shiyin"
