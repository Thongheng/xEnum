#!/bin/bash

# ==============================
# EnumX - Service Enumeration Tool
# ==============================

# Color codes
C_OKCYAN='\033[96m'
C_OKGREEN='\033[92m'
C_WARNING='\033[93m'
C_FAIL='\033[91m'
C_ENDC='\033[0m'

# Default values
INTERFACE="tun0"
PORT=4444
PAYLOAD="windows/meterpreter/reverse_tcp"
CLIPBOARD=false
USERPASS=""
TARGET=""
USERNAME=""
PASSWORD=""

# Parse credentials once and store them
parse_credentials() {
    if [ -n "$USERPASS" ]; then
        USERNAME=$(echo "$USERPASS" | cut -d: -f1)
        PASSWORD=$(echo "$USERPASS" | cut -d: -f2)
    fi
}

# Clipboard helper (Linux/macOS support)
copy_to_clipboard() {
    if command -v xclip &>/dev/null; then
        echo -n "$1" | xclip -selection clipboard
        echo -e "${C_OKGREEN}Command copied to clipboard.${C_ENDC}"
    elif command -v pbcopy &>/dev/null; then
        echo -n "$1" | pbcopy
        echo -e "${C_OKGREEN}Command copied to clipboard.${C_ENDC}"
    else
        echo -e "${C_WARNING}Clipboard tool not found. Command will be shown instead.${C_ENDC}"
        echo "$1"
    fi
}

# Run or copy command
handle_command() {
    local cmd="$1"
    if $CLIPBOARD; then
        copy_to_clipboard "$cmd"
    else
        echo -e "${C_OKCYAN}Running: $cmd${C_ENDC}"
        eval "$cmd"
    fi
}

# Detect IP based on interface
get_ip() {
    local iface=$1
    # Prefer `ip` when available, fall back to `ifconfig` (macOS)
    if command -v ip &>/dev/null; then
        ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
    elif command -v ifconfig &>/dev/null; then
        ifconfig "$iface" 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | head -n1
    else
        echo ""
    fi
}

# SMB Enumeration
enum_smb() {
    echo -e "${C_OKCYAN}[*] SMB Enumeration on $TARGET${C_ENDC}"

    local auth_params="-N"
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        auth_params="-U '$USERNAME%$PASSWORD'"
    fi

    if $DO_SMB_CLIENT; then
        handle_command "smbclient $auth_params -L //$TARGET/"
    fi

    if $DO_SMB_MAP; then
        local smbmap_user="''"
        local smbmap_pass="''"
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            smbmap_user="'$USERNAME'"
            smbmap_pass="'$PASSWORD'"
        fi
        handle_command "smbmap -H $TARGET -u $smbmap_user -p $smbmap_pass"
    fi

    if $DO_ENUM4LINUX_NG; then
        local enum4linux_params="-A"
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            enum4linux_params="$enum4linux_params -u '$USERNAME' -p '$PASSWORD'"
        fi
        handle_command "enum4linux-ng $enum4linux_params $TARGET"
    fi
}

# FTP Enumeration
enum_ftp() {
    echo -e "${C_OKCYAN}[*] FTP Enumeration on $TARGET${C_ENDC}"
    local ftp_user="anonymous"
    local ftp_pass=""
    
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        ftp_user="$USERNAME"
        ftp_pass="$PASSWORD"
    fi
    
    handle_command "lftp -u $ftp_user,$ftp_pass ftp://$TARGET"
    handle_command "nmap -p 21 --script ftp-anon,ftp-syst,ftp-enum $TARGET"
}

# Nmap Command Function
run_nmap() {
    local target=$1
    local base_command="nmap -sV -sC -Pn -v $target"
    echo -e "${C_OKCYAN}[*] Running Nmap on $target${C_ENDC}"
    handle_command "$base_command"
}

# Rustscan Command Function
run_rustscan() {
    local target=$1
    local base_command="rustscan -a $target --ulimit 5000"
    echo -e "${C_OKCYAN}[*] Running Rustscan on $target${C_ENDC}"
    handle_command "$base_command"
}

# Metasploit Multi-handler
start_msf() {
    local ip=$(get_ip "$INTERFACE")
    if [ -z "$ip" ]; then
        echo -e "${C_FAIL}Could not detect IP on interface $INTERFACE${C_ENDC}"
        exit 1
    fi

    local cmd="msfconsole -q -x \"use exploit/multi/handler; set payload $PAYLOAD; set LHOST $ip; set LPORT $PORT; run\""
    echo -e "${C_OKCYAN}[*] Starting msfconsole handler${C_ENDC}"
    handle_command "$cmd"
}

# RDP Command Function
run_rdp() {
    local target=$1
    local current_dir=$(pwd)
    local cmd="xfreerdp /v:$target"
    
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        cmd="$cmd /u:$USERNAME /p:'$PASSWORD'"
    fi
    
    cmd="$cmd /drive:transfer,\"$current_dir\" /dynamic-resolution +clipboard"
    echo -e "${C_OKCYAN}[*] Running RDP on $target${C_ENDC}"
    handle_command "$cmd"
}

# Usage
usage() {
    echo "Usage: $0 <target> [options]"
    echo "Options:"
    echo "  -nmap           Run Nmap scan"
    echo "  -rust           Run Rustscan"
    echo "  -smb-c          Run smbclient enumeration"
    echo "  -smb-m          Run smbmap enumeration"
    echo "  -enum4          Run enum4linux-ng enumeration"
    echo "  -ftp            Run FTP enumeration"
    echo "  -msf            Start msfconsole multi-handler"
    echo "  -rdp            Run RDP command"
    echo "  -U user:pass    Use credentials for authentication (optional)"
    echo "  -i iface        Network interface for msf handler (default: tun0)"
    echo "  -p port         LPORT for msf handler (default: 4444)"
    echo "  -P payload      Payload for msf handler (default: windows/meterpreter/reverse_tcp)"
    echo "  -c              Copy commands to clipboard instead of executing"
    exit 1
}

# Parse args
if [ $# -lt 1 ]; then
    usage
fi

TARGET=$1
shift

DO_SMB=false
DO_FTP=false
DO_MSF=false
DO_NMAP=false
DO_RUST=false

# SMB Enumeration flags
DO_SMB_CLIENT=false
DO_SMB_MAP=false
DO_ENUM4LINUX_NG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -smb-c) DO_SMB_CLIENT=true ;;
        -smb-m) DO_SMB_MAP=true ;;
        -enum4) DO_ENUM4LINUX_NG=true ;;
        -ftp) DO_FTP=true ;;
        -msf) DO_MSF=true ;;
        -nmap) DO_NMAP=true ;;
        -rust) DO_RUST=true ;;
        -U) 
            USERPASS=$2
            parse_credentials
            shift 
            ;;
        -i) INTERFACE=$2; shift ;;
        -p) PORT=$2; shift ;;
        -P) PAYLOAD=$2; shift ;;
        -c) CLIPBOARD=true ;;
        -rdp) run_rdp "$TARGET" ;;
        *) usage ;;
    esac
    shift
done

# Run selected options
$DO_SMB_CLIENT && enum_smb
$DO_SMB_MAP && enum_smb
$DO_ENUM4LINUX_NG && enum_smb
$DO_FTP && enum_ftp
$DO_MSF && start_msf
$DO_NMAP && run_nmap "$TARGET" "$PORT"
$DO_RUST && run_rustscan "$TARGET" "$PORT"