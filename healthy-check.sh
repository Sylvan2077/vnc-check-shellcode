#!/usr/bin/env bash
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

set -o pipefail

# ------------------------------------------------------------------------------
# 初始化环境变量和函数库
# ------------------------------------------------------------------------------
export DOCKER_CMD=docker
export PROJECT_DIR=$(realpath "$(dirname "$0")"/../)
export DATA_DIR=$PROJECT_DIR/server-data
export CONF_DIR=$DATA_DIR/config
export SCRIPT_DIR=$DATA_DIR/config

source "$PROJECT_DIR/deploy-scripts/init_env.sh"
source "$PROJECT_DIR/deploy-scripts/common.sh"

MODE="PROD"  # FRESH DEV PROD

if ! echo "$0" | grep -q '\.sh$'; then
    bail 'Please run using "bash"/"dash"/"zsh"/"sh", but not "." or "source"'
fi


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

main() {
    serverCheck
}

main "$@"