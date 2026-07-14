#!/bin/bash

# 用户创建脚本
# 参数：username uid

if [ $# -ne 2 ]; then
    echo "{\"success\": false, \"message\": \"参数错误，需要username和uid\"}"
    exit 1
fi

username=$1
uid=$2
home_dir="/data/home/${username}"

# 检查UID是否已存在
if id -u "$uid" &>/dev/null; then
    echo "{\"success\": false, \"message\": \"UID ${uid} 已被占用\"}"
    exit 1
fi

# 检查用户是否已存在
if id "$username" &>/dev/null; then
    echo "{\"success\": false, \"message\": \"用户 ${username} 已存在\"}"
    exit 1
fi

# 创建用户
if ! useradd -d "${home_dir}" -m -u "${uid}" "${username}"; then
    echo "{\"success\": false, \"message\": \"创建用户失败\"}"
    exit 1
fi

# 生成随机密码
rand_passwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
echo "${rand_passwd}" | passwd --stdin "${username}" &>/dev/null

# 设置目录权限
chown -R "${username}:${username}" "${home_dir}"

echo "{\"success\": true, \"message\": \"用户 ${username} 创建成功\"}"
exit 0