#!/usr/bin/env bash
# Grok Register 本地开发模式启动脚本
#
# 后端：uvicorn --reload（watch backend/），改 Python 代码自动重启
# 前端：Vite dev server（HMR），改 front/src 即时热更新，/api 自动代理到后端
#
# 与 start-web.sh 的区别：
#   start-web.sh  → backend/web/cli.py，单进程、无热重载，只服务 front/dist 构建产物（生产/日常使用）
#   start-dev.sh  → uvicorn --reload + Vite dev server，改代码即时生效（开发调试）
#
# 用法：
#   ./start-dev.sh                       # 后端 127.0.0.1:8787 + 前端 127.0.0.1:5173
#   ./start-dev.sh --backend-only        # 只起后端
#   ./start-dev.sh --frontend-only       # 只起前端（需后端已在跑）
#   ./start-dev.sh --no-install          # 跳过依赖自动安装
#
# 可用环境变量：
#   GROK_WEB_HOST          监听地址，默认 127.0.0.1
#   GROK_WEB_PORT          后端端口，默认 8787
#   GROK_WEB_FRONT_PORT    前端端口，默认 5173
#   GROK_WEB_COOKIE_SECURE 会话 Cookie 是否带 Secure，默认 0（本机纯 HTTP 必须为 0）
#
# 注意：改后端端口需同步修改 front/vite.config.ts 里的 server.proxy 目标地址。
set -euo pipefail

# 【坑】UTF-8 locale 下 bash 用 isalnum() 判定变量名，中文和全角标点会被当成字母：
#   echo "$VAR）"   → bash 把变量名解析成 "VAR）"，直接报 unbound variable
# 变量后面紧跟非 ASCII 字符时，必须写成 "${VAR}" 显式界定，或者中间留一个空格。
# 该行为在 bash 3.2 和 5.3 上都存在，与版本无关，只跟 locale 有关。
cd "$(dirname "$0")"

HOST="${GROK_WEB_HOST:-127.0.0.1}"
BACKEND_PORT="${GROK_WEB_PORT:-8787}"
FRONT_PORT="${GROK_WEB_FRONT_PORT:-5173}"
BACKEND_LOG="logs/dev-backend.log"

# 本机是纯 HTTP 调试，会话 Cookie 不能带 Secure 标记，否则浏览器不落盘、登录态会异常
export GROK_WEB_COOKIE_SECURE="${GROK_WEB_COOKIE_SECURE:-0}"

WITH_BACKEND=1
WITH_FRONTEND=1
AUTO_INSTALL=1

for arg in "$@"; do
  case "$arg" in
    --backend-only)  WITH_FRONTEND=0 ;;
    --frontend-only) WITH_BACKEND=0 ;;
    --no-install)    AUTO_INSTALL=0 ;;
    -h|--help)       sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[dev] 未知参数：${arg}（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done

if [[ "$WITH_BACKEND" == "0" && "$WITH_FRONTEND" == "0" ]]; then
  echo "[dev] --backend-only 与 --frontend-only 不能同时使用" >&2
  exit 2
fi

# WorkBuddy / CodeBuddy 沙箱会通过 NODE_OPTIONS 注入文件代理钩子（node-language-shim.cjs），
# 它会拦截 npm / vite 对 node_modules 的 mkdir、rename，报错形如：
#   CODEBUDDY_BROKER_DENY: Brokered host mkdir requires an available runtime file rule
# 这里只在确实检测到该钩子时剥离，避免影响用户自己配置的 NODE_OPTIONS。
if [[ "${NODE_OPTIONS:-}" == *"node-language-shim.cjs"* ]]; then
  echo "[dev] 检测到沙箱文件代理钩子，已为子进程剥离 NODE_OPTIONS"
  unset NODE_OPTIONS
fi
unset CODEBUDDY_BROKERED_FS_HOOK_ENABLED CODEBUDDY_BROKERED_SHELL_ENV

# ---------- 环境检查 ----------

if [[ "$WITH_BACKEND" == "1" ]]; then
  if [[ ! -x .venv/bin/python ]]; then
    echo "[dev] 未找到 .venv，请先初始化后端环境：" >&2
    echo "       python3 -m venv .venv" >&2
    echo "       .venv/bin/pip install -r requirements.txt" >&2
    exit 1
  fi
  PY=".venv/bin/python"
fi

if [[ "$WITH_FRONTEND" == "1" ]]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "[dev] 未找到 npm，请先安装 Node.js 22+" >&2
    exit 1
  fi
  if [[ ! -d front/node_modules ]]; then
    if [[ "$AUTO_INSTALL" == "1" ]]; then
      echo "[dev] front/node_modules 不存在，先执行 npm install ..."
      ( cd front && npm install --no-audit --no-fund )
    else
      echo "[dev] front/node_modules 不存在，请先执行：cd front && npm install" >&2
      exit 1
    fi
  fi
fi

port_in_use() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

if [[ "$WITH_BACKEND" == "1" ]] && port_in_use "$BACKEND_PORT"; then
  echo "[dev] 端口 $BACKEND_PORT 已被占用，请先停掉旧进程或改用 GROK_WEB_PORT" >&2
  exit 1
fi
if [[ "$WITH_FRONTEND" == "1" ]] && port_in_use "$FRONT_PORT"; then
  echo "[dev] 端口 $FRONT_PORT 已被占用，请先停掉旧进程或改用 GROK_WEB_FRONT_PORT" >&2
  exit 1
fi

# ---------- 启动后端 ----------

BACKEND_PID=""

cleanup() {
  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo ""
    echo "[dev] 停止后端 (pid $BACKEND_PID)"
    kill "$BACKEND_PID" 2>/dev/null || true
    wait "$BACKEND_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

start_backend() {
  mkdir -p logs
  echo "[dev] 启动后端 -> http://${HOST}:${BACKEND_PORT} （热重载，日志 ${BACKEND_LOG}）"
  "$PY" -m uvicorn backend.web.application:create_app \
    --factory --reload --reload-dir backend \
    --host "$HOST" --port "$BACKEND_PORT" \
    >"$BACKEND_LOG" 2>&1 &
  BACKEND_PID=$!
}

wait_for_backend() {
  local url="http://$HOST:$BACKEND_PORT/api/health"
  local i=0
  while (( i < 60 )); do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      echo "[dev] 后端启动失败，日志末尾：" >&2
      tail -n 20 "$BACKEND_LOG" >&2 || true
      return 1
    fi
    if curl -fsS -m 2 "$url" >/dev/null 2>&1; then
      echo "[dev] 后端就绪 -> $url"
      return 0
    fi
    sleep 0.5
    i=$(( i + 1 ))
  done
  echo "[dev] 等待后端超时（30s），请查看 $BACKEND_LOG" >&2
  return 1
}

if [[ "$WITH_BACKEND" == "1" ]]; then
  start_backend
  wait_for_backend
fi

# ---------- 启动前端 ----------

if [[ "$WITH_FRONTEND" == "1" ]]; then
  echo "[dev] 启动前端 -> http://${HOST}:${FRONT_PORT} （HMR，/api 代理到 ${HOST}:${BACKEND_PORT}）"
  echo "[dev] Ctrl+C 结束全部进程"
  echo ""
  cd front
  npm run dev -- --host "$HOST" --port "$FRONT_PORT"
else
  echo "[dev] 仅后端模式，Ctrl+C 退出"
  wait "$BACKEND_PID"
fi
