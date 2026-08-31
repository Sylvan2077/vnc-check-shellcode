#!/bin/bash

export PROJECT_DIR=$(realpath "$(dirname "$BASH_SOURCE[0]")"/../)
export DATA_DIR=$PROJECT_DIR/server-data
export CONF_DIR=$PROJECT_DIR/server-data/config
export NOVNC_DATA_DIR=$PROJECT_DIR/server-data/data/web_data

export DOCKER_PREFIX="caep"
export PG_NAME="${DOCKER_PREFIX}_postgresql"
export RDS_NAME="${DOCKER_PREFIX}_redis"
export NGX_NAME="${DOCKER_PREFIX}_nginx"
export BACKEND_NAME="${DOCKER_PREFIX}_backend"

# backend
export BACKEND_IMG=scns-app-db:0.1.1
export VNCMANAGEMENT_PROTOCAL=http
export VNCMANAGEMENT_HOST=0.0.0.0
export VNCMANAGEMENT_PORT=10086
export VNCMANAGEMENT_ROOT=admin
export VNCMANAGEMENT_PASSWD=adminadmin

# fe
export NGINX_IMG=nginx:1.18.0
export TARGET=$VNCMANAGEMENT_PROTOCAL://$VNCMANAGEMENT_HOST:$VNCMANAGEMENT_PORT
export FRONT_ENV=development
export FRONT_PORT=8086

# redis
export REDIS_IMG=redis:5.0.10
export REDIS_HOST=0.0.0.0
export REDIS_PORT=55555

# pg
export PG_IMG=postgres:10
export POSTGRES_HOST=0.0.0.0
export POSTGRES_PORT=12377
export POSTGRES_DB=externaldb
export POSTGRES_USER=novncserver
export POSTGRES_PASSWORD=novncserver


# filebrowser
export FILE_BROWSER_HOST=http://0.0.0.0:8088
export FILEBROWSER_PROTOCAL=http
export FILEBROWSER_HOST=0.0.0.0
export FILEBROWSER_PORT=8088
export FILE_BROWSER_DATA_DIR=/public_files_dir

# third party
export Thirdparty_DIR=$PROJECT_DIR/thirdparty
export Template_DIR=$Thirdparty_DIR/template
export Installer_DIR=$Thirdparty_DIR/pkgs
export TurboVNC_DIR=$Thirdparty_DIR/TurboVNC
export TurboVNC_installer=$Installer_DIR/TurboVNC-3.0.1-Linux-x86_64.sh
export NoVNC_DIR=$Thirdparty_DIR/noVNC
export NoVNC_installer=$Installer_DIR/noVNC-1.3.0.tar.gz
export OPENBOX_DIR=$Thirdparty_DIR/OpenBox
export OpenBox_installer=$Installer_DIR/OpenBox-3.6.1-Linux-x86_64.sh
export VIRTUALGL_DIR=$Thirdparty_DIR/VirtualGL
export VirtualGL_installer=$Installer_DIR/VirtualGL-2.5.2-Linux-x86_64.sh
export START_APP_SCRIPTS_DIR=$Thirdparty_DIR/app_start_scripts
export Miniconda_installer=$PROJECT_DIR/web-server/pkgs/Miniconda3-py310_23.3.1-0-Linux-x86_64.sh

# vnc session management
export VNC_SESSION_MANAGER_PORT=8000
export VNC_SESSION_MANAGER_URL=http://0.0.0.0:$VNC_SESSION_MANAGER_PORT
export VNC_SERVER_DIR=$Thirdparty_DIR/TurboVNC/bin
export CHECK_INTERVAL=86400

# user management
export USER_MANAGEMENT_PORT=9000
export USER_MANAGEMENT_HOST=http://0.0.0.0:$USER_MANAGEMENT_PORT
export VPN_CONFIG_FILE_PATH=$Thirdparty_DIR/user-passwd

# node user management script
export USER_MANAGE_SCRIPT_PORT=9001

# output .env file
> ./.env
echo "REDIS_HOST=$REDIS_HOST" >> ./.env
echo "REDIS_PORT=$REDIS_PORT" >> ./.env
echo "POSTGRES_HOST=$POSTGRES_HOST" >> ./.env
echo "POSTGRES_PORT=$POSTGRES_PORT" >> ./.env
echo "POSTGRES_DB=$POSTGRES_DB" >> ./.env
echo "POSTGRES_USER=$POSTGRES_USER" >> ./.env
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >> ./.env
echo "START_APP_SCRIPTS_DIR=$START_APP_SCRIPTS_DIR" >> ./.env
echo "VNC_SESSION_MANAGER_URL=$VNC_SESSION_MANAGER_URL" >> ./.env
echo "USER_MANAGEMENT_HOST=$USER_MANAGEMENT_HOST" >> ./.env
echo "NOVNC_DATA_DIR=$NOVNC_DATA_DIR" >> ./.env
echo "OPENBOX_DIR=$OPENBOX_DIR" >> ./.env
echo "VIRTUALGL_DIR=$VIRTUALGL_DIR" >> ./.env