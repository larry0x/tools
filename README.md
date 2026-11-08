# tools

Configuration files and justfile recipes shared by my repositories, so a change is made once, here, rather than once per repository.

**A repository takes the files as committed copies, pinned by its `flake.lock`.** `just sync-tools` copies the files at the pinned version into the repository, and `nix flake check` fails while any copy differs from it. So a copy cannot be edited by hand without failing CI, and bumping this repository is a code change: `just bump-tools` updates `flake.lock` and the copies together, and the diff shows exactly what changed. The CI workflows are not copied: they are reusable workflows, which each repository calls (see below).

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

The workflows in `.github/workflows/` are reusable ones, one per language; `ci.yml` is this repository's own CI, which calls them from the same commit. A repository keeps a short workflow of its own per language, which holds its triggers, so its paths filter can list files of that repository alone, and calls the reusable one at a commit.

`just sync-tools` writes the commit that `flake.lock` pins into every call, whatever reference the call named before: a full or short hash, a branch, or a tag. `nix flake check` fails while a call names anything but the pinned commit, written in full.

A GitHub repository writes the call as:

```yaml
jobs:
  rust:
    uses: larry0x/tools/.github/workflows/rust.yml@<commit>
```

A Forgejo repository writes it by URL, since the reusable workflows live on GitHub, and passes inputs for its runners, which carry the label `native` and have nix installed already:

```yaml
jobs:
  rust:
    runs-on: native
    uses: https://github.com/larry0x/tools/.github/workflows/rust.yml@<commit>
    with:
      runner: native
      install-nix: false
```

**`runs-on` is required on Forgejo.** Without it, Forgejo creates no job for a workflow called from another host, so CI looks absent rather than failing. `nix flake check` fails when a job in `.forgejo/workflows/` calls a tools workflow without it. With it, the runner runs the whole reusable workflow as one job, so Forgejo shows one status per language, where GitHub shows one per job, such as Format and Lint + Test.

**The workflows install nix with a plain step, not an action.** Forgejo resolves a short action name, such as `cachix/install-nix-action`, against its own mirror, which does not carry it, and fetches every action before the job starts, even one whose step is skipped, so the job fails. The step runs the official installer at a pinned version and checksum, and only where `install-nix` is true.
