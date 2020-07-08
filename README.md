# create_spider
Create MariaDB Spider cluster on Azure VMs with Ultra Disk

This script makes a MariaDB Spider cluster consisting of a Spider Server and two Spider Data nodes by default.

Only you need to do is edit at least two lines of the script, 'AZURE_ACCT' and 'RES_LOC' as you want.

After creating the cluster, only the Spider Server has a public IP address for security. All the nodes are connected through VNET with private IP address.

For more details, please see the settings.txt written by the script after creating.
