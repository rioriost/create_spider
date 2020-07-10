#!/bin/zsh

# Building Spider server on Azure IaaS with Azure Database for MySQL instances as Spider Data node
# based on the articles as follows
# https://mariadb.com/kb/en/spider-installation/
# https://mariadb.com/kb/en/spider-storage-engine-overview/#sharding-setup

# Azure Ultra Disk
# https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disks-types#ultra-disk

# You should edit at least following 2 lines
readonly AZURE_ACCT="rifujita" 
readonly RES_LOC="japaneast"

# You don't need to edit, but up to you
readonly PRJ_NAME="spdvd"
readonly RES_GRP="${AZURE_ACCT}${PRJ_NAME}rg"

# MySQL parameters
# MY_COUNT means the number of Spider Data nodes.
readonly MY_COUNT=2
readonly MY_ADMIN_USER="root"
readonly MY_ADMIN_PASS=$(openssl rand -base64 16)

# VNET parameters
# You don't need to edit, but up to you
readonly VNET_NAME="${AZURE_ACCT}${PRJ_NAME}vnet"
readonly VNET_SUBNET_NAME="${VNET_NAME}subnet"

# VM parameters
readonly VM_SIZE="Standard_D16s_v3"
readonly VM_NAME="${AZURE_ACCT}${PRJ_NAME}"
readonly VM_OS_DISK_SIZE="256" #256GB
# As I commented in create_spider_nodes(), you need to change IOPS and bandwidth of Ultra Disk on Azure Portal as in July 2020.
readonly VM_DATA_DISK_SIZE="512" #512GB

# Spider parameters
readonly SPIDER_SIZE="Standard_D32s_v3"
readonly SPIDER_USER="spider"
readonly SPIDER_PASS=$(openssl rand -base64 16)
# This database will be sharded
readonly SPIDER_DB_NAME="spider_test"

# The file to pass parameters to remote host
readonly CREDENTIALS="credentials.inc"

# 1. Check Ultra Disk
check_ultra_disk () {
    echo -e "\e[31mChecking if Ultra Disk can be used...\e[m"
    local "st=$(date '+%s')"
    local "vm_zones=$(az vm list-skus -r virtualMachines  -l $RES_LOC --query "[?name=='$VM_SIZE'].locationInfo[0].zoneDetails[0].Name" -o tsv)"
    if [ -z "$vm_zones" ]; then
        echo "The VM size '$VM_SIZE' is not supported for Ultra Disk in the region '$RES_LOC'."
        exit
    fi
    VM_ZONE_ULTRA_DISK_AVAILABLE=${vm_zones:0:1} #choose first one
    show_elapsed_time $st
}

# 2. Create resource group
create_group () {
    # Checking if Resource Group exists
    echo -e "\e[31mCreating Resource Group...\e[m"
    local "st=$(date '+%s')"
    local "res=$(az group show -g $RES_GRP -o tsv --query "properties.provisioningState" 2>&1 | grep -o 'could not be found')"
    if [ "${res}" != "could not be found" ]; then
        echo "Resource Group, ${RES_GRP} has already existed."
        exit
    fi

    # Create Resource Group
    res=$(az group create -l $RES_LOC -g $RES_GRP -o tsv --query "properties.provisioningState")
    if [ "$res" != "Succeeded" ]; then
        az group delete --yes --no-wait -g $RES_GRP
        echo "Failed to create resource group."
        exit
    fi
    show_elapsed_time $st
}

# 3. Create VNET
create_vnet () {
    echo -e "\e[31mCreating VNET...\e[m"
    local "st=$(date '+%s')"
    local "res=$(az network vnet create -g $RES_GRP -n $VNET_NAME --subnet-name $VNET_SUBNET_NAME)"
    res=$(az network vnet subnet update -g $RES_GRP --vnet-name $VNET_NAME -n $VNET_SUBNET_NAME)
    show_elapsed_time $st
}

