#!/bin/bash

# Function to check if the script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo "Error: This script must be run as root. Please use 'sudo'."
       exit 1
    fi
}

# --- Color Definitions ---
NC=$'\e[0m' # No Color
YELLOW=$'\e[1;33m'
GREEN=$'\e[1;32m'
WHITE=$'\e[1;37m'
RED=$'\e[0;31m'
HEADER_COLOR=$GREEN
OPTION_COLOR=$WHITE

# --- Server Tools Functions ---

update_server() {
    echo -e "${HEADER_COLOR}--- Starting Server Update and Essential Dependency Installation ---${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get upgrade -y
        apt-get install -y debian-archive-keyring
        apt-get install -y curl wget socat git nano ipset
    elif command -v yum &> /dev/null; then
        yum update -y
        yum install -y curl wget socat git nano ipset
    else
        echo -e "${RED}Error: Unsupported package manager.${NC}"; return 1
    fi
    echo -e "${GREEN}Server updated and essential packages are installed.${NC}"
}

server_backup() {
    echo -e "${HEADER_COLOR}--- Professional Server Backup ---${NC}"
    local backup_path="/root/backups"
    local sources_to_backup="/root /home /etc"
    local days_to_keep=7
    local log_file="$backup_path/backup_log_$(date +%Y-%m-%d).log"
    local exclude_list_file="/tmp/backup_exclude.txt"
    mkdir -p "$backup_path"
    cat << EOF > "$exclude_list_file"
/tmp
/var/tmp
/var/cache
/root/backups
/home/*/.cache
/home/*/.local/share/Trash
*.vmdk
*.iso
EOF
    local available_space=$(df -h / | awk 'NR==2 {print $4}')
    echo -e "${YELLOW}A professional backup is about to be created.${NC}"
    echo -e "${WHITE}Sources:${NC} $sources_to_backup + All MySQL Databases (if found)"
    echo -e "${WHITE}Destination:${NC} $backup_path"
    echo -e "${WHITE}Log File:${NC} $log_file"
    echo -e "${WHITE}Available Space:${NC} $available_space"
    echo -e "${WHITE}Backups older than $days_to_keep days will be deleted.${NC}"
    read -p "Press Enter to continue, or Ctrl+C to cancel."
    exec > >(tee -a "$log_file") 2>&1
    echo "--- Backup started at $(date) ---"
    if command -v mysqldump &> /dev/null; then
        echo "MySQL detected. Backing up all databases..."
        mkdir -p "$backup_path/mysql"
        mysqldump --all-databases > "$backup_path/mysql/all-databases-$(date +%Y-%m-%d).sql"
        if [ $? -eq 0 ]; then echo "Database backup successful."; else echo "Database backup failed."; fi
    else
        echo "MySQL not found, skipping database backup."
    fi
    local backup_file="backup-$(date +%Y-%m-%d-%H-%M-%S).tar.gz"
    local full_backup_path="$backup_path/$backup_file"
    echo "Starting file backup... This may take a while."
    tar -czpf "$full_backup_path" --exclude-from="$exclude_list_file" -C / $sources_to_backup 2>/dev/null
    if [ -f "$full_backup_path" ]; then
        echo "Verifying backup integrity..."
        if gzip -t "$full_backup_path"; then
            echo -e "${GREEN}Backup created and verified successfully!${NC}"
            local final_size=$(du -sh "$full_backup_path" | awk '{print $1}')
            echo -e "${WHITE}Final Backup Size: $final_size${NC}"; echo -e "${WHITE}File saved at: $full_backup_path${NC}"
        else
            echo -e "${RED}Backup created, but integrity check failed.${NC}"
        fi
    else
        echo -e "${RED}Backup failed. File was not created.${NC}"
    fi
    echo "Cleaning up old backups..."; find "$backup_path" -type f -name "backup-*.tar.gz" -mtime +$days_to_keep -delete
    echo "Cleanup complete."; echo "--- Backup finished at $(date) ---"
    exec > /dev/tty 2>&1
}

