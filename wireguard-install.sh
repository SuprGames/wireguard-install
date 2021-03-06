#!/bin/bash

function addClient() {
	# Load params
	source /etc/wireguard/params
	
	ENDPOINT="$SERVER_PUB_IP:$SERVER_PORT"

	CLIENT_WG_IPV4="10.0.100.2"
	read -rp "Client's WireGuard IPv4 " -e -i "$CLIENT_WG_IPV4" CLIENT_WG_IPV4

	CLIENT_NAME=$(
		head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10
		echo ''
	)

	# Generate key pair for the client
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	CLIENT_PORT=60005
    read -rp "Client's WireGuard listening port: " -e -i "$CLIENT_PORT" CLIENT_PORT

	ALLOWED_IPS="10.0.0.0/16"
	read -rp "VPC CIRD: " -e -i "$ALLOWED_IPS" ALLOWED_IPS

	# Create client file and add the server as a peer
	echo "[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = $CLIENT_WG_IPV4/32
ListenPort = $CLIENT_PORT

[Peer]
PublicKey = $SERVER_PUB_KEY
PresharedKey = $CLIENT_PRE_SHARED_KEY
Endpoint = $ENDPOINT
AllowedIPs = $ALLOWED_IPS" >>"$HOME/$SERVER_WG_NIC-client-$CLIENT_NAME.conf"

	# Add the client as a peer to the server
	echo -e "\n[Peer]
PublicKey = $CLIENT_PUB_KEY
PresharedKey = $CLIENT_PRE_SHARED_KEY
AllowedIPs = $CLIENT_WG_IPV4/32" >>"/etc/wireguard/$SERVER_WG_NIC.conf"

	systemctl restart "wg-quick@$SERVER_WG_NIC"

	echo -e "\nHere is your client config file as a QR Code:"

	qrencode -t ansiutf8 -l L <"$HOME/$SERVER_WG_NIC-client-$CLIENT_NAME.conf"

	echo "It is also available in $HOME/$SERVER_WG_NIC-client-$CLIENT_NAME.conf"
}

if [ "$EUID" -ne 0 ]; then
	echo "You need to run this script as root"
	exit 1
fi

if [ "$(systemd-detect-virt)" == "openvz" ]; then
	echo "OpenVZ is not supported"
	exit
fi

if [ "$(systemd-detect-virt)" == "lxc" ]; then
	echo "LXC is not supported (yet)."
	echo "WireGuard can technically run in an LXC container,"
	echo "but the kernel module has to be installed on the host,"
	echo "the container has to be run with some specific parameters"
	echo "and only the tools need to be installed in the container."
	exit
fi

if [[ $1 == "add-client" ]]; then
	if [[ -e /etc/wireguard/params ]]; then
		addClient
		exit 0
	else
		echo "Please install and configure WireGuard first."
		exit 1
	fi
elif [[ -e /etc/wireguard/params ]]; then
	echo "WireGuard is already installed. Run with 'add-client' to add a client."
	exit 1
fi

# Check OS version
if [[ -e /etc/debian_version ]]; then
	source /etc/os-release
	OS=$ID # debian or ubuntu
elif [[ -e /etc/fedora-release ]]; then
	source /etc/os-release
	OS=$ID
elif [[ -e /etc/centos-release ]]; then
	OS=centos
elif [[ -e /etc/arch-release ]]; then
	OS=arch
else
	echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS or Arch Linux system"
	exit 1
fi

# The public IP detection didn't work when running in container
SERVER_PUB_IPV4=""
read -rp "Public external IPv4 address: " -e -i "$SERVER_PUB_IPV4" SERVER_PUB_IP

# Detect public interface and pre-fill for the user
SERVER_PUB_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
read -rp "Public interface, WireGuard Virtual Network Device: " -e -i "$SERVER_PUB_NIC" SERVER_PUB_NIC

SERVER_WG_NIC="wg0"
read -rp "WireGuard interface name: " -e -i "$SERVER_WG_NIC" SERVER_WG_NIC

SERVER_WG_IPV4="10.0.100.1"
read -rp "Server's WireGuard IPv4, check it is a valid VPC IP: " -e -i "$SERVER_WG_IPV4" SERVER_WG_IPV4

# To generate random number within private ports range change 60005 for: $(shuf -i49152-65535 -n1)
SERVER_PORT=60005
read -rp "Server's WireGuard port: " -e -i "$SERVER_PORT" SERVER_PORT

