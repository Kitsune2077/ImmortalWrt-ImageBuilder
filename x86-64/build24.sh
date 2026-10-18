#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# 创建ipv6配置文件 yml传入ipv6变量————>ipv6-settings文件 (首启由 99-ipv6.sh 读取)
# 未启用时写入 enable_ipv6=no, 99-ipv6.sh 会静默跳过, 不影响原有行为
cat << EOF > /home/build/immortalwrt/files/etc/config/ipv6-settings
enable_ipv6=${ENABLE_IPV6:-no}
ipv6_assign=${IPV6_ASSIGN:-64}
ipv6_ifaceid=${IPV6_IFACEID:-eui64}
ipv6_dhcpv6=${IPV6_DHCPV6:-disabled}
ipv6_dns=${IPV6_DNS:-no}
EOF

# 创建ap-modem配置文件 yml传入变量————>ap-modem-settings文件 (99-ap-modem.sh 首启读取)
# 插件 ipk 包经 extra-packages/ 收进本地 packages/ 源, PACKAGES 处正规安装
cat << EOF > /home/build/immortalwrt/files/etc/config/ap-modem-settings
install_ap_modem=${ENABLE_AP_MODEM:-no}
ap_modem_enabled=${AP_MODEM_ENABLED:-no}
ap_modem_ip=${AP_MODEM_IP:-192.168.1.1}
EOF

# 创建daede安装配置: install_daede=yes 时首启等待联网后在后台执行
# kenzok8/openwrt-daede 官方安装脚本 (99-install-daede.sh 读取), 日志 /root/daede-install.log
cat << EOF > /home/build/immortalwrt/files/etc/config/daede-settings
install_daede=${ENABLE_DAEDE:-no}
EOF

# luci-app-run 必装: 无条件同步并收集第三方包仓库 (未选中的包不会被安装)
echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

# 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
mkdir -p /home/build/immortalwrt/extra-packages
cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/
echo "✅ Run files copied to extra-packages:"
ls -lh /home/build/immortalwrt/extra-packages/*.run

# 解压并拷贝ipk到packages目录 (extra-packages/ 同时由 volume 注入 istore 官方
# 源的 luci-app-ap-modem ipk 包, 见 workflow Prepare 步骤)
sh shell/prepare-packages.sh
ls -lah /home/build/immortalwrt/packages/

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 必装: luci-app-run (wukongdaily 网页上传/运行 .run/.sh/.ipk/.apk 安装器)
PACKAGES="$PACKAGES luci-app-run"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# luci-app-ap-modem: 本地 ipk 源正规安装 (设备上可被 opkg 管理);
# kmod-veth 是 init 脚本创建 veth 对所需
if [ "$ENABLE_AP_MODEM" = "yes" ]; then
    PACKAGES="$PACKAGES luci-app-ap-modem luci-i18n-ap-modem-zh-cn kmod-veth"
fi


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi
# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
