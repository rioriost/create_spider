#!/bin/zsh

# Building Spider server on Azure IaaS with Azure Database for MySQL instances as Spider Data node
# based on the articles as follows
# https://mariadb.com/kb/en/spider-installation/
# https://mariadb.com/kb/en/spider-storage-engine-overview/#sharding-setup

# Private Link for Azure Database for MySQL
# https://docs.microsoft.com/en-us/azure/mysql/concepts-data-access-security-private-link

# Azure Ultra Disk
# https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disks-types#ultra-disk

setopt SH_WORD_SPLIT

# You should edit at least following 2 lines
readonly AZURE_ACCT="rifujita" 
readonly RES_LOC="japaneast"

# You don't need to edit, but up to you
readonly PRJ_NAME="spdod"
readonly RES_GRP="${AZURE_ACCT}${PRJ_NAME}rg"

# MySQL parameters
# MY_COUNT means the number of Spider Data nodes.
readonly MY_COUNT=2
readonly MY_NAME="${AZURE_ACCT}${PRJ_NAME}mysql"
readonly MY_SKU="MO_Gen5_16"
# at least 200GB for better performance, 200GB equals 600 IOPS
readonly MY_STORAGE_SIZE="204800"
readonly MY_ADMIN_USER=${AZURE_ACCT}
readonly MY_ADMIN_PASS=$(openssl rand -base64 16)
NODE_NAMES=() # auto-generated

# VNET parameters
# You don't need to edit, but up to you
readonly VNET_NAME="${AZURE_ACCT}${PRJ_NAME}vnet"
readonly VNET_SUBNET_NAME="${VNET_NAME}subnet"
readonly PLINK_ZONE_NAME="privatelink.mysql.database.azure.com"

# VM parameters
readonly VM_SIZE="Standard_D16s_v3"
readonly VM_NAME="${AZURE_ACCT}${PRJ_NAME}"
readonly VM_OS_DISK_SIZE="256" #256GB
# As I commented in create_spider_vm(), you need to change IOPS and bandwidth of Ultra Disk on Azure Portal as in July 2020.
readonly VM_DATA_DISK_SIZE="512" #512GB

# Spider parameters
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
    res=$(az network vnet subnet update -g $RES_GRP --vnet-name $VNET_NAME -n $VNET_SUBNET_NAME --disable-private-endpoint-network-policies true)
    show_elapsed_time $st
}

# 4. Create Spider VM
create_spider_vm () {
    echo -e "\e[31mCreating VM...\e[m"
    local "st=$(date '+%s')"
    res=$(az vm create --image Canonical:UbuntuServer:18.04-LTS:latest --size ${VM_SIZE} -g ${RES_GRP} -n ${VM_NAME} \
        --admin-username ${AZURE_ACCT} \
        --generate-ssh-keys \
        --ultra-ssd-enabled true \
        --storage-sku os=Premium_LRS 0=UltraSSD_LRS \
        --os-disk-size-gb $VM_OS_DISK_SIZE \
        --data-disk-sizes-gb $VM_DATA_DISK_SIZE \
        --vnet-name $VNET_NAME \
        --subnet $VNET_SUBNET_NAME \
        -z $VM_ZONE_ULTRA_DISK_AVAILABLE \
        --public-ip-address-dns-name ${VM_NAME} --no-wait)
    
    # There is an issue to change Ultra Disk as in July 2020. (https://github.com/Azure/azure-cli/issues/14013)
    #local ultradisk=$(az vm show -g ${RES_GRP} -n ${VM_NAME} --query storageProfile.dataDisks[0].name -o tsv)
    #az disk update -g ${RES_GRP} -n ${ultradisk} --disk-iops-read-write 160000 --disk-mbps-read-write 2000

    show_elapsed_time $st
}

