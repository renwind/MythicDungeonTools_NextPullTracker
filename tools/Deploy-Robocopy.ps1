#Requires -Version 5.1

<#
.SYNOPSIS
    把 NPT 开发副本的插件源文件同步（镜像）到 WoW 的 AddOns 安装目录。

.DESCRIPTION
    工作方式：
      1. 检测当前 PowerShell 是否以管理员身份运行（写入 C:\Program Files (x86) 必需）。
         未提权时直接报错退出，并给出操作指引 —— 本脚本【不会】尝试自动提权后静默修改系统目录。
      2. 把 AddOns 里现有的 NPT 目录完整备份到 <仓库根>\deploy\backup\<时间戳>\（只读源，不动原文件）。
      3. 用 robocopy /MIR 把仓库根镜像同步到 AddOns 目录，
         但排除开发专属内容：tools\、.git\、deploy\ 目录，以及 .gitignore、.gitattributes、README-DEV.md 文件。
      4. 打印 robocopy 结果摘要，并提示进游戏执行 /reload。

    注意（NPT 特有约束）：
      NPT 的 .toc 里有一行跨目录加载 ..\MythicDungeonTools\Midnight\load_midnight.xml，
      因此部署后 NPT 必须与 MythicDungeonTools 同级放在 AddOns 目录下，相对路径才能解析。
      本脚本的默认目标路径已满足这一条件，请勿把 NPT 部署到别处。

.PARAMETER DryRun
    只打印将要发生的变更（robocopy /L 列表模式），不备份、不写入任何文件。

.PARAMETER TargetPath
    覆盖默认的安装目录路径。默认值见下方「可配置区」。

.PARAMETER SkipBackup
    跳过部署前备份。除非你确定不需要回滚点，否则不建议使用。

.EXAMPLE
    # 先干跑，看看会改哪些文件（不需要管理员权限）
    powershell -ExecutionPolicy Bypass -File .\tools\Deploy-Robocopy.ps1 -DryRun

.EXAMPLE
    # 真正部署：必须以「管理员身份」打开 PowerShell 后执行
    powershell -ExecutionPolicy Bypass -File .\tools\Deploy-Robocopy.ps1

.NOTES
    PowerShell 语句分隔一律使用 ';'，不使用 '&&'（Windows PowerShell 5.1 不支持）。
    所有含空格的路径均使用引号包裹并通过 -LiteralPath 传递。
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipBackup,
    [string]$TargetPath
)

$ErrorActionPreference = 'Stop'
# 语言模式自检：ConstrainedLanguage 下 .NET 方法被禁，Test-IsAdmin 会 fail-closed
try {
    $lm = $ExecutionContext.SessionState.LanguageMode
    if ($lm -ne 'FullLanguage') {
        Write-Warning "当前 PowerShell 语言模式为 $lm（非 FullLanguage）：管理员检测会 fail-closed，-Execute 无法真正执行。请以管理员身份重开并确认为 FullLanguage。"
    }
} catch { }

# ========================= 可配置区 =========================
# 插件在 WoW 安装目录中的真实位置（部署目标）。
# 如果你的 WoW 装在别处，改这一行即可，或用 -TargetPath 参数临时覆盖。
$DefaultTargetPath = 'C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\MythicDungeonTools_NextPullTracker'

# 插件目录名（用于日志与校验）
$AddonName = 'MythicDungeonTools_NextPullTracker'

# 同步时需要排除的「开发专属」目录（相对仓库根，robocopy /XD 用绝对路径传入）
# .qoder/.github/.tmp-npt-task：IDE/CI/临时任务目录，绝不进游戏目录
$ExcludeDirs = @('tools', '.git', 'deploy', 'Libs', '.qoder', '.github', '.tmp-npt-task')

# 同步时需要排除的「开发专属」文件（robocopy /XF 用绝对路径传入）
$ExcludeFiles = @('.gitignore', '.gitattributes', 'README-DEV.md')
# ==========================================================

# 仓库根 = 本脚本所在 tools\ 目录的上一级
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $TargetPath) { $TargetPath = $DefaultTargetPath }

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-IsAdmin {
    <#
        通过 [Security.Principal.WindowsPrincipal] 判断当前进程是否具备管理员权限。
        判断失败时一律返回 $false（fail closed）——宁可拒绝执行，
        也不要在权限不明的情况下去动 C:\Program Files (x86)。
    #>
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-Warning "无法判断当前是否具备管理员权限：$($_.Exception.Message)"
        return $false
    }
}

