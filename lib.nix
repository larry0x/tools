# The functions a repository calls from its flake.nix to take files from this
# one. `root` is this repository's source, in the Nix store, and `rev` its
# commit, or null when the source is a working tree with uncommitted changes.
{ root, rev }:
let
  # Every file a repository may take. The repository's own files, such as
  # flake.nix and README.md, are not on the list, so no repository can take
  # one by mistake. The CI workflows are not files to take: a repository
  # calls them, from workflows of its own that hold its triggers.
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

  # A call to a reusable workflow of this repository: the workflow's path,
  # then @ and a reference. A GitHub caller writes the path as is; a Forgejo
  # caller writes it after https://github.com/. The reference is the whole
  # of what follows the @, up to a space, a quote, or the end of the line,
  # so that a commit hash, short or full, a branch, or a tag with any of the
  # characters git allows, such as `v1.0.0+build`, is read in full. The
  # first group is everything up to and including the @. The shell receives
  # it through escapeShellArg, since it holds both kinds of quote, and sed
  # uses ~ as its delimiter, which git forbids in a reference.
  workflowCall = "(larry0x/tools/\\.github/workflows/[A-Za-z0-9_.-]+@)[^[:space:]\"']+";

  # The folders that hold a repository's CI workflows.
  workflowDirs = ".github/workflows .forgejo/workflows";
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

  # A flake check that fails when:
  #
  # - a copy in the repository differs from the file in this repository at
  #   the pinned version, or is missing;
  # - a CI workflow calls a reusable workflow of this repository at any
  #   reference but the pinned commit, written in full;
  # - a job in .forgejo/workflows/ calls one without `runs-on`, which makes
  #   Forgejo create no job at all, so CI would look absent, not failing.
  #
  # `src` is the repository's own source, its flake's `self`. Since a flake's
  # source holds only the files git tracks, a copy not yet added to git
  # counts as missing.
  check =
    {
      pkgs,
      src,
      files,
    }:
    pkgs.runCommandLocal "tools-files" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
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
      ${
        if rev == null then
          ''
            echo 'The tools input has uncommitted changes, so the workflow calls are not checked.'
          ''
        else
          ''
            for dir in ${workflowDirs}; do
              [ -d '${src}'/"$dir" ] || continue
              while IFS= read -r call; do
                if [ "''${call#*@}" != '${rev}' ]; then
                  echo "$dir calls $call, not the pinned commit ${rev}."
                  status=1
                fi
              done < <(grep -rhoE ${pkgs.lib.escapeShellArg workflowCall} '${src}'/"$dir" || true)
            done
          ''
      }
      if [ -d '${src}/.forgejo/workflows' ]; then
        for file in '${src}'/.forgejo/workflows/*.y*ml; do
          [ -f "$file" ] || continue
          jobs=$(yq -r '.jobs // {} | to_entries[] | select((.value.uses // "") | test("larry0x/tools/")) | select(.value["runs-on"] == null) | .key' "$file")
          for job in $jobs; do
            echo ".forgejo/workflows/$(basename "$file"): job $job calls a tools workflow without runs-on, so Forgejo would create no job for it."
            status=1
          done
        done
      fi
      if [ "$status" -ne 0 ]; then
        echo 'Run `just sync-tools` to copy the files and pin the workflow calls at the pinned version. It does not add runs-on.'
        exit 1
      fi
      touch "$out"
    '';

  # A flake app that copies the files into the repository, at the top of the
  # git working tree it runs in, and writes the pinned commit into every call
  # to a reusable workflow of this repository, whatever reference it named
  # before. Files in the store are read-only, so each copy is given ordinary
  # permissions.
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
          pkgs.findutils
          pkgs.git
          pkgs.gnused
        ];
        text = ''
          top=$(git rev-parse --show-toplevel)
          ${forEach files (f: ''
            install -D -m 644 '${root}/${f.from}' "$top/${f.to}"
            echo 'copied ${f.from} to ${f.to}'
          '')}
          ${
            if rev == null then
              ''
                echo 'The tools input has uncommitted changes, so the workflow calls are left as they are.'
              ''
            else
              ''
                for dir in ${workflowDirs}; do
                  [ -d "$top/$dir" ] || continue
                  find "$top/$dir" -name '*.y*ml' -exec sed -i -E "s~"${pkgs.lib.escapeShellArg workflowCall}"~\\1${rev}~g" {} +
                done
                echo 'pinned the workflow calls to ${rev}'
              ''
          }
        '';
      };
    in
    {
      type = "app";
      program = "${script}/bin/sync-tools";
      meta.description = "Copy the shared files, and pin the workflow calls, at the pinned tools version";
    };
}
