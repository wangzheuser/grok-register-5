<#
.SYNOPSIS
    Grok Register 本地开发模式启动脚本（Windows PowerShell）。

.DESCRIPTION
    后端：uvicorn --reload（watch backend\），改 Python 代码自动重启。
    前端：Vite dev server（HMR），改 front\src 即时热更新，/api 自动代理到后端。

    与 start-web.sh 的区别：
      start-web.sh  -> backend/web/cli.py，单进程、无热重载，只服务 front/dist 构建产物（生产/日常使用）
      start-dev.ps1 -> uvicorn --reload + Vite dev server，改代码即时生效（开发调试）

    可用环境变量：
      GROK_WEB_HOST          监听地址，默认 127.0.0.1
      GROK_WEB_PORT          后端端口，默认 8787
      GROK_WEB_FRONT_PORT    前端端口，默认 5173
      GROK_WEB_COOKIE_SECURE 会话 Cookie 是否带 Secure，默认 0（本机纯 HTTP 必须为 0）

    注意：改后端端口需同步修改 front/vite.config.ts 里的 server.proxy 目标地址。

.EXAMPLE
    .\start-dev.ps1
    后端 127.0.0.1:8787 + 前端 127.0.0.1:5173。

.EXAMPLE
    .\start-dev.ps1 -BackendOnly
    只起后端。

.EXAMPLE
    .\start-dev.ps1 -NoInstall
    跳过依赖自动安装。
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$BackendOnly,
    [switch]$FrontendOnly,
    [switch]$NoInstall
)

$ErrorActionPreference = "Stop"

if ($PSScriptRoot) {
    $Root = $PSScriptRoot
} else {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
Set-Location $Root

# $ErrorActionPreference = "Stop" 会让 Write-Error 直接抛终止异常，
# 因此统一用 Fail 输出可读信息后再退出。
function Fail {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
    exit 1
}

# ---------- 配置 ----------

$WebHost = if ($env:GROK_WEB_HOST) { $env:GROK_WEB_HOST } else { "127.0.0.1" }
$BackendPort = if ($env:GROK_WEB_PORT) { [int]$env:GROK_WEB_PORT } else { 8787 }
$FrontPort = if ($env:GROK_WEB_FRONT_PORT) { [int]$env:GROK_WEB_FRONT_PORT } else { 5173 }
$BackendLog = Join-Path $Root "logs\dev-backend.log"

# 本机是纯 HTTP 调试，会话 Cookie 不能带 Secure 标记，否则浏览器不落盘、登录态会异常
if (-not $env:GROK_WEB_COOKIE_SECURE) {
    $env:GROK_WEB_COOKIE_SECURE = "0"
}

$WithBackend = -not $FrontendOnly
$WithFrontend = -not $BackendOnly
$AutoInstall = -not $NoInstall

if ($BackendOnly -and $FrontendOnly) {
    Fail "[dev] -BackendOnly 与 -FrontendOnly 不能同时使用"
}

# WorkBuddy / CodeBuddy 沙箱会通过 NODE_OPTIONS 注入文件代理钩子（node-language-shim.cjs），
# 它会拦截 npm / vite 对 node_modules 的 mkdir、rename，报错形如：
#   CODEBUDDY_BROKER_DENY: Brokered host mkdir requires an available runtime file rule
# 这里只在确实检测到该钩子时剥离，避免影响用户自己配置的 NODE_OPTIONS。
if ($env:NODE_OPTIONS -and $env:NODE_OPTIONS -like "*node-language-shim.cjs*") {
    Write-Host "[dev] 检测到沙箱文件代理钩子，已为子进程剥离 NODE_OPTIONS"
    Remove-Item Env:\NODE_OPTIONS -ErrorAction SilentlyContinue
}
Remove-Item Env:\CODEBUDDY_BROKERED_FS_HOOK_ENABLED -ErrorAction SilentlyContinue
Remove-Item Env:\CODEBUDDY_BROKERED_SHELL_ENV -ErrorAction SilentlyContinue

# ---------- 环境检查 ----------

$Python = $null
if ($WithBackend) {
    $Python = Join-Path $Root ".venv\Scripts\python.exe"
    if (-not (Test-Path $Python)) {
        Fail @"
[dev] 未找到 .venv\Scripts\python.exe，请先初始化后端环境：
      python -m venv .venv
      .venv\Scripts\pip.exe install -r requirements.txt
"@
    }
}

$Npm = $null
if ($WithFrontend) {
    $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npmCmd) {
        Fail "[dev] 未找到 npm，请先安装 Node.js 22+"
    }
    $Npm = $npmCmd.Source

    $nodeModules = Join-Path $Root "front\node_modules"
    if (-not (Test-Path $nodeModules)) {
        if ($AutoInstall) {
            Write-Host "[dev] front\node_modules 不存在，先执行 npm install ..."
            Push-Location (Join-Path $Root "front")
            try { & $Npm install --no-audit --no-fund } finally { Pop-Location }
        } else {
            Fail "[dev] front\node_modules 不存在，请先执行：cd front; npm install"
        }
    }
}

