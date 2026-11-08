# tools

Configuration files and justfile recipes shared by my repositories, so a change is made once, here, rather than once per repository.

**A repository takes the files as committed copies, pinned by its `flake.lock`.** `just sync-tools` copies the files at the pinned version into the repository, and `nix flake check` fails while any copy differs from it. So a copy cannot be edited by hand without failing CI, and bumping this repository is a code change: `just bump-tools` updates `flake.lock` and the copies together, and the diff shows exactly what changed.

**The copies are files, not symlinks into the Nix store.** Editors and their language servers read them without entering a dev shell, the forge's web interface shows them, and garbage collection cannot remove them.

## Adopting it in a repository

1. Add the input, and the check, the app, and the tools to `flake.nix`:

   ```nix
   {
     inputs = {
       nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
       tools = {
         url = "github:larry0x/tools";
         inputs.nixpkgs.follows = "nixpkgs";
       };
     };

     outputs =
       { self, nixpkgs, tools }:
       let
         # The files this repository takes. A repository with recipes of its
         # own takes the justfile as { from = "justfile"; to = "base.just"; }.
         toolsFiles = [
           ".editorconfig"
           ".gitignore"
           ".markdownlint-cli2.yaml"
           ".yamlfmt.yaml"
           ".yamllint.yaml"
           "clippy.toml"
           "justfile"
           "rustfmt.toml"
           "taplo.toml"
         ];
         # ...
       in
       {
         checks = forEachSystem (system: {
           tools = tools.lib.check {
             pkgs = nixpkgs.legacyPackages.${system};
             src = self;
             files = toolsFiles;
           };
         });

         apps = forEachSystem (system: {
           sync-tools = tools.lib.sync {
             pkgs = nixpkgs.legacyPackages.${system};
             files = toolsFiles;
           };
         });

         devShells = forEachSystem (
           system:
           let
             pkgs = nixpkgs.legacyPackages.${system};
           in
           {
             default = pkgs.mkShell {
               packages = tools.lib.packages pkgs ++ [
                 # the language toolchains
               ];
             };
           }
         );
       };
   }
   ```

2. Run `nix run .#sync-tools`, then `git add` the copies. `nix flake check` sees only files git tracks.
3. A repository with recipes of its own keeps them in its `justfile`, which opens with `import 'base.just'`. A recipe or variable of the same name as one in `base.just` replaces it.

## The JSON files

JSON cannot carry comments, so their reasons are here.

- **`biome.json`:** Biome takes its ignore list from `.gitignore` and its indentation from `.editorconfig`, so neither is repeated here. Biome does not format or lint Markdown, which markdownlint-cli2 owns. In Svelte files, the unused-import and unused-variable rules are off, because Biome sees only the script block, not the markup that uses those names. `useLiteralKeys` is off because it contradicts `noPropertyAccessFromIndexSignature` in `tsconfig.json`: for a type with an index signature, TypeScript requires `obj["key"]` where Biome would demand `obj.key`.
- **`tsconfig.json`:** Type checking only (`noEmit`); Vite bundles. The sources live in `ui/`.

## The CI workflows

One workflow per language, in two variants: `.github/workflows/` for GitHub, and `.forgejo/workflows/` for Forgejo, whose runners carry the label `native` and have nix installed already. A repository takes the variant for its forge, for the languages it has, the same way it takes the configuration files.

Each step runs one just recipe, so CI checks exactly what `just ci` checks. A language's workflow runs when a file of that language changes, or a file that changes what the recipes do: `flake.nix`, `flake.lock`, the justfile, and `.gitignore`. The Nix workflow runs on every change, because `nix flake check` is what catches a copy that differs from the pinned version.

This repository runs the GitHub variants on itself. The recipes for languages it does not have do nothing, so those workflows pass.