# 4. Create Spider Nodes
create_spider_nodes () {
    for num in $(seq $(expr $MY_COUNT + 1)); do
        if [ $num = 1 ]; then
            local "vm_size=${SPIDER_SIZE}"
        else
            local "vm_size=${VM_SIZE}"
        fi
        local "last_octet=$(expr $num + 3)"
        echo -e "\e[31mCreating Spider Node $num...\e[m"
        local "st=$(date '+%s')"
        res=$(az vm create --image Canonical:UbuntuServer:18.04-LTS:latest --size ${vm_size} -g ${RES_GRP} -n ${VM_NAME}${num} \
            --admin-username ${AZURE_ACCT} \
            --generate-ssh-keys \
            --ultra-ssd-enabled true \
            --storage-sku os=Premium_LRS 0=UltraSSD_LRS \
            --os-disk-size-gb $VM_OS_DISK_SIZE \
            --data-disk-sizes-gb $VM_DATA_DISK_SIZE \
            --vnet-name $VNET_NAME \
            --subnet $VNET_SUBNET_NAME \
            -z $VM_ZONE_ULTRA_DISK_AVAILABLE \
            --public-ip-address-dns-name ${VM_NAME}${num} \
            --private-ip-address 10.0.0.$last_octet \
            --no-wait)
        
        # There is an issue to change Ultra Disk as in July 2020. (https://github.com/Azure/azure-cli/issues/14013)
        #local "ultradisk=$(az vm show -g ${RES_GRP} -n ${VM_NAME}${num} --query storageProfile.dataDisks[0].name -o tsv)"
        #az disk update -g ${RES_GRP} -n ${ultradisk} --disk-iops-read-write 160000 --disk-mbps-read-write 2000
    
        show_elapsed_time $st
    done
}

