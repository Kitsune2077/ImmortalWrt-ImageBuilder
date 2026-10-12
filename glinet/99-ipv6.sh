#!/bin/sh
# 99-ipv6.sh: 按 Aethersailor wiki《OpenWrt IPv6 设置方案》配置 IPv6
# (WAN 委托上游前缀 + LAN RA/SLAAC 下发, 关闭 NDP 代理)
# 仅当构建时勾选了 IPv6 (build.sh 生成 /etc/config/ipv6-settings) 才生效;
# 文件不存在或 enable_ipv6=no 时静默退出, 不影响原有行为。
# 执行顺序在 99-custom.sh 之后 (uci-defaults 按文件名排序),
# 因此可以读到 99-custom.sh 已配置好的 wan/wan6/lan。
LOGFILE="/etc/config/uci-defaults-log.txt"
SETTINGS_FILE="/etc/config/ipv6-settings"

[ -f "$SETTINGS_FILE" ] || exit 0
. "$SETTINGS_FILE"
[ "$enable_ipv6" = "yes" ] || exit 0
echo "Applying IPv6: assign=$ipv6_assign ifaceid=$ipv6_ifaceid dhcpv6=$ipv6_dhcpv6 dns=$ipv6_dns" >>"$LOGFILE"

# --- WAN 侧: 仅多网口模式存在 wan 接口时处理 ---
if uci -q get network.wan >/dev/null 2>&1; then
    uci -q set network.wan.delegate='1'
    # 关键: wan.ipv6 必须留空/auto —— ppp.sh 只在留空时设置 AUTOIPV6,
    # 显式 ipv6=1 只做 IPv6CP、不会自动生成动态 wan_6 (dhcpv6+PD)
    uci -q delete network.wan.ipv6
    uci -q delete network.wan.ip6assign
    uci -q delete network.wan.ip6class
    uci -q delete network.wan.ip6hint
    uci -q delete network.wan.ip6weight
    [ -n "$(uci -q get dhcp.wan)" ] && uci -q set dhcp.wan.ignore='1'

    if [ "$(uci -q get network.wan.proto)" = "pppoe" ]; then
        # PPPoE: 删除静态 wan6 (99-custom.sh 会把它置为 proto=none),
        # 拨号成功后 ppp 的 ppp6-up 自动生成动态 wan_6 (dhcpv6 客户端 + PD)
        uci -q delete network.wan6
    else
        # DHCP WAN: proto dhcp 不会自动生成 wan_6,
        # 必须由显式 wan6 (dhcpv6 客户端, 同 wan 端口) 承载 PD
        WANDEV=$(uci -q get network.wan.device || uci -q get network.wan.ifname)
        uci -q set network.wan6=interface
        [ -n "$WANDEV" ] && uci -q set network.wan6.device="$WANDEV"
        uci -q set network.wan6.proto='dhcpv6'
        uci -q set network.wan6.reqaddress='try'
        uci -q set network.wan6.reqprefix='auto'
    fi
fi

# --- LAN 侧: 仅静态 LAN (多网口主路由模式) 时下发 RA/SLAAC ---
if [ "$(uci -q get network.lan.proto)" = "static" ]; then
    uci -q set network.lan.delegate='1'
    # 路由器 LAN 接口自身地址的后缀 (仅作用于路由器自身, 不影响客户端)
    uci -q set network.lan.ip6ifaceid="$ipv6_ifaceid"
    if [ "$ipv6_assign" = "disabled" ]; then
        uci -q delete network.lan.ip6assign
    else
        uci -q set network.lan.ip6assign="$ipv6_assign"
    fi

    uci -q get dhcp.lan >/dev/null 2>&1 || {
        uci -q set dhcp.lan=dhcp
        uci -q set dhcp.lan.interface='lan'
    }
    # RA 服务器 + SLAAC, 关闭 NDP 代理; 默认纯 SLAAC (兼容不支持
    # 有状态 DHCPv6 的安卓), 选 server 时 RA 自动带 M/O 标志
    uci -q set dhcp.lan.ra='server'
    uci -q set dhcp.lan.ra_slaac='1'
    uci -q set dhcp.lan.ndp='disabled'
    uci -q set dhcp.lan.dhcpv6="$ipv6_dhcpv6"
    uci -q delete dhcp.lan.ra_flags
    if [ "$ipv6_dhcpv6" = "server" ]; then
        uci -q add_list dhcp.lan.ra_flags='managed-config'
        uci -q add_list dhcp.lan.ra_flags='other-config'
    else
        uci -q add_list dhcp.lan.ra_flags='none'
    fi
    if [ "$ipv6_dns" = "yes" ]; then
        uci -q set dhcp.lan.dns_service='1'
    else
        # 不通告路由器为 IPv6 DNS: 客户端继续用路由器 IPv4 地址解析,
        # 保持代理类插件的分流链路
        uci -q set dhcp.lan.dns_service='0'
        uci -q delete dhcp.lan.dns
    fi
fi

# --- dnsmasq: 不过滤 IPv6 AAAA 记录 ---
uci -q set dhcp.@dnsmasq[0].filter_aaaa='0'

uci -q commit network
uci -q commit dhcp
echo "IPv6 configuration applied." >>"$LOGFILE"
exit 0
