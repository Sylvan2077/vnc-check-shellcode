#!/bin/bash
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
        exit 1
    fi

    logWarn "会话管理器日志: /opt/scns_apps_platform/web-server/vnc-session-manager/workspace/logs/vnc_session_manager.log"
    
    # 调用 VNC 会话服务 API 创建桌面会话
    logInfo "正在调用 VNC 会话服务 API 创建桌面..."
    local api_url="http://0.0.0.0:8000/vnc/start_session"
    local api_payload='{"username":"caep_user1","display_number":1,"custom_script_path":"/opt/scns_apps_platform/thirdparty/app_start_scripts/run_glx.sh"}'
    
    local api_response
    api_response=$(curl -s -X POST "$api_url" 
        -H "accept: application/json" 
        -H "Content-Type: application/json" 
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
        logWarn "未解析到 session_id，API 响应: $api_response"
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
    执行 bash vnc-check.sh --kill
    或者 curl -X 'DELETE' 
    'http://0.0.0.0:8000/vnc/close_session/{session_id}' 
    -H 'accept: application/json'"
    
}

# ------------------------------------------------------------------------------
# 主逻辑
# ------------------------------------------------------------------------------

logInfo "执行模式: VNC 会话服务深度检测"
deep_check_vnc_session
