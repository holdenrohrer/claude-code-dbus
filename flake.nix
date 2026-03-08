{
  description = "D-Bus bridge for Claude Code lifecycle events";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          runtimeDeps = with pkgs; [ jq dbus coreutils ];
          runtimePath = pkgs.lib.makeBinPath runtimeDeps;
        in
        {
          hook-script = pkgs.writeShellScriptBin "claude-code-dbus-hook" ''
            export PATH="${runtimePath}:$PATH"
            source ${self}/scripts/claude-code-dbus-hook.sh
          '';

          default = self.packages.${system}.hook-script;
        });

      # Home-manager module for wiring hooks + loading elisp
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          hook-script = self.packages.${pkgs.system}.hook-script;
          hookCmd = "${hook-script}/bin/claude-code-dbus-hook";
          mkHook = { type = "command"; command = hookCmd; };
        in
        {
          programs.emacs.extraConfig = ''
            ${builtins.readFile "${self}/claude-code-dbus.el"}
            (claude-code-dbus-mode 1)
          '';

          claude.hooks.SessionStart = [{ hooks = [ mkHook ]; }];
          claude.hooks.SessionEnd = [{ hooks = [ mkHook ]; }];
          claude.hooks.Stop = [{ hooks = [ mkHook ]; }];
          claude.hooks.PostToolUse = [{ matcher = "AskUserQuestion"; hooks = [ mkHook ]; }];
          claude.hooks.PermissionRequest = [{ hooks = [ mkHook ]; }];
          claude.hooks.Notification = [{ hooks = [ mkHook ]; }];
        };
    };
}