# 5. Create DNS zone
create_dns_zone () {
    echo -e "\e[31mCreating private DNS zone. Please wait for about 2 mins to complete...\e[m"
    local "st=$(date '+%s')"
    res=$(az network private-dns zone create -g $RES_GRP --name $PLINK_ZONE_NAME)
    res=$(az network private-dns link vnet create -g $RES_GRP --zone-name $PLINK_ZONE_NAME --name "dnslink" --virtual-network $VNET_NAME --registration-enabled false)
    show_elapsed_time $st
}

# 6. Create mysql
create_mysql () {
    local "i=1"
    while [ $i -le ${MY_COUNT} ]; do
        echo -e "\e[31mCreating MySQL ${i}. Please wait for about 2 mins to complete...\e[m"
        local "st=$(date '+%s')"
        # Because of use of Private Link, disable SSL
        local "res=$(az mysql server create -g $RES_GRP -n "${MY_NAME}${i}" --sku $MY_SKU --storage-size $MY_STORAGE_SIZE -u $MY_ADMIN_USER -p $MY_ADMIN_PASS --ssl-enforcement Disabled)"
        show_elapsed_time $st
        create_pep $MY_NAME${i}
        configure_dns $MY_NAME${i}
        NODE_NAMES+=("${MY_NAME}${i}.${PLINK_ZONE_NAME}")
        i=$(expr $i + 1)
    done
}

# 7. Creating Private Endpoint
create_pep () {
    local "mysql_server=$1"
    echo -e "\e[31mCreating Private Endpoint...\e[m"
    local "st=$(date '+%s')"
    local "server_id=$(az mysql server show -g $RES_GRP -n $mysql_server --query 'id' -o tsv)"
    res=$(az network private-endpoint create --name "${mysql_server}ep" -g $RES_GRP --vnet-name $VNET_NAME --subnet $VNET_SUBNET_NAME \
        --private-connection-resource-id $server_id --group-id mysqlServer --connection-name "${mysql_server}epcon")
    show_elapsed_time $st
}

# 8. Configure DNS
configure_dns () {
    local "mysql_server=$1"
    echo -e "\e[31mRegistering '$mysql_server' to private DNS zone...\e[m"
    st=$(date '+%s')
    local "nic_id=$(az network private-endpoint show -n "${mysql_server}ep" -g $RES_GRP --query 'networkInterfaces[0].id' -o tsv)"
    local "private_ip=$(az resource show --ids $nic_id --api-version 2019-04-01 --query 'properties.ipConfigurations[0].properties.privateIPAddress' -o tsv)"
    res=$(az network private-dns record-set a create --name $mysql_server --zone-name $PLINK_ZONE_NAME -g $RES_GRP)
    res=$(az network private-dns record-set a add-record --record-set-name $mysql_server --zone-name $PLINK_ZONE_NAME -g $RES_GRP -a $private_ip)
    show_elapsed_time $st
}

