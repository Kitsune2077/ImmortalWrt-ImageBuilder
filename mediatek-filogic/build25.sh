#!/bin/bash
source shell/apk-custom-packages.sh
#echo "✅ 你选择了第三方软件包：$CUSTOM_PACKAGES"
# luci-app-run 必装: 无条件同步并收集第三方包仓库 (未选中的包不会被安装)
if true; then
  if [ -n "$CUSTOM_PACKAGES" ]; then
    # ============= 同步第三方插件库==============
    # 同步第三方软件仓库run/apk
    echo "🔄 正在同步第三方软件仓库 Cloning apk file repo..."
    git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

    # 拷贝 run/arm64 下所有 run 文件和apk文件 到 extra-packages 目录
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-apk-repo/run/arm64-a53/* /home/build/immortalwrt/extra-packages/

    echo "✅ Run files copied to extra-packages:"
  fi
  # 解压并拷贝apk到packages目录 (extra-packages/ap-modem/ 由 volume 挂载注入
  # 仓库内自编译的 ap-modem apk, 见 workflow 挂载)
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
else
  echo "⚪️ 未选择 任何第三方软件包"
fi



# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"

echo "Include Docker: $INCLUDE_DOCKER"
echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入pppoe变量————>pppoe-settings文件
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

# luci-app-ap-modem (访问 WAN 口光猫/AP): apk 包在仓库 apk-repo/ap-modem/
# (由 build-ap-modem-package workflow 用同版本 SDK 编译, 工具链与 IB 兼容),
# 经 extra-packages/ 进本地源正规安装

# 创建ap-modem配置文件 yml传入变量————>ap-modem-settings文件 (99-ap-modem.sh 首启读取)
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

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."


# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 必装: luci-app-run (wukongdaily 网页上传/运行 .run/.sh/.ipk/.apk 安装器)
PACKAGES="$PACKAGES luci-app-run"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"


# 第三方软件包 合并
# ======== shell/apk-custom-packages.sh =======
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# luci-app-ap-modem: 25.12 走本地 apk 源正规安装 (设备上可被 apk 管理);
# kmod-veth 是 init 脚本创建 veth 对所需
if [ "$ENABLE_AP_MODEM" = "yes" ]; then
    # i18n 包按实际存在与否引用 (build-ap-modem-package 尚在完善其构建)
    APMODEM_PKGS="luci-app-ap-modem"
    if ls /home/build/immortalwrt/extra-packages/ap-modem/luci-i18n-ap-modem-zh-cn-*.apk >/dev/null 2>&1; then
        APMODEM_PKGS="$APMODEM_PKGS luci-i18n-ap-modem-zh-cn"
    fi
    PACKAGES="$PACKAGES $APMODEM_PKGS kmod-veth"
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
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi


# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