restore_backup_menu() {
    echo -e "${HEADER_COLOR}--- Restore Server from Backup ---${NC}"
    local backup_path="/root/backups"

    if [ ! -d "$backup_path" ]; then
        echo -e "${RED}Backup directory not found: $backup_path${NC}"; return
    fi

    mapfile -t backups < <(find "$backup_path" -maxdepth 1 -type f -name "backup-*.tar.gz" | sort -r)

    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${YELLOW}No backup files found in $backup_path${NC}"; return
    fi

    echo "Available backups (newest first):"
    local i=1
    for backup in "${backups[@]}"; do
        echo "   ${YELLOW}${i})${OPTION_COLOR} $(basename "$backup")"
        i=$((i+1))
    done
    echo "   ${YELLOW}0)${OPTION_COLOR} Cancel"

    read -p "Enter the number of the backup to restore: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt ${#backups[@]} ]; then
        echo -e "${RED}Invalid selection.${NC}"; return
    fi

    if [ "$choice" -eq 0 ]; then echo "Restore cancelled."; return; fi

    local selected_backup="${backups[$((choice-1))]}"
    
    echo -e "\n${RED}!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!"
    echo -e "You are about to restore the server from:"
    echo -e "${WHITE}$(basename "$selected_backup")${NC}"
    echo -e "${RED}This action is IRREVERSIBLE and will OVERWRITE all current data in:"
    echo -e "${YELLOW}/root, /home, /etc${NC}"
    echo -e "${RED}and restore all MySQL databases from the backup date."
    echo -e "It is strongly recommended to do this on a fresh server."
    echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    read -p "To confirm, please type 'YES' in all caps: " confirmation

    if [ "$confirmation" != "YES" ]; then
        echo -e "${GREEN}Restore cancelled. No changes were made.${NC}"; return
    fi

    echo -e "\n${YELLOW}Starting restore process... Do not interrupt!${NC}"
    
    echo "Restoring files from $(basename "$selected_backup")..."
    if tar -xpf "$selected_backup" -C /; then
        echo -e "${GREEN}File restore completed successfully.${NC}"
    else
        echo -e "${RED}File restore failed. Aborting.${NC}"; return 1
    fi

    local backup_date=$(basename "$selected_backup" | cut -d'-' -f2-4)
    local sql_backup_file="$backup_path/mysql/all-databases-${backup_date}.sql"

    if [ -f "$sql_backup_file" ]; then
        if command -v mysql &> /dev/null; then
            echo "Restoring MySQL databases from $(basename "$sql_backup_file")..."
            if mysql < "$sql_backup_file"; then
                echo -e "${GREEN}Database restore completed successfully.${NC}"
            else
                echo -e "${RED}Database restore failed. Please check MySQL logs.${NC}"
            fi
        else
            echo -e "${YELLOW}MySQL is not installed. Skipping database restore.${NC}"
        fi
    else
        echo -e "${YELLOW}No matching SQL backup file found for this date. Skipping database restore.${NC}"
    fi

    echo -e "\n${GREEN}Restore process finished!${NC}"
    echo -e "${YELLOW}A system reboot is highly recommended to apply all changes correctly.${NC}"
    read -p "Do you want to reboot now? (y/N): " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo "Rebooting now..."
        reboot
    else
        echo "Please reboot the server manually as soon as possible."
    fi
}

backup_restore_menu() {
    while true; do
        clear
        echo -e "${HEADER_COLOR}--- Backup & Restore Menu ---${NC}"
        echo -e "   ${YELLOW}1)${OPTION_COLOR} Create a new backup (Professional)"
        echo -e "   ${YELLOW}2)${OPTION_COLOR} Restore from a backup file"
        echo -e "   ${YELLOW}0)${OPTION_COLOR} Back to Main Menu"
        read -p "Enter your choice: " backup_choice
        case $backup_choice in
            1) server_backup ;;
            2) restore_backup_menu ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 2; continue ;;
        esac
        
        echo -e "${YELLOW}Press Enter to return...${NC}"
        read
        break
    done
}

