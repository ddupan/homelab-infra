# PoC 主机的网络事实，集中一处；网段与 AS 的登记在 infrastructure/network/ipam.yml。
{
  hostname = "router-poc";
  # PoC 用过的地址；VM 已删（2026-11-04），DNS 记录随之撤掉。重建时重新登记 hosts.tf。
  address = "10.60.0.40";
  prefixLength = 24;
  gateway = "10.60.0.1";
  nameserver = "192.168.10.5";

  asn = 65003; # 65000–65099 段的下一个；PoC 结束即释放
  # 对端是 vyos-rtr 的 labnet 地址，VyOS 侧以 local-as 65002 出现（同 LB 主机）。
  peer = {
    address = "10.60.0.1";
    asn = 65002;
  };
  # 只宣告一个测试用 /32，不进任何真实路径；VyOS 侧导入策略应为全拒或只收这一条。
  testPrefix = "198.51.100.1/32"; # RFC 5737 文档段，不占 IPAM 空间

  # 管理面：SSH 与 BGP 只放行这些来源。
  mgmtSources = [ "192.168.10.0/24" "10.60.0.0/24" ];
}