# 5. Install MariaDB
install_mariadb () {
    cat << EOF > ${CREDENTIALS}
    export MY_ADMIN_USER="${MY_ADMIN_USER}"
    export MY_ADMIN_PASS="${MY_ADMIN_PASS}"
    export SPIDER_USER="${SPIDER_USER}"
    export SPIDER_PASS="${SPIDER_PASS}"
    export SPIDER_DB_NAME="${SPIDER_DB_NAME}"
EOF
    for num in $(seq $(expr $MY_COUNT + 1)); do
        # On Local
        echo -e "\e[31mConfiguring Spider Nodes $num...\e[m"
        local "st=$(date '+%s')"
        local "vm_name="${VM_NAME}${num}""

        # Wait for VM can be connected via ssh
        fqdn="${vm_name}.${RES_LOC}.cloudapp.azure.com"
        echo -e "Connecting $fqdn..."
        ssh-keygen -R $fqdn 2>&1
        trying=0
        sshres=$(ssh -o "StrictHostKeyChecking no " "${AZURE_ACCT}@$fqdn" 'uname')
        while [ "$sshres" != "Linux" ]; do
            trying=$(expr $trying + 1)
            echo "Challenge: $trying"
            if [ $trying -eq 30 ]; then
                echo "Could not login $fqdn for 5 mins. Please check if 22/tcp is open."
                exit
            fi
            sleep 10
            sshres=$(ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" 'uname')
        done
    
        # Copy credentials
        scp -o "StrictHostKeyChecking no" ${CREDENTIALS} ${AZURE_ACCT}@"$fqdn:~/"
        # SSH Login and execute commands
        ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" <<-'EOF'
    
        # On Remote
        source credentials.inc
        ssh-keygen -t rsa -f ~/.ssh/id_rsa -N "" > /dev/null

        # Find Ultra or Premium SSD
        for dl in a b c; do
            disk_check=$(sudo parted /dev/sd$dl --script 'print' 2>&1 | grep 'Partition Table: unknown')
            if [ "$disk_check" != "" ]; then
                target_disk="/dev/sd$dl"
            fi
        done
        
        # Make a mount point for data disk
        sudo sh -c "
            parted ${target_disk} --script 'mklabel gpt mkpart primary 0% 100%';
            sleep 2;
            mkfs.xfs -f "${target_disk}1" > /dev/null;
            sleep 5;
            echo \"${target_disk}1 /var/lib/mysql xfs defaults,discard 0 0\" >> /etc/fstab;
            mkdir -p /var/lib/mysql;
            mount /var/lib/mysql;
            "
    
        # Install packages
        sudo sh -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get -y update > /dev/null;
            apt-get -y install mariadb-server mariadb-plugin-spider mariadb-client > /dev/null
            "

        # Allow connect from remote host
        sudo sh -c "
            sed -i 's/^\(bind\-address.*= \).*/\10.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
            "

        # Start MariaDB
        sudo sh -c "
            systemctl enable mariadb;
            systemctl restart mariadb;
            "
    
        # Install Spider Engine
        sudo mysql -e "
            SOURCE /usr/share/mysql/install_spider.sql;
            " > /dev/null

        # Do same things as mysql_secure_installation
        sudo mysql -e "
            UPDATE mysql.user SET Password = PASSWORD('${MY_ADMIN_PASS}') WHERE User = 'root';
            DROP USER ''@'localhost';
            DROP USER ''@'$(hostname)';
            DROP DATABASE test;
            FLUSH PRIVILEGES;
            "

        # Create Spider user
        sudo mysql -e "
            CREATE USER '${SPIDER_USER}';
            GRANT ALL ON *.* TO '${SPIDER_USER}' IDENTIFIED BY '${SPIDER_PASS}';
            FLUSH PRIVILEGES;
            "

EOF
        show_elapsed_time $st
    done
}

# 6. Enable ssh login to Spider Data Nodes from Spider Server
enable_ssh_login () {
    echo -e "\e[31mEnabling SSH Login...\e[m"
    local "st=$(date '+%s')"
    local "fqdn="${VM_NAME}1.${RES_LOC}.cloudapp.azure.com""
    local "ssh_key=$(ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" 'cat ~/.ssh/id_rsa.pub')"
    for num in $(seq 2 $(expr $MY_COUNT + 1)); do
        local "res=$(az vm extension set -g ${RES_GRP} --vm-name ${VM_NAME}$num --publisher Microsoft.OSTCExtensions --name VMAccessForLinux --protected-settings '{"username": "${AZURE_ACCT}", "ssh_key": "$ssh_key"}')"
        res=$(az vm extension set -g ${RES_GRP} --vm-name ${VM_NAME}$num --publisher Microsoft.OSTCExtensions --name VMAccessForLinux --protected-settings '{"reset_ssh": true}')
    done
    show_elapsed_time $st
}

# 7. Configure Firewall
configure_fw () {
    echo -e "\e[31mConfiguring Firewall...\e[m"
    local "st=$(date '+%s')"
    # Open 3306/tcp of Spider Data nodes
    for num in $(seq 2 $(expr $MY_COUNT + 1)); do
        local "res=$(az vm open-port --port 3306 -g ${RES_GRP} -n ${VM_NAME}$num)"
        local "nicid=$(az vm show -g ${RES_GRP} -n ${VM_NAME}$num --query 'networkProfile.networkInterfaces[0].id' -o tsv)"
        local "ipid=$(az network nic show -g ${RES_GRP} --ids $nicid --query 'ipConfigurations[0].publicIpAddress.id' -o tsv)"
        res=$(az network nic update --ids $nicid --remove 'ipConfigurations[0].publicIpAddress')
        res=$(az network public-ip delete -g ${RES_GRP} --ids $ipid)
    done
    show_elapsed_time $st
}

