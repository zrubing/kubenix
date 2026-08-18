{ self, ... }:
{
  perSystem = { pkgs, self', evalModules, ... }:
    let
      inherit (pkgs.lib.attrsets) mapAttrs' filterAttrs nameValuePair;
    in
    {
      packages = {
        default = pkgs.callPackage ../pkgs/kubenix.nix {
          inherit evalModules;
        };
        docs = import ../docs {
          inherit pkgs;
          options = (evalModules {
            modules = builtins.attrValues self.nixosModules.kubenix;
          }).options;
        };
      } // mapAttrs' (name: value: nameValuePair "generate-${name}" value)
        (builtins.removeAttrs (pkgs.callPackage ../pkgs/generators { }) [ "override" "overrideDerivation" ])
      // (
        let
          examplesDir = ../docs/content/examples;

          # An example is packageable iff it exposes a pure `module.nix`; the rest only
          # ship a default.nix pinned to the impure builtins.currentSystem, so they can't
          # build.
          # TODO: once those default.nix files are made pure they grow a module.nix and get
          #   picked up here automatically; drop this note then (matches the one in checks.nix).
          isPackageable = name: type:
            type == "directory"
              && builtins.pathExists (examplesDir + "/${name}/module.nix");

          toPackage = name: _:
            nameValuePair
              ("example-" + name)
              (self'.packages.default.override {
                module = examplesDir + "/${name}/module.nix";
              });
        in
        mapAttrs' toPackage
          (filterAttrs isPackageable (builtins.readDir examplesDir))
      );
    };
}
