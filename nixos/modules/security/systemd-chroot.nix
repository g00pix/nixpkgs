{ config, pkgs, lib, ... }:

let
  inherit (lib) types;
  inherit (import ../system/boot/systemd-lib.nix {
    inherit config pkgs lib;
  }) mkPathSafeName;
in {
  options.systemd.services = lib.mkOption {
    type = types.attrsOf (types.submodule ({ name, config, ... }: {
      options.chroot.enable = lib.mkOption {
        type = types.bool;
        default = false;
        description = ''
          If set, all the required runtime store paths for this service are
          bind-mounted into a <literal>tmpfs</literal>-based <citerefentry>
            <refentrytitle>chroot</refentrytitle>
            <manvolnum>2</manvolnum>
          </citerefentry>.
        '';
      };

      options.chroot.packages = lib.mkOption {
        type = types.listOf (types.either types.str types.package);
        default = [];
        description = let
          mkScOption = optName: "<option>serviceConfig.${optName}</option>";
        in ''
          Additional packages or strings with context to add to the closure of
          the chroot. By default, this includes all the packages from the
          ${lib.concatMapStringsSep ", " mkScOption [
            "ExecReload" "ExecStartPost" "ExecStartPre" "ExecStop"
            "ExecStopPost"
          ]} and ${mkScOption "ExecStart"} options.

          <note><para><emphasis role="strong">Only</emphasis> the latter
          (${mkScOption "ExecStart"}) will be used if
          ${mkScOption "RootDirectoryStartOnly"} is enabled.</para></note>

          <note><para>Also, the store paths listed in <option>path</option> are
          <emphasis role="strong">not</emphasis> included in the closure as
          well as paths from other options except those listed
          above.</para></note>
        '';
      };

      options.chroot.withBinSh = lib.mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to symlink <command>dash</command> as
          <filename>/bin/sh</filename> to the chroot.

          This is useful for some applications, which for example use the
          <citerefentry>
            <refentrytitle>system</refentrytitle>
            <manvolnum>3</manvolnum>
          </citerefentry> library function to execute commands.
        '';
      };

      options.chroot.confinement = lib.mkOption {
        type = types.enum [ "full-apivfs" "chroot-only" ];
        default = "full-apivfs";
        description = ''
          The value <literal>full-apivfs</literal> (the default) sets up
          private <filename class="directory">/dev</filename>, <filename
          class="directory">/proc</filename>, <filename
          class="directory">/sys</filename> and <filename
          class="directory">/tmp</filename> file systems in a separate user
          name space.

          If this is set to <literal>chroot-only</literal>, only the file
          system name space is set up along with the call to <citerefentry>
            <refentrytitle>chroot</refentrytitle>
            <manvolnum>2</manvolnum>
          </citerefentry>.

          <note><para>This doesn't cover network namespaces and is solely for
          file system level isolation.</para></note>
        '';
      };

      config = lib.mkIf config.chroot.enable {
        serviceConfig = let
          rootName = "${mkPathSafeName name}-chroot";
        in {
          RootDirectory = pkgs.runCommand rootName {} "mkdir \"$out\"";
          TemporaryFileSystem = "/";
          MountFlags = lib.mkDefault "private";
        } // lib.optionalAttrs config.chroot.withBinSh {
          BindReadOnlyPaths = [ "${pkgs.dash}/bin/dash:/bin/sh" ];
        } // lib.optionalAttrs (config.chroot.confinement == "full-apivfs") {
          MountAPIVFS = true;
          PrivateDevices = true;
          PrivateTmp = true;
          PrivateUsers = true;
          ProtectControlGroups = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
        };
        chroot.packages = let
          startOnly = config.serviceConfig.RootDirectoryStartOnly or false;
          execOpts = if startOnly then [ "ExecStart" ] else [
            "ExecReload" "ExecStart" "ExecStartPost" "ExecStartPre" "ExecStop"
            "ExecStopPost"
          ];
          execPkgs = lib.concatMap (opt: let
            isSet = config.serviceConfig ? ${opt};
          in lib.optional isSet config.serviceConfig.${opt}) execOpts;
        in execPkgs ++ lib.optional config.chroot.withBinSh pkgs.dash;
      };
    }));
  };

  config.assertions = lib.concatLists (lib.mapAttrsToList (name: cfg: let
    whatOpt = optName: "The 'serviceConfig' option '${optName}' for"
                    + " service '${name}' is enabled in conjunction with"
                    + " 'chroot.enable'";
  in lib.optionals cfg.chroot.enable [
    { assertion = !cfg.serviceConfig.RootDirectoryStartOnly or false;
      message = "${whatOpt "RootDirectoryStartOnly"}, but right now systemd"
              + " doesn't support restricting bind-mounts to 'ExecStart'."
              + " Please either define a separate service or find a way to run"
              + " commands other than ExecStart within the chroot.";
    }
    { assertion = !cfg.serviceConfig.DynamicUser or false;
      message = "${whatOpt "DynamicUser"}. Please create a dedicated user via"
              + " the 'users.users' option instead as this combination is"
              + " currently not supported.";
    }
  ]) config.systemd.services);

  config.systemd.packages = lib.concatLists (lib.mapAttrsToList (name: cfg: let
    rootPaths = let
      contents = lib.concatStringsSep "\n" cfg.chroot.packages;
    in pkgs.writeText "${mkPathSafeName name}-string-contexts.txt" contents;

    chrootPaths = pkgs.runCommand "${mkPathSafeName name}-chroot-paths" {
      closureInfo = pkgs.closureInfo { inherit rootPaths; };
      serviceName = "${name}.service";
      excludedPath = rootPaths;
    } ''
      mkdir -p "$out/lib/systemd/system"
      serviceFile="$out/lib/systemd/system/$serviceName"

      echo '[Service]' > "$serviceFile"

      while read storePath; do
        if [ -L "$storePath" ]; then
          # Currently, systemd can't cope with symlinks in Bind(ReadOnly)Paths,
          # so let's just bind-mount the target to that location.
          echo "BindReadOnlyPaths=$(readlink -e "$storePath"):$storePath"
        elif [ "$storePath" != "$excludedPath" ]; then
          echo "BindReadOnlyPaths=$storePath"
        fi
      done < "$closureInfo/store-paths" >> "$serviceFile"
    '';
  in lib.optional cfg.chroot.enable chrootPaths) config.systemd.services);
}
