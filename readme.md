# AKS Egress Routing with UDR and Azure Firewall

This repo shows how to send selected outbound traffic from an AKS subnet through Azure Firewall by attaching a user-defined route (UDR) to the subnet.

The example in [setup.ps1](setup.ps1) builds:

- A resource group in `eastus2`
- A virtual network with an AKS subnet and `AzureFirewallSubnet`
- An Azure Firewall with a public IP
- A route table that forwards a specific destination prefix to the firewall
- An AKS cluster deployed into the pre-created subnet
- A firewall network rule that allows TCP 443 from the AKS subnet to the targeted destination range

## Why use a UDR for AKS egress

AKS workloads normally follow the system route table for outbound traffic. When you associate a route table with the AKS subnet, you can override that behavior for specific prefixes.

In this pattern:

1. A pod or node initiates outbound traffic.
2. Azure checks the route table attached to the AKS subnet.
3. If the destination matches the configured prefix, Azure sends the packet to the firewall's private IP as a `VirtualAppliance` next hop.
4. Azure Firewall evaluates the traffic against its rule collections.
5. If a matching allow rule exists, the firewall SNATs and forwards the traffic out.

The key point is that the UDR only changes the path. It does not grant access by itself. You still need a firewall rule that explicitly allows the routed traffic.

## Current example flow

The script targets `34.160.111.0/24` on TCP `443`.

That means:

- Traffic from the AKS subnet to addresses inside `34.160.111.0/24` is redirected to Azure Firewall.
- Other egress keeps using the normal system routes unless you add more UDR entries.
- The firewall must allow traffic from `10.240.0.0/16` to `34.160.111.0/24` on port `443`.

This is useful when you want to inspect, filter, or SNAT only a subset of outbound traffic instead of forcing all egress through a central appliance.

## What the script configures

The important pieces in [setup.ps1](setup.ps1) are:

- AKS subnet CIDR: `10.240.0.0/16`
- Firewall subnet: `10.0.1.0/26`
- Destination prefix routed through the firewall: `34.160.111.0/24`
- Route next hop type: `VirtualAppliance`
- Route next hop IP: the private IP assigned to Azure Firewall

The UDR entry is effectively:

```text
Destination: 34.160.111.0/24
Next hop type: VirtualAppliance
Next hop IP: <azure firewall private ip>
```

The matching firewall rule is effectively:

```text
Source: 10.240.0.0/16
Destination: 34.160.111.0/24
Protocol: TCP
Port: 443
Action: Allow
```

## Deploy

Prerequisites:

- Azure CLI installed and logged in
- Permissions to create networking, firewall, and AKS resources

Run:

```powershell
# create vnet, firewall/rules, UDR, and AKS cluster
.\setup.ps1

# deploy curl test pod
kubectl apply -f .\curl.yaml
```

At the end of the script, it prints:

- The Azure Firewall public IP
- The AKS load balancer egress public IP

## Validate the routing behavior

After the cluster is created, test from the `curl` pod.

```powershell
# should return the IP of the firewall
kubectl exec -it curl -- curl https://ifconfig.me

# should return the IP of the default load balancer
kubectl exec -it curl -- curl https://api.ipify.org
```

From inside the test pod, call a destination in the routed prefix. If the route and firewall rule are both correct, the connection should succeed and the destination should see the firewall's public IP as the source.

For traffic that does not match the routed prefix, outbound traffic should continue to use the AKS load balancer egress public IP printed by the script.

## Common failure mode

If traffic is routed to Azure Firewall but you did not create a matching allow rule, connections usually fail during setup or TLS negotiation because the firewall is on the path but is not permitting the flow.

That is the most common mistake with this pattern:

- Subnet UDR present
- Firewall next hop reachable
- No matching firewall allow rule

When that happens, the fix is not the UDR. The fix is adding the correct firewall rule collection and rule.

## Notes

- The script demonstrates targeted egress steering, not a full forced-tunnel design.
- If you want all outbound traffic to traverse the firewall, add a broader route such as `0.0.0.0/0` and account for AKS control-plane and dependency requirements.
- Be careful with destination IP-based routing for public services because the service IP range can change over time.
