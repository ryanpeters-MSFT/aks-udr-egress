$group        = "rg-aks-udr"
$location     = "eastus2"
$vnetName     = "aks-vnet"
$podSubnet    = "pod-subnet"
$podSubnetCidr = "10.240.0.0/16"
$fwSubnetName = "AzureFirewallSubnet"   # name is required by azure firewall
$fwName       = "aks-firewall"
$fwPipName    = "aks-firewall-pip"
$fwIpConfig   = "aks-firewall-ipconfig"
$fwRuleCollection = "allow-targeted-egress"
$fwRuleName   = "allow-https-to-target-range"
$routeTable   = "rt-pod-egress"
$clusterName  = "udrcluster"
$destRange    = "34.160.111.0/24"      # ip range to direct through the firewall for ifconfig.me
$destPort     = "443"

# create resource group
az group create -n $group -l $location

# create vnet with pod subnet and dedicated AzureFirewallSubnet in the same vnet
az network vnet create -g $group -n $vnetName -l $location `
    --address-prefix 10.0.0.0/8 `
    --subnet-name $podSubnet --subnet-prefix $podSubnetCidr

az network vnet subnet create -g $group --vnet-name $vnetName `
    -n $fwSubnetName --address-prefix 10.0.1.0/26

# create public ip for the firewall (standard sku required)
az network public-ip create -g $group -n $fwPipName -l $location `
    --sku Standard --allocation-method static

# create the azure firewall
az network firewall create -g $group -n $fwName -l $location

# attach the public ip and vnet to the firewall
az network firewall ip-config create -g $group `
    --firewall-name $fwName -n $fwIpConfig `
    --public-ip-address $fwPipName --vnet-name $vnetName

# apply the ip config
az network firewall update -g $group -n $fwName

# allow the routed subnet to reach the targeted destination range through the firewall
az network firewall network-rule create -g $group --firewall-name $fwName `
    --collection-name $fwRuleCollection --name $fwRuleName `
    --source-addresses $podSubnetCidr `
    --destination-addresses $destRange `
    --destination-ports $destPort `
    --protocols TCP `
    --action Allow --priority 100

# capture the firewall private ip (dynamically assigned)
$fwPrivateIp = az network firewall show -g $group -n $fwName `
    --query "ipConfigurations[0].privateIPAddress" -o tsv

# create route table and add a targeted route for the destination range through the firewall
az network route-table create -g $group -l $location -n $routeTable

az network route-table route create -g $group --route-table-name $routeTable `
    -n "to-firewall" --address-prefix $destRange `
    --next-hop-type VirtualAppliance --next-hop-ip-address $fwPrivateIp

# associate route table with the pod subnet
az network vnet subnet update -g $group --vnet-name $vnetName `
    -n $podSubnet --route-table $routeTable

# get the pod subnet resource id for aks
$subnetId = az network vnet subnet show -g $group --vnet-name $vnetName `
    -n $podSubnet --query id -o tsv

# create the aks cluster with azure cni in the pre-configured pod subnet
az aks create -g $group -n $clusterName -l $location `
    --network-plugin azure `
    --vnet-subnet-id $subnetId `
    --service-cidr 192.168.0.0/16 `
    --dns-service-ip 192.168.1.3 `
    --generate-ssh-keys

# authenticate
az aks get-credentials -g $group -n $clusterName --overwrite-existing