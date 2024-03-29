{
  outputs = { self, ... }:
    let
      nosecretHelper = { writeShellApplication }:
        writeShellApplication {
          name = "nosecret";
          runtimeInputs = [ ];
          text = ''
            OPTS=""
            targetConfig=
            targetHost=
            while [ "$#" -gt 0 ]; do
                i="$1"; shift 1
                case "$i" in
                --help|-h)
                  echo "$0 [{--target-host|-t} host] [--use-remote-sudo] flake-uri"
                  exit 0
                ;;
                --target-host|t)
                  targetHost="$1"
                  shift 1
                  ;;
                --use-remote-sudo)
                  OPTS="$OPTS sudo"
                  ;;
                *#*)
                  targetConfig="$i"
                  ;;
                *)
                  echo "$0: unknown option \`$i'"
                  exit 1
                  ;;
              esac
            done
            if [ -z "$targetConfig" ]; then
              echo "missing target config" >&2
              exit 1
            fi
            if [ -z "$targetHost" ]; then
              targetHost="''${targetConfig#*#}"
            fi

            # shellcheck disable=SC2086
            nix eval --raw ".#nixosConfigurations.''${targetConfig#*#}.config.system.build.nosecretScript" --apply 'f: f {}' \
              | ssh ''${NIX_SSHOPTS:=} "$targetHost" $OPTS bash -
          '';
        };
    in
    {
      nixosModules.default =
        { config, lib, pkgs, ... }:
          with lib;
          let
            cfg = config.nosecret;
          in
          {
            options.nosecret =
              let
                secretType = types.submodule ({ config, ... }: {
                  options = {
                    content = mkOption { type = types.str; description = "content of secret."; apply = value: { confirm ? false }: if confirm then value else throw "reading not allowed"; };
                    mode = mkOption { type = types.str; default = "0400"; description = "File permissions in octal."; };
                    owner = mkOption { type = types.str; default = "root"; description = "Owner user name."; };
                    group = mkOption { type = types.str; default = "root"; description = "Owner group name."; };
                  };
                });
              in
              {
                directory = mkOption { type = types.path; default = "/run/nosecret"; description = "Folder where values will be written."; };
                values = mkOption { type = types.attrsOf secretType; default = { }; description = "the defined values to be mapped."; };
                file = mkOption { type = types.attrsOf types.string; description = "will be populated with the path to the secret. do not set."; };
                allowReading = mkOption { type = types.bool; default = false; description = "internal; do not set"; };
              };

            config =
              let
                tag = config.system.nixos.revision;
                secretGenerator = name:
                  let
                    secret = cfg.values."${name}";
                    filename = concatStringsSep "/" [ cfg.directory name ];
                  in
                  ''
                    touch ${filename}
                    ${optionalString (secret.mode != "") "chmod ${secret.mode} '${filename}'"}
                    ${optionalString (secret.owner != "") "chown ${secret.owner} '${filename}'"}
                    ${optionalString (secret.group != "") "chown ${secret.group} '${filename}'"}
                    cat <<"END_OF_SECRET_${tag}" | head -c -1 > '${filename}'
                    ${secret.content {confirm = true;}}
                    END_OF_SECRET_${tag}
                    rm -f '${filename}.missing'
                  '';
              in
              mkIf (cfg.values != { }) {
                system.build.nosecretScript = {}:
                  ''
                    #!${pkgs.runtimeShell}
                    set -e -o pipefail
                    ${concatStringsSep "\n" (map secretGenerator (attrNames cfg.values))}
                  '';

                nosecret.file = listToAttrs (map
                  (name: nameValuePair name (concatStringsSep "/" [ cfg.directory name ]))
                  (attrNames cfg.values));

                nixpkgs.config.packageOverrides = _: {
                  nosecret = pkgs.callPackage nosecretHelper { };
                };

                system.activationScripts.nosecret = {
                  text = ''
                    mkdir -p '${cfg.directory}'
                    if ! grep -q '${cfg.directory} ramfs' /proc/mounts; then
                      echo '[nosecret] mount ramfs in ${cfg.directory}'
                      mount -t ramfs none '${cfg.directory}' -o nodev,nosuid,mode=0751
                    fi

                    echo '[nosecret] Processing secret files in ${cfg.directory}'
                    for existingFile in '${cfg.directory}'/*; do
                      name=$(basename "$existingFile")
                      for f in ${concatStringsSep " " (attrNames cfg.values)}; do
                        if [ "$f" == "$name" ] || [ "$f.missing" == "$name" ]; then
                          continue 2
                        fi
                      done
                      echo "[nosecret] delete obsolete file $existingFile"
                      rm "$existingFile"
                    done

                    for f in ${concatStringsSep " " (attrNames cfg.values)}; do
                      if [ -f "${cfg.directory}/$f" ] || [ -f "${cfg.directory}/$f.missing" ]; then
                        : file exists already
                      else
                        echo "[nosecret] create marker file to ${cfg.directory}/$f.missing"
                        touch touch '${cfg.directory}'"/''${f}.missing"
                      fi
                    done
                  '';
                  deps = [ "specialfs" ];
                };
              };
          };
    };
}
