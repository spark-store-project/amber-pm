#!/bin/bash



# 提取配置信息
VERSION=@VERSION@
UUID=$(cat /etc/machine-id)
# 获取系统信息
LSB_OUTPUT=$(lsb_release --all 2>/dev/null)
DISTRIBUTOR_ID=$(echo "$LSB_OUTPUT" | grep -i 'Distributor ID:' | awk -F: '{print $2}' | xargs)
RELEASE=$(echo "$LSB_OUTPUT" | grep -i 'Release:' | awk -F: '{print $2}' | xargs)
ARCHITECTURE=$(uname -m)


# 构建当前时间
CURRENT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 构建 JSON 数据
JSON_DATA=$(cat <<EOF
{
  "Distributor ID": "$DISTRIBUTOR_ID",
  "Release": "$RELEASE",
  "Architecture": "$ARCHITECTURE",
  "Store_Version": "$SIMPLIFIED_VERSION",
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