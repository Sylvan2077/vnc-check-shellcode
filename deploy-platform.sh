#!/bin/bash

# constants
export DOCKER_CMD=docker
export PROJECT_DIR=$(realpath "$(dirname "$0")"/../)
export DATA_DIR=$PROJECT_DIR/server-data
export CONF_DIR=$DATA_DIR/config
export SCRIPT_DIR=$(realpath "$(dirname "$0")")

source $PROJECT_DIR/deploy-scripts/init_env.sh
source $PROJECT_DIR/deploy-scripts/common.sh

MODE="PROD" # FRESH DEV PROD

if ! echo "$0" | grep '\.sh$' >/dev/null; then
    bail 'Please run using "bash"/"dash"/"zsh"/"sh", but not "." or "source"'
fi

########### PreCheck #################
preCheck() {
    checkForRoot
    checkFirewalld
    checkSelinuxDisabled
}

########### Docker #################
getDockerVersion() {
    DOCKER_VERSION=$(docker -v | awk '{gsub(/,/, "", $3); print $3}')
    echo $DOCKER_VERSION
}

installDockerFromTarball() {
    logInfo "Start to install docker from tarball ..."
    pushd $PROJECT_DIR/docker >/dev/null
    tar -xf pkgs/docker-20.10.15.tar.gz
    mv docker/bin/* /usr/bin/
    mv docker/docker.service /etc/systemd/system
    rm -rf docker
    popd >/dev/null
}

installDockerFromRpm() {
    logInfo "Start to install docker from rpm packages ..."
    yum install ../docker/pkgs/*.rpm
}

adjustPermission() {
    # adjust permission
    group=docker
    # create group if not exists
    egrep "^$group" /etc/group >&/dev/null
    if [ $? -ne 0 ]; then
        groupadd $group
        usermod -aG docker $USER
    fi
    newgrp $group
    chmod a+rw /var/run/docker.sock

    logInfo "Docker has been installed in your computer, thank you for installing docker!"
}

loadImages() {
    if [[ "$MODE" == "FRESH" ]]; then
        find "$1" -type f | xargs -I{} bash -c "docker load < {}"
    else
        # nginx
        local haveImage=$(docker images -a --no-trunc --format "{{.Repository}}:{{.Tag}}" | grep -e "\b$NGINX_IMG\b" -c)
        if [[ "$haveImage" == "1" ]]; then
            logSuccess "Image [$NGINX_IMG] is alrealdy loaded."
        else
            logInfo "Now load image [$NGINX_IMG]"
            find "$1" -name "nginx*.tar" -type f | xargs -I{} bash -c "docker load < {}"
        fi
        # pg
        local haveImage=$(docker images -a --no-trunc --format "{{.Repository}}:{{.Tag}}" | grep -e "\b$PG_IMG\b" -c)
        if [[ "$haveImage" == "1" ]]; then
            logSuccess "Image [$PG_IMG] is alrealdy loaded."
        else
            logInfo "Now load image [$PG_IMG]"
            find "$1" -name "postgresql*.tar" -type f | xargs -I{} bash -c "docker load < {}"
        fi
        # redis
        local haveImage=$(docker images -a --no-trunc --format "{{.Repository}}:{{.Tag}}" | grep -e "\b$REDIS_IMG\b" -c)
        if [[ "$haveImage" == "1" ]]; then
            logSuccess "Image [$REDIS_IMG] is alrealdy loaded."
        else
            logInfo "Now load image [$REDIS_IMG]"
            find "$1" -name "postgresql*.tar" -type f | xargs -I{} bash -c "docker load < {}"
        fi
        # db
        local haveImage=$(docker images -a --no-trunc --format "{{.Repository}}:{{.Tag}}" | grep -e "\b$BACKEND_IMG\b" -c)
        if [[ "$haveImage" == "1" ]]; then
            logSuccess "Image [$BACKEND_IMG] is alrealdy loaded."
        else
            logInfo "Now load image [$BACKEND_IMG]"
            find "$1" -name "postgresql*.tar" -type f | xargs -I{} bash -c "docker load < {}"
        fi
    fi
}

startDocker() {
    # enable docker service
    chmod +x /etc/systemd/system/docker.service
    logInfo "Enable and start docker service ..."
    logInfo "Please wait ..."
    systemctl daemon-reload
    systemctl enable docker.service
    timeout 5s systemctl start docker.service

    if [ $? -ne 0 ]; then
        bail "Something wrong when start docker. Please run 'systemctl start docker.service' again or try to install docker with rpm packages."
    else
        logInfo "Docker has been started."
    fi
}

removeDocker() {
    local dockerIntallFromTarball=$(rpm -q docker-ce | grep "not" -c)
    if [[ "$dockerIntallFromTarball" == "1" ]]; then
        systemctl disable docker.service
        systemctl stop docker.service
        if [ -f "/etc/systemd/system/docker.service" ]; then
            rm /etc/systemd/system/docker.service -rf
        fi
        if [ -d "/etc/docker" ]; then
            rm /etc/docker -rf
        fi
        for item in {containerd,containerd-shim,containerd-shim-runc-v2,ctr,docker,dockerd,docker-init,docker-proxy,runc}; do
            rm -rf /usr/bin/$item
            rm -rf /bin/$item
        done
    else
        yum erase docker-ce -y
    fi
}

Install_Docker() {
    setTimer
    logSuccess "Install_Docker"
    if ! checkCmdExists docker; then
        installDockerFromTarball
        if ! startDocker; then
            logWarn "start docker failed, now attempt to install docker from rpm packages."
            installDockerFromRpm
            if ! startDocker; then
                bail 'error, both install docker from tarball and rpm failed. Now exit. '
            fi
        fi
    fi
    docker_version=$(getDockerVersion)
    logSuccess "Docker is installed, version is $docker_version"
    sleep 2s

    loadImages $PROJECT_DIR/docker/images
    logInfo "Run Install_Docker End"
    reportTime "Install_Docker"
}

########### PG Redis Nginx Backend #################
statusContainer() {
    # status: 0 for started, 1 for not started, 2 for down
    serviceName=$1
    local name_status=$(docker ps -a --format "{{.Names}} | {{.Status}}" | grep -e "\b${serviceName}\b")
    local existing_status=$(echo $name_status | grep "|" -c)
    local up_status=$(echo $name_status | grep "Up" -c)
    local down_status=$(echo $name_status | grep "Exited" -c)

    if [[ "$up_status" == "1" ]]; then
        echo 0
    fi

    # 如果容器没有被启动，则启动容器
    if [[ "$existing_status" == "0" ]]; then
        echo 1
    fi

    # 如果已启动但是 stop 状态，则用 docker start 启动。
    if [[ "$down_status" == 1 ]]; then
        echo 2
    fi
}

statusPG() {
    local status=$(statusContainer $PG_NAME)
    if [[ "$status" == "0" ]]; then
        logSuccess "Service [PostgreSQL] started"
    elif [[ "$status" == "1" ]]; then
        logWarn "Service [PostgreSQL] is not started."
    else
        logWarn "Service [PostgreSQL] is stoped."
    fi
}

startPG() {
    local status=$(statusContainer $PG_NAME)
    if [[ "$status" == "0" ]]; then
        logInfo "$PG_NAME is alrealdy started, do nothing."
    elif [[ "$status" == "1" ]]; then
        logInfo "$PG_NAME not started, now start it."
        pushd "$SCRIPT_DIR" >/dev/null
        $DOCKER_CMD run -d --name $PG_NAME --restart=always \
            -p $POSTGRES_PORT:5432 -e POSTGRES_USER=$POSTGRES_USER \
            -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD -e ALLOW_IP_RANGE=0.0.0.0/0 \
            -v $DATA_DIR/data/db_data/postgresql:/var/lib/postgresql $PG_IMG
        # check start status
        local status=$(statusContainer $PG_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$PG_NAME has been started!"
        else
            logError "$PG_NAME not started successfully."
        fi
        popd >/dev/null
    else
        logWarn "$PG_NAME is stoped, now start it."
        $DOCKER_CMD start $PG_NAME >/dev/null
        local status=$(statusContainer $PG_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$PG_NAME has been started!"
        else
            logError "$PG_NAME not started successfully."
        fi
    fi
}

stopPG() {
    logInfo "Now stop $PG_NAME"
    $DOCKER_CMD stop $PG_NAME >/dev/null
    local status=$(statusContainer $PG_NAME)
    if [[ "$status" == "0" ]]; then
        logWarn "Stop $PG_NAME failed, still up."
    elif [[ "$status" == "1" ]]; then
        logWarn "$PG_NAME not started."
    else
        logSuccess "Stoped $PG_NAME"
    fi
}

initPG() {
    set +e
    sleep 2s
    logInfo "Now init pg database."
    db_exists=$(docker exec $PG_NAME psql -U $POSTGRES_USER -tc "SELECT datname FROM pg_database" | grep -c "$POSTGRES_DB")
    if [ "$db_exists" == "1" ]; then
        logWarn "database $POSTGRES_DB exists, do you want to 'delete' and recreate a null one? [y/N]?"
        if confirmDefaultNo; then
            docker exec $PG_NAME psql -U $POSTGRES_USER -c "DROP DATABASE $POSTGRES_DB"
            docker exec $PG_NAME psql -U $POSTGRES_USER -c "CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_USER"
        fi
    else
        logInfo "database $POSTGRES_DB does not exists, now create it."
        docker exec $PG_NAME psql -U $POSTGRES_USER -c "CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_USER"
    fi
    set -e
}

statusRedis() {
    local status=$(statusContainer $RDS_NAME)
    if [[ "$status" == "0" ]]; then
        logSuccess "Service [Redis] started."
    elif [[ "$status" == "1" ]]; then
        logWarn "Service [Redis] is not started."
    else
        logWarn "Service [Redis] is stoped."
    fi
}

startRedis() {
    local status=$(statusContainer $RDS_NAME)
    if [[ "$status" == "0" ]]; then
        logInfo "$RDS_NAME is alrealdy started, do nothing."
    elif [[ "$status" == "1" ]]; then
        logInfo "$RDS_NAME not started, now start it."
        pushd "$SCRIPT_DIR" >/dev/null
        $DOCKER_CMD run -d --name $RDS_NAME --restart=always \
            -p $REDIS_PORT:6379 --log-opt max-size=100m --log-opt max-file=2 \
            -v $CONF_DIR/redis/redis-5.0.10.conf:/etc/redis/redis.conf \
            -v $DATA_DIR/data/db_data/redis:/data $REDIS_IMG
        # check start status
        local status=$(statusContainer $RDS_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$RDS_NAME has been started!"
        else
            logError "$RDS_NAME not started successfully."
        fi
        popd >/dev/null
    else
        logWarn "$RDS_NAME is stoped, now start it."
        $DOCKER_CMD start $RDS_NAME >/dev/null
        local status=$(statusContainer $RDS_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$RDS_NAME has been started!"
        else
            logError "$RDS_NAME not started successfully."
        fi
    fi
}

stopRedis() {
    logInfo "Now stop $RDS_NAME"
    $DOCKER_CMD stop $RDS_NAME >/dev/null
    local status=$(statusContainer $RDS_NAME)
    if [[ "$status" == "0" ]]; then
        logWarn "Stop $RDS_NAME failed, still up."
    elif [[ "$status" == "1" ]]; then
        logWarn "$RDS_NAME not started."
    else
        logSuccess "Stoped $RDS_NAME"
    fi
}

statusNginx() {
    local status=$(statusContainer $NGX_NAME)
    if [[ "$status" == "0" ]]; then
        logSuccess "Service [Nginx] started"
    elif [[ "$status" == "1" ]]; then
        logWarn "Service [Nginx] is not started."
    else
        logWarn "Service [Nginx] is stoped."
    fi
}

startNginx() {
    if [ -f "$DATA_DIR/data/fe_data/fbport.json" ]; then
        # 修改文件管理系统的端口
        sed -i "s#\"FBPORT\":.*#\"FBPORT\": $FILEBROWSER_PORT#g" $DATA_DIR/data/fe_data/fbport.json
    fi

    local status=$(statusContainer $NGX_NAME)
    if [[ "$status" == "0" ]]; then
        logInfo "$NGX_NAME is alrealdy started, do nothing."
    elif [[ "$status" == "1" ]]; then
        logInfo "$NGX_NAME not started, now start it."
        pushd "$SCRIPT_DIR" >/dev/null
        $DOCKER_CMD run --name $NGX_NAME --restart=always -d -p $FRONT_PORT:$FRONT_PORT \
            --add-host="host.docker.internal:host-gateway" \
            -v $CONF_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf \
            -v $CONF_DIR/nginx/locations.conf:/etc/nginx/locations.conf \
            -v $CONF_DIR/nginx/api_proxy.conf:/etc/nginx/api_proxy.conf \
            -v $CONF_DIR/nginx/http_locations.conf:/etc/nginx/http_locations.conf \
            -v $CONF_DIR/nginx/https_locations.conf:/etc/nginx/https_locations.conf \
            -v $DATA_DIR/data/fe_data:/fe_data \
            -v $DATA_DIR/data/web_data:/web_data \
            $NGINX_IMG
        # check start status
        local status=$(statusContainer $NGX_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$NGX_NAME has been started!"
        else
            logError "$NGX_NAME not started successfully."
        fi
        popd >/dev/null
    else
        logWarn "$NGX_NAME is stoped, now start it."
        $DOCKER_CMD start $NGX_NAME >/dev/null
        local status=$(statusContainer $NGX_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$NGX_NAME has been started!"
        else
            logError "$NGX_NAME not started successfully."
        fi
    fi
}

stopNginx() {
    logInfo "Now stop $NGX_NAME"
    $DOCKER_CMD stop $NGX_NAME >/dev/null
    local status=$(statusContainer $NGX_NAME)
    if [[ "$status" == "0" ]]; then
        logWarn "Stop $NGX_NAME failed, still up."
    elif [[ "$status" == "1" ]]; then
        logWarn "$NGX_NAME not started."
    else
        logSuccess "Stoped $NGX_NAME"
    fi
}

statusBackend() {
    local status=$(statusContainer $BACKEND_NAME)
    if [[ "$status" == "0" ]]; then
        logSuccess "Service [Backend] started."
    elif [[ "$status" == "1" ]]; then
        logWarn "Service [Backend] is not started."
    else
        logWarn "Service [Backend] is stoped."
    fi
}

startBackend() {
    local status=$(statusContainer $BACKEND_NAME)
    if [[ "$status" == "0" ]]; then
        logInfo "$BACKEND_NAME is alrealdy started, do nothing."
    elif [[ "$status" == "1" ]]; then
        logInfo "$BACKEND_NAME not started, now start it."
        pushd "$SCRIPT_DIR" >/dev/null
        $DOCKER_CMD run --name $BACKEND_NAME --restart=always -d \
            --network host \
            -v /opt:/opt \
            --env-file $SCRIPT_DIR/.env \
            --add-host="host.docker.internal:host-gateway" \
            $BACKEND_IMG
        # check start status
        local status=$(statusContainer $BACKEND_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$BACKEND_NAME has been started!"
        else
            logError "$BACKEND_NAME not started successfully."
        fi
        popd >/dev/null
    else
        logWarn "$BACKEND_NAME is stoped, now start it."
        $DOCKER_CMD start $BACKEND_NAME >/dev/null
        local status=$(statusContainer $BACKEND_NAME)
        if [[ "$status" == "0" ]]; then
            logSuccess "$BACKEND_NAME has been started!"
        else
            logError "$BACKEND_NAME not started successfully."
        fi
    fi
}

stopBackend() {
    logInfo "Now stop $BACKEND_NAME"
    $DOCKER_CMD stop $BACKEND_NAME >/dev/null
    local status=$(statusContainer $BACKEND_NAME)
    if [[ "$status" == "0" ]]; then
        logWarn "Stop $BACKEND_NAME failed, still up."
    elif [[ "$status" == "1" ]]; then
        logWarn "$BACKEND_NAME not started."
    else
        logSuccess "Stoped $BACKEND_NAME"
    fi
}

initBackendDB() {
    sleep 2s
    logInfo "Start to initialize backend database"
    docker exec $BACKEND_NAME python3 manage.py makemigrations
    docker exec $BACKEND_NAME python3 manage.py migrate

    if [[ "$MODE" == "FRESH" ]]; then
        # flush django data
        docker exec $BACKEND_NAME python3 manage.py flush --noinput

        # create superadmin
        logInfo "Creating superadmin. \n"
        docker exec $BACKEND_NAME python3 manage.py inituser --action=create_super_admin --username=$VNCMANAGEMENT_ROOT --password=$VNCMANAGEMENT_PASSWD
        logSuccess "The Superadmin has already been created, please enjoy the app platform!"
    fi
}

########### user-mgt vnc-mgt #################
installBackendDependency() {
    export python_exec=$PROJECT_DIR/web-server/miniconda3/bin/python
    export python_env_path=$PROJECT_DIR/web-server/py310-env/bin

    logInfo "Now install Backend Dependency"

    # install miniconda
    logInfo "Step0301: Installing miniconda ..."
    pushd $PROJECT_DIR/web-server >/dev/null
    if [ -d "$PROJECT_DIR/web-server/miniconda3" ]; then
        rm $PROJECT_DIR/web-server/miniconda3 -rf
    fi

    sh $Miniconda_installer -p $PROJECT_DIR/web-server/miniconda3 -b -f

    # create virtual envs and install dependencies
    logInfo "Creating virtual envs and installing dependencies ...\\n"
    if [ -d "$PROJECT_DIR/web-server/py310-env" ]; then
        rm $PROJECT_DIR/web-server/py310-env -rf
    fi
    $python_exec -m venv --copies py310-env

    # install dependencies
    logInfo "Installing dependencies for user mgt service..."
    $python_env_path/pip install -r user-management-service/requirements.txt --no-index --find-links=./pkgs

    logInfo "Installing dependencies for vnc mgt service..."
    $python_env_path/pip install -r vnc-session-manager/requirements.txt --no-index --find-links=./pkgs

    popd >/dev/null
    logSuccess "web-server dependencies has been installed!\\n"
}

statusProgram() {
    # $1 for grep target, 0 for started, 1 for not started
    local started=$(ps -ef | grep -v grep | grep -e "\b$1\b" -c)
    if [[ "$started" == "0" ]]; then
        echo 1
    else
        echo 0
    fi
}

statusVNCMgt() {
    # 1 for not started, 0 for started
    local started=$(statusProgram $VNC_SESSION_MANAGER_PORT)
    if [[ "$started" == "0" ]]; then
        logSuccess "Service [VNCMgt] started."
    else
        logWarn "Service [VNCMgt] not started."
    fi
}

startVNCMgt() {
    local started=$(statusProgram $VNC_SESSION_MANAGER_PORT)
    if [[ "$started" == "1" ]]; then
        logInfo "Service [VNCMgt] not started, now start it."
        source $PROJECT_DIR/web-server/py310-env/bin/activate
        APP=${PROJECT_DIR}/web-server/vnc-session-manager

        cd $APP
        uvicorn --host 0.0.0.0 --port $VNC_SESSION_MANAGER_PORT --reload main:app >/dev/null 2>&1 &
        cd $SCRIPT_DIR
        # check again status
        local started=$(statusProgram $VNC_SESSION_MANAGER_PORT)

        if [[ "$started" == "1" ]]; then
            logError "Service [VNCMgt] failed."
        else
            logSuccess "Service [VNCMgt] is started successfully."
        fi
    else
        logSuccess "Service [VNCMgt] is already started"
    fi
}

stopVNCMgt() {
    local started=$(statusProgram $VNC_SESSION_MANAGER_PORT)
    if [[ "$started" == "0" ]]; then
        logSuccess "Now kill VNCMgt"
        local vncpid=$(ps -ef | grep -v grep | grep -e "\b$VNC_SESSION_MANAGER_PORT\b" | awk '{print $2}')
        kill $vncpid
        sleep 1s
        # check again status
        local started=$(statusProgram $VNC_SESSION_MANAGER_PORT)
        if [[ "$started" == "1" ]]; then
            logInfo "Service [VNCMgt] stoped."
        else
            logWarn "Service [VNCMgt] not stoped."
        fi
    else
        logWarn "VNCMgt not running..."
    fi
}

statusUserMgt() {
    # 1 for not started, 0 for started
    local started=$(statusProgram $USER_MANAGEMENT_PORT)
    if [[ "$started" == "0" ]]; then
        logSuccess "Service [UserMgt] started."
    else
        logWarn "Service [UserMgt] not started."
    fi
}

startUserMgt() {
    local started=$(statusProgram $USER_MANAGEMENT_PORT)
    if [[ "$started" == "1" ]]; then
        logInfo "Service [UserMgt] not started, now start it."
        source $PROJECT_DIR/web-server/py310-env/bin/activate
        APP=${PROJECT_DIR}/web-server/user-management-service

        cd $APP
        uvicorn --host 0.0.0.0 --port $USER_MANAGEMENT_PORT --reload main:app >/dev/null 2>&1 &
        cd $SCRIPT_DIR
        # check again status
        local started=$(statusProgram $USER_MANAGEMENT_PORT)
        if [[ "$started" == "1" ]]; then
            logError "Service [UserMgt] failed."
        else
            logSuccess "Service [UserMgt] is started successfully."
        fi
    else
        logSuccess "Service [UserMgt] is already started"
    fi
}

stopUserMgt() {
    local started=$(statusProgram $USER_MANAGEMENT_PORT)
    if [[ "$started" == "0" ]]; then
        logSuccess "Now kill UserMgt"
        local userpid=$(ps -ef | grep -v grep | grep -e "\b$USER_MANAGEMENT_PORT\b" | awk '{print $2}')
        kill $userpid
        sleep 1s
        # check again status
        local started=$(statusProgram $USER_MANAGEMENT_PORT)
        if [[ "$started" == "1" ]]; then
            logInfo "Service [UserMgt] stoped."
        else
            logWarn "Service [UserMgt] not stoped."
        fi
    else
        logWarn "UserMgt not running..."
    fi
}

statusNodeUserMgt() {
    local started=$(statusProgram $USER_MANAGE_SCRIPT_PORT)
    if [[ "$started" == "0" ]]; then
        logSuccess "Service [NodeUserMgt] started."
    else
        logWarn "Service [NodeUserMgt] not started."
    fi
}

startNodeUserMgt() {
    local started=$(statusProgram $USER_MANAGE_SCRIPT_PORT)
    if [[ "$started" == "1" ]]; then
        logInfo "Service [NodeUserMgt] not started, now start it."
        pushd "$SCRIPT_DIR" >/dev/null
        python3 user_manage.py $USER_MANAGE_SCRIPT_PORT >/dev/null 2>&1 &
        popd >/dev/null
        sleep 1s
        local started=$(statusProgram $USER_MANAGE_SCRIPT_PORT)
        if [[ "$started" == "1" ]]; then
            logError "Service [NodeUserMgt] failed."
        else
            logSuccess "Service [NodeUserMgt] is started successfully."
        fi
    else
        logSuccess "Service [NodeUserMgt] is already started"
    fi
}

stopNodeUserMgt() {
    local started=$(statusProgram $USER_MANAGE_SCRIPT_PORT)
    if [[ "$started" == "0" ]]; then
        logInfo "Now kill NodeUserMgt"
        local nodepid=$(ps -ef | grep -v grep | grep -e "\b$USER_MANAGE_SCRIPT_PORT\b" | awk '{print $2}')
        kill $nodepid
        sleep 1s
        local started=$(statusProgram $USER_MANAGE_SCRIPT_PORT)
        if [[ "$started" == "1" ]]; then
            logInfo "Service [NodeUserMgt] stoped."
        else
            logWarn "Service [NodeUserMgt] not stoped."
        fi
    else
        logWarn "NodeUserMgt not running..."
    fi
}

########### file browser #################
statusFileBrowser() {
    # 1 for not started, 0 for started
    local started=$(statusProgram filebrowser)
    if [[ "$started" == "0" ]]; then
        logSuccess "Service [FileBrowser] started."
    else
        logWarn "Service [FileBrowser] not started."
    fi
}

startFileBrowser() {
    local started=$(statusProgram filebrowser)
    if [[ "$started" == "1" ]]; then
        logInfo "Service [FileBrowser] not started, now start it."
        if [[ ! -d "$FILE_BROWSER_DATA_DIR" ]]; then
            mkdir -p "$FILE_BROWSER_DATA_DIR"
        fi
        pushd $PROJECT_DIR/web-server/filebrowser >/dev/null
        ./linux-amd64-filebrowser/filebrowser -r $FILE_BROWSER_DATA_DIR -p $FILEBROWSER_PORT -a $FILEBROWSER_HOST >/dev/null 2>&1 &
        popd >/dev/null
        # check again status
        local started=$(statusProgram filebrowser)
        if [[ "$started" == "1" ]]; then
            logError "Service [FileBrowser] failed."
        else
            logSuccess "Service [FileBrowser] is started successfully."
        fi
    else
        logSuccess "Service [FileBrowser] is already started"
    fi
}

stopFileBrowser() {
    local started=$(statusProgram filebrowser)
    if [[ "$started" == "0" ]]; then
        logSuccess "Now kill FileBrowser"
        local fbpid=$(ps -ef | grep -v grep | grep -e "\bfilebrowser\b" | awk '{print $2}')
        kill $fbpid
        sleep 1s
        # check again status
        local started=$(statusProgram filebrowser)
        if [[ "$started" == "1" ]]; then
            logInfo "Service [FileBrowser] stoped."
        else
            logWarn "Service [FileBrowser] not stoped."
        fi
    else
        logWarn "FileBrowser not running..."
    fi
}

########### extra checks #################
extraAction() {
    # check turbovnc log dirs
    if [[ "$MODE" == "FRESH" ]]; then
        if [ -d "/tmp/turbo-vnc" ]; then
            rm /tmp/turbo-vnc -rf
        fi
    fi
    mkdir -p /tmp/turbo-vnc/
    chmod 777 /tmp/turbo-vnc/

    # 添加到 /etc/rc.d/rc.local 中开机自启动
    if [ ! -f /etc/rc.d/rc.local ]; then
        mkdir -p /etc/rc.d/init.d
        touch /etc/rc.d/rc.localsetupStartupScript
        chmod a+x /etc/rc.d/rc.local
    fi
    if [ "$(grep -c 'deploy-platform' /etc/rc.d/rc.local)" == 0 ]; then
        echo "bash $SCRIPT_DIR/deploy-platform.sh s s" >>/etc/rc.d/rc.local
    fi
    # 增加自启动脚本
    if [ ! -f /etc/rc.d/init.d/scns_app ]; then
        cp "$SCRIPT_DIR/scns_app.sh" /etc/rc.d/init.d/scns_app
        chmod 755 /etc/rc.d/init.d/scns_app
        sed -i "s#^PREFIX=.*#PREFIX=$PROJECT_DIR#g" /etc/rc.d/init.d/scns_app
    fi
}

########### command server #################
serverStart() {
    # check docker
    if ! checkCmdExists docker; then
        logWarn "not found 'docker' command, now install docker ..."
        Install_Docker
        logSuccess "Installing docker End"
    else
        logSuccess "docker is already installed"
    fi

    # load images
    loadImages $PROJECT_DIR/docker/images

    startPG
    if [[ "$MODE" == "FRESH" ]]; then
        initPG
    fi

    startRedis

    startNginx

    # check backend dependencies
    if [[ -f "$PROJECT_DIR/web-server/py310-env/bin/python" ]]; then
        logInfo "backend dependencies installed, continue."
    else
        installBackendDependency
    fi
    startBackend
    initBackendDB

    if [[ "$MODE" == "FRESH" ]]; then
        set +e
        killall uvicorn
        set -e
    fi

    # check VNCMgt UserMgt service
    startVNCMgt
    startUserMgt

    # check NodeUserMgt service
    startNodeUserMgt

    # check filebrowser
    startFileBrowser

    # extra actions
    extraAction
}

serverStop() {
    stopPG
    stopRedis
    stopNginx
    stopBackend
    stopVNCMgt
    stopUserMgt
    stopNodeUserMgt
    stopFileBrowser
}

removeContainer() {
    # remove all containers: pg redis nginx
    for item in {$PG_NAME,$RDS_NAME,$NGX_NAME,$BACKEND_NAME}; do
        local started=$(docker ps -a --format "{{.Names}}" | grep -e "\b${item}\b" -c)
        if [[ "$started" == "1" ]]; then
            docker rm -f $item
            logSuccess "container ${item} already stopped"
        else
            logWarn "container ${item} not running"
        fi
    done
    # remove database data
    rm -rf $DATA_DIR/data/db_data
    mkdir -p $DATA_DIR/data/db_data/{postgresql,redis,mysql}
}

serverRestart() {
    serverStop
    serverStart
}

setupStartupScript() {
    local unit=/etc/systemd/system/scns-platform.service
    cat <<EOF >$unit
[Unit]
Description=SCNS Platform Service
After=network.target docker.service
Requires=docker.service

[Service]
Type=forking
RemainAfterExit=yes
WorkingDirectory=$SCRIPT_DIR
ExecStart=/bin/bash $SCRIPT_DIR/deploy-platform.sh server start
ExecStop=/bin/bash $SCRIPT_DIR/deploy-platform.sh server stop
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable scns-platform.service
    systemctl enable docker.service
    systemctl enable containerd.service
    logSuccess "scns-platform service enabled, managed via systemctl."
}

dependenciesInstall() {
    # docker
    Install_Docker
    # python virtualenv
    installBackendDependency
    setupStartupScript
}

dependenciesUninstall() {
    logWarn "This command will remove docker containers and database data, continue ? [y/N]"
    if confirmDefaultNo; then
        # stop service
        serverStop
        sleep 1
        # remove container
        removeContainer
        sleep 1
        # remove docker images
        docker rmi $PG_IMG $NGINX_IMG $REDIS_IMG $BACKEND_IMG
        sleep 1
        # remove docker
        removeDocker
        # remove backend dependencies
        if [ -d "$PROJECT_DIR/web-server/miniconda3" ]; then
            rm $PROJECT_DIR/web-server/miniconda3 -rf
        fi
        if [ -d "$PROJECT_DIR/web-server/py310-env" ]; then
            rm $PROJECT_DIR/web-server/py310-env -rf
        fi
        if [ -d "/tmp/turbo-vnc" ]; then
            rm /tmp/turbo-vnc -rf
        fi
        if [ -d "$Thirdparty_DIR/app_start_scripts" ]; then
            rm $Thirdparty_DIR/app_start_scripts -rf
        fi
    fi
}

dependenciesReinstall() {
    dependenciesUninstall
    dependenciesInstall
}

serverCheck() {
    # 检测各个服务的状态
    statusPG
    statusRedis
    statusNginx
    statusBackend
    statusVNCMgt
    statusUserMgt
    statusNodeUserMgt
    statusFileBrowser
}

help() {
    printf ${GREEN}
    cat <<EOF
Deploy script for SCNS APPS PLATFORM.

Usage:
    $(basename "$0") [commands [subcommand] [options]] | [flags]

Available Commands:
    server | s: manager web servers
        options:
            start   | s  : start server
            stop    | t  : stop server
            restart | r  : restart server
            status  | ss : check server status

        subcommand:
            pg redis nginx backend vncmgt usermgt nodeusermgt filebrowser

            options:
                start   | s  : start server
                stop    | t  : stop server
                restart | r  : restart server
                status  | ss : check server status
    dependencies | deps: manager dependencies
        options:
            install   | i : install dependencies
            uninstall | u : uninstall dependencies
            reinstall | r : reinstall dependencies

Available Flags:
    -h | --help: display this help message

EOF
    printf ${NOCOLOR}
}

main() {
    preCheck

    if [[ "$#" == "0" ]]; then
        MODE="FRESH"
        logWarn "No parameters with this script, MODE=FRESH will clear database, continue ? [y/N]"
        if confirmDefaultNo; then
            serverStart
        fi
    else
        # 解析参数
        while [ "${1:-}" != "" ]; do
            case $1 in
            -h | --help)
                help
                exit 1
                ;;
            server | s)
                shift
                case $1 in
                start | s)
                    serverStart
                    ;;
                stop | t)
                    serverStop
                    ;;
                restart | r)
                    serverRestart
                    ;;
                status | ss)
                    serverCheck
                    ;;
                pg)
                    shift
                    case $1 in
                    start | s)
                        startPG
                        ;;
                    stop | t)
                        stopPG
                        ;;
                    restart | r)
                        stopPG
                        startPG
                        ;;
                    status | ss)
                        statusPG
                        ;;
                    esac
                    ;;
                redis | rds)
                    shift
                    case $1 in
                    start | s)
                        startRedis
                        ;;
                    stop | t)
                        stopRedis
                        ;;
                    restart | r)
                        stopRedis
                        startRedis
                        ;;
                    status | ss)
                        statusRedis
                        ;;
                    esac
                    ;;
                nginx | ngx)
                    shift
                    case $1 in
                    start | s)
                        startNginx
                        ;;
                    stop | t)
                        stopNginx
                        ;;
                    restart | r)
                        stopNginx
                        startNginx
                        ;;
                    status | ss)
                        statusNginx
                        ;;
                    esac
                    ;;
                backend | db)
                    shift
                    case $1 in
                    start | s)
                        startBackend
                        ;;
                    stop | t)
                        stopBackend
                        ;;
                    restart | r)
                        stopBackend
                        startBackend
                        ;;
                    status | ss)
                        statusBackend
                        ;;
                    esac
                    ;;
                vncmgt | vnc)
                    shift
                    case $1 in
                    start | s)
                        startVNCMgt
                        ;;
                    stop | t)
                        stopVNCMgt
                        ;;
                    restart | r)
                        stopVNCMgt
                        startVNCMgt
                        ;;
                    status | ss)
                        statusVNCMgt
                        ;;
                    esac
                    ;;
                usermgt | user)
                    shift
                    case $1 in
                    start | s)
                        startUserMgt
                        ;;
                    stop | t)
                        stopUserMgt
                        ;;
                    restart | r)
                        stopUserMgt
                        startUserMgt
                        ;;
                    status | ss)
                        statusUserMgt
                        ;;
                    esac
                    ;;
                nodeusermgt | nodeuser)
                    shift
                    case $1 in
                    start | s)
                        startNodeUserMgt
                        ;;
                    stop | t)
                        stopNodeUserMgt
                        ;;
                    restart | r)
                        stopNodeUserMgt
                        startNodeUserMgt
                        ;;
                    status | ss)
                        statusNodeUserMgt
                        ;;
                    esac
                    ;;
                filebrowser | fb)
                    shift
                    case $1 in
                    start | s)
                        startFileBrowser
                        ;;
                    stop | t)
                        stopFileBrowser
                        ;;
                    restart | r)
                        stopFileBrowser
                        startFileBrowser
                        ;;
                    status | ss)
                        statusFileBrowser
                        ;;
                    esac
                    ;;
                *)
                    logError "command 'server | s' not support options '$@'"
                    logSuccess "command 'server | s' available options are: \n    start\n    stop\n    restart"
                    exit 1
                    ;;
                esac
                ;;
            dependencies | deps)
                shift
                case $1 in
                install | i)
                    dependenciesInstall
                    ;;
                uninstall | u)
                    dependenciesUninstall
                    ;;
                reinstall | r)
                    dependenciesReinstall
                    ;;
                *)
                    logError "command 'dependencies | deps' not support options '$@'"
                    logSuccess "command 'dependencies | deps' available options are: \n    install\n    uninstall\n    reinstall"
                    exit 1
                    ;;
                esac
                ;;
            *)
                help
                exit 1
                ;;
            esac
            shift
        done
    fi
}

main "$@"