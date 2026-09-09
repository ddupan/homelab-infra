#!/usr/bin/env bash
# Subnet routes advertised by the laptop (192.168.10.127).
#
# The laptop is the tailnet's ONLY subnet router. Everything else in the tailnet
# is either an operator-managed pod (the ts-* StatefulSets in the `tailscale`
# namespace, one per exposed Service) or a client device — none of them route.
#
# WHY the laptop rather than VyOS or a PVE node: it already sits on every path
# worth reaching. It is on the LAN, it is the NFS/k3s/netboot host, and it
# speaks OSPF with the VyOS router (vm:100), so the PVE SDN VNets show up as
# ordinary kernel routes without adding another tailnet node.
#
# WHY these three:
#   192.168.10.0/24   the LAN — PVE nodes, the AD DC, OpenBao, k3s ingress
#   10.60.0.0/24      SDN labnet   (VLAN 100) — retrolab, future lab VMs
#   10.61.0.0/24      SDN retronet (VLAN 110) — 86Box guests. Included on
#                     purpose: the alternative is a second VPN or a jump box
#                     just to reach an emulated Win98. retronet is a quarantine
#                     network as seen from the LAN, not from the tailnet.
#
# The two 10.x routes are LEARNED BY OSPF, not configured here — check with
# `ip route show proto ospf`. If VyOS stops advertising them this script still
# reports success while the routes blackhole, so verify the kernel table too.
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

sudo tailscale set --advertise-routes=192.168.10.0/24,10.60.0.0/24,10.61.0.0/24

sudo tailscale debug netmap | jq -r '"approved: " + (.SelfNode.AllowedIPs | join(", "))'
