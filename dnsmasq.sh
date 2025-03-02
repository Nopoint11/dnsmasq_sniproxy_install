#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] 请使用root用户来执行脚本!" && exit 1

disable_selinux(){
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
}

check_sys(){
    local checkType=$1
    local value=$2

    local release=''
    local systemPackage=''

    if [[ -f /etc/redhat-release ]]; then
        release="centos"
        systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /etc/issue; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /etc/issue; then
        release="ubuntu"
        systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue; then
        release="centos"
        systemPackage="yum"
    elif grep -Eqi "debian|raspbian" /proc/version; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /proc/version; then
        release="ubuntu"
        systemPackage="apt"
    elif grep -Eqi "centos|red hat|redhat" /proc/version; then
        release="centos"
        systemPackage="yum"
    fi

    if [[ "${checkType}" == "sysRelease" ]]; then
        if [ "${value}" == "${release}" ]; then
            return 0
        else
            return 1
        fi
    elif [[ "${checkType}" == "packageManager" ]]; then
        if [ "${value}" == "${systemPackage}" ]; then
            return 0
        else
            return 1
        fi
    fi
}

getversion(){
    if [[ -s /etc/redhat-release ]]; then
        grep -oE  "[0-9.]+" /etc/redhat-release
    else
        grep -oE  "[0-9.]+" /etc/issue
    fi
}

centosversion(){
    if check_sys sysRelease centos; then
        local code=$1
        local version="$(getversion)"
        local main_ver=${version%%.*}
        if [ "$main_ver" == "$code" ]; then
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

get_ip(){
    local IP="185.204.2.88"
    [ -z ${IP} ] && IP="185.204.2.88"
    echo ${IP}
}

download(){
    local filename=${1}
    echo -e "[${green}Info${plain}] ${filename} download configuration now..."
    wget --no-check-certificate -q -t3 -T60 -O ${1} ${2}
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Download ${filename} failed."
        exit 1
    fi
}

error_detect_depends(){
    local command=$1
    local depend=`echo "${command}" | awk '{print $4}'`
    echo -e "[${green}Info${plain}] Starting to install package ${depend}"
    ${command} > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Failed to install ${red}${depend}${plain}"
        exit 1
    fi
}

config_firewall(){
    ports="53"
    if centosversion 6; then
        /etc/init.d/iptables status > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            for port in ${ports}; do
                iptables -L -n | grep -i ${port} > /dev/null 2>&1
                if [ $? -ne 0 ]; then
                    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${port} -j ACCEPT
                    iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${port} -j ACCEPT
                else
                    echo -e "[${green}Info${plain}] port ${green}${port}${plain} already be enabled."
                fi
            done
            /etc/init.d/iptables save
            /etc/init.d/iptables restart
        else
            echo -e "[${yellow}Warning${plain}] iptables looks like not running or not installed, please enable port ${ports} manually if necessary."
        fi
    elif centosversion 7; then
        systemctl status firewalld > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            default_zone=$(firewall-cmd --get-default-zone)
            firewall-cmd --permanent --zone=${default_zone} --add-port=53/tcp
            firewall-cmd --permanent --zone=${default_zone} --add-port=53/udp
            firewall-cmd --reload
        else
            echo -e "[${yellow}Warning${plain}] firewalld looks like not running or not installed, please enable port ${ports} manually if necessary."
        fi
    fi
}

install_cleanup(){
    cd  /tmp/
    rm -rf dnsmasq-2.80 dnsmasq-2.80.tar.gz
    rm -rf sniproxy
    rm -rf proxy-domains1.txt out-proxy-domains1.txt
}

install_dependencies(){
    if check_sys packageManager yum; then
        echo -e "[${green}Info${plain}] Checking the EPEL repository..."
        if [ ! -f /etc/yum.repos.d/epel.repo ]; then
            yum install -y epel-release > /dev/null 2>&1
        fi
        [ ! -f /etc/yum.repos.d/epel.repo ] && echo -e "[${red}Error${plain}] Install EPEL repository failed, please check it." && exit 1
        [ ! "$(command -v yum-config-manager)" ] && yum install -y yum-utils > /dev/null 2>&1
        [ x"$(yum-config-manager epel | grep -w enabled | awk '{print $3}')" != x"True" ] && yum-config-manager --enable epel > /dev/null 2>&1
        echo -e "[${green}Info${plain}] Checking the EPEL repository complete..."

        yum_depends=(
            wget git autoconf automake curl gettext-devel libev-devel pcre-devel perl pkgconfig rpm-build udns-devel
        )
        for depend in ${yum_depends[@]}; do
            error_detect_depends "yum -y install ${depend}"
        done
        error_detect_depends "yum -y groupinstall development"
        if centosversion 6; then
          error_detect_depends "yum -y install centos-release-scl"
          error_detect_depends "yum -y install devtoolset-6-gcc-c++"
        fi
    elif check_sys packageManager apt; then
        apt_depends=(
            wget git autotools-dev cdbs debhelper dh-autoreconf dpkg-dev gettext libev-dev libpcre3-dev libudns-dev pkg-config fakeroot devscripts
        )
        apt-get -y update
        for depend in ${apt_depends[@]}; do
            error_detect_depends "apt-get -y install ${depend}"
        done
        error_detect_depends "apt-get -y install build-essential"
    fi
}

upgrade_dnsmasq(){
    cd /tmp/
    if [ -e dnsmasq-2.80 ]; then
        rm -rf dnsmasq-2.80
    fi
    download dnsmasq-2.80.tar.gz http://www.thekelleys.org.uk/dnsmasq/dnsmasq-2.80.tar.gz
    tar -zxf dnsmasq-2.80.tar.gz
    cd dnsmasq-2.80
    make
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] dnsmasq upgrade failed."
        install_cleanup
        exit 1
    fi
    yes|cp -f /tmp/dnsmasq-2.80/src/dnsmasq /usr/sbin/dnsmasq && chmod 755 /usr/sbin/dnsmasq
}

