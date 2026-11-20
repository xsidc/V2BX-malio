#!/bin/bash
# ==============================================
# 自定义自动化开关配置区
# ==============================================
AUTO_SET_DNS=true
DNS_PRIMARY="8.8.8.8"
DNS_SECONDARY="1.1.1.1"

AUTO_BBR_FQ=true
AUTO_FORWARD_TUNING=true          # 代理/转发组网优化开关

# 首次安装全部默认Yes，关闭则不执行对应动作
AUTO_GEN_CONFIG=true
AUTO_AUDIT_CONFIG=true
AUTO_SET_API_URL=true

# 请修改为你的机场面板地址与API密钥
PANEL_URL="https://xxx.com"
PANEL_API_KEY="your_api_key_here"
# ==============================================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
cur_dir=$(pwd)

# 设置DNS函数
set_dns(){
    if [ "$AUTO_SET_DNS" != "true" ];then
        echo -e "${green}DNS自动配置开关关闭，跳过${plain}"
        return 0
    fi
    echo -e "${green}【自动设置DNS】主DNS:${DNS_PRIMARY} 备DNS:${DNS_SECONDARY}${plain}"
    [ ! -f /etc/resolv.conf.bak ] && cp -a /etc/resolv.conf /etc/resolv.conf.bak

    if [ -f /etc/systemd/resolved.conf ];then
        sed -i "s/^DNS=.*/DNS=${DNS_PRIMARY} ${DNS_SECONDARY}/" /etc/systemd/resolved.conf
        sed -i "s/^#DNS=.*/DNS=${DNS_PRIMARY} ${DNS_SECONDARY}/" /etc/systemd/resolved.conf
        sed -i "s/^FallbackDNS=.*/FallbackDNS=${DNS_PRIMARY} ${DNS_SECONDARY}/" /etc/systemd/resolved.conf
        sed -i "s/^#FallbackDNS=.*/FallbackDNS=${DNS_PRIMARY} ${DNS_SECONDARY}/" /etc/systemd/resolved.conf
        systemctl restart systemd-resolved 2>/dev/null
    fi

    if [ -d /etc/NetworkManager/conf.d ];then
        cat > /etc/NetworkManager/conf.d/99-static-dns.conf <<EOF
[main]
dns=none
EOF
        systemctl restart NetworkManager 2>/dev/null
    fi

    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
EOF
}