repository_menu() {
    source /etc/os-release
    while true; do
        clear
        echo -e "${HEADER_COLOR}--- Change Repository Menu (Detected OS: $PRETTY_NAME) ---${NC}"
        echo -e "${YELLOW}1)${OPTION_COLOR} Change to German Repository"
        echo -e "${YELLOW}2)${OPTION_COLOR} Optimize for Iran Servers (ArvanCloud)"
        echo -e "${YELLOW}3)${OPTION_COLOR} Manual Edit"
        echo -e "${YELLOW}0)${OPTION_COLOR} Back to Main Menu"
        read -p "Enter your choice: " repo_choice
        case $repo_choice in
            1)
                local repo_url=""
                if [[ "$ID" == "ubuntu" ]]; then
                    repo_url="http://de.archive.ubuntu.com"
                    sed -i.bak 's|http://[^ ]*.ubuntu.com|'"$repo_url"'|g' /etc/apt/sources.list
                elif [[ "$ID" == "debian" ]]; then
                    repo_url="http://deb.debian.org"
                    sed -i.bak 's|http://[^ ]*debian.org|'"$repo_url"'|g' /etc/apt/sources.list
                else
                    echo -e "${RED}Unsupported OS: $ID.${NC}"; sleep 3; continue
                fi
                echo "Changing main repository to $repo_url..."; apt-get update
                echo -e "${GREEN}Repository changed. 'apt update' is complete.${NC}"
                ;;
            2)
                echo "Backing up /etc/apt/sources.list to /etc/apt/sources.list.bak-$(date +%F)..."
                cp /etc/apt/sources.list /etc/apt/sources.list.bak-$(date +%F)
                if [[ "$ID" == "ubuntu" ]]; then
                    echo "Changing repository to ArvanCloud mirror for Ubuntu ($VERSION_CODENAME)..."
                    cat << EOF > /etc/apt/sources.list
deb http://mirror.arvancloud.ir/ubuntu ${VERSION_CODENAME} universe
EOF
                elif [[ "$ID" == "debian" ]]; then
                    echo "Changing repository to ArvanCloud mirror for Debian ($VERSION_CODENAME)..."
                    cat << EOF > /etc/apt/sources.list
deb http://mirror.arvancloud.ir/debian ${VERSION_CODENAME} main
deb http://mirror.arvancloud.ir/debian-security ${VERSION_CODENAME}-security main
EOF
                else
                    echo -e "${RED}Unsupported OS for ArvanCloud mirror: $ID.${NC}"; sleep 3; continue
                fi
                apt-get update
                echo -e "${GREEN}Repository changed to ArvanCloud. 'apt update' is complete.${NC}"
                ;;
            3) nano /etc/apt/sources.list; echo -e "${GREEN}Manual edit complete.${NC}" ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 2; continue ;;
        esac
        echo -e "${YELLOW}Press Enter to return...${NC}"; read; break
    done
}

nameserver_menu() {
    set_dns() {
        echo "Applying DNS servers: $1, $2..."
        chattr -i /etc/resolv.conf 2>/dev/null
        cat << EOF > /etc/resolv.conf
nameserver $1
nameserver $2
EOF
        chattr +i /etc/resolv.conf
        echo -e "${GREEN}DNS servers have been set and protected!${NC}"
    }
    while true; do
        clear
        echo -e "${HEADER_COLOR}--- Change Nameserver Menu ---${NC}"
        echo -e "${YELLOW}1)${OPTION_COLOR} Apply Cloudflare DNS (Recommended)"
        echo -e "${YELLOW}2)${OPTION_COLOR} Apply Google DNS"
        echo -e "${YELLOW}3)${OPTION_COLOR} Apply DNS for Bypassing Sanctions (Shecan)"
        echo -e "${YELLOW}4)${OPTION_COLOR} Manual Edit"
        echo -e "${YELLOW}0)${OPTION_COLOR} Back to Main Menu"
        read -p "Enter your choice: " dns_choice
        case $dns_choice in
            1) set_dns "1.1.1.1" "1.0.0.1" ;;
            2) set_dns "8.8.8.8" "8.8.4.4" ;;
            3) set_dns "178.22.122.100" "185.51.200.2" ;;
            4) nano /etc/resolv.conf; echo -e "${GREEN}Manual edit complete.${NC}" ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 2; continue ;;
        esac
        echo -e "${YELLOW}Press Enter to return...${NC}"; read; break
    done
}

