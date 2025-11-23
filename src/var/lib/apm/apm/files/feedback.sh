#!/bin/bash

# 提取配置信息
VERSION_FEEDBACK=@VERSION@-apm
UUID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")


# 获取系统信息 - 不依赖 lsb_release
if [ -f /etc/os-release ]; then
    # 现代 Linux 系统使用 /etc/os-release
    source /etc/os-release
    DISTRIBUTOR_ID="$NAME"
    RELEASE="$VERSION_ID"
elif [ -f /etc/redhat-release ]; then
    # RedHat/CentOS 系统
    DISTRIBUTOR_ID=$(cat /etc/redhat-release | awk '{print $1}')
    RELEASE=$(cat /etc/redhat-release | sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p')
elif [ -f /etc/debian_version ]; then
    # Debian 系统
    DISTRIBUTOR_ID="Debian"
    RELEASE=$(cat /etc/debian_version)
else
    # 其他系统
    DISTRIBUTOR_ID="Unknown"
    RELEASE="Unknown"
fi

ARCHITECTURE=$(uname -m)

# 构建当前时间
CURRENT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 构建 JSON 数据
JSON_DATA=$(cat <<EOF
{
  "Distributor ID": "$DISTRIBUTOR_ID",
  "Release": "$RELEASE",
  "Architecture": "$ARCHITECTURE",
  "Store_Version": "$VERSION_FEEDBACK",
  "UUID": "$UUID",
  "TIME": "$CURRENT_TIME"
}
EOF
)

#echo "Spark Store Feedback"
# 调试输出 JSON 数据
#echo "发送的 JSON 数据："
#echo "$JSON_DATA" | jq .

# 目标 URL
URL="https://status.deepinos.org.cn/upload"

# 使用 curl 发送 POST 请求
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$JSON_DATA" "$URL")

# 检查 HTTP 响应码
if [ "$RESPONSE" -eq 200 ]; then
    #echo "上传成功"
    true
elif [ "$RESPONSE" -eq 400 ]; then
    echo "错误：客户端请求错误，请检查 JSON 数据或接口逻辑"
elif [ "$RESPONSE" -eq 422 ]; then
    echo "错误：请求数据无效，请检查 JSON 字段值"
elif [ "$RESPONSE" -eq 500 ]; then
    echo "错误：服务器内部错误，请联系服务器管理员"
else
    echo "错误：未处理的响应码 $RESPONSE"
fi