install_check(){
    if check_sys packageManager yum || check_sys packageManager apt; then
        if centosversion 5; then
            return 1
        fi
        return 0
    else
        return 1
    fi
}

Hello() {
    echo ""
    echo -e "${yellow}Dnsmasq自动安裝脚本${plain}"
    echo -e "${yellow}支持系统:  CentOS 6+, Debian8+, Ubuntu16+${plain}"
    echo ""
}

Help() {
    Hello
    echo "使用方法：bash $0 [-h] [-i] [-u]"
    echo ""
    echo "  -h, --help            显示帮助信息"
    echo "  -i, --install         安装 Dnsmasq"
    echo "  -u, --uninstall       卸载 Dnsmasq"
    echo ""
}

Install() {
    Hello
    echo "检测您的系統..."
    if ! install_check; then
        echo -e "[${red}Error${plain}] Your OS is not supported to run it!"
        echo "Please change to CentOS 6+/Debian 8+/Ubuntu 16+ and try again."
        exit 1
    fi
    if check_sys packageManager yum; then
        error_detect_depends "yum -y install net-tools"
    elif check_sys packageManager apt; then
        error_detect_depends "apt-get -y install net-tools"
    fi
    for aport in 53; do
        netstat -a -n -p | grep LISTEN | grep -P "\d+\.\d+\.\d+\.\d+:${aport}\s+" > /dev/null && echo -e "[${red}Error${plain}] required port ${aport} already in use\n" && exit 1
    done
    disable_selinux
    echo -e "[${green}Info${plain}] Checking the system complete..."
    echo "安装依赖软件..."
    install_dependencies
    echo "安装Dnsmasq..."
    if check_sys packageManager yum; then
        error_detect_depends "yum -y install dnsmasq"
        if centosversion 6; then
            upgrade_dnsmasq
        fi
    elif check_sys packageManager apt; then
        error_detect_depends "apt-get -y install dnsmasq"
    fi
    download /etc/dnsmasq.d/custom_netflix.conf https://raw.githubusercontent.com/Nopoint11/dnsmasq_sniproxy_install/master/dnsmasq.conf
    download /tmp/proxy-domains1.txt https://raw.githubusercontent.com/Nopoint11/dnsmasq_sniproxy_install/master/proxy-domains1.txt
    PublicIP=$(get_ip)
    for domain in $(cat /tmp/proxy-domains1.txt); do
        printf "address=/${domain}/${PublicIP}\n"\
        | tee -a /etc/dnsmasq.d/custom_netflix.conf > /dev/null 2>&1
    done
    [ "$(grep -x -E "(conf-dir=/etc/dnsmasq.d|conf-dir=/etc/dnsmasq.d,.bak|conf-dir=/etc/dnsmasq.d/,\*.conf|conf-dir=/etc/dnsmasq.d,.rpmnew,.rpmsave,.rpmorig)" /etc/dnsmasq.conf)" ] || echo -e "\nconf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf
    if check_sys packageManager yum; then
        if centosversion 6; then
            chkconfig dnsmasq on
            service dnsmasq start
        elif centosversion 7; then
            systemctl enable dnsmasq
            systemctl start dnsmasq
        fi
    elif check_sys packageManager apt; then
        systemctl enable dnsmasq
        systemctl restart dnsmasq
    fi
    echo -e "[${green}Info${plain}] dnsmasq startup complete..."
    if check_sys packageManager yum; then
        echo "检查防火墙端口..."
        config_firewall
        echo -e "[${green}Info${plain}] Firewall port detection complete..."
    fi
    install_cleanup
    echo ""
    echo -e "${yellow}Dnsmasq 已完成安装！${plain}"
    echo ""
    echo -e "${yellow}将您的DNS设置完成了。${plain}"
    echo ""
}