# BBR+FQ + 系统网络自适应优化 + 代理转发组网调优
enable_bbr_fq(){
    if [ "$AUTO_BBR_FQ" != "true" ] && [ "$AUTO_FORWARD_TUNING" != "true" ];then
        echo -e "${green}BBR与转发优化开关全部关闭，跳过网络调优${plain}"
        return 0
    fi
    echo -e "${green}【网络优化】BBR+FQ、系统自适应、代理转发组网调优${plain}"

    KV=$(uname -r | awk -F. '{print $1"."$2}')
    MAJ=${KV%.[0-9]*}
    MIN=${KV#*.}

    # 加载内核模块
    modprobe tcp_bbr 2>/dev/null
    modprobe nf_conntrack 2>/dev/null
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

    cat > /etc/sysctl.d/99-bbr-adaptive.conf <<EOF
# ========= BBR + FQ 拥塞控制 =========
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ========= TCP自适应缓冲 =========
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432

# ========= 连接队列优化 =========
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 8192

# ========= TIME_WAIT端口复用 =========
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

net.ipv4.tcp_syncookies = 1

# ========= 【代理转发组网】IP转发开关 =========
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# 非对称路由宽松rp_filter，中转服务器防丢包
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# 扩大本地出站端口范围，避免高并发端口耗尽
net.ipv4.ip_local_port_range = 1024 65535

# ========= conntrack连接追踪优化（转发/NAT必备） =========
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
EOF

    # 文件句柄全局调高
    cat > /etc/security/limits.d/99-v2bx-nofile.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    sysctl --system 2>/dev/null

    echo -e "${green}BBR状态: $(sysctl -n net.ipv4.tcp_congestion_control)${plain}"
    echo -e "${green}FQ队列: $(sysctl -n net.core.default_qdisc)${plain}"
    echo -e "${green}IPv4转发: $(sysctl -n net.ipv4.ip_forward)${plain}"
}

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1
# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi
arch=$(uname -m)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi
echo "架构: ${arch}"
if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi
# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi
if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi
install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y
        update-ca-trust force-enable
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates
        update-ca-certificates
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y
        apt install wget curl unzip tar cron socat ca-certificates -y
        update-ca-certificates
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y
        apt install wget curl unzip tar cron socat -y
        apt-get install ca-certificates wget -y
        update-ca-certificates
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy
        pacman -S --noconfirm --needed wget curl unzip tar cron socat
        pacman -S --noconfirm --needed ca-certificates wget
    fi
}
# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service V2bX status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status V2bX | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}
install_V2bX() {
    if [[ -e /usr/local/V2bX/ ]]; then
        rm -rf /usr/local/V2bX/
    fi
    mkdir /usr/local/V2bX/ -p
    cd /usr/local/V2bX/
    if  [ $# == 0 ] ;then
        # 使用q42602736的V2BX-malio仓库
        last_version=$(curl -Ls "https://api.github.com/repos/q42602736/V2BX-malio/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 V2bX-malio 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 V2bX 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 V2bX-malio 最新版本：${last_version}，开始安装"
        wget -q -N --no-check-certificate -O /usr/local/V2bX/V2bX-linux.zip https://github.com/q42602736/V2BX-malio/releases/download/${last_version}/V2bX-linux-${arch}.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 V2bX-malio 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="https://github.com/q42602736/V2BX-malio/releases/download/${last_version}/V2bX-linux-${arch}.zip"
        echo -e "开始安装 V2bX-malio $1"
        wget -q -N --no-check-certificate -O /usr/local/V2bX/V2bX-linux.zip ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 V2bX-malio $1 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi
    unzip V2bX-linux.zip
    rm V2bX-linux.zip -f
    chmod +x V2bX
    mkdir /etc/V2bX/ -p
    cp geoip.dat /etc/V2bX/
    cp geosite.dat /etc/V2bX/
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/V2bX -f
        cat <<EOF > /etc/init.d/V2bX
#!/sbin/openrc-run
name="V2bX"
description="V2bX"
command="/usr/local/V2bX/V2bX"
command_args="server"
command_user="root"
pidfile="/run/V2bX.pid"
command_background="yes"
depend() {
        need net
}
EOF
        chmod +x /etc/init.d/V2bX
        rc-update add V2bX default
        echo -e "${green}V2bX ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/V2bX.service -f
        file="https://github.com/wyx2685/V2bX-script/raw/master/V2bX.service"
        wget -q -N --no-check-certificate -O /etc/systemd/system/V2bX.service ${file}
        systemctl daemon-reload
        systemctl stop V2bX
        systemctl enable V2bX
        echo -e "${green}V2bX ${last_version}${plain} 安装完成，已设置开机自启"
    fi
    if [[ ! -f /etc/V2bX/config.json ]]; then
        cp config.json /etc/V2bX/
        echo -e ""
        echo -e "全新安装，请先参看教程：https://v2bx.v-50.me/，配置必要的内容"
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX start
        else
            systemctl start V2bX
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX 重启成功${plain}"
        else
            echo -e "${red}V2bX 可能启动失败，请稍后使用 V2bX log 查看日志信息，若无法启动，则可能更改了配置格式，请前往 wiki 查看：https://github.com/q42602736/V2BX-malio${plain}"
        fi
        first_install=false
    fi
    if [[ ! -f /etc/V2bX/dns.json ]]; then
        cp dns.json /etc/V2bX/
    fi
    if [[ ! -f /etc/V2bX/route.json ]]; then
        cp route.json /etc/V2bX/
    fi
    if [[ ! -f /etc/V2bX/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/V2bX/
    fi
    if [[ ! -f /etc/V2bX/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/V2bX/
    fi
    curl -o /usr/bin/V2bX -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh
    chmod +x /usr/bin/V2bX
    if [ ! -L /usr/bin/v2bx ]; then
        ln -s /usr/bin/V2bX /usr/bin/v2bx
        chmod +x /usr/bin/v2bx
    fi
    cd $cur_dir
    rm -f install.sh
    echo -e ""
    echo "V2bX 管理脚本使用方法 (兼容使用V2bX执行，大小写不敏感): "
    echo "------------------------------------------"
    echo "V2bX              - 显示管理菜单 (功能更多)"
    echo "V2bX start        - 启动 V2bX"
    echo "V2bX stop         - 停止 V2bX"
    echo "V2bX restart      - 重启 V2bX"
    echo "V2bX status       - 查看 V2bX 状态"
    echo "V2bX enable       - 设置 V2bX 开机自启"
    echo "V2bX disable      - 取消 V2bX 开机自启"
    echo "V2bX log          - 查看 V2bX 日志"
    echo "V2bX x25519       - 生成 x25519 密钥"
    echo "V2bX generate     - 生成 V2bX 配置文件"
    echo "V2bX update       - 更新 V2bX"
    echo "V2bX update x.x.x - 更新 V2bX 指定版本"
    echo "V2bX install      - 安装 V2bX"
    echo "V2bX uninstall    - 卸载 V2bX"
    echo "V2bX version      - 查看 V2bX 版本"
    echo "------------------------------------------"
    # 首次安装询问是否生成配置文件 —— 改为静默自动yes
    if [[ $first_install == true ]]; then
        if_generate="y"
        if [[ $if_generate == [Yy] ]]; then
            curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/initconfig.sh
            source initconfig.sh
            rm initconfig.sh -f
            generate_config_file
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
set_dns
enable_bbr_fq
install_V2bX $1
