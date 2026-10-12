#!/bin/sh
# 99-ap-modem.sh: 应用构建时选择的 luci-app-ap-modem 配置
# 插件本体(含中文翻译)由 build.sh 从 files-apmodem overlay 拷入镜像;
# 本脚本读取 /etc/config/ap-modem-settings (build.sh 生成), 未安装时
# 镜像内没有该文件, 静默退出。
LOGFILE="/etc/config/uci-defaults-log.txt"
SETTINGS_FILE="/etc/config/ap-modem-settings"

[ -f "$SETTINGS_FILE" ] || exit 0
. "$SETTINGS_FILE"
[ "$install_ap_modem" = "yes" ] || exit 0

if [ "$ap_modem_enabled" = "yes" ]; then
    # 开启访问 WAN 口光猫: enabled=1 + 在光猫所在子网给路由器加一个虚拟 IP
    # (取光猫 IP 前三段 + .254, 假定光猫侧为 /24; 刷机后可在 LuCI「AP / Modem」页调整)
    uci -q set ap_modem.config.enabled='1'
    MODEM_PREFIX=$(echo "$ap_modem_ip" | sed 's/\.[0-9]*$//')
    if [ -n "$MODEM_PREFIX" ]; then
        uci -q add_list ap_modem.wan.ipaddr="$MODEM_PREFIX.254"
    fi
    uci -q commit ap_modem
    echo "ap_modem enabled, wan virtual ip: ${MODEM_PREFIX}.254" >>"$LOGFILE"
else
    uci -q set ap_modem.config.enabled='0'
    uci -q commit ap_modem
    echo "ap_modem installed but disabled" >>"$LOGFILE"
fi

# 注册开机自启 (init 脚本自身会按 enabled 决定生成/清理 veth 配置)
/etc/init.d/ap_modem enable 2>/dev/null
exit 0
