#!/usr/bin/env bash
# Subnet routes advertised by the laptop (192.168.10.127).
#
# The laptop is the tailnet's ONLY subnet router. Everything else in the tailnet
# is either an operator-managed pod (the ts-* StatefulSets in the `tailscale`
# namespace, one per exposed Service) or a client device — none of them route.
#
# WHY the laptop rather than VyOS or a PVE node: it already sits on every path
# worth reaching. It is on the LAN, it is the NFS/k3s/netboot host, and it
# speaks eBGP with the NEC IX, which relays the VyOS router's (vm:100) summaries
# with the next hop left at 192.168.10.2 -- so everything behind VyOS shows up
# as an ordinary kernel route without adding another tailnet node.
#
# WHY these two:
#   192.168.10.0/24   the LAN — PVE nodes, the AD DC, OpenBao, k3s ingress
#   10.60.0.0/14      everything behind VyOS, as one summary (role "internal"
#                     in infrastructure/network/ipam.yml): SDN labnet
#                     10.60.0.0/24, retronet 10.61.0.0/24 and the LoadBalancer
#                     VIP pools 10.62.0.0/24 (Prod) and 10.62.1.0/24 (Dev).
#                     The summary, not the /24s: per-subnet routes had to be
#                     added here by hand and the VIP pools were forgotten for
#                     weeks. Anything new carved from the /14 is covered.
#                     retronet is included on purpose: the alternative is a
#                     second VPN or a jump box just to reach an emulated Win98.
#                     It is a quarantine network as seen from the LAN, not from
#                     the tailnet.
#
# 10.60.0.0/14 is LEARNED BY BGP via the IX (VyOS's summary, next hop VyOS),
# not configured here — check with `ip route show proto bgp`. If VyOS stops
# advertising it this script still reports success while the route blackholes,
# so verify the kernel table too.
#
# ⚠️ Advertising is only half the job. A newly advertised route arrives
# UNAPPROVED and carries no traffic until it is enabled in the admin console
# (Machines -> laptop -> Edit route settings) or matched by an `autoApprovers`
# entry in the tailnet policy file. Approval state is not visible in
# `tailscale debug prefs` — that only shows what was offered. Check what was
# accepted:
#     sudo tailscale debug netmap | jq '.SelfNode.AllowedIPs'
# An advertised-but-unapproved route is simply absent from that list.
#
# Re-running is safe: --advertise-routes replaces the whole list, so this file
# is the complete set, not an increment.
set -euo pipefail

sudo tailscale set --advertise-routes=192.168.10.0/24,10.60.0.0/14

sudo tailscale debug netmap | jq -r '"approved: " + (.SelfNode.AllowedIPs | join(", "))'