# 9. Configure spider
configure_spider () {   
    # On Local
    echo -e "\e[31mConfiguring VM...\e[m"
    local "st=$(date '+%s')"

    # Create a file of credentials
    cat << EOF > ${CREDENTIALS}
    export MY_ADMIN_USER="${MY_ADMIN_USER}"
    export MY_ADMIN_PASS="${MY_ADMIN_PASS}"
    export NODE_NAMES="${NODE_NAMES}"
    export SPIDER_DB_NAME="${SPIDER_DB_NAME}"
EOF

    # Wait for VM can be connected via ssh
    fqdn="${VM_NAME}.${RES_LOC}.cloudapp.azure.com"
    echo -e "Connecting $fqdn..."
    ssh-keygen -R $fqdn 2>&1
    trying=0
    sshres=$(ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" 'uname')
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

    # Copy credentials needed to configure Spider
    scp -o "StrictHostKeyChecking no" ${CREDENTIALS} ${AZURE_ACCT}@"$fqdn:~/"
    rm -f ${CREDENTIALS}

    # SSH Login and execute commands
    ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" <<-'EOF'

    # On Remote
    source credentials.inc

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

    # Enable Spider for Non root connection
    # https://mariadb.com/kb/en/spider-server-system-variables/#spider_remote_sql_log_off
    sudo sed --in-place -e "/^\[mariadb\]/a spider_remote_sql_log_off = 1" /etc/mysql/mariadb.conf.d/50-server.cnf

    # Start MariaDB
    sudo sh -c "
        systemctl enable mariadb;
        systemctl restart mariadb
        "

    # Install Spider Engine
    sudo mysql -e " \
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

    # Create Admin user
    sudo mysql -e "
        CREATE USER '${MY_ADMIN_USER}';
        GRANT ALL ON *.* TO '${MY_ADMIN_USER}' IDENTIFIED BY '${MY_ADMIN_PASS}';
        FLUSH PRIVILEGES;
        "

    # Create Spider user on Spider Data Nodes
    for node_fqdn in ${NODE_NAMES}; do
        node_name=$(echo $node_fqdn | cut -d'.' -f1)
        mysql -h $node_fqdn -u $MY_ADMIN_USER@$node_name -p$MY_ADMIN_PASS -e "
            CREATE DATABASE ${SPIDER_DB_NAME};
            GRANT ALL ON ${SPIDER_DB_NAME}.* TO ${MY_ADMIN_USER} IDENTIFIED BY '${MY_ADMIN_PASS}';
            FLUSH PRIVILEGES;
            "
    done

EOF
    show_elapsed_time $st
}

# 10. Show and write all settings
show_settings () {
    part_comment_ar=()
    mysql_com_ar=()
    num=1
    for node_fqdn in $NODE_NAMES; do
        node_name=$(echo $node_fqdn | cut -d'.' -f1)
        part_comment_ar+=("PARTITION pt$num COMMENT = 'srv \\\"backend$num\\\"'")
        mysql_com_ar+=(",    mysql -u ${MY_ADMIN_USER}@$node_name -p${MY_ADMIN_PASS} -h $node_fqdn")
        num=$(expr $num + 1)
    done
    part_comment=$(echo $part_comment_ar | sed 's/ PARTITION/, PARTITION/g')
    mysql_com=$(echo $mysql_com_ar | tr "," "\n  ")
    
    echo -e "\e[31mWriting all settings to 'settings.txt'...\e[m\n"
    cat << EOF | tee settings_${AZURE_ACCT}${PRJ_NAME}.txt
Azure Region   : ${RES_LOC}
Resource Group : ${RES_GRP}

Spider Server  : ${VM_NAME}.${RES_LOC}.cloudapp.azure.com

Spider Data Nodes :
    ${NODE_NAMES}
    MySQL Admin User : ${MY_ADMIN_USER}, Password : ${MY_ADMIN_PASS}

How to connect to Spider Data node from Spider Server${mysql_com}

How to create a table to be sharded
    ssh ${AZURE_ACCT}@${VM_NAME}.${RES_LOC}.cloudapp.azure.com
    tbl_name="sbtest"
    num=1
    for node_fqdn in ${NODE_NAMES}; do
        node_name=\$(echo \$node_fqdn | cut -d'.' -f1)
        mysql -u ${MY_ADMIN_USER}@\$node_name -p${MY_ADMIN_PASS} -h \$node_fqdn -e "
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
                HOST '\$node_fqdn', DATABASE '$SPIDER_DB_NAME', USER '${MY_ADMIN_USER}@\$node_name', PASSWORD '${MY_ADMIN_PASS}', PORT 3306);
            FLUSH TABLES;
            "
        num=\$(expr \$num + 1)
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

How to connect to Spider Server, ${VM_NAME}.${RES_LOC}.cloudapp.azure.com
    Open 3306/tcp in Azure Portal for the IP address range, or Azure Services.

EOF
}

show_elapsed_time () {
    local "st=$1"
    echo "Elapsed time: $(expr $(date '+%s') - $st) secs"
}

total_st=$(date '+%s')

check_ultra_disk
create_group
create_vnet
create_spider_vm
create_dns_zone
create_mysql
configure_spider
show_settings

show_elapsed_time $total_st
