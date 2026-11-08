# The functions a repository calls from its flake.nix to take files from this
# one. `root` is this repository's source, in the Nix store, and `rev` its
# commit, or null when the source is a working tree with uncommitted changes.
{ root, rev }:
let
  # Every file a repository may take. The repository's own files, such as
  # flake.nix and README.md, are not on the list, so no repository can take
  # one by mistake. .gitignore is not on it either: git does not follow a
  # .gitignore that is a symbolic link, so each repository keeps its own.
  files = [
    ".editorconfig"
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

  # A repository names each file it takes either by its name, to link it at
  # the same path, or as { from = <name>; to = <path>; }, to link it
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

  # A call to a reusable workflow of this repository, as a caller writes it:
  # the path, then @ and a full commit hash. A Forgejo caller writes the same
  # path after https://github.com/. The first group is everything before the
  # hash.
  workflowRef = "(larry0x/tools/\\.github/workflows/[A-Za-z0-9_.-]+@)[0-9a-f]{40}";

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

    # The links point into this repository's source in the Nix store. nix
    # can evaluate a flake input without copying it into the store, so
    # nothing would put the source there, and the links would be broken. A
    # package that refers to the source makes building the dev shell copy
    # it, and keeps it from garbage collection while the shell's own root
    # does.
    (pkgs.runCommandLocal "tools-source" { } ''
      mkdir -p "$out"
      ln -s '${root}' "$out/source"
    '')
  ];

  # A flake check that fails when a file the repository takes is not a link
  # to that file at the pinned version of this repository, or when a CI
  # workflow calls a reusable workflow of this repository at another commit.
  # `src` is the repository's own source, its flake's `self`. A link is read,
  # never followed, so the check works whether or not its target exists.
  check =
    {
      pkgs,
      src,
      files,
    }:
    pkgs.runCommandLocal "tools-links" { } ''
      status=0
      ${forEach files (
        f:
        let
          path = "${src}/${f.to}";
          parent = dirOf path;
          type =
            if builtins.pathExists parent then (builtins.readDir parent).${baseNameOf f.to} or null else null;
        in
        if type == "symlink" then
          ''
            target=$(readlink '${path}')
            if [ "$target" != '${root}/${f.from}' ]; then
              echo "${f.to} links to $target, not to ${f.from} at the pinned version."
              status=1
            fi
          ''
        else if type == null then
          ''
            echo '${f.to} is missing, or not added to git.'
            status=1
          ''
        else
          ''
            echo '${f.to} is not a symbolic link.'
            status=1
          ''
      )}
      ${
        if rev == null then
          ""
        else
          ''
            for dir in ${workflowDirs}; do
              [ -d '${src}'/"$dir" ] || continue
              while IFS= read -r ref; do
                if [ "''${ref##*@}" != '${rev}' ]; then
                  echo "$dir calls $ref, not the pinned commit ${rev}."
                  status=1
                fi
              done < <(grep -rhoE '${workflowRef}' '${src}'/"$dir" || true)
            done
          ''
      }
      if [ "$status" -ne 0 ]; then
        echo 'Run `just sync-tools` to link the files at the pinned version.'
        exit 1
      fi
      touch "$out"
    '';

  # A flake app that links the files into the repository, at the top of the
  # git working tree it runs in, and writes the pinned commit into every call
  # to a reusable workflow of this repository. Each link points into the Nix
  # store, at this repository's source; the path is the same on every
  # machine, so the link resolves wherever nix has fetched the pinned version.
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
            mkdir -p "$(dirname "$top/${f.to}")"
            ln -sfn '${root}/${f.from}' "$top/${f.to}"
            echo 'linked ${f.to} to ${f.from}'
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
                  find "$top/$dir" -name '*.y*ml' -exec sed -i -E 's#${workflowRef}#\1${rev}#g' {} +
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
      meta.description = "Link the shared files from the pinned tools version";
    };
}
