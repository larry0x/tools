# The functions a repository calls from its flake.nix to take files from this
# one. `root` is this repository's source, in the Nix store.
{ root }:
let
  # Every file a repository may take. The repository's own files, such as
  # flake.nix and README.md, are not on the list, so no repository can take
  # one by mistake.
  files = [
    ".editorconfig"
    ".gitignore"
    ".latexindent.yaml"
    ".latexmkrc"
    ".markdownlint-cli2.yaml"
    ".yamlfmt.yaml"
    ".yamllint.yaml"
    "biome.json"
    "clippy.toml"
    "justfile"
    "rustfmt.toml"
    "taplo.toml"
    "tsconfig.json"

    # The CI workflows, one per language, in a variant for each forge. Each
    # runs the language's just recipes, which do nothing where the language
    # is absent.
    ".forgejo/workflows/js.yml"
    ".forgejo/workflows/latex.yml"
    ".forgejo/workflows/lean.yml"
    ".forgejo/workflows/markdown.yml"
    ".forgejo/workflows/nix.yml"
    ".forgejo/workflows/python.yml"
    ".forgejo/workflows/rust.yml"
    ".forgejo/workflows/toml.yml"
    ".forgejo/workflows/yaml.yml"
    ".github/workflows/js.yml"
    ".github/workflows/latex.yml"
    ".github/workflows/lean.yml"
    ".github/workflows/markdown.yml"
    ".github/workflows/nix.yml"
    ".github/workflows/python.yml"
    ".github/workflows/rust.yml"
    ".github/workflows/toml.yml"
    ".github/workflows/yaml.yml"
  ];

  # A repository names each file it takes either by its name, to copy it to
  # the same path, or as { from = <name>; to = <path>; }, to copy it
  # elsewhere: a repository with recipes of its own takes the justfile as
  # { from = "justfile"; to = "base.just"; }.
  normalize =
    entry:
    let
      file =
        if builtins.isString entry then
          {
            from = entry;
            to = entry;
          }
        else
          entry;
    in
    if builtins.elem file.from files then
      file
    else
      throw "tools: no shared file named ${file.from}; the shared files are: ${builtins.concatStringsSep " " files}";

  # A list of entries, each turned into a line of shell, joined.
  forEach = entries: f: builtins.concatStringsSep "\n" (map (e: f (normalize e)) entries);
in
{
  inherit files;

  # The tools the base justfile calls in every repository: just itself, and
  # the formatters and linters for Nix, TOML, YAML, and Markdown, which every
  # repository has. A repository adds its languages' toolchains on top.
  packages = pkgs: [
    pkgs.just

    # Formatter and linters for the Nix files, plus nixf-tidy (in nixf), the
    # checks of the language server nixd, and jq to print its findings.
    pkgs.nixfmt
    pkgs.statix
    pkgs.deadnix
    pkgs.nixf
    pkgs.jq

    # Formatter and linter for the TOML files, configured by taplo.toml.
    pkgs.taplo

    # Formatter and linters for the YAML files, configured by .yamlfmt.yaml
    # and .yamllint.yaml, and the linter for CI workflows.
    pkgs.yamlfmt
    pkgs.yamllint
    pkgs.actionlint

    # Linter for the Markdown files, configured by .markdownlint-cli2.yaml.
    pkgs.markdownlint-cli2
  ];

  # A flake check that fails when a copy in the repository differs from the
  # file in this repository at the pinned version, or is missing. `src` is the
  # repository's own source, its flake's `self`. Since a flake's source holds
  # only the files git tracks, a copy not yet added to git counts as missing.
  check =
    {
      pkgs,
      src,
      files,
    }:
    pkgs.runCommandLocal "tools-files" { } ''
      status=0
      ${forEach files (
        f:
        if builtins.pathExists "${src}/${f.to}" then
          ''
            if ! diff -u '${root}/${f.from}' '${src}/${f.to}'; then
              echo '${f.to} differs from ${f.from} in the tools repository.'
              status=1
            fi
          ''
        else
          ''
            echo '${f.to} is missing, or not added to git.'
            status=1
          ''
      )}
      if [ "$status" -ne 0 ]; then
        echo 'Run `nix run .#sync-tools` to copy the files from the pinned version.'
        exit 1
      fi
      touch "$out"
    '';

  # A flake app that copies the files into the repository, at the top of the
  # git working tree it runs in. Files in the store are read-only, so each
  # copy is given ordinary permissions.
  sync =
    {
      pkgs,
      files,
    }:
    let
      script = pkgs.writeShellApplication {
        name = "sync-tools";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.git
        ];
        text = ''
          top=$(git rev-parse --show-toplevel)
          ${forEach files (f: ''
            install -D -m 644 '${root}/${f.from}' "$top/${f.to}"
            echo 'copied ${f.from} to ${f.to}'
          '')}
        '';
      };
    in
    {
      type = "app";
      program = "${script}/bin/sync-tools";
      meta.description = "Copy the shared files from the pinned tools version";
    };
}