function Invoke-Robocopy {
    param([string[]]$Arguments, [string]$What)

    Write-Step "$What : robocopy $($Arguments -join ' ')"
    & robocopy @Arguments
    $code = $LASTEXITCODE

    # robocopy 的退出码是位标志：0-7 属于成功语义，>=8 才是真正的失败
    if ($code -ge 8) {
        throw "robocopy 失败（退出码 $code），$What 未完成。请查看上方输出定位问题。"
    }
    Write-Host "    robocopy 退出码 = $code（0-7 为正常）" -ForegroundColor DarkGray
    return $code
}

# ---------------------------------------------------------------
# 0. 前置校验
# ---------------------------------------------------------------
Write-Step "仓库根（同步来源）: $RepoRoot"
Write-Step "部署目标（AddOns）: $TargetPath"

if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "仓库根不存在：$RepoRoot"
}

# 校验仓库根确实是 NPT 插件目录（防止把错误的目录镜像到 Program Files）
$tocPath = Join-Path $RepoRoot "$AddonName.toc"
if (-not (Test-Path -LiteralPath $tocPath -PathType Leaf)) {
    throw "仓库根下找不到 $AddonName.toc，$RepoRoot 看起来不是 NPT 插件目录。已中止，避免误同步。"
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
    throw "部署目标不存在：$TargetPath`n请确认 WoW 安装路径，或用 -TargetPath 指定正确位置。已中止（不会自动创建目录）。"
}

# 若目标已经是指向本仓库的 junction，说明用户走的是「联接方案」，
# 此时再 robocopy /MIR 等于把目录镜像到自身，必须拦下。
$targetItem = Get-Item -LiteralPath $TargetPath -Force
if ($targetItem.LinkType) {
    throw @"
部署目标已经是一个 $($targetItem.LinkType)，指向：$($targetItem.Target)
说明你已经用 Setup-Junction.ps1 建立了目录联接 —— 联接方案下改代码即时生效，不需要再部署。
如果确实要改回 robocopy 方案，请先以管理员身份运行 tools\Undo-Junction.ps1 解除联接。
"@
}

# ---------------------------------------------------------------
# 1. 管理员权限检测
# ---------------------------------------------------------------
$isAdmin = Test-IsAdmin
Write-Step "管理员权限: $(if ($isAdmin) { '是' } else { '否' })"

if (-not $isAdmin) {
    if ($DryRun) {
        Write-Warning "当前未提权。-DryRun 只读取不写入，可以继续；真正部署时必须以管理员身份运行。"
    }
    else {
        Write-Host ''
        Write-Host '【已中止】部署目标位于 C:\Program Files (x86)，写入需要管理员权限。' -ForegroundColor Red
        Write-Host ''
        Write-Host '请按以下任一方式以管理员身份重开 PowerShell 后再执行本脚本：' -ForegroundColor Yellow
        Write-Host '  1) 开始菜单搜索 "PowerShell" -> 右键 -> "以管理员身份运行"'
        Write-Host '  2) Win+X -> 选择 "终端(管理员)" 或 "Windows PowerShell(管理员)"'
        Write-Host '  3) 在普通 PowerShell 里执行下面这行，会弹出 UAC 提权窗口：'
        Write-Host '     Start-Process powershell -Verb RunAs -ArgumentList ''-NoExit'',''-Command'',''"cd '''''$RepoRoot'''''; .\tools\Deploy-Robocopy.ps1"'''
        Write-Host ''
        Write-Host '想先不写入、只看会改哪些文件，请加 -DryRun：' -ForegroundColor Yellow
        Write-Host "  .\tools\Deploy-Robocopy.ps1 -DryRun"
        Write-Host ''
        throw '未以管理员身份运行，部署已中止。'
    }
}

# ---------------------------------------------------------------
# 2. 组装 robocopy 排除参数
# ---------------------------------------------------------------
$xdArgs = @()
foreach ($d in $ExcludeDirs) {
    $full = Join-Path $RepoRoot $d
    if (Test-Path -LiteralPath $full) { $xdArgs += $full }
}

$xfArgs = @()
foreach ($f in $ExcludeFiles) {
    $full = Join-Path $RepoRoot $f
    if (Test-Path -LiteralPath $full) { $xfArgs += $full }
}

Write-Step "排除目录: $(if ($xdArgs) { $xdArgs -join ' | ' } else { '(无)' })"
Write-Step "排除文件: $(if ($xfArgs) { $xfArgs -join ' | ' } else { '(无)' })"

