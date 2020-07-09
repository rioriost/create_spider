# create_spider
Create MariaDB Spider Server on Azure VM with Ultra Disk

These scripts make a MariaDB Spider cluster consisting of a Spider Server and two Spider Data nodes by default.

- create_spider.sh : Create a cluster with VMs. e.g. 1 VM Spider Server with 2 VM Spider Data nodes.
- create_spider_with_orcas.sh : Create a cluster with a VM and Azure Database for MySQLs. e.g. 1 VM Spider Server with 2 Azure MySQLs.

Only you need to do is edit at least two lines of the script, 'AZURE_ACCT' and 'RES_LOC' as you want.

After creating the cluster, only the Spider Server has a public IP address for security. All the nodes are connected through VNET with private IP address.

For more details, please see the settings.txt written by the script after creating.

![A list showing the resrouces.](resources.png 'Resources')