Uninstall() {
    Hello
    echo -e "${yellow}确定卸载Dnsmasq?${plain}"
    echo -e "${yellow}[Enter] 确定 [N] 取消${plain}"
    read selection
    if [[ -z $selection ]]; then
        echo -e "[${green}Info${plain}] Stoping dnsmasq"
        if check_sys packageManager yum; then
            if centosversion 6; then
                chkconfig dnsmasq off > /dev/null 2>&1
                service dnsmasq stop || echo -e "[${red}Error:${plain}] Failed to stop dnsmasq."
            elif centosversion 7; then
                systemctl disable dnsmasq > /dev/null 2>&1
                systemctl stop dnsmasq || echo -e "[${red}Error:${plain}] Failed to stop dnsmasq."
          fi
        elif check_sys packageManager apt; then
            systemctl disable dnsmasq > /dev/null 2>&1
            systemctl stop dnsmasq || echo -e "[${red}Error:${plain}] Failed to stop dnsmasq."
        fi
        echo -e "[${green}Info${plain}] Starting to uninstall dnsmasq"
        if check_sys packageManager yum; then
            yum remove dnsmasq -y > /dev/null 2>&1
            if [ $? -ne 0 ]; then
              echo -e "[${red}Error${plain}] Failed to uninstall ${red}dnsmasq${plain}"
            fi
        elif check_sys packageManager apt; then
            apt-get remove dnsmasq -y > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "[${red}Error${plain}] Failed to uninstall ${red}dnsmasq${plain}"
            fi
        fi
        rm -rf /etc/dnsmasq.d/custom_netflix.conf || echo -e "[${red}Error${plain}] Failed to delete dnsmasq configuration file"
        echo -e "[${green}Info${plain}] dnsmasq uninstall complete..."
    else
        exit 0
    fi
}

if [[ $# > 0 ]];then
    key="$1"
    case $key in
        -i|--install)
        Install
        ;;
        -u|--uninstall)
        Uninstall
        ;;
        -h|--help)
        Help
        ;;
    esac
else
    Help
fi
