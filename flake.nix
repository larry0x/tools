{
  description = "Configuration files and justfile recipes shared by my repositories";

  # nixpkgs is for this repository's own dev shell only. The functions in lib
  # take each repository's own `pkgs`, so a repository that sets
  # `inputs.tools.inputs.nixpkgs.follows = "nixpkgs"` pins one nixpkgs, and
  # its own flake.lock decides every tool version.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # CI runs on x86_64-linux; development happens on an Apple Silicon Mac.
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];

      forEachSystem = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      lib = import ./lib.nix { root = self.outPath; };

      # This repository uses its own files: the justfile at its root is the
      # base justfile, so `just ci` here runs the shared recipes against the
      # shared configuration files.
      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = self.lib.packages pkgs ++ [
              # biome.json and tsconfig.json are JSON, which Biome checks.
              pkgs.biome
            ];
          };
        }
      );
    };
}
