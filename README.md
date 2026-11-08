# tools

Configuration files and justfile recipes shared by my repositories, so a change is made once, here, rather than once per repository.

**A repository takes the files as committed symbolic links into the Nix store, pinned by its `flake.lock`.** `just sync-tools` links each file to this repository's source at the pinned version, such as `rustfmt.toml -> /nix/store/<hash>-source/rustfmt.toml`. The store path is the same on every machine, so a link resolves wherever nix has fetched that version: in CI, the dev shell fetches it. `nix flake check` fails while a link points anywhere else. `just bump-tools` updates `flake.lock` and the links together.

**A link is broken where nix has not fetched its target:** in the forge's web interface, in a clone before any nix command has run, and after garbage collection has removed the target.

**`.gitignore` is not shared.** git does not follow a `.gitignore` that is a symbolic link, so each repository keeps its own.

## Adopting it in a repository

1. Add the input, and the check, the app, and the tools to `flake.nix`. The input is pinned by commit, which `flake.lock` records either way:

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
         # The files this repository links. A repository with recipes of its
         # own takes the justfile as { from = "justfile"; to = "base.just"; }.
         toolsFiles = [
           ".editorconfig"
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

2. Run `nix run .#sync-tools`, then `git add` the links. `nix flake check` sees only files git tracks.
3. A repository with recipes of its own keeps them in its `justfile`, which opens with `import 'base.just'`. A recipe or variable of the same name as one in `base.just` replaces it.

## The JSON files

JSON cannot carry comments, so their reasons are here.

- **`biome.json`:** Biome takes its ignore list from `.gitignore` and its indentation from `.editorconfig`, so neither is repeated here. Biome does not format or lint Markdown, which markdownlint-cli2 owns. In Svelte files, the unused-import and unused-variable rules are off, because Biome sees only the script block, not the markup that uses those names. `useLiteralKeys` is off because it contradicts `noPropertyAccessFromIndexSignature` in `tsconfig.json`: for a type with an index signature, TypeScript requires `obj["key"]` where Biome would demand `obj.key`.
- **`tsconfig.json`:** Type checking only (`noEmit`); Vite bundles. The sources live in `ui/`.

## The CI workflows

The workflows in `.github/workflows/` are reusable ones, one per language. A repository keeps a short workflow of its own per language, which holds the triggers and calls the reusable one at a commit:

```yaml
jobs:
  rust:
    uses: larry0x/tools/.github/workflows/rust.yml@<commit>
```

`just sync-tools` writes the commit that `flake.lock` pins into every such call, and `nix flake check` fails while a call names another commit. A Forgejo repository writes the call as `https://github.com/larry0x/tools/.github/workflows/rust.yml@<commit>`, and passes `with: { runner: native, install-nix: false }`.

`ci.yml` is this repository's own CI: it calls the reusable workflows from the same commit.

**Known gap:** the reusable workflows pin `actions/checkout` at the commit GitHub serves. A Forgejo runner resolves actions through its own mirror, which may not hold that commit.
