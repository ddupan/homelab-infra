{
  # NixOS 路由器 PoC（infrastructure/network/router.md「备选：NixOS」）。
  # 只为验证三件事：改配置 BGP 不断、坏 frr.conf 在 check 阶段被拦、锁死自己时 magic rollback 在线回退。
  description = "NixOS router PoC";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko/v1.13.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, deploy-rs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      facts = import ./facts.nix;
    in
    {
      nixosConfigurations.router-poc = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit facts; };
        modules = [
          disko.nixosModules.disko
          ./disk.nix
          ./router-poc.nix
        ];
      };

      deploy.nodes.router-poc = {
        hostname = facts.address;
        sshUser = "root";
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.router-poc;
        };
        # 路由器改坏就失联，这正是要的保护：激活后 confirmTimeout 内部署端确认不了，
        # 目标机在线切回上一代。确认走被改的转发面，所以"确认不了"就等于"网断了"。
        magicRollback = true;
        autoRollback = true;
        confirmTimeout = 60;
      };

      checks.${system} = deploy-rs.lib.${system}.deployChecks self.deploy // {
        # frrinit.sh reload 无条件 exit 0：frr-reload.py 失败也报激活成功，auto/magic rollback
        # 都不会触发。所以坏配置只能在这里拦。
        # `--config_dir` 而非 `-f`：两者都校验传入的文件，但 `-f` 的报错里写的是 /etc/frr/frr.conf，
        # 读日志会以为没查到自己的文件。"processing failure: 11" 是缺 vtysh.conf 的提示，好配置也会
        # 出现，rc 仍为 0；真正的语法错误 rc=2（2026-11-04 用 FRR 10.6.1 实测）。
        frr-config = pkgs.runCommand "frr-config-dryrun" { } ''
          mkdir conf
          cp ${self.nixosConfigurations.router-poc.config.environment.etc."frr/frr.conf".source} conf/frr.conf
          ${pkgs.frr}/bin/vtysh --dryrun --config_dir "$PWD/conf"
          touch $out
        '';
      };
    };
}