firewall_menu() {
    if ! command -v ufw &> /dev/null; then
        echo "UFW not found. Installing now...";
        apt-get update
        apt-get install -y ufw
    fi
    
    while true; do
        clear
        ufw status | head -n 1
        echo -e "${HEADER_COLOR}--- Firewall (UFW) Management ---${NC}"
        if ufw status | grep -q "inactive"; then
            echo -e "   ${YELLOW}Warning: Firewall is inactive. Rules are not being enforced.${NC}"
        fi
        echo ""
        echo -e "   ${YELLOW}1)${OPTION_COLOR} Allow SSH (Port 22)"
        echo -e "   ${YELLOW}2)${OPTION_COLOR} Allow HTTP/HTTPS (Ports 80, 443)"
        echo -e "   ${YELLOW}3)${OPTION_COLOR} Allow Custom Port"
        echo -e "   ${YELLOW}4)${OPTION_COLOR} ${GREEN}Enable Firewall${NC}"
        echo -e "   ${YELLOW}5)${OPTION_COLOR} ${RED}Disable Firewall${NC}"
        echo -e "   ${YELLOW}6)${OPTION_COLOR} Check Status"
        echo -e "   ${YELLOW}0)${OPTION_COLOR} Back to Main Menu"
        read -p "Enter your choice: " ufw_choice

        case $ufw_choice in
            1) ufw allow ssh; echo "SSH port rule added."; sleep 2 ;;
            2) ufw allow http; ufw allow https; echo "HTTP/HTTPS ports rule added."; sleep 2 ;;
            3) read -p "Enter port number to allow: " custom_port; ufw allow "$custom_port"; echo "Port $custom_port rule added."; sleep 2 ;;
            4) ufw enable ;;
            5) ufw disable; echo "Firewall disabled."; sleep 2 ;;
            6) ufw status verbose; read -p "Press Enter to continue..." ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 2 ;;
        esac
    done
}

show_panel_warning() {
    echo -e "${YELLOW}--------------------------------------------------------------------"
    echo -e "${YELLOW}IMPORTANT NOTE BEFORE INSTALLATION${NC}"
    echo -e "${YELLOW}--------------------------------------------------------------------"
    echo -e "${WHITE}If you encounter network or package download failures, it is often"
    echo -e "due to repository issues."
    echo -e ""
    echo -e "${GREEN}Solution: Return to the main menu, select option '3) Change"
    echo -e "Repository', and switch to the 'German Repository'.${NC}"
    echo -e "${YELLOW}--------------------------------------------------------------------${NC}"
    echo ""
}

run_panel_installer() {
    local panel_name="$1"
    local install_command="$2"
    local video_link="$3"

    show_panel_warning
    echo -e "${HEADER_COLOR}--- Installing ${panel_name} ---${NC}"
    echo -e "${WHITE}Video Tutorial:${NC} ${GREEN}${video_link}${NC}"
    read -p "Press Enter to continue with the installation..."
    
    eval "$install_command"
}

install_3xui() {
    run_panel_installer "3x-ui" \
        "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)" \
        "https://youtu.be/55howDWZtRg?si=ANpyAMFsuGtkhbXe"
}

install_sui() {
    run_panel_installer "s-ui" \
        "bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)" \
        "https://youtu.be/-wOtg_JFHrM?si=5DrJUaHwaC3q3eWy"
}

install_libertea() {
    run_panel_installer "Libertea" \
        "curl -s https://raw.githubusercontent.com/VZiChoushaDui/Libertea/master/bootstrap.sh -o /tmp/bootstrap.sh && bash /tmp/bootstrap.sh install" \
        "https://youtu.be/InEpCcFnwvI?si=eeAt2uqkx45YxGbW"
}

install_blitz() {
    run_panel_installer "Blitz" \
        "bash <(curl https://raw.githubusercontent.com/ReturnFI/Blitz/main/install.sh)" \
        "https://youtu.be/u2bv15o7t6M?si=UMp8tY8QBYrPRJa3"
}

install_hui() {
    run_panel_installer "h-ui" \
        "bash <(curl -fsSL https://raw.githubusercontent.com/jonssonyan/h-ui/main/install.sh)" \
        "https://youtu.be/xYoUNpbp2Fk?si=vV5H5fPb8Y1JFHQD"
}