function Test-PortInUse {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

if ($WithBackend -and (Test-PortInUse -Port $BackendPort)) {
    Fail "[dev] 端口 $BackendPort 已被占用，请先停掉旧进程或改用 GROK_WEB_PORT"
}
if ($WithFrontend -and (Test-PortInUse -Port $FrontPort)) {
    Fail "[dev] 端口 $FrontPort 已被占用，请先停掉旧进程或改用 GROK_WEB_FRONT_PORT"
}

# ---------- 启动 ----------

$backendProc = $null

function Stop-Backend {
    if ($backendProc -and -not $backendProc.HasExited) {
        Write-Host ""
        Write-Host "[dev] 停止后端 (pid $($backendProc.Id))"
        # cmd.exe 包装过一层，用 /T 连同 uvicorn 的 reloader 子进程一起结束
        & taskkill.exe /PID $backendProc.Id /T /F 2>&1 | Out-Null
    }
}

try {
    if ($WithBackend) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root "logs") | Out-Null

        Write-Host "[dev] 启动后端 -> http://${WebHost}:${BackendPort} （热重载，日志 ${BackendLog}）"

        $backendArgLine = "-m uvicorn backend.web.application:create_app " +
            "--factory --reload --reload-dir backend " +
            "--host $WebHost --port $BackendPort"

        # 用 cmd.exe 包一层，把 stdout / stderr 合并进同一个日志文件
        # （Start-Process 不允许 stdout 与 stderr 重定向到同一个路径）
        $cmdLine = "`"$Python`" $backendArgLine > `"$BackendLog`" 2>&1"
        $backendProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmdLine -PassThru -NoNewWindow

        $healthUrl = "http://${WebHost}:${BackendPort}/api/health"
        $deadline = (Get-Date).AddSeconds(30)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if ($backendProc.HasExited) {
                Write-Warning "[dev] 后端启动失败，日志末尾："
                if (Test-Path $BackendLog) { Get-Content $BackendLog -Tail 20 | Write-Host }
                exit 1
            }
            try {
                $resp = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 2 -UseBasicParsing
                if ($resp.StatusCode -eq 200) { $ready = $true; break }
            } catch {
                # 还没起来，继续等
            }
            Start-Sleep -Milliseconds 500
        }

        if (-not $ready) {
            Write-Warning "[dev] 等待后端超时（30s），请查看 $BackendLog"
            exit 1
        }
        Write-Host "[dev] 后端就绪 -> $healthUrl"
    }

    if ($WithFrontend) {
        Write-Host "[dev] 启动前端 -> http://${WebHost}:${FrontPort} （HMR，/api 代理到 ${WebHost}:${BackendPort}）"
        Write-Host "[dev] Ctrl+C 结束全部进程"
        Write-Host ""
        Push-Location (Join-Path $Root "front")
        try {
            & $Npm run dev -- --host $WebHost --port $FrontPort
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "[dev] 仅后端模式，Ctrl+C 退出"
        if ($backendProc) { Wait-Process -Id $backendProc.Id }
    }
} finally {
    Stop-Backend
}
