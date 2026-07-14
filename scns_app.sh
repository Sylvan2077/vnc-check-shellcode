#! /bin/bash
#
# scns_app       Bring up/down scns app platform
#
# chkconfig: 2345 10 90
# description: Activates/Deactivates all services for scns app platform \
#              start at boot time.
#
### BEGIN INIT INFO
# Provides: $scns_app
# Should-Start: NetworkManager
# Short-Description: Bring up/down scns app platform
# Description: Bring up/down scns app platform
### END INIT INFO

# Source function library.
. /etc/init.d/functions

# may change it
PREFIX=/opt/scns_apps_platform

CWD=$(pwd)
cd $PREFIX/deploy-scripts/
. ./common.sh
. ./init_env.sh

rc=0

# See how we were called.
case "$1" in
start)
    bash deploy-platform.sh s s
    rc=$?
    ;;
stop)
    bash deploy-platform.sh s t
    rc=$?
    ;;
status)
    bash deploy-platform.sh s ss
    rc=$?
    ;;
restart|force-reload)
    bash deploy-platform.sh s r
    rc=$?
    ;;
*)
    echo $"Usage: $0 {start|stop|status|restart|force-reload}"
    exit 2
esac

exit $rc