install_marzban() {
    show_panel_warning
    echo -e "${HEADER_COLOR}--- Video Tutorial ---${NC}"
    echo -e "${WHITE}Video Tutorial:${NC} ${GREEN}https://youtu.be/2yWopaxdkM0?si=WBAd1NTp31KF7s4H${NC}"
    read -p "Press Enter to continue with the installation..."
    
    echo -e "${HEADER_COLOR}--- Installing Marzban Panel ---${NC}"
    echo -e "${WHITE}The Marzban installer will now run. It will handle its own dependencies (like Docker).${NC}"
    read -p "Press Enter to begin..."
    bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
    
    echo -e "${GREEN}Marzban installation script finished. Continuing with setup...${NC}"
    
    if [ ! -f /opt/marzban/docker-compose.yml ]; then
        echo -e "${RED}Error: Marzban docker-compose file not found. Installation may have failed.${NC}"; return 1
    fi

    echo -e "${HEADER_COLOR}--- Create Sudo Admin User ---${NC}"
    echo -e "${WHITE}Please follow the prompts to create your first admin user.${NC}"
    docker-compose -f /opt/marzban/docker-compose.yml run --rm marzban cli admin create --sudo
    
    echo -e "${HEADER_COLOR}--- Starting Marzban Services ---${NC}"
    docker-compose -f /opt/marzban/docker-compose.yml up -d
    
    echo -e "${HEADER_COLOR}--- IMPORTANT: SSL CERTIFICATE ---${NC}"
    echo -e "${YELLOW}Follow the official documentation to issue a certificate:${NC}"
    echo -e "${WHITE}https://gozargah.github.io/marzban/en/examples/issue-ssl-certificate${NC}"
}

run_speedtest() {
    if ! command -v speedtest &> /dev/null; then
        echo "Speedtest CLI not found. Installing now...";
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
        sudo apt-get install -y speedtest
    fi
    echo "Running the test..."; speedtest
}

reverse_proxy() {
    echo -e "${HEADER_COLOR}--- Reverse Tunnel Information ---${NC}"
    echo -e "${WHITE}Video Tutorial:${NC} ${GREEN}https://www.youtube.com/watch?v=EXAMPLE_REVERSE_TUNNEL${NC}"
    read -p "Press Enter to continue..."
    echo -e "${YELLOW}This feature is under development. Please watch the video for manual instructions.${NC}"
}

block_iran_traffic_menu() {
    if ! command -v ipset &> /dev/null; then
        echo "ipset not found. Installing..."; apt-get update; apt-get install -y ipset;
    fi
    if ! dpkg -l | grep -q iptables-persistent; then
        echo "iptables-persistent not found. Installing...";
        apt-get install -y iptables-persistent
    fi

    while true; do
        clear
        echo -e "${HEADER_COLOR}--- Block Forwarded Traffic to Iran ---${NC}"
        echo -e "${YELLOW}1)${OPTION_COLOR} Block traffic to Iran (and make it persistent)"
        echo -e "${YELLOW}2)${OPTION_COLOR} Unblock traffic to Iran (and remove persistence)"
        echo -e "${YELLOW}0)${OPTION_COLOR} Back to Main Menu"
        read -p "Enter your choice: " block_choice
        case $block_choice in
            1)
                echo "Step 1: Downloading Iran IP list..."
                curl -4sL -o /tmp/iran_ips.txt https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr
                if [ $? -ne 0 ] || [ ! -s /tmp/iran_ips.txt ]; then echo -e "${RED}Failed to download IP list.${NC}"; break; fi
                
                echo "Step 2: Preparing the ipset 'iran_dst'..."
                ipset create iran_dst hash:net -exist; ipset flush iran_dst
                
                echo "Step 3: Adding IPs to the ipset..."
                while read -r ip; do ipset add iran_dst "$ip"; done < /tmp/iran_ips.txt
                
                echo "Step 4: Applying firewall rule to FORWARD chain..."
                if ! iptables -C FORWARD -m set --match-set iran_dst dst -j DROP &> /dev/null; then
                    iptables -A FORWARD -m set --match-set iran_dst dst -j DROP
                fi

                echo "Step 5: Saving rules to make them persistent across reboots..."
                ipset save iran_dst > /etc/ipset.conf
                cat << EOF > /etc/systemd/system/ipset-restore.service
