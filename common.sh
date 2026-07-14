GREEN='\033[0;32m'
RED='\033[0;31m'
NOCOLOR='\033[0m'
LIGHT_BLUE='\033[0;34m'
YELLOW='\033[0;33m'

# functions
logSuccess() {
    printf "${GREEN}[SUCCESS] $1${NOCOLOR}\n" 1>&2
}

logInfo() {
    printf "[INFO] $1\n" 1>&2
}

logWarn() {
    printf "${YELLOW}[WARN] $1${NOCOLOR}\n" 1>&2
}

logError() {
    printf "${RED}[ERROR] $1${NOCOLOR}\n" 1>&2
}

bail() {
    logError "$@"
    exit 1
}

reportTime() {
    local behavior=$1
    if (($SECONDS > 3600)); then
        let "hours=SECONDS/3600"
        let "minutes=(SECONDS%3600)/60"
        let "seconds=(SECONDS%3600)%60"
        logSuccess "${behavior} completed in $hours hour(s), $minutes minute(s) and $seconds second(s)"
    elif (($SECONDS > 60)); then
        let "minutes=(SECONDS%3600)/60"
        let "seconds=(SECONDS%3600)%60"
        logSuccess "${behavior} completed in $minutes minute(s) and $seconds second(s)"
    else
        logSuccess "${behavior} completed in $SECONDS seconds"
    fi
}

TIMER_TIME=
setTimer() {
    TIMER_TIME=$SECONDS
}

if [ -z "$READ_TIMEOUT" ]; then
    READ_TIMEOUT="-t 20"
fi

promptTimeout() {
    set +e
    read ${READ_TIMEOUT} PROMPT_RESULT </dev/tty
    set -e
}

confirmDefaultNo() {
    promptTimeout "$@"
    if [ "$PROMPT_RESULT" = "y" ] || [ "$PROMPT_RESULT" = "Y" ]; then
        return 0
    fi
    return 1
}

confirmDefaultNo() {
    promptTimeout "$@"
    if [ "$PROMPT_RESULT" = "y" ] || [ "$PROMPT_RESULT" = "Y" ]; then
        return 0
    fi
    return 1
}

confirmDefaultYes() {
    promptTimeout "$@"
    if [ "$PROMPT_RESULT" = "n" ] || [ "$PROMPT_RESULT" = "N" ]; then
        return 1
    fi
    return 0
}

checkCmdExists() {
    command -v "$@" >/dev/null 2>&1
}

checkForRoot() {
    local user="$(id -un 2>/dev/null || true)"
    if [ "$user" != "root" ]; then
        bail "this installer needs to be run as root."
    fi
    FLAG_ROOTCHECK=true
}

checkFirewalld() {
    if ! systemctl -q is-active firewalld; then
        return
    fi

    logWarn "Firewalld is active, do you want to disable it? [y/N]"
    if confirmDefaultNo; then
        systemctl stop firewalld
        systemctl disable firewalld
        return
    fi

    bail "The system cannot continue with firewalld on"
}

checkSelinuxDisabled() {
    if selinuxEnabled && selinuxEnforced; then
        logError "scns-platform is incompatible with selinux, disable it? [y/N]"
        if confirmDefaultNo; then
            setenforce 0
            sed -i s/^SELINUX=.*$/SELINUX=permissive/ /etc/selinux/config
        else
            bail "disable selinux to continue"
        fi
    fi
}

selinuxEnabled() {
    if checkCmdExists "selinuxenabled"; then
        selinuxenabled
        return
    elif checkCmdExists "sestatus"; then
        ENABLED=$(sestatus | grep 'SELinux status' | awk '{ print $3 }')
        echo "$ENABLED" | grep --quiet --ignore-case enabled
        return
    fi

    return 1
}

selinuxEnforced() {
    if checkCmdExists "getenforce"; then
        ENFORCED=$(getenforce)
        echo $(getenforce) | grep --quiet --ignore-case enforcing
        return
    elif checkCmdExists "sestatus"; then
        ENFORCED=$(sestatus | grep 'SELinux mode' | awk '{ print $3 }')
        echo "$ENFORCED" | grep --quiet --ignore-case enforcing
        return
    fi

    return 1
}
