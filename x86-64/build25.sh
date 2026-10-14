#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
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
# 插件 apk 包经 extra-packages/ 收进本地 packages/ 源, PACKAGES 处正规安装
cat << EOF > /home/build/immortalwrt/files/etc/config/ap-modem-settings
install_ap_modem=${ENABLE_AP_MODEM:-no}
ap_modem_enabled=${AP_MODEM_ENABLED:-no}
ap_modem_ip=${AP_MODEM_IP:-192.168.1.1}
EOF

if [ -n "$CUSTOM_PACKAGES" ] || [ "$ENABLE_AP_MODEM" = "yes" ]; then
  if [ -n "$CUSTOM_PACKAGES" ]; then
    # ============= 同步第三方插件库==============
    # 同步第三方软件仓库run/apk
    echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
    git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

    # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

    echo "✅ Run files copied to extra-packages:"
  fi
  # 解压并拷贝apk到packages目录 (extra-packages/ 同时由 volume 注入 istore 官方
  # 源的 luci-app-ap-modem apk 包, 见 workflow Prepare 步骤)
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
else
  echo "⚪️ 未选择 任何第三方软件包"
fi

# (以下必须在上方 apk-prepare-packages.sh 收集完成之后执行)
# 导入 istore 官方 apk 公钥: IB 默认 CONFIG_SIGNATURE_CHECK=y, keys/ 只有官方
# 公钥, 未导入 istore 公钥时其签名的本地源包会 UNTRUSTED 安装失败
if [ "$ENABLE_AP_MODEM" = "yes" ] && [ -f /home/build/immortalwrt/extra-packages/istore-apk.pem ]; then
    cp /home/build/immortalwrt/extra-packages/istore-apk.pem /home/build/immortalwrt/keys/
    echo "✅ istore apk key imported"
fi

# 诊断+预建索引: IB 的 package_index 会把 mkndx 的输出全部吞掉 (>/dev/null || true),
# 失败时无从定位。这里用可见的裸命令复刻其行为: 列目录 -> 生成签名密钥 ->
# mkndx 建索引(输出不重定向) -> 校验 ap-modem 已收录。成功后 make image 会
# 直接复用这份索引 (package_reload 检测到索引比包新即跳过重建)。
if [ "$ENABLE_AP_MODEM" = "yes" ]; then
    IB=/home/build/immortalwrt
    echo "=== packages/ 目录内容 ==="
    ls -la "$IB/packages/"
    if [ ! -s "$IB/keys/local-private-key.pem" ]; then
        echo "生成 IB 本地签名密钥 (复刻 _check_keys 逻辑)..."
        mkdir -p "$IB/keys"
        OSSL="$IB/staging_dir/host/bin/openssl"; [ -x "$OSSL" ] || OSSL=openssl
        "$OSSL" ecparam -name prime256v1 -genkey -noout -out "$IB/keys/local-private-key.pem" \
            || { echo "::error::openssl 生成密钥失败"; exit 1; }
        sed -i '1s/^/untrusted comment: Local build key\n/' "$IB/keys/local-private-key.pem"
        "$OSSL" ec -in "$IB/keys/local-private-key.pem" -pubout > "$IB/keys/local-public-key.pem" \
            || { echo "::error::导出公钥失败"; exit 1; }
        sed -i '1s/^/untrusted comment: Local build key\n/' "$IB/keys/local-public-key.pem"
    fi
    echo "=== 运行 mkndx 建索引 (输出可见) ==="
    (cd "$IB/packages" && "$IB/staging_dir/host/bin/apk" mkndx \
        --keys-dir "$IB/keys" --sign "$IB/keys/local-private-key.pem" \
        --allow-untrusted --output packages.adb *.apk) \
        || { echo "::error::mkndx 建索引失败, 见上方输出"; exit 1; }
    if strings "$IB/packages/packages.adb" | grep -q 'luci-app-ap-modem'; then
        echo "✅ ap-modem 已进入本地 apk 索引"
    else
        echo "::error::索引已生成但其中无 ap-modem (packages/ 目录缺少 apk?)"
        exit 1
    fi
fi

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
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# luci-app-ap-modem: 本地 apk 源正规安装 (设备上可被 apk 管理);
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
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
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
