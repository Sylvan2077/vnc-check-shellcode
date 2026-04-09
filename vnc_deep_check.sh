#!/bin/bash
# ==============================================================================
# vnc_session_check.sh - SCNS APPS PLATFORM TurboVNC 会话检测
#
# 目标：
#   - 确认 TurboVNC 能否正常启动桌面
#   - 提供 noVNC 访问信息与会话操作指引
#
# 注意：
#   启动 VNC 会话管理服务后，才能进行检测
#   检测完毕后，请根据提示终止测试桌面
#
# 退出码：
#   1  : 存在阻断项，建议重启vnc会话管理服务
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# 初始化环境变量和函数库
# ------------------------------------------------------------------------------
export DOCKER_CMD=docker
export PROJECT_DIR=$(realpath "$(dirname "$0")"/../)
export DATA_DIR=$PROJECT_DIR/server-data
export CONF_DIR=$DATA_DIR/config
export SCRIPT_DIR=$(realpath "$(dirname "$0")")

source "$PROJECT_DIR/deploy-scripts/init_env.sh"
source "$PROJECT_DIR/deploy-scripts/common.sh"

MODE="PROD"  # FRESH DEV PROD

if ! echo "$0" | grep -q '\.sh$'; then
    bail 'Please run using "bash"/"dash"/"zsh"/"sh", but not "." or "source"'
fi

is_root() { [[ "$(id -u 2>/dev/null || echo 99999)" == "0" ]]; }


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
        logError "存在 :1 会话，可能是之前测试未终止，请先终止会话:bash vnc-check.sh --kill
        或 $vnc_session_cmd -kill :1"
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
    printf '%s
' "$vnc_output"
    
    if [[ $rc -ne 0 ]]; then
        logError "TurboVNC 桌面启动失败"
        return 1
    fi
    
    echo "$vnc_output"
}

# 验证桌面启动成功（检查 Xvnc 进程）
_verify_desktop_startup() {
    sleep 1  # 等待进程启动完成
    local vnc_pid=$(pgrep -f "Xvnc.*:1" | head -n1)
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
        # 去掉行首空白
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ $trimmed =~ ^noVNC[[:space:]]+URL ]]; then
            logWarn "$trimmed"
        elif [[ $trimmed =~ ^Full[[:space:]]+control[[:space:]]+one-time[[:space:]]+password ]]; then
            logWarn "$trimmed"
        fi
    done <<< "$vnc_output"
    shopt -u nocasematch
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

# 执行 glxspheres64 并验证帧率信息
_verify_glxspheres64() {
    local glx_cmd="$1"
    logInfo "执行 glxspheres64 验证 GPU 渲染..."
    
    # 执行 glxspheres64 5 次以获取帧率统计
    local glx_output
    glx_output=$("$glx_cmd" 5 2>&1)
    local rc=$?
    
    if [[ $rc -ne 0 ]]; then
        logError "glxspheres64 执行失败"
        return 1
    fi
    
    # 检查是否输出了帧率信息（通常包含 fps 或帧率相关的数字）
    if echo "$glx_output" | grep -qi "fps\|frame"; then
        local fps_info=$(echo "$glx_output" | grep -i "fps\|frame" | head -n1)
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
   执行bash vnc-check.sh --kill
   或者 /opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver -kill :1

6. 如有问题请检查日志并根据日志内容联系质保管理员处理

EOF
}


# ------------------------------------------------------------------------------
# 检测主函数
# ------------------------------------------------------------------------------

check_turbovnc_usage() {
    logInfo "开始检测 TurboVNC 桌面启动信息"
    
    if is_root; then logSuccess "当前为 root（deploy-*.sh 会 checkForRoot）"; else logError "当前不是 root（deploy-*.sh 会直接退出）"; exit 1; fi

    # 步骤 1：检查并创建测试用户
    _check_and_create_user "caep_user1" || return 1
    
    # 步骤 2：切换到 caep_user1 用户
    _switch_to_user "caep_user1" || return 1
    
    # 步骤 3：检查并定位 glxspheres64
    local glx_cmd
    glx_cmd=$(_check_glxspheres64) || return 1
    logSuccess "已定位 glxspheres64: $glx_cmd"
    
    # 步骤 4：执行 glxspheres64 并验证帧率信息
    su - "caep_user1" -c "$glx_cmd 5" >/dev/null 2>&1
    _verify_glxspheres64 "$glx_cmd" || logWarn "glxspheres64 验证失败，但继续检测"
    
    # 步骤 5：检查是否存在冲突的 :1 会话
    _check_existing_session || return 1
    
    # 步骤 6：启动 TurboVNC :1 会话
    local vnc_output
    vnc_output=$(_start_turbovnc_session "$glx_cmd") || return 1
    
    # 步骤 7：验证桌面启动成功
    _verify_desktop_startup || return 1
    
    # 步骤 8：检测 noVNC 服务端口
    _check_novnc_port || logWarn "noVNC 端口检测失败，但继续检测"
    
    # 步骤 9：解析并打印关键信息
    _parse_vnc_output "$vnc_output"
    
    # 步骤 10：打印使用说明和提示
    logInfo "检测 TurboVNC 桌面启动信息结束"
    logWarn "请在检测桌面启动结束后终止会话:
    执行 bash vnc-check.sh --kill
    或者 /opt/scns_apps_platform/thirdparty/TurboVNC/bin/vncserver -kill :1"
    
    _print_usage_guide
}

# ------------------------------------------------------------------------------
# 主逻辑
# ------------------------------------------------------------------------------

logInfo "执行模式: TurboVNC 完整检测"
check_turbovnc_usage