# 8. Show and write all settings
show_settings () {
    local "part_comment_ar=()"
    local "mysql_com_ar=()"
    local "NODE_NAMES=()"
    for num in $(seq $MY_COUNT); do
        last_octet=$(expr 4 + $num)
        node_ipaddress="10.0.0.$last_octet"
        NODE_NAMES+=($node_ipaddress)
        part_comment_ar+=("PARTITION pt$num COMMENT = 'srv \\\"backend$num\\\"'")
        mysql_com_ar+=(",    mysql -u ${SPIDER_USER} -p${SPIDER_PASS} -h $node_ipaddress")
    done
    part_comment=$(echo $part_comment_ar | sed 's/ PARTITION/, PARTITION/g')
    mysql_com=$(echo $mysql_com_ar | tr "," "\n  ")
    
    echo -e "\e[31mWriting all settings to 'settings.txt'...\e[m\n"
    cat << EOF | tee settings_${AZURE_ACCT}${PRJ_NAME}.txt
Azure Region   : ${RES_LOC}
Resource Group : ${RES_GRP}

Spider Server  : ${VM_NAME}1.${RES_LOC}.cloudapp.azure.com

Spider Data Nodes :
    ${NODE_NAMES}
    MySQL Admin User : ${MY_ADMIN_USER}, Password : ${MY_ADMIN_PASS}
    Spider User      : ${SPIDER_USER}, Password : ${SPIDER_PASS}

How to connect to Spider Data node from Spider Server${mysql_com}

How to create a table to be sharded
    ssh ${VM_NAME}1.${RES_LOC}.cloudapp.azure.com
    tbl_name="sbtest"
    for num in $(seq -s " " $MY_COUNT); do
        last_octet=\$(expr 4 + \$num)
        node_ipaddress="10.0.0.\$last_octet"
        mysql -u ${SPIDER_USER} -p${SPIDER_PASS} -h \$node_ipaddress -e "
            CREATE DATABASE IF NOT EXISTS $SPIDER_DB_NAME;
            CREATE TABLE $SPIDER_DB_NAME.\$tbl_name (
                id int(10) unsigned NOT NULL AUTO_INCREMENT,
                k int(10) unsigned NOT NULL DEFAULT '0',
                c char(120) NOT NULL DEFAULT '',
                pad char(60) NOT NULL DEFAULT '',
                PRIMARY KEY (id),
                KEY k (k)
            ) ENGINE=InnoDB;
            "
        sudo mysql -e "
            CREATE SERVER backend\$num FOREIGN DATA WRAPPER mysql OPTIONS (
                HOST '\$node_ipaddress', DATABASE '$SPIDER_DB_NAME', USER '${SPIDER_USER}', PASSWORD '${SPIDER_PASS}', PORT 3306);
            FLUSH TABLES;
            "
    done
    sudo mysql -e "
        CREATE DATABASE IF NOT EXISTS $SPIDER_DB_NAME;
        CREATE TABLE $SPIDER_DB_NAME.\$tbl_name (
            id int(10) unsigned NOT NULL AUTO_INCREMENT,
            k int(10) unsigned NOT NULL DEFAULT '0',
            c char(120) NOT NULL DEFAULT '',
            pad char(60) NOT NULL DEFAULT '',
            PRIMARY KEY (id),
            KEY k (k)
        ) ENGINE=spider
        COMMENT='wrapper \\"mysql\\", table \\"\$tbl_name\\"'
            PARTITION BY KEY (id)
        (
            $part_comment
        );
        "

How to connect to Spider Server, ${VM_NAME}1.${RES_LOC}.cloudapp.azure.com
    Open 3306/tcp in Azure Portal for the IP address range, or Azure Services.

EOF
}

show_elapsed_time () {
    st=$1
    echo "Elapsed time: $(expr $(date '+%s') - $st) secs"
}


##### MAIN
total_st=$(date '+%s')

check_ultra_disk
create_group
create_vnet
create_spider_nodes
install_mariadb
#enable_ssh_login
configure_fw
show_settings

show_elapsed_time $total_st
