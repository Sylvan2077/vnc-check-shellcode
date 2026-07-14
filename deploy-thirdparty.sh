#!/bin/bash

# constants
export PROJECT_DIR=$(realpath "$(dirname "$0")"/../)

source $PROJECT_DIR/deploy-scripts/init_env.sh
source $PROJECT_DIR/deploy-scripts/common.sh

echo "$0" | grep '\.sh$' >/dev/null
if (($?)); then
    bail 'Please run using "bash" or "sh", but not "." or "source"'
fi

########### Step01 Install TurboVNC #################
installTurboVNC() {
    logInfo "Step0101: Installing TurboVNC ...\n"
    pushd $Thirdparty_DIR >/dev/null
    if [ -d "$TurboVNC_DIR" ]; then
        rm $TurboVNC_DIR -rf
    fi

    sh $TurboVNC_installer -p $TurboVNC_DIR -b -f
    popd

    logSuccess "Step0101: TurboVNC has been installed! \n"
}

modifyTurboVNCConfig() {
    export TurboVNC_configuration_file=$TurboVNC_DIR/etc/turbovncserver.conf

    logInfo "Step0102: Modify TurboVNC configuration file ..."
    pushd $TurboVNC_DIR/etc >/dev/null
    if [ -f "$TurboVNC_configuration_file" ]; then
        cp $Template_DIR/turbovncserver.conf $TurboVNC_configuration_file
        sed -i.bak -e "s#/opt/scns_apps_platform/thirdparty#$Thirdparty_DIR#g" $TurboVNC_configuration_file
        chmod 644 $TurboVNC_DIR/etc/turbovncserver-security.conf
    fi
    logSuccess "Step0102: Modify TurboVNC configuration file DONE \n"
}

installNoVNC() {
    logInfo "Step0103: Installing NoVNC ..."
    pushd $Thirdparty_DIR >/dev/null
    if [ -d "$NoVNC_DIR" ]; then
        rm -rf $NoVNC_DIR
    fi
    if ! checkCmdExists tar; then
        bail "not found 'tar' command, the installation process aborted."
    else
        tar -xf $NoVNC_installer -C $Thirdparty_DIR
    fi
    popd >/dev/null
    logSuccess "Step0103: Installing NoVNC DONE \n"
}

Step01_Install_TurboVNC() {
    logSuccess "Run Step01_Install_TurboVNC"
    installTurboVNC
    modifyTurboVNCConfig
    installNoVNC
    logSuccess "Run Step01_Install_TurboVNC End\n"
}

########### Step02 install OpenBox #################
installOpenBox() {
    logInfo "Step0201: Installing OpenBox ...\n"
    pushd $Thirdparty_DIR >/dev/null
    if [ -d "$OPENBOX_DIR" ]; then
        rm $OPENBOX_DIR -rf
    fi

    sh $OpenBox_installer -p $OPENBOX_DIR -b -f
    popd >/dev/null

    logSuccess "Step0201: OpenBox has been installed!\n"
}

modifyOpenBoxConfig() {
    export OPENBOX_DIR=$Thirdparty_DIR/OpenBox
    export OpenBox_configuration_file=$OPENBOX_DIR/etc/xdg/openbox/menu.xml

    logInfo "Step0202: Modify OpenBox configuration file ..."
    pushd $OPENBOX_DIR/etc/xdg/openbox >/dev/null
    if [ -f "$OpenBox_configuration_file" ]; then
        mv $OpenBox_configuration_file $OpenBox_configuration_file-bk
        cp $Template_DIR/menu.xml $OpenBox_configuration_file
    fi
    popd >/dev/null

    # fix $OPENBOX_DIR/libexec/openbox-xdg-autostart 1st line logError
    pushd $OPENBOX_DIR/libexec >/dev/null
    cp $OPENBOX_DIR/libexec/openbox-xdg-autostart{,.bak}
    head -n 1 openbox-xdg-menu >openbox-xdg-autostart
    tail -n +2 openbox-xdg-autostart.bak >>openbox-xdg-autostart
    popd

    logSuccess "Step0202: Modify OpenBox configuration file DONE"
}

Step02_Install_OpenBox() {
    logSuccess "Run Step02_Install_OpenBox"
    installOpenBox
    modifyOpenBoxConfig
    logSuccess "Run Step02_Install_OpenBox End\n"
}

########### Step03 install VirtualGL #################
installVirtualGL() {
    export VIRTUALGL_DIR=$Thirdparty_DIR/VirtualGL

    logInfo "\nStep0301: Installing VirtualGL ...\n"
    pushd $Thirdparty_DIR >/dev/null
    if [ -d "$VIRTUALGL_DIR" ]; then
        rm $VIRTUALGL_DIR -rf
    fi

    sh $VirtualGL_installer -p $VIRTUALGL_DIR -b -f

    popd >/dev/null
    logSuccess "Step0301: VirtualGL has been installed!\n"
}

Step03_Install_VirtualGL() {
    logSuccess "Run Step03_Install_VirtualGL"
    installVirtualGL
    logSuccess "Run Step03_Install_VirtualGL End\n"
}

RemoveThirdparty() {
    logInfo "Now remove all thirdparty"

    pushd $Thirdparty_DIR >/dev/null
    for item in {$TurboVNC_DIR,$NoVNC_DIR,$OPENBOX_DIR,$VIRTUALGL_DIR}; do
        if [ -d "$item" ]; then
            logInfo "now rm $item ..."
            rm $item -rf
        else
            logInfo "$item not found, skip ..."
        fi
    done
    popd >/dev/null

    logSuccess "Thirdparty TurboVNC NoVNC OpenBox VirtualGL has been removed !"
}

installThirdparty() {
    Step01_Install_TurboVNC
    Step02_Install_OpenBox
    Step03_Install_VirtualGL
}

uninstallThirdparty() {
    RemoveThirdparty
}

help() {
    printf ${GREEN}
    cat <<EOF
Deploy script for SCNS APPS PLATFORM thirdparty.

Usage:
    $(basename "$0") [install | i] [ uninstall | u] [ reinstall | r]

Examples:
    install | i:
        bash $(basename "$0")
        bash $(basename "$0") i
        bash $(basename "$0") install
    uninstall | u:
        bash $(basename "$0") u
        bash $(basename "$0") uninstall
    reinstall | r:
        bash $(basename "$0") r
        bash $(basename "$0") reinstall
EOF
    printf ${NOCOLOR}
}

checkForRoot
if [[ "$#" == "0" ]]; then
    logInfo "No parameters specified, Now install Third Party softwares."
    installThirdparty
else
    while [ "${1:-}" != "" ]; do
        case $1 in
        -h | --help)
            help
            exit 0
            ;;
        install | i)
            installThirdparty
            break
            ;;
        uninstall | u)
            uninstallThirdparty
            break
            ;;
        reinstall | r)
            uninstallThirdparty
            installThirdparty
            break
            ;;
        *)
            logError "not support options '$@'\n"
            help
            exit 1
            ;;
        esac
    done
fi
