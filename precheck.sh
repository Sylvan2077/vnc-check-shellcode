#!/usr/bin/env bash
# ==============================================================================
# precheck.sh - SCNS APPS PLATFORM 部署前置条件检测
#
# 目标：
#   在不执行任何安装/修改动作的前提下，尽可能提前暴露部署失败风险：
#   - OS/架构/权限是否满足部署脚本要求（脚本强制 root，且安装包为 x86_64）
#   - 部署过程中用到的关键命令是否存在（tar/systemctl/yum/rpm 等）
#   - 部署所需的离线资源、配置文件、二进制文件是否齐全
#   - 关键端口是否已被占用（输出占用端口的 PID 与程序名）
#   - VNC 端口段（5801-5899、5901-5999）是否存在占用（明确告知）
#
# 行为约束：
#   仅检测：不安装、不修改、不创建目录、不启动服务
#
# 退出码：
#   0  : 无阻断项（FAIL=0）；WARN 可能存在
#   2  : 存在阻断项（FAIL>0），建议修复后再部署
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# 日志输出与计数器
# ------------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
LIGHT_BLUE='\033[0;34m'
NOCOLOR='\033[0m'

log_ok()   { printf "${GREEN}[PASS]${NOCOLOR} %s\n" "$*" 1>&2; }
log_info() { printf "${LIGHT_BLUE}[INFO]${NOCOLOR} %s\n" "$*" 1>&2; }
log_warn() { printf "${YELLOW}[WARN]${NOCOLOR} %s\n" "$*" 1>&2; }
log_fail() { printf "${RED}[FAIL]${NOCOLOR} %s\n" "$*" 1>&2; }

PASS=0
WARN=0
FAIL=0
pass() { PASS=$((PASS+1)); log_ok "$*"; }
warn() { WARN=$((WARN+1)); log_warn "$*"; }
fail() { FAIL=$((FAIL+1)); log_fail "$*"; }

# ------------------------------------------------------------------------------
# 基础工具函数
# ------------------------------------------------------------------------------
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "$(id -u 2>/dev/null || echo 99999)" == "0" ]]; }

# 文件/目录存在且可读、非空判断
file_nonempty() { [[ -f "$1" && -s "$1" && -r "$1" ]]; }
dir_exists() { [[ -d "$1" ]]; }

# 检查命令是否存在：缺失会直接影响脚本执行（FAIL）
check_cmd() {
  local c="$1"
  if cmd_exists "$c"; then
    pass "命令存在：$c"
  else
    fail "命令缺失：$c"
  fi
}

# 检查文件存在且可读且非空：缺失会导致部署失败（FAIL）
check_file() {
  local f="$1"
  if file_nonempty "$f"; then
    pass "文件存在且可读：$f"
  else
    fail "文件缺失/不可读/为空：$f"
  fi
}

# 检查可执行文件：filebrowser 直接运行，需要 +x（FAIL）
check_exec_file() {
  local f="$1"
  if [[ -f "$f" && -x "$f" ]]; then
    pass "可执行文件存在：$f"
  elif [[ -f "$f" ]]; then
    fail "文件存在但不可执行（缺少 +x）：$f"
  else
    fail "可执行文件缺失：$f"
  fi
}

check_dir() {
  local d="$1"
  if dir_exists "$d"; then
    pass "目录存在：$d"
  else
    fail "目录缺失：$d"
  fi
}

# ------------------------------------------------------------------------------
# 固定端口 -> 服务名称映射（供部署/研发对齐）
#
# 说明：
#   这些端口来自 init_env.sh，用于部署前端口冲突检查；
#   若被占用，会影响对应服务启动或导致部署脚本中途失败。
# ------------------------------------------------------------------------------
service_of_port() {
  local p="$1"
  case "$p" in
    12377) echo "PostgreSQL 数据库（Docker 容器 postgres:10，对外映射端口）" ;;
    55555) echo "Redis 缓存（Docker 容器 redis:5.0.10，对外映射端口）" ;;
    8086)  echo "Nginx 前端入口/反向代理（Docker 容器 nginx:1.18.0，对外映射端口）" ;;
    10086) echo "平台后端 API 服务（Gunicorn 托管 Django 应用 vncmanagementdb）" ;;
    8088)  echo "Filebrowser 文件服务（filebrowser 二进制，提供共享目录访问）" ;;
    8000)  echo "VNC Session 管理服务（Session Manager, FastAPI应用）" ;;
    9000) echo "User Management 用户管理服务（User Management，FastAPI应用）" ;;
    *)
      echo "（未定义/动态端口）"
      ;;
  esac
}

