{ lib, pkgs, modulesPath, facts, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  system.stateVersion = "26.05";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # 与 vyos-rtr 一样无 VGA，`qm terminal` 是带外通道。
  boot.kernelParams = [ "console=ttyS0,115200" ];

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.hostName = facts.hostname;
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-lan" = {
    # 按驱动匹配而非接口名：PVE 的 virtio NIC 名字随 PCI 槽位变。
    matchConfig.Driver = "virtio_net";
    address = [ "${facts.address}/${toString facts.prefixLength}" ];
    routes = [ { Gateway = facts.gateway; } ];
    dns = [ facts.nameserver ];
  };

  # 整份规则集，switch 时 `nft -f` 原子替换。锁死自己的测试就改这里。
  networking.firewall.enable = false;
  networking.nftables = {
    enable = true;
    ruleset = ''
      table inet filter {
        set mgmt {
          type ipv4_addr; flags interval
          elements = { ${lib.concatStringsSep ", " facts.mgmtSources} }
        }
        chain input {
          type filter hook input priority 0; policy drop;
          ct state established,related accept
          iif lo accept
          meta l4proto icmp accept
          ip saddr @mgmt tcp dport 22 accept
          ip saddr ${facts.peer.address} tcp dport 179 accept
        }
      }
    '';
  };

  services.frr = {
    bgpd.enable = true;
    config = ''
      ip prefix-list OUT seq 10 permit ${facts.testPrefix}
      ip prefix-list IN seq 10 deny any
      route-map OUT permit 10
       match ip address prefix-list OUT
      route-map IN deny 10
      !
      router bgp ${toString facts.asn}
       bgp router-id ${facts.address}
       no bgp ebgp-requires-policy
       neighbor ${facts.peer.address} remote-as ${toString facts.peer.asn}
       neighbor ${facts.peer.address} description vyos-rtr
       neighbor ${facts.peer.address} timers 10 30
       address-family ipv4 unicast
        network ${facts.testPrefix}
        neighbor ${facts.peer.address} route-map IN in
        neighbor ${facts.peer.address} route-map OUT out
       exit-address-family
    '';
  };
  # ⚠ 不用模块默认的 `frrinit.sh reload`（2026-11-04 实测 FRR 10.6.1）：它先重启 watchfrr，
  # watchfrr 退出时向 systemd 发 STOPPING=1（unit 是 NotifyAccess=all），systemd 于是把 frr.service
  # 当成在停，2 分钟 TimeoutStop 后 SIGKILL 全部守护进程再拉起 —— BGP 断一次。脚本里防这个的
  # cgroup 搬迁只认 cgroup v1 的 /sys/fs/cgroup/systemd，v2 下是空操作。
  # 直接调 frr-reload.py：不碰 watchfrr；且它的退出码原样返回，reload 失败会让激活失败
  # （frrinit.sh 末尾无条件 exit 0）。代价：增删守护进程（bgpd.enable 之类）reload 不会生效，要手动 restart。
  systemd.services.frr.serviceConfig.ExecReload = lib.mkForce
    "${pkgs.frr}/libexec/frr/frr-reload.py --reload --bindir ${pkgs.frr}/bin --confdir /etc/frr --rundir /run/frr /etc/frr/frr.conf";

  # 测试前缀需要在 RIB 里才能被 `network` 宣告。
  systemd.network.netdevs."20-dummy0".netdevConfig = { Name = "dummy0"; Kind = "dummy"; };
  systemd.network.networks."20-dummy0" = {
    matchConfig.Name = "dummy0";
    address = [ facts.testPrefix ];
  };

  # 只信 Bao 签发的短期证书（同 openbao_ssh_ca_trust），不放长期 authorized_keys。
  # 公钥取自 bao 的未认证端点 /v1/ssh-client-signer/public_key，CA 轮换时要更新这里。
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    extraConfig = "TrustedUserCAKeys /etc/ssh/openbao_user_ca.pub";
  };
  environment.etc."ssh/openbao_user_ca.pub".text = ''
    ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDKtYZFrLM4P/5PNXSI7230vmqzgwxQuWfsckv9LmSwDCUe1ZRXaxs5bt1wprrZsAspa8qEJvvDciC1z8wyMakDzSPHWAL1MoBVHD2rOtkOFTqfFQmg0FgUDSTy37DVEMAHKD/DEYJdRWSdk5Pv+XyCfQFFk1q2U5IDApGPonwtscHjgeowvXRXj2Omon0ac6kwK2xLMvMkSMBJv1Cz3cdD2vIxvtkaKriSPSuwPRhyK4Br4zN2uCrQu7VMYrf/nHPPyOr/U7hRXe46Z7hO/oAp1H/XqmbS+Mr63Uc9egzFmOedF3yjXS1IkYtEDfmwoLpytDvkiI7tbdez2iaa6SyPOy5W9uSnkP2XQIKXYYtN0QXziOFFrqmXg/VvY389YhYRirwSgqjnv+hOai7r3PQeQm7lmVxl+sQnRtey8gXV5GNUyKIG+Jwiu5z7QnnT1BG3JFCjfqN7Q43HdujvXWxFWKPj4fEoANFriOHQ/sJpx2Rf1LJQBh0zqB1Ziyq5D8eVpi342A2pS9Jqy0gxDBzN7ICBefvotw7a2bY3phtlpZFsblVXolXYUOHs5K6KKzMeJBZDdqk9sQ9uKJnPY1ci2BT/ZA6VkK5th5VlBBT5jj7vuUsWQezGGi8M7NCK4x/5x84dA8fy+3nyUHssIqhDSZ2cw8LVPNr9o7Bw3ie71w==
  '';

  services.qemuGuest.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = [ pkgs.tcpdump ];
}
