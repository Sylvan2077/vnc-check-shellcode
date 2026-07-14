#!/bin/bash

# 用户删除脚本
# 参数：username

if [ $# -ne 1 ]; then
    echo "{\"success\": false, \"message\": \"参数错误，需要username\"}"
    exit 1
fi

username=$1
home_dir="/data/home/${username}"

# 检查用户是否存在
if ! id "$username" &>/dev/null; then
    echo "{\"success\": false, \"message\": \"用户 ${username} 不存在\"}"
    exit 1
fi

# 检查用户是否有进程在运行
if pgrep -u "${username}" &>/dev/null; then
    echo "{\"success\": false, \"message\": \"该用户下存在桌面未关闭\"}"
    exit 1
fi

# 强制终止用户进程
pkill -u "${username}" &>/dev/null

# 删除用户及其家目录
if ! userdel -r "${username}"; then
    echo "{\"success\": false, \"message\": \"删除用户失败\"}"
    exit 1
fi

# 删除文件管理系统用户文件夹
if [ -d "${home_dir}" ]; then
    rm -rf "${home_dir}"
fi

echo "{\"success\": true, \"message\": \"用户 ${username} 删除成功\"}"
exit 0