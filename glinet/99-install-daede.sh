#!/bin/sh
# 99-install-daede.sh: 构建时勾选"首启自动安装 openwrt-daede"后, 在首次启动
# 阶段后台等待联网并执行 kenzok8/openwrt-daede 的官方一键安装脚本
# (README 的安装命令)。安装脚本会自行识别 opkg/apk 并从其 feed 下载
# 匹配版本 (含 sha256 校验), 无需在此重复实现。
# 日志: /root/daede-install.log ; 未启用时静默退出, 不影响原有行为。
SETTINGS_FILE="/etc/config/daede-settings"
LOGFILE="/root/daede-install.log"

[ -f "$SETTINGS_FILE" ] || exit 0
. "$SETTINGS_FILE"
[ "$install_daede" = "yes" ] || exit 0

(
    echo "=== daede install started at $(date) ===" > "$LOGFILE"
    # 首启脚本运行在 S10 阶段, WAN 尚未就绪: 等待网络(最长约 10 分钟)
    i=0
    while [ $i -lt 120 ]; do
        wget -q -T 8 -O /dev/null "https://raw.githubusercontent.com" 2>/dev/null && break
        sleep 5
        i=$((i + 1))
    done
    if [ $i -ge 120 ]; then
        echo "network not ready after 10 minutes, abort" >> "$LOGFILE"
        exit 1
    fi
    echo "network ok, downloading installer..." >> "$LOGFILE"
    # 官方一键安装命令 (优先直连, 失败走 ghfast.top 加速镜像, 同 README 大陆版)
    if ! wget -q -T 30 -O /tmp/daede-install.sh \
        "https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh"; then
        echo "direct download failed, trying ghfast.top mirror" >> "$LOGFILE"
        wget -q -T 30 --no-check-certificate -O /tmp/daede-install.sh \
            "https://ghfast.top/https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh"
    fi
    if [ ! -s /tmp/daede-install.sh ]; then
        echo "install.sh download failed, abort (可稍后在路由器上手动执行 README 安装命令)" >> "$LOGFILE"
        exit 1
    fi
    sh /tmp/daede-install.sh >> "$LOGFILE" 2>&1
    echo "=== installer finished, exit=$? at $(date) ===" >> "$LOGFILE"
    # 安装完成后立即拉起服务 (daed 优先, dae 兜底)
    /etc/init.d/daed restart >/dev/null 2>&1 || /etc/init.d/dae restart >/dev/null 2>&1
) >/dev/null 2>&1 &

exit 0
