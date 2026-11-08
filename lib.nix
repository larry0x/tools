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

  # A call to a reusable workflow of this repository is the `uses` value of a
  # job, which names the workflow's path, then @ and a reference: a commit
  # hash, short or full, a branch, or a tag. A GitHub caller writes the path
  # as is; a Forgejo caller writes it after https://github.com/. Only a job's
  # `uses` calls a workflow; a step's names an action. The value is read
  # from the YAML, so the punctuation around it, such as the braces of a
  # flow mapping, is never taken for part of it.
  workflowPath = "larry0x/tools/.github/workflows/";

  # A yq program that prints every such value in a workflow file, one per
  # line.
  listCalls = ''.jobs // {} | .[] | .uses // "" | select(test("larry0x/tools/\\.github/workflows/"))'';

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
              for file in '${src}'/"$dir"/*.y*ml; do
                [ -f "$file" ] || continue
                while IFS= read -r call; do
                  rest=''${call#*${workflowPath}}
                  if [ "''${rest#*@}" != '${rev}' ]; then
                    echo "$dir/$(basename "$file") calls $call, not the pinned commit ${rev}."
                    status=1
                  fi
                done < <(yq -r ${pkgs.lib.escapeShellArg listCalls} "$file")
              done
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
          pkgs.gawk
          pkgs.git
          pkgs.gnused
          pkgs.yq-go
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
                # Each value is replaced as a literal string, so nothing
                # around it changes. The longest values go first, so that one
                # which begins another, such as @main and @main-v2, cannot
                # replace part of it. sed uses ~ as its delimiter, which git
                # forbids in a reference.
                for dir in ${workflowDirs}; do
                  for file in "$top/$dir"/*.y*ml; do
                    [ -f "$file" ] || continue
                    while IFS= read -r call; do
                      rest=''${call#*${workflowPath}}
                      new="''${call%%${workflowPath}*}${workflowPath}''${rest%%@*}@${rev}"
                      old=$(printf '%s' "$call" | sed 's/[][\\.*^$~]/\\&/g')
                      sed -i "s~$old~$new~g" "$file"
                    done < <(yq -r ${pkgs.lib.escapeShellArg listCalls} "$file" | sort -u | awk '{ print length($0) "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr | cut -f2-)
                  done
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
