# nosecret - nixos values deployment helper

**Experimental** This is not well tested.

### Configuration:

Import module:
```nix
  inputs.nosecret.url = "github:yvesf/nix-nosecret";
  outputs = { self, ... }:
    {
      nixosConfigurations."hostname" = self.inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ 
          self.inputs.nosecret.nixosModules.default
          # ...
```

Define values:
```nix
  # keep valus in seperate encrypted file
  nosecret.values = import ./secret.nix;
```

`secret.nix`:
```nix
{
  sshSecretKey = {
    content = ''
      -----BEGIN OPENSSH PRIVATE KEY-----
      ...
      -----END OPENSSH PRIVATE KEY-----
    '';
  };
  diskPassphrase.content = "foobar";
}
```

example with using values:
```nix
systemd.services.cryptsetupOpen = {
  path = with pkgs; [ cryptsetup util-linux ];
  script = ''
    if [[ -e ${config.nosecret.file.diskPassphrase} ]]; then
      for disk in ABCDEFG; do
        test -e /dev/mapper/$disk && continue
        cryptsetup open --type luks /dev/disk/by-partlabel/''${disk}.crypt ''${disk} --key-file ${config.nosecret.file.diskPassphrase}
      done
    fi
    lsblk
  '';
  serviceConfig = {
    Type = "oneshot";
  };
  after = [ "network.target" ];
};
systemd.paths.cryptsetupOpen = {
  pathConfig.PathChanged = config.nosecret.file.diskPassphrase;
  wantedBy = [ "multi-user.target" ];
};
```

Deployment of values after system change:
```bash
$ TARGET=hostname
$ nixos-rebuild --use-remote-sudo --target-host jack@${TARGET} --flake .#${TARGET} switch
$ nix run .#nixosConfigurations.${TARGET}.pkgs.nosecret -- --use-remote-sudo --target-host jack@${TARGET} .#${TARGET}
```


### git-crypt
https://github.com/AGWA/git-crypt can be used for `secrets.nix` file.

`.gitattributes`:
```
secret.nix filter=git-crypt diff=git-crypt
```