# Install WireGuard tools and module
if [[ $OS == 'ubuntu' ]]; then
	apt-get install -y software-properties-common
	add-apt-repository -y ppa:wireguard/wireguard
	apt-get update
	apt-get install -y "linux-headers-$(uname -r)"
	apt-get install -y wireguard iptables resolvconf qrencode
elif [[ $OS == 'debian' ]]; then
	echo "deb http://deb.debian.org/debian/ unstable main" >/etc/apt/sources.list.d/unstable.list
	printf 'Package: *\nPin: release a=unstable\nPin-Priority: 90\n' >/etc/apt/preferences.d/limit-unstable
	apt update
	apt-get install -y "linux-headers-$(uname -r)"
	apt-get install -y wireguard iptables resolvconf qrencode
	apt-get install -y bc # mitigate https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=956869
elif [[ $OS == 'fedora' ]]; then
	if [[ $VERSION_ID -lt 32 ]]; then
		dnf install -y dnf-plugins-core
		dnf copr enable -y jdoss/wireguard
		dnf install -y wireguard-dkms
	fi
	dnf install -y wireguard-tools iptables qrencode
elif [[ $OS == 'centos' ]]; then
	curl -Lo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
	yum -y install epel-release
	yum -y install wireguard-dkms wireguard-tools iptables qrencode
elif [[ $OS == 'arch' ]]; then
	pacman -S --noconfirm linux-headers
	pacman -S --noconfirm wireguard-tools iptables qrencode
fi

# Make sure the directory exists (this does not seem the be the case on fedora)
mkdir /etc/wireguard >/dev/null 2>&1

chmod 600 -R /etc/wireguard/

SERVER_PRIV_KEY=$(wg genkey)
SERVER_PUB_KEY=$(echo "$SERVER_PRIV_KEY" | wg pubkey)

# Save WireGuard settings
echo "SERVER_PUB_IP=$SERVER_PUB_IP
SERVER_PUB_NIC=$SERVER_PUB_NIC
SERVER_WG_NIC=$SERVER_WG_NIC
SERVER_WG_IPV4=$SERVER_WG_IPV4
SERVER_PORT=$SERVER_PORT
SERVER_PRIV_KEY=$SERVER_PRIV_KEY
SERVER_PUB_KEY=$SERVER_PUB_KEY" >/etc/wireguard/params

source /etc/wireguard/params

# Add server interface
echo "[Interface]
Address = $SERVER_WG_IPV4/24
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIV_KEY" >"/etc/wireguard/$SERVER_WG_NIC.conf"

if [ -x "$(command -v firewall-cmd)" ]; then
	FIREWALLD_IPV4_ADDRESS=$(echo "$SERVER_WG_IPV4" | cut -d"." -f1-3)".0"
	echo "PostUp = firewall-cmd --add-port $SERVER_PORT/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=$FIREWALLD_IPV4_ADDRESS/24 masquerade'
PostDown = firewall-cmd --remove-port $SERVER_PORT/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=$FIREWALLD_IPV4_ADDRESS/24 masquerade'" >>"/etc/wireguard/$SERVER_WG_NIC.conf"
else
	echo "PostUp = iptables -A FORWARD -i $SERVER_WG_NIC -j ACCEPT; iptables -t nat -A POSTROUTING -o $SERVER_PUB_NIC -j MASQUERADE
PostDown = iptables -D FORWARD -i $SERVER_WG_NIC -j ACCEPT; iptables -t nat -D POSTROUTING -o $SERVER_PUB_NIC -j MASQUERADE" >>"/etc/wireguard/$SERVER_WG_NIC.conf"
fi

# Enable routing on the server
echo "net.ipv4.ip_forward = 1" >/etc/sysctl.d/wg.conf

sysctl --system

systemctl start "wg-quick@$SERVER_WG_NIC"
systemctl enable "wg-quick@$SERVER_WG_NIC"

# Check if WireGuard is running
systemctl is-active --quiet "wg-quick@$SERVER_WG_NIC"
WG_RUNNING=$?

# Warn user about kernel version mismatch with headers
if [[ $OS =~ (fedora|centos) ]] && [[ $WG_RUNNING -ne 0 ]]; then
	echo -e "\nWARNING: WireGuard does not seem to be running."
	echo "Due to kernel mismatch issues on $OS, WireGuard might work if your system is out of date."
	echo "You can check if WireGuard is running with: systemctl status wg-quick@$SERVER_WG_NIC"
	echo 'If you get something like "Cannot find device wg0", please run:'
	if [[ $OS == 'fedora' ]]; then
		echo "dnf update -y && reboot"
	elif [[ $OS == 'centos' ]]; then
		echo "yum update -y && reboot"
	fi
fi

addClient
