#!/usr/bin/env bash
# ==============================================================================
# all_health_check.sh - SCNS APPS PLATFORM 一键式合并健康检查脚本
#
# 说明：
#   本脚本一键按顺序执行三项检查试用平台所有服务状态，打印详细信息进行输出。
#   本脚本不调用任何参数，支持用户傻瓜式一键操作。
#
# 检查顺序：
#   1) 端口等部署前置条件预检查
#   2) 服务及进程状态检查
#   3) 后端 VNC 会话服务接口检查
#   3.1) VNC 深度检查 - TurboVNC 切换用户桌面启动检测（仅在第3步失败时执行）
# ==============================================================================

set -o pipefail

# --- Unified environment initialization ---
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR="$(realpath "${SCRIPT_DIR}/..")"
export DATA_DIR="$PROJECT_DIR/server-data"
export CONF_DIR="$DATA_DIR/config"
export DEPLOY_SCRIPTS_DIR="$PROJECT_DIR/deploy-scripts"
export DOCKER_CMD=docker
MODE="PROD"  # FRESH DEV PROD

INIT_ENV_FILE="$DEPLOY_SCRIPTS_DIR/init_env.sh"
COMMON_SH_FILE="$DEPLOY_SCRIPTS_DIR/common.sh"

if [[ -f "$INIT_ENV_FILE" && -s "$INIT_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$INIT_ENV_FILE"
fi

if [[ -f "$COMMON_SH_FILE" && -s "$COMMON_SH_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$COMMON_SH_FILE"
fi

# --- Color constants and precheck log functions ---
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

# --- Shared utility ---
is_root() { [[ "$(id -u 2>/dev/null || echo 99999)" == "0" ]]; }

# --- ask_continue() and print_stage_header() ---
ask_continue() {
    local prompt="${1:-是否继续下一项检查？}"
    local answer

    while true; do
        read -r -p "$prompt (y/n): " answer
        case "$answer" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO]) return 1 ;;
            *) echo "请输入 y 或 n" ;;
        esac
    done
}

print_stage_header() {
    local title="$1"
    printf "\n${LIGHT_BLUE}========== %s ==========${NOCOLOR}\n" "$title"
}

  # 检查用户是否存在，不存在则创建
_check_and_create_user() {
  local username="$1"
  if ! id -u "$username" >/dev/null 2>&1; then
    logWarn "用户 $username 不存在，正在创建..."
    useradd -m "$username" || {
      logError "创建用户 $username 失败"
      return 1
    }
    logSuccess "用户 $username 创建成功"
  else
    logInfo "用户 $username 已存在，继续检测"
  fi
}

# 切换到指定用户
_switch_to_user() {
  local username="$1"
  logInfo "切换到用户 $username..."
  su - "$username" -c "whoami" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then
    logSuccess "成功切换到用户 $username"
    return 0
  else
    logError "切换到用户 $username 失败"
    return 1
  fi
}
# === STAGE 1: run_precheck() function ===
run_precheck() {
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

  # 重置 precheck 计数器
  PASS=0
  WARN=0
  FAIL=0

# ------------------------------------------------------------------------------
# 基础工具函数
# ------------------------------------------------------------------------------
  cmd_exists() { command -v "$1" >/dev/null 2>&1; }

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
          if (match(proc, /\("([^"]+)"/, m)) { prog=m[1] }
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
    cleanup
    return 2
  fi

  if [[ "$WARN" -gt 0 ]]; then
    log_warn "无阻断项，但存在 WARN：部署可继续，建议评估风险项"
    cleanup
    return 0
  fi

  log_ok "全部通过：环境满足部署脚本的前置条件"
  cleanup
  return 0
}

# === STAGE 2: run_healthy_check() function ===
run_healthy_check() {
# ==============================================================================
# healthy-check.sh - SCNS APPS PLATFORM 服务状态一键式检测
#
# 目标：
#   - 确认 docker 容器服务是否正常运行
#   - 确认 fastapi 服务是否正常运行
#
# 行为约束：
#   仅检测：不安装、不修改、不创建目录、不启动服务
#
# 退出：
#   根据提示对服务进行排查和修复
# ==============================================================================

# ------------------------------------------------------------------------------
# 基础工具函数
# ------------------------------------------------------------------------------
  statusContainer() {
      # status: 0 for started, 1 for not-started, 2 for down
      local serviceName=$1

      local name_status=$(docker ps -a --format "{{.Names}} {{.Status}}" | grep -e "\b${serviceName}\b")
      local existing_status=$(echo "$name_status" | grep -c "")
      local up_status=$(echo "$name_status" | grep -c "Up")
      local down_status=$(echo "$name_status" | grep -c "Exited")

      if [[ "$up_status" == "1" ]]; then
          echo 0
          return
      fi

      # 如果容器没有被启动，则返回 1
      if [[ "$existing_status" == "0" ]]; then
          echo 1
          return
      fi

      # 如果已启动但是 stop 状态，则返回 2
      if [[ "$down_status" == "1" ]]; then
          echo 2
          return
      fi

      echo 1
  }

  statusProgram() {
      # $1 为 grep target, 0 for started, 1 for not started
      local started=$(ps -ef | grep -v grep | grep -e "\b$1\b" -c)

      if [[ "$started" == "0" ]]; then
          echo 1
      else
          echo 0
      fi
  }


# ------------------------------------------------------------------------------
# docker 容器状态检测函数
# ------------------------------------------------------------------------------
  statusPG() {
      local status=$(statusContainer "$PG_NAME")

      if [[ "$status" == "0" ]]; then
          logSuccess "数据库 [PostgreSQL] 已正常启动"
      else
          logError "数据库 [PostgreSQL] 未启动，请按照以下步骤进行启动"
          logWarn "1. 进入项目目录：cd /opt/scns-apps-platform/deploy-scripts/"
          logWarn "2. 启动数据库服务：bash deploy-platform.sh s pg s 或直接运行bash deploy-platform.sh s s"
          logWarn "3. 启动后再次调用脚本：bash health-check.sh或bash deploy-platform.sh s ss检查服务状态"
          logWarn "4. 查看日志：docker logs -f $PG_NAME"
          logWarn "5. 如仍存在问题，请检查日志并根据日志内容联系质保管理员处理"
      fi
  }

  statusRedis() {
      local status=$(statusContainer "$RDS_NAME")

      if [[ "$status" == "0" ]]; then
          logSuccess "缓存 [Redis] 已正常启动"
      else
          logError "缓存 [Redis] 未启动，请按照以下步骤进行启动"
          logWarn "1. 进入项目目录：cd /opt/scns-apps-platform/deploy-scripts/"
          logWarn "2. 启动缓存服务：bash deploy-platform.sh s redis s 或直接运行bash deploy-platform.sh s s"
          logWarn "3. 启动后再次调用脚本：bash health-check.sh或bash deploy-platform.sh s ss检查服务状态"
          logWarn "4. 查看日志：docker logs -f $RDS_NAME"
          logWarn "5. 如仍存在问题，请检查日志并根据日志内容联系质保管理员处理"
      fi
  }

  statusNginx() {
      local status=$(statusContainer "$NGX_NAME")

      if [[ "$status" == "0" ]]; then
          logSuccess "网关 [Nginx] 已正常启动"
      else
          logError "网关 [Nginx] 未启动，请按照以下步骤进行启动"
          logWarn "1. 进入项目目录：cd /opt/scns-apps-platform/deploy-scripts/"
          logWarn "2. 启动网关服务：bash deploy-platform.sh s nginx s 或直接运行bash deploy-platform.sh s s"
          logWarn "3. 启动后再次调用脚本：bash health-check.sh或bash deploy-platform.sh s ss检查服务状态"
          logWarn "4. 查看日志：docker logs -f $NGX_NAME"
          logWarn "5. 如仍存在问题，请检查日志并根据日志内容联系质保管理员处理"
      fi
  }

  statusBackend() {
      local status=$(statusContainer "$BACKEND_NAME")

      if [[ "$status" == "0" ]]; then
          logSuccess "后端服务 [Backend] 已正常启动"
      else
          logError "后端服务 [Backend] 未启动，请按照以下步骤进行启动"
          logWarn "1. 进入项目目录：cd /opt/scns-apps-platform/deploy-scripts/"
          logWarn "2. 启动后端服务：bash deploy-platform.sh s backend s 或直接运行bash deploy-platform.sh s s"
          logWarn "3. 启动后再次调用脚本：bash health-check.sh或bash deploy-platform.sh s ss检查服务状态"
          logWarn "4. 查看日志：docker logs -f $BACKEND_NAME"
          logWarn "5. 如仍存在问题，请检查日志并根据日志内容联系质保管理员处理"
      fi
  }

# ------------------------------------------------------------------------------
#  web服务状态检测函数
# ------------------------------------------------------------------------------
  statusVNCMgt() {
      # 1 for not started, 0 for started
      local started=$(statusProgram "$VNC_SESSION_MANAGER_PORT")

      if [[ "$started" == "0" ]]; then
          logSuccess "会话管理服务 [VNCMgt] 已正常启动"
      else
          logError "会话管理服务 [VNCMgt] 未启动，请按照以下步骤进行启动"
          logWarn "1. 进入项目目录：cd /opt/scns-apps-platform/deploy-scripts/"
          logWarn "2. 启动会话管理服务：bash deploy-platform.sh s vncmgt s 或直接运行bash deploy-platform.sh s s"
          logWarn "3. 启动后再次调用脚本：bash health-check.sh或bash deploy-platform.sh s ss检查服务状态"
          logWarn "4. 会话管理器日志: /opt/scns_apps_platform/web-server/vnc-session-manager/workspace/logs/vnc_session_manager.log"
          logWarn "5. 如果仍未启动，请按照以下步骤进行手动启动："
          logInfo "5.1 进入会话管理所在目录：cd /opt/scns_apps_platform/web-server/"
          logInfo "5.2 激活目录下虚环境 source py310-env/bin/activate"
          logInfo "5.3 进入vnc-session-manager目录，并手动启动服务：uvicorn --host 0.0.0.0 --port 8000 --reload main:app > log 2>&1 &"
          logInfo "5.4 检查服务是否启动：netstat -nlp | grep 8000 （应显示 0.0.0.0:8000）"
          logInfo "5.5 查看服务日志：tail -f log"
          logInfo "5.6 如仍存在问题，请检查日志并根据日志内容联系质保管理员处理"
      fi
  }

  statusUserMgt() {
      # 1 for not started, 0 for started
      local started=$(statusProgram "$USER_MANAGEMENT_PORT")

      if [[ "$started" == "0" ]]; then
          logSuccess "用户管理服务 [UserMgt] 已正常启动"
      else
          logError "用户管理服务 [UserMgt] 未启动，请按照以下步骤进行启动"
          logWarn "1. 进入项目目录：cd /opt/scns-apps-platform/deploy-scripts/"
          logWarn "2. 启动用户管理服务：bash deploy-platform.sh s usermgt s 或直接运行bash deploy-platform.sh s s"
          logWarn "3. 启动后再次调用脚本：bash health-check.sh或bash deploy-platform.sh s ss检查服务状态"
          logWarn "4. 用户管理服务日志: /opt/scns_apps_platform/web-server/user-management-service/workspace/logs/user_management.log"
          logWarn "5. 如果仍未启动，请按照以下步骤进行手动启动："
          logInfo "5.1 进入用户管理所在目录：cd /opt/scns_apps_platform/web-server/user-management-service/"
          logInfo "5.2 激活目录下虚环境 source py310-env/bin/activate"
          logInfo "5.3 进入user-management-service目录，手动启动服务：uvicorn --host 0.0.0.0 --port 9000 --reload main:app > log 2>&1 &"
          logInfo "5.4 检查服务是否启动：netstat -nlp | grep 9000 （应显示 0.0.0.0:9000）"
          logInfo "5.5 查看服务日志：tail -f log"
          logInfo "5.6 如仍存在问题，请检查日志并根据日志内容联系质保管理员处理"
      fi
  }

  statusFileBrowser() {
      # 1 for not started, 0 for started
      local started=$(statusProgram filebrowser)

      if [[ "$started" == "0" ]]; then
          logSuccess "文件浏览器服务 [FileBrowser] 已正常启动"
      else
          logError "文件浏览器服务 [FileBrowser] 未启动，请按照以下步骤进行启动"
          logWarn "1. 进入项目目录：cd /opt/scns-apps-platform/deploy-scripts/"
          logWarn "2. 启动文件浏览器服务：bash deploy-platform.sh s filebrowser s 或直接运行bash deploy-platform.sh s s"
          logWarn "3. 启动后再次调用脚本：bash health-check.sh或bash deploy-platform.sh s ss检查服务状态"
          logWarn "4. 文件浏览器服务日志: /opt/scns_apps_platform/web-server/filebrowser/workspace/logs/file_browser.log"
          logWarn "5. 如果仍未启动，请按照以下步骤进行手动启动："
          logInfo "5.1 进入文件浏览器所在目录：cd /opt/scns_apps_platform/web-server/filebrowser/"
          logInfo "5.2 激活目录下虚环境 source py310-env/bin/activate"
          logInfo "5.3 进入filebrowser/linux-amd64-filebrowser目录"
          logInfo "5.4 手动启动服务：./filebrowser -r /public-files-dir -p 8088 -a 0.0.0.0 > log 2>&1 &"
          logInfo "5.5 检查服务是否启动：netstat -nlp | grep 8088 （应显示 0.0.0.0:8088）"
          logInfo "5.6 查看服务日志：tail -f log"
          logInfo "5.7 如仍存在问题，请检查日志并根据日志内容联系质保管理员处理"
      fi
  }


# ------------------------------------------------------------------------------
# 主逻辑
# ------------------------------------------------------------------------------
  serverCheck() {
      # 检测各个服务的状态
      statusPG
      statusRedis
      statusNginx
      statusBackend
      statusVNCMgt
      statusUserMgt
      statusFileBrowser
  }

  serverCheck
  return 0
}

# === STAGE 3: run_vnc_check() function ===
run_vnc_check() {
# ==============================================================================
# vnc_deep_check.sh - SCNS APPS PLATFORM VNC 会话服务深度检测
#
# 目标：
#   - 确认 VNC 会话管理服务是否正常运行
#   - 调用会话服务 API 创建桌面并校验返回信息
#
# 注意：
#   启动 VNC 会话管理服务后，才能进行检测
#   检测完毕后，请根据提示终止测试桌面
#
# 退出码：
#   1  : 存在阻断项，建议重启vnc会话管理服务
# ==============================================================================

# ------------------------------------------------------------------------------
# 检测 VNC 静态函数
# ------------------------------------------------------------------------------
## 调用vnc session api接口启动桌面
  _check_vnc_session() {
      logInfo "开始检测 VNC 会话服务"

      local count=$(ps -ef | grep -v grep | grep -w "$VNC_SESSION_MANAGER_PORT" -c)

      if [[ $count -ge 1 ]]; then
          logSuccess "VNC 会话服务正常运行（检测到 ${count} 个相关进程）"
      else
          logError "VNC 会话服务未启动（端口 ${VNC_SESSION_MANAGER_PORT} 无进程）"
          return 1
      fi

      logWarn "会话管理器日志: /opt/scns_apps_platform/web-server/vnc-session-manager/workspace/logs/vnc_session_manager.log"

      # 调用 VNC 会话服务 API 创建桌面会话
      logInfo "正在调用 VNC 会话服务 API 创建桌面..."
      local api_url="http://0.0.0.0:8000/vnc/start_session"
      
      # 检查脚本是否存在
      if [ ! -f /opt/scns_apps_platform/thirdparty/app_start_scripts/run_glx.sh ]; then
          logError "脚本 /opt/scns_apps_platform/thirdparty/app_start_scripts/run_glx.sh 不存在，退出"
          exit 1
      fi
      
      local api_payload='{"username":"caep_user1","display_number":1,"custom_script_path":"/opt/scns_apps_platform/thirdparty/app_start_scripts/run_glx.sh"}'

      local api_response
      api_response=$(curl -s -X POST "$api_url" \
          -H "accept: application/json" \
          -H "Content-Type: application/json" \
          -d "$api_payload" 2>&1)
      local api_rc=$?

      if [[ $api_rc -ne 0 ]]; then
          logError "调用 VNC 会话服务 API 失败（curl 返回码: $api_rc）"
          logWarn "API 响应: $api_response"
          return 1
      fi

      # 检查 API 响应
      if echo "$api_response" | grep -q "error\|failed\|Error"; then
          logWarn "VNC 会话服务 API 返回异常: $api_response"
      else
          logSuccess "VNC 会话服务 API 调用成功: $api_response"
      fi

      # 解析 session_id 并返回（优先使用 jq，再用 python3，最后用 sed 回退）
      local session_id=""
      if command -v jq >/dev/null 2>&1; then
          session_id=$(echo "$api_response" | jq -r '.data.vnc_session_info.session_id // empty')
      elif command -v python >/dev/null 2>&1; then
          session_id=$(python -c "
          import sys,json
          try:
              d=json.load(sys.stdin)
              print(d.get('data',{}).get('vnc_session_info',{}).get('session_id',''))
          except:
              print('error')
          " <<< "$api_response" 2>/dev/null)
      else
          session_id=$(echo "$api_response" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -n1)
      fi

      if [[ -n "$session_id" ]]; then
          export VNC_SESSION_ID="$session_id"
          logSuccess "解析到 session_id: $session_id"
          echo "$session_id"
          return 0
      else
          logError "未解析到 session_id，API 响应: $api_response"
          return 1
      fi
  }


# ------------------------------------------------------------------------------
# 检测主函数
# ------------------------------------------------------------------------------
  deep_check_vnc_session() {
      logInfo "开始调用 VNC 服务"

      # 调用 VNC 会话服务检测
      _check_vnc_session || return 1

      logWarn "请在检测桌面启动结束后终止会话:
      执行 /opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver -kill :1
      然后执行 pgrep -f "Xvnc.*:1" 获取进程pid
      若存在pid 执行 kill pid 杀死进程"
  }

# ------------------------------------------------------------------------------
# 主逻辑
# ------------------------------------------------------------------------------
  logInfo "执行模式: VNC 会话服务深度检测"
  deep_check_vnc_session
  return $?
}

run_vnc_deep_check() {

  # 检查并定位 glxspheres64 可执行文件
  _check_glxspheres64() {
    local glx_cmd=""
    if command -v glxspheres64 >/dev/null 2>&1; then
      glx_cmd=$(command -v glxspheres64)
    elif [[ -x /opt/scns_apps_platform/thirdparty/VirtualGL/bin/glxspheres64 ]]; then
      glx_cmd="/opt/scns_apps_platform/thirdparty/VirtualGL/bin/glxspheres64"
    else
      logError "未检测到 glxspheres64。请安装 VirtualGL，例如: yum install -y VirtualGL"
      return 1
    fi
    echo "$glx_cmd"
  }

  # 检查当前是否已存在 :1 会话
  _check_existing_session() {
    local vnc_session_cmd="/opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver"
    if $vnc_session_cmd -list 2>/dev/null | grep -q ':1'; then
      logError "存在 :1 会话，可能是之前测试未终止，请先终止会话:
      $vnc_session_cmd -kill :1"
      return 1
    fi
    return 0
  }

  # 启动 TurboVNC :1 会话并捕获输出
  _start_turbovnc_session() {
    local glx_cmd="$1"
    local vnc_server_cmd="/opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver"

    logInfo "正在启动 TurboVNC :1 会话..."
    local vnc_output
    vnc_output=$(sudo $vnc_server_cmd :1 -geometry 1280x800 -depth 24 -xstartup "$glx_cmd" 2>&1)
    local rc=$?

    # 打印完整输出供用户查看
    printf '%s\n' "$vnc_output"

    if [[ $rc -ne 0 ]]; then
      logError "TurboVNC 桌面启动失败"
      return 1
    fi

    echo "$vnc_output"
  }

  # 验证桌面启动成功（检查 Xvnc 进程）
  _verify_desktop_startup() {
    sleep 1
    local vnc_pid
    vnc_pid=$(pgrep -f "Xvnc.*:1" | head -n1)
    if [[ -z "$vnc_pid" ]]; then
      logError "桌面启动失败：未检测到 Xvnc 进程（:1 会话）"
      return 1
    fi
    logSuccess "桌面启动成功（PID: $vnc_pid）"
    echo "$vnc_pid"
  }

  # 检测 noVNC 端口（5801）
  _check_novnc_port() {
    if netstat -tuln 2>/dev/null | grep -q ':5801 '; then
      logSuccess "5801 端口检测成功（noVNC 服务正常运行）"
      return 0
    else
      logWarn "5801 端口未检测到，请确认 noVNC 服务是否已启动"
      return 1
    fi
  }

  # 解析 vncserver 输出并打印关键信息
  _parse_vnc_output() {
    local vnc_output="$1"
    shopt -s nocasematch
    while IFS= read -r line; do
      local trimmed="${line#"${line%%[![:space:]]*}"}"
      if [[ $trimmed =~ ^noVNC[[:space:]]+URL ]]; then
        logWarn "$trimmed"
      elif [[ $trimmed =~ ^Full[[:space:]]+control[[:space:]]+one-time[[:space:]]+password ]]; then
        logWarn "$trimmed"
      fi
    done <<< "$vnc_output"
    shopt -u nocasematch
  }

  # 执行 glxspheres64 并验证帧率信息
  _verify_glxspheres64() {
    local glx_cmd="$1"
    logInfo "执行 glxspheres64 验证 GPU 渲染..."

    local glx_output
    glx_output=$("$glx_cmd" 5 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]]; then
      logError "glxspheres64 执行失败"
      return 1
    fi

    if echo "$glx_output" | grep -qi "fps\|frame"; then
      local fps_info
      fps_info=$(echo "$glx_output" | grep -i "fps\|frame" | head -n1)
      logSuccess "glxspheres64 执行成功，帧率信息: $fps_info"
      return 0
    else
      logWarn "glxspheres64 执行完成，但未检测到帧率信息"
      return 0
    fi
  }

  # 打印使用说明
  _print_usage_guide() {
    cat << 'EOF'

TurboVNC / noVNC 使用说明：

1. noVNC 访问方式
   上方桌面启动信息输出中noVNC URL为桌面地址、Full control one-time password为桌面密码
   浏览器打开 noVNC 页面 → 输入密码 

2. 查看当前会话列表
   /opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver -list

3. 启动新会话（冒号后为<会话编号>，例如 :1）
   /opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver :1 
       -geometry 1280x800 -depth 24 
       -xstartup /opt/scns_apps_platform/thirdparty/VirtualGL/bin/glxspheres64

4. 日志位置
   /tmp/turbo-vnc/<用户名>-vnc/<用户名>:<会话编号>.log

5. 注意检测结束请终止会话（冒号后为<会话编号>，例如 :1）
   /opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver -kill :1
    然后执行 pgrep -f "Xvnc.*:1" 获取进程pid
    若存在pid 执行 kill pid 杀死进程"

6. 如有问题请检查日志并根据日志内容联系质保管理员处理

EOF
  }

  # 检测主函数
  check_turbovnc_usage() {
    logInfo "开始检测 TurboVNC 桌面启动信息"

    if is_root; then
      logSuccess "当前为 root（deploy-*.sh 会 checkForRoot）"
    else
      logError "当前不是 root（deploy-*.sh 会直接退出）"
      return 1
    fi

    _check_and_create_user "caep_user1" || return 1
    _switch_to_user "caep_user1" || return 1

    local glx_cmd
    glx_cmd=$(_check_glxspheres64) || return 1
    logSuccess "已定位 glxspheres64: $glx_cmd"

    su - "caep_user1" -c "$glx_cmd 5" >/dev/null 2>&1
    if ! _verify_glxspheres64 "$glx_cmd"; then
      logError "glxspheres64 验证失败，退出"
      return 1
    fi

    _check_existing_session || return 1

    local vnc_output
    vnc_output=$(_start_turbovnc_session "$glx_cmd") || return 1

    _verify_desktop_startup || return 1
    if ! _check_novnc_port; then
      logError "noVNC 端口检测失败，退出"
      return 1
    fi

    _parse_vnc_output "$vnc_output"

    logInfo "检测 TurboVNC 桌面启动信息结束"
    logWarn "请在检测桌面启动结束后终止会话:
    /opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver -kill :1
    然后执行 pgrep -f "Xvnc.*:1" 获取进程pid
    若存在pid 执行 kill pid 杀死进程"

    _print_usage_guide
  }

  logInfo "执行模式: TurboVNC 完整检测"
  check_turbovnc_usage
  return $?
}

# === Main flow ===
main() {
    local rc_precheck=0
    local rc_healthy=0
    local rc_vnc=0
    local rc_vnc_deep=0
    local ran_vnc_deep=0

    print_stage_header "第1项：端口等部署前置条件预检查"
    run_precheck
    rc_precheck=$?
    if ! ask_continue "是否继续下一项检查？"; then
        log_warn "用户选择停止。已结束检查流程。"
        return 0
    fi

    print_stage_header "第2项：服务及进程状态检查"
    run_healthy_check
    rc_healthy=$?
    if ! ask_continue "是否继续下一项检查？"; then
        log_warn "用户选择停止。已结束检查流程。"
        return 0
    fi

    print_stage_header "第3项：VNC服务后端接口检查"
    run_vnc_check
    rc_vnc=$?

    if [[ $rc_vnc -ne 0 ]]; then
        if ! ask_continue "VNC检查失败，是否进行VNC深度检查？"; then
            log_warn "用户选择停止。已结束检查流程。"
            return 0
        fi
        ran_vnc_deep=1
        print_stage_header "第3.1项：VNC 深度检查（TurboVNC 桌面启动检测）"
        run_vnc_deep_check
        rc_vnc_deep=$?
    fi

    print_stage_header "全部检查执行完成"
    log_info "结果汇总："

    if [[ $rc_precheck -eq 0 ]]; then
        log_ok "端口预检查：成功"
    else
        log_fail "端口预检查：失败，退出码 $rc_precheck"
    fi

    if [[ $rc_healthy -eq 0 ]]; then
        log_ok "进程及服务状态检查：成功"
    else
        log_fail "进程及服务状态检查：失败，退出码 $rc_healthy"
    fi

    if [[ $rc_vnc -eq 0 ]]; then
        log_ok "VNC服务后端接口检查：成功"
    else
        log_fail "VNC服务后端接口检查：失败，退出码 $rc_vnc"
    fi

    if [[ $ran_vnc_deep -eq 1 ]]; then
        if [[ $rc_vnc_deep -eq 0 ]]; then
            log_ok "VNC深度检查：成功"
        else
            log_fail "VNC深度检查：失败，退出码 $rc_vnc_deep"
        fi
    fi

    log_info "一键健康检查流程结束。"
    return 0
}

main "$@"