[Unit]
Description=Restore ipset rules
Before=netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -f /etc/ipset.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
                systemctl enable ipset-restore.service >/dev/null 2>&1
                iptables-save > /etc/iptables/rules.v4

                echo -e "${GREEN}Forwarded traffic to Iran has been blocked and rules are now persistent.${NC}"
                rm /tmp/iran_ips.txt; break
                ;;
            2)
                echo "Unblocking forwarded traffic to Iran...";
                if iptables -C FORWARD -m set --match-set iran_dst dst -j DROP &> /dev/null; then
                    iptables -D FORWARD -m set --match-set iran_dst dst -j DROP
                fi
                ipset destroy iran_dst 2>/dev/null

                echo "Removing persistence..."
                rm -f /etc/ipset.conf
                systemctl disable ipset-restore.service >/dev/null 2>&1
                rm -f /etc/systemd/system/ipset-restore.service
                iptables-save > /etc/iptables/rules.v4

                echo -e "${GREEN}Forwarded traffic to Iran has been unblocked and persistence is removed.${NC}"; break
                ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 2 ;;
        esac
    done
    echo -e "${YELLOW}Press Enter to return...${NC}"; read
}

setup_fake_site() {
    clear
    echo -e "${HEADER_COLOR}--- Setup Fake Website (Nginx + SSL) ---${NC}"
    echo -e "${YELLOW}--------------------------------------------------------------------${NC}"
    echo -e "${WHITE}This tool will install Nginx and configure a fake website with a"
    echo -e "valid SSL certificate. Please follow the steps carefully."
    echo -e ""
    echo -e "${HEADER_COLOR}PRE-INSTALLATION STEPS:${NC}"
    echo -e "  1. You must have a ${WHITE}domain name${NC}."
    echo -e "  2. In your DNS provider (e.g., Cloudflare), create an ${WHITE}A record${NC} pointing"
    echo -e "     your domain to this server's IP: ${GREEN}$(curl -4s ifconfig.me)${NC}"
    echo -e "  3. ${RED}CRITICAL FOR INSTALLATION:${NC} The Cloudflare proxy must be"
    echo -e "     ${WHITE}OFF${NC} (grey cloud) for the certificate to be issued correctly."
    echo -e "     ${YELLOW}(You will be instructed to turn it ON after installation).${NC}"
    echo -e "${YELLOW}--------------------------------------------------------------------${NC}"
    
    read -p "Have you completed all the pre-installation steps above? (y/N): " confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Action cancelled. Please complete the requirements first.${NC}"
        return
    fi

    read -p "Please enter your domain name: " domain_name
    if [ -z "$domain_name" ]; then
        echo -e "${RED}Domain name cannot be empty. Aborting.${NC}"
        return
    fi

    echo -e "${YELLOW}Step 1: Installing dependencies (Nginx & Certbot)...${NC}"
    apt-get update
    apt-get install -y nginx certbot python3-certbot-nginx git
    if ! command -v nginx &> /dev/null || ! command -v certbot &> /dev/null; then
        echo -e "${RED}Failed to install dependencies. Aborting.${NC}"
        return
    fi
    systemctl start nginx
    systemctl enable nginx

    echo -e "${YELLOW}Step 2: Downloading templates and selecting one randomly...${NC}"
    local site_path="/var/www/html"
    rm -rf "${site_path:?}"/*
    git clone https://github.com/learning-zone/website-templates.git /tmp/templates
    
    mapfile -t templates < <(find /tmp/templates -mindepth 1 -maxdepth 1 -type d)
    if [ ${#templates[@]} -eq 0 ]; then
        echo -e "${RED}No templates found in the repository. Aborting.${NC}"
        rm -rf /tmp/templates
        return
    fi

    random_index=$(( RANDOM % ${#templates[@]} ))
    selected_template="${templates[$random_index]}"
    echo -e "${WHITE}Selected template: $(basename "$selected_template")${NC}"
    cp -r "$selected_template"/* "$site_path"
    rm -rf /tmp/templates
    chown -R www-data:www-data "$site_path"

    echo -e "${YELLOW}Step 3: Obtaining SSL certificate for $domain_name...${NC}"
    certbot --nginx -d "$domain_name" --redirect --agree-tos --non-interactive -m "info@${domain_name}"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}--------------------------------------------------${NC}"
        echo -e "${GREEN}SUCCESS! The fake website is installed.${NC}"
        echo ""
        echo -e "${HEADER_COLOR}FINAL STEPS (VERY IMPORTANT):${NC}"
        echo -e "  1. Go back to your Cloudflare dashboard."
        echo -e "  2. Turn the proxy ${YELLOW}ON${NC} (orange cloud) for your domain."
        echo -e "  3. Go to the ${WHITE}SSL/TLS${NC} tab."
        echo -e "  4. Set the encryption mode to ${GREEN}Full (Strict)${NC}."
        echo ""
        echo -e "${WHITE}Your site is now live and secure at: https://$domain_name${NC}"
        echo -e "${GREEN}--------------------------------------------------${NC}"
    else
        echo -e "${RED}--------------------------------------------------${NC}"
        echo -e "${RED}Error: Failed to obtain an SSL certificate.${NC}"
        echo -e "${YELLOW}Please check the following:${NC}"
        echo -e "  - Your domain is correctly pointed to this server's IP."
        echo -e "  - The Cloudflare proxy is OFF (grey cloud)."
        echo -e "  - Port 80 is not blocked by any other firewall."
        echo -e "${RED}--------------------------------------------------${NC}"
    fi
}

show_menu() {
    clear
    echo -e "${WHITE}Created by YouTube Channel: ${GREEN}@iAghapour${NC}"
    echo -e "${OPTION_COLOR}Tutorials for all these scripts are available on the channel${NC}"
    echo -e "${WHITE}https://www.youtube.com/@iAghapour${NC}"
    echo -e "${RED}ver 1.2${NC}"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    echo -e "${WHITE}                      Main Menu${NC}"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
    echo -e "${HEADER_COLOR}--- Server Tools ---${NC}"
    echo -e "   ${YELLOW}1)${OPTION_COLOR} Update server and install dependencies"
    echo -e "   ${YELLOW}2)${OPTION_COLOR} Backup & Restore Management"
    echo -e "   ${YELLOW}3)${OPTION_COLOR} Change Repository"
    echo -e "   ${YELLOW}4)${OPTION_COLOR} Change Nameserver"
    echo -e "   ${YELLOW}5)${OPTION_COLOR} Firewall (UFW) Management"
    echo ""
    echo -e "${HEADER_COLOR}--- Panels ---${NC}"
    echo -e "   ${YELLOW}6)${OPTION_COLOR} Install 3x-ui ${GREEN}(Xray Core)${NC}"
    echo -e "   ${YELLOW}7)${OPTION_COLOR} Install Marzban ${GREEN}(Xray Core)${NC}"
    echo -e "   ${YELLOW}8)${OPTION_COLOR} Install Libertea ${GREEN}(Xray Core)${NC}"
    echo -e "   ${YELLOW}9)${OPTION_COLOR} Install s-ui ${GREEN}(Sing-Box Core)${NC}"
    echo -e "  ${YELLOW}10)${OPTION_COLOR} Install Blitz ${GREEN}(Hysteria & Sing-Box Core)${NC}"
    echo -e "  ${YELLOW}11)${OPTION_COLOR} Install h-ui ${GREEN}(Hysteria Core)${NC}"
    echo ""
    echo -e "${HEADER_COLOR}--- Side Tools ---${NC}"
    echo -e "  ${YELLOW}12)${OPTION_COLOR} Setup Fake Website (for Camouflage)"
    echo -e "  ${YELLOW}13)${OPTION_COLOR} Block Forwarded Traffic to Iran"
    echo -e "  ${YELLOW}14)${OPTION_COLOR} SpeedTest"
    echo -e "  ${YELLOW}15)${OPTION_COLOR} Reverse Tunnel ${RED}(SOON)${NC}"
    echo ""
    echo -e "   ${YELLOW}0)${OPTION_COLOR} QUIT"
    echo -e "${YELLOW}--------------------------------------------------${NC}"
}

main() {
    check_root
    while true; do
        show_menu
        read -p "Enter your choice [0-15]: " choice
        case $choice in
            1) update_server ;;
            2) backup_restore_menu ;;
            3) repository_menu ;;
            4) nameserver_menu ;;
            5) firewall_menu ;;
            6) install_3xui ;;
            7) install_marzban ;;
            8) install_libertea ;;
            9) install_sui ;;
            10) install_blitz ;;
            11) install_hui ;;
            12) setup_fake_site ;;
            13) block_iran_traffic_menu ;;
            14) run_speedtest ;;
            15) reverse_proxy ;;
            0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) echo -e "${RED}Error: Invalid option.${NC}" ;;
        esac
        
        if [[ "$choice" -ne 2 && "$choice" -ne 3 && "$choice" -ne 4 && "$choice" -ne 5 && "$choice" -ne 13 ]]; then
            echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
            read
        fi
    done
}

main