# 在日志中打印固定端口与服务对照表
print_fixed_port_map() {
  log_info "固定端口与服务对应关系（供部署/研发对齐）："
  log_info "  12377 -> $(service_of_port 12377)"
  log_info "  55555 -> $(service_of_port 55555)"
  log_info "   8086 -> $(service_of_port 8086)"
  log_info "  10086 -> $(service_of_port 10086)"
  log_info "   8088 -> $(service_of_port 8088)"
  log_info "   8000 -> $(service_of_port 8000)"
  log_info "   9000 -> $(service_of_port 9000)" 
  log_info "  5801-5899 -> VNC Web/HTTP 端口段（noVNC/浏览器访问常用）"
  log_info "  5901-5999 -> VNC TCP 端口段（VNC Viewer/桌面连接常用）"
}

# ------------------------------------------------------------------------------
# 端口占用明细获取（用于：端口 -> PID/程序名）
#
# 输出 TSV：port<TAB>pid<TAB>prog<TAB>raw
#
# 注意：
#   这里检测的是“监听端口”（LISTEN），即真正会导致 bind 失败的占用情况。
# ------------------------------------------------------------------------------
build_listeners_tsv() {
  local out="$1"
  : > "$out"

  if cmd_exists ss; then
    # ss -lntpH: 无表头；最后一列通常含 Process 信息 users:(("xxx",pid=123))
    ss -lntpH 2>/dev/null | awk '
      {
        local=$4
        proc=$NF

        # 提取端口：取 local 字段最后的 :number
        port=local
        sub(/^.*:/, "", port)
        if (port !~ /^[0-9]+$/) next

        pid="-"; prog="-"
        if (match(proc, /\(\"([^"]+)\"/, m)) { prog=m[1] }
        if (match(proc, /pid=([0-9]+)/, n)) { pid=n[1] }

        print port "\t" pid "\t" prog "\t" proc
      }
    ' >> "$out"
    return 0
  fi

  if cmd_exists netstat; then
    # netstat -lntp: 最后一列通常为 PID/PROGRAM
    netstat -lntp 2>/dev/null | awk '
      $1 ~ /^tcp/ {
        local=$4
        port=local
        sub(/^.*:/, "", port)
        if (port !~ /^[0-9]+$/) next

        pidprog=$7
        pid="-"; prog="-"
        if (pidprog ~ /^[0-9]+\//) {
          split(pidprog, a, "/")
          pid=a[1]; prog=a[2]
        }

        print port "\t" pid "\t" prog "\t" pidprog
      }
    ' >> "$out"
    return 0
  fi

  return 1
}

# 查询单端口占用明细；若占用返回码=1，并输出所有匹配行
port_details() {
  local port="$1"
  local tsv="$2"
  local lines
  lines="$(awk -F'\t' -v p="$port" '$1==p {print}' "$tsv" 2>/dev/null || true)"
  if [[ -z "$lines" ]]; then
    return 0
  fi
  echo "$lines"
  return 1
}

# 单端口检查：输出服务名 + 若占用则打印 PID/程序名
check_port_free_with_details() {
  local port="$1"
  local tsv="$2"
  local svc="$3"

  local lines
  if lines="$(port_details "$port" "$tsv")"; then
    pass "端口可用：$port -> $svc"
  else
    fail "端口已被占用（监听中）：$port -> $svc"
    echo "$lines" | while IFS=$'\t' read -r p pid prog raw; do
      log_info "  占用明细：port=${p} pid=${pid} prog=${prog}"
    done
  fi
}

# 范围端口检查（用于 VNC 两段）
check_port_range_with_details() {
  local start="$1"
  local end="$2"
  local tsv="$3"
  local label="$4"  # 例如 "VNC Web/HTTP(5801-5899)"

  local tmp
  tmp="$(mktemp -t precheck_range.XXXXXX)"
  : > "$tmp"

  # 收集范围内所有监听条目
  awk -F'\t' -v s="$start" -v e="$end" '
    ($1 ~ /^[0-9]+$/) && ($1>=s && $1<=e) {print}
  ' "$tsv" 2>/dev/null | sort -n -t$'\t' -k1,1 >> "$tmp"

  local cnt
  cnt="$(wc -l < "$tmp" | tr -d ' ' 2>/dev/null || echo 0)"

  if [[ "$cnt" -eq 0 ]]; then
    pass "端口范围可用：${start}-${end}（${label}：无占用）"
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 0
  fi

  fail "端口范围存在占用：${start}-${end}（${label}：占用条目=${cnt}）"
  # 明细逐条输出（端口、PID、程序名）。条目过多时可截断。
  local max_show=200
  local shown=0
  while IFS=$'\t' read -r p pid prog raw; do
    log_info "  占用明细：port=${p} pid=${pid} prog=${prog}"
    shown=$((shown+1))
    if [[ "$shown" -ge "$max_show" ]]; then
      log_warn "  占用明细过多，仅展示前 ${max_show} 条；请自行检查完整列表（ss/netstat）"
      break
    fi
  done < "$tmp"

  rm -f "$tmp" >/dev/null 2>&1 || true
  return 1
}

# ------------------------------------------------------------------------------
# 项目路径定位，与部署脚本内 PROJECT_DIR 规则对齐
#   部署脚本：PROJECT_DIR = deploy-scripts 所在目录的上一级
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(realpath "${SCRIPT_DIR}/.." 2>/dev/null || echo "${SCRIPT_DIR}/..")"
DEPLOY_SCRIPTS_DIR="${PROJECT_DIR}/deploy-scripts"

INIT_ENV="${DEPLOY_SCRIPTS_DIR}/init_env.sh"
COMMON_SH="${DEPLOY_SCRIPTS_DIR}/common.sh"
DEPLOY_THIRDPARTY="${DEPLOY_SCRIPTS_DIR}/deploy-thirtparty.sh"
DEPLOY_PLATFORM="${DEPLOY_SCRIPTS_DIR}/deploy-platform.sh"

log_info "PROJECT_DIR = ${PROJECT_DIR}"
log_info "DEPLOY_SCRIPTS_DIR = ${DEPLOY_SCRIPTS_DIR}"

# ------------------------------------------------------------------------------
# 1) OS/架构/root 检查（部署脚本硬前置）
# ------------------------------------------------------------------------------
os="$(uname -s 2>/dev/null || echo UNKNOWN)"
arch="$(uname -m 2>/dev/null || echo UNKNOWN)"

if [[ "$os" == "Linux" ]]; then pass "操作系统为 Linux"; else fail "操作系统不是 Linux（当前：$os）"; fi
if [[ "$arch" == "x86_64" ]]; then pass "CPU 架构为 x86_64"; else fail "CPU 架构不是 x86_64（当前：$arch；thirdparty 安装器为 Linux-x86_64）"; fi
if is_root; then pass "当前为 root（deploy-*.sh 会 checkForRoot）"; else fail "当前不是 root（deploy-*.sh 会直接退出）"; fi

# ------------------------------------------------------------------------------
# 2) 必要命令检查
#
# - thirdparty：tar/sed/cp/mv/chmod/rm/realpath 等
# - platform  ：systemctl/timeout/find/xargs/awk/grep/ps 等
# - yum/rpm    ：docker rpm fallback 或卸载路径会用到（缺失给 WARN）
# ------------------------------------------------------------------------------
for c in bash sh realpath tar sed cp mv chmod rm; do check_cmd "$c"; done
for c in awk grep find xargs timeout ps systemctl; do check_cmd "$c"; done

if cmd_exists yum; then pass "yum 可用"; else warn "yum 不可用：docker rpm fallback/卸载路径存在风险"; fi
if cmd_exists rpm; then pass "rpm 可用"; else warn "rpm 不可用：docker rpm fallback/卸载路径存在风险"; fi

# SELinux：不关闭会造成容器挂载/权限问题
if cmd_exists getenforce; then
  selinux_state="$(getenforce 2>/dev/null || true)"
  if [[ "$selinux_state" == "Enforcing" ]]; then
    warn "SELinux=Enforcing：可能影响容器挂载/读取配置（若失败需准备策略或调整）"
  else
    pass "SELinux 状态：$selinux_state"
  fi
else
  warn "未发现 getenforce：跳过 SELinux 状态检测"
fi

# ------------------------------------------------------------------------------
# 3) 关键脚本与 init_env.sh 加载
# ------------------------------------------------------------------------------
check_file "$COMMON_SH"
check_file "$INIT_ENV"
check_file "$DEPLOY_THIRDPARTY"
check_file "$DEPLOY_PLATFORM"

# init_env.sh 仅导出变量（无副作用），用于后续路径/端口/文件定位
if file_nonempty "$INIT_ENV"; then
  # shellcheck disable=SC1090
  source "$INIT_ENV"
  pass "已加载 init_env.sh（端口/目录变量已生效）"
else
  fail "init_env.sh 不可读：后续路径/端口检查可能不准确"
fi

# ------------------------------------------------------------------------------
# 4) thirdparty 部署前置：安装包与模板文件存在性
# ------------------------------------------------------------------------------
if [[ -n "${Thirdparty_DIR:-}" ]]; then pass "Thirdparty_DIR=${Thirdparty_DIR}"; else warn "Thirdparty_DIR 未定义"; fi
if [[ -n "${Installer_DIR:-}" ]]; then pass "Installer_DIR=${Installer_DIR}"; else fail "Installer_DIR 未定义（thirdparty 安装包目录无法确定）"; fi
if [[ -n "${Template_DIR:-}" ]]; then pass "Template_DIR=${Template_DIR}"; else fail "Template_DIR 未定义（模板目录无法确定）"; fi

check_file "${TurboVNC_installer:-$PROJECT_DIR/thirdparty/pkgs/TurboVNC-3.0.1-Linux-x86_64.sh}"
check_file "${NoVNC_installer:-$PROJECT_DIR/thirdparty/pkgs/noVNC-1.3.0.tar.gz}"
check_file "${OpenBox_installer:-$PROJECT_DIR/thirdparty/pkgs/OpenBox-3.6.1-Linux-x86_64.sh}"
check_file "${VirtualGL_installer:-$PROJECT_DIR/thirdparty/pkgs/VirtualGL-2.5.2-Linux-x86_64.sh}"

check_file "${Template_DIR:-$PROJECT_DIR/thirdparty/template}/turbovncserver.conf"
check_file "${Template_DIR:-$PROJECT_DIR/thirdparty/template}/menu.xml"

# ------------------------------------------------------------------------------
# 5) platform 部署前置：配置挂载文件、离线 docker 资源、后端离线依赖、filebrowser
# ------------------------------------------------------------------------------
# Nginx/Redis 配置文件为 docker run 的 -v 挂载源文件：必须存在，否则容器起不来
CONF_DIR_EFFECTIVE="${CONF_DIR:-$PROJECT_DIR/server-data/config}"
check_dir "$CONF_DIR_EFFECTIVE"
check_file "$CONF_DIR_EFFECTIVE/redis/redis-5.0.10.conf"

check_file "$CONF_DIR_EFFECTIVE/nginx/nginx.conf"
check_file "$CONF_DIR_EFFECTIVE/nginx/locations.conf"
check_file "$CONF_DIR_EFFECTIVE/nginx/api_proxy.conf"
check_file "$CONF_DIR_EFFECTIVE/nginx/http_locations.conf"
check_file "$CONF_DIR_EFFECTIVE/nginx/https_locations.conf"

# docker：允许当前不存在（脚本会尝试离线安装），但离线资源必须齐全
if cmd_exists docker; then
  pass "检测到 docker 命令（deploy-platform.sh 将直接使用现有 docker）"
else
  warn "未检测到 docker：deploy-platform.sh 将尝试离线安装（下面检查离线资源是否齐全）"
  check_dir "$PROJECT_DIR/docker"
  check_dir "$PROJECT_DIR/docker/pkgs"
  check_dir "$PROJECT_DIR/docker/images"
  check_file "$PROJECT_DIR/docker/pkgs/docker-20.10.15.tar.gz"
  check_file "$PROJECT_DIR/docker/docker.service"
fi

# 后端依赖：deploy-platform.sh 会离线安装 miniconda + venv + pip --no-index
check_dir "$PROJECT_DIR/web-server"
check_dir "$PROJECT_DIR/web-server/pkgs"
check_file "$PROJECT_DIR/web-server/pkgs/Miniconda3-py39_4.10.3-Linux-x86_64.sh"
check_file "$PROJECT_DIR/web-server/requirements.txt"

# filebrowser：deploy-platform.sh 直接运行二进制，必须存在且可执行
check_exec_file "$PROJECT_DIR/web-server/filebrowser/linux-amd64-filebrowser/filebrowser"

# /tmp 可写：deploy-platform.sh 会创建 /tmp/turbo-vnc（运行时目录），预检只需要可写性
if [[ -w /tmp ]]; then
  pass "/tmp 可写（/tmp/turbo-vnc 可在部署过程中创建）"
else
  fail "/tmp 不可写：部署时创建 /tmp/turbo-vnc 会失败"
fi

# ------------------------------------------------------------------------------
# 6) 端口检测（固定端口 + VNC 端口段；输出 PID/程序名）
# ------------------------------------------------------------------------------
print_fixed_port_map
log_info "开始检测端口占用（监听状态；显示 PID/程序名）..."

LISTENERS_TSV="$(mktemp -t precheck_listeners.XXXXXX)"
cleanup() { rm -f "$LISTENERS_TSV" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if build_listeners_tsv "$LISTENERS_TSV"; then
  pass "已获取监听端口明细（port/pid/prog）"
else
  warn "无法获取监听端口明细（缺少 ss 或 netstat），端口明细检测将跳过"
fi

# 固定占用端口
P_PG="${POSTGRES_PORT:-12377}"
P_REDIS="${REDIS_PORT:-55555}"
P_FRONT="${FRONT_PORT:-8086}"
P_BACKEND="${VNCMANAGEMENT_PORT:-10086}"
P_FILEB="${FILEBROWSER_PORT:-8088}"
P_SESSION_MGR="${VNC_SESSION_MGR_PORT:-8000}"
P_USER_MGMT="${USER_MANAGEMENT_PORT:-9000}"

if [[ -s "$LISTENERS_TSV" ]]; then
  check_port_free_with_details "$P_PG" "$LISTENERS_TSV"  "$(service_of_port "$P_PG")"
  check_port_free_with_details "$P_REDIS" "$LISTENERS_TSV" "$(service_of_port "$P_REDIS")"
  check_port_free_with_details "$P_FRONT" "$LISTENERS_TSV" "$(service_of_port "$P_FRONT")"
  check_port_free_with_details "$P_BACKEND" "$LISTENERS_TSV" "$(service_of_port "$P_BACKEND")"
  check_port_free_with_details "$P_FILEB" "$LISTENERS_TSV" "$(service_of_port "$P_FILEB")"
  check_port_free_with_details "$P_SESSION_MGR" "$LISTENERS_TSV" "$(service_of_port "$P_SESSION_MGR")"
  check_port_free_with_details "$P_USER_MGMT" "$LISTENERS_TSV" "$(service_of_port "$P_USER_MGMT")"
#   check_port_free_with_details "$P_SYM" "$LISTENERS_TSV" "$(service_of_port "$P_SYM")"

  # VNC 端口范围：明确告知两段范围是否占用，并列出占用明细
  check_port_range_with_details 5801 5899 "$LISTENERS_TSV" "VNC Web/HTTP(5801-5899)"
  check_port_range_with_details 5901 5999 "$LISTENERS_TSV" "VNC TCP(5901-5999)"
else
  warn "端口检测跳过：未生成监听端口明细"
fi

# ------------------------------------------------------------------------------
# 汇总与退出
# ------------------------------------------------------------------------------
log_info "========== 预检汇总 =========="
log_info "PASS=${PASS}  WARN=${WARN}  FAIL=${FAIL}"

if [[ "$FAIL" -gt 0 ]]; then
  log_fail "存在阻断项（FAIL）：请先修复后再执行部署脚本"
  exit 2
fi

if [[ "$WARN" -gt 0 ]]; then
  log_warn "无阻断项，但存在 WARN：部署可继续，建议评估风险项"
  exit 0
fi

log_ok "全部通过：环境满足部署脚本的前置条件"
exit 0
