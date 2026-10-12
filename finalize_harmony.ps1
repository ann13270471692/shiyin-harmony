# 一键收尾：等待/检测 signingConfigs → 编译 → 安装 → 启动 → 验证
# 用法：pwsh -File finalize_harmony.ps1   （在 F:\shiyin-harmony 或本仓库任意副本旁运行）
$ErrorActionPreference = 'Stop'
$proj = 'F:\shiyin-harmony'
$hdc  = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$target = '192.168.2.15:46787'

# 1) 确认签名配置已写入（DevEco Project Structure → Signing Configs → Apply 之后）
$bp = Join-Path $proj 'build-profile.json5'
if (-not (Select-String -Path $bp -Pattern '"keyPassword"' -Quiet)) {
    Write-Host '尚未检测到 signingConfigs：请先在 DevEco 里 Project Structure → Signing Configs → 勾选 Automatically generate signature → Apply' -ForegroundColor Yellow
    exit 2
}

# 2) 同步源码（工作区 → 构建目录），保留构建目录里的签名配置
$src = 'F:\DeepSeek Workspace\时事分析\shiyin-harmony'
$bpBackup = Get-Content $bp -Raw
robocopy $src $proj /MIR /XD .git node_modules oh_modules .hvigor build .idea .deveco /NFL /NDL /NJH | Out-Null
if (-not (Select-String -Path $bp -Pattern '"keyPassword"' -Quiet)) {
    Set-Content -Path $bp -Value $bpBackup -Encoding UTF8
    Write-Host '已恢复被覆盖的签名配置' -ForegroundColor Yellow
}

# 3) 编译
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
Set-Location $proj
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
if ($LASTEXITCODE -ne 0) { Write-Host '编译失败' -ForegroundColor Red; exit 1 }

# 4) 安装 + 启动
$hap = Join-Path $proj 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not (Test-Path $hap)) { Write-Host "未生成已签名 HAP：$hap" -ForegroundColor Red; exit 1 }
& $hdc -t $target install -r $hap
& $hdc -t $target shell aa start -a EntryAbility -b com.shiyin.player

# 5) 验证
Start-Sleep 3
& $hdc -t $target shell "bm dump -n com.shiyin.player" | Select-String 'versionName'
& $hdc -t $target shell "hilog -x -T Shiyin" | Select-Object -Last 5
Write-Host '完成：请在 Mate 70 桌面确认「梦秋音乐」图标' -ForegroundColor Green