$commonArgs = @('/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH')

# ---------------------------------------------------------------
# 3. DryRun：只列出将要发生的变更
# ---------------------------------------------------------------
if ($DryRun) {
    Write-Host ''
    Write-Host '================ DRY RUN（不会写入任何文件）================' -ForegroundColor Yellow
    Write-Host '说明：跳过部署前备份；robocopy 使用 /L 列表模式，只报告不执行。' -ForegroundColor Yellow
    Write-Host ''

    $listArgs = @($RepoRoot, $TargetPath, '/MIR', '/L', '/NS', '/NC', '/NJH')
    if ($xdArgs.Count -gt 0) { $listArgs += '/XD'; $listArgs += $xdArgs }
    if ($xfArgs.Count -gt 0) { $listArgs += '/XF'; $listArgs += $xfArgs }

    # /L 模式下去掉 /NFL /NDL，否则看不到具体条目
    $code = Invoke-Robocopy -Arguments $listArgs -What 'DRY RUN 变更清单'

    Write-Host ''
    Write-Host '以上为将要发生的变更（新文件 / 覆盖 / *EXTRA 表示目标端多余文件将被 /MIR 删除）。' -ForegroundColor Yellow
    Write-Host '确认无误后，请以【管理员身份】运行：' -ForegroundColor Yellow
    Write-Host '  .\tools\Deploy-Robocopy.ps1'
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------
# 4. 部署前备份（带时间戳）
# ---------------------------------------------------------------
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($SkipBackup) {
    Write-Warning '已指定 -SkipBackup，本次部署不创建回滚点。'
}
else {
    $backupRoot = Join-Path $RepoRoot 'deploy\backup'
    $backupDir  = Join-Path $backupRoot $timestamp

    if (-not (Test-Path -LiteralPath $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    Write-Step "备份现有安装目录到: $backupDir"
    $bakArgs = @($TargetPath, $backupDir, '/E') + $commonArgs
    Invoke-Robocopy -Arguments $bakArgs -What '部署前备份' | Out-Null
    Write-Host "    备份完成（如需回滚，可把该目录内容 robocopy 回 $TargetPath）" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------
# 5. 正式镜像同步
# ---------------------------------------------------------------
Write-Host ''
Write-Step "开始镜像同步: $RepoRoot  ->  $TargetPath"

$syncArgs = @($RepoRoot, $TargetPath, '/MIR') + $commonArgs
if ($xdArgs.Count -gt 0) { $syncArgs += '/XD'; $syncArgs += $xdArgs }
if ($xfArgs.Count -gt 0) { $syncArgs += '/XF'; $syncArgs += $xfArgs }

$syncCode = Invoke-Robocopy -Arguments $syncArgs -What '镜像同步'

# ---------------------------------------------------------------
# 6. 部署后校验与提示
# ---------------------------------------------------------------
Write-Host ''
$deployedToc = Join-Path $TargetPath "$AddonName.toc"
if (Test-Path -LiteralPath $deployedToc) {
    Write-Step "校验通过：$deployedToc 存在"
    $mdtSibling = Join-Path (Split-Path -Parent $TargetPath) 'MythicDungeonTools'
    if (Test-Path -LiteralPath $mdtSibling) {
        Write-Step '校验通过：父插件 MythicDungeonTools 与 NPT 同级（跨目录 load_midnight.xml 可解析）'
    }
    else {
        Write-Warning "未在同级目录找到 MythicDungeonTools：$mdtSibling`nNPT 的 .toc 依赖 ..\MythicDungeonTools\Midnight\load_midnight.xml，缺失会导致加载失败。"
    }
}
else {
    Write-Warning "同步后未在目标目录找到 $AddonName.toc，请人工检查部署结果。"
}

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Green
Write-Host ' 部署完成。' -ForegroundColor Green
Write-Host ''
Write-Host ' 下一步：进入魔兽世界，在聊天框执行  /reload  重新加载插件。' -ForegroundColor Green
Write-Host ' （若 /reload 后行为异常，完全退出并重启 WoW 客户端再试。）' -ForegroundColor DarkGray
Write-Host ''
Write-Host " 本次备份位置: $(if ($SkipBackup) { '(已跳过)' } else { (Join-Path $RepoRoot "deploy\backup\$timestamp") })" -ForegroundColor DarkGray
Write-Host " robocopy 退出码: $syncCode" -ForegroundColor DarkGray
Write-Host '==========================================================' -ForegroundColor Green
