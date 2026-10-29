{
  description = "agent-vm: AI coding agents in a disposable Linux VM per project";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Linux only for now: on macOS the binary needs cgo, the SDK and the
      # virtualization entitlement (nixpkgs' lima signs it with
      # darwin.sigtool), none of which this build sets up.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The version, the build tags and Lima's version are the Makefile's and
      # third_party/SOURCES's: there is one place to change each.
      linesOf = file: builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile file));
      lineWith =
        file: prefix:
        builtins.head (
          builtins.filter (l: builtins.substring 0 (builtins.stringLength prefix) l == prefix) (linesOf file)
        );
      makeVar =
        name:
        let
          prefix = "${name} := ";
        in
        builtins.substring (builtins.stringLength prefix) (-1) (lineWith ./Makefile prefix);
      # lima  <upstream>  <commit>  <version>  <left out>
      limaVersion = builtins.elemAt (builtins.filter (s: builtins.isString s && s != "") (
        builtins.split " +" (lineWith ./third_party/SOURCES "lima ")
      )) 3;
    in
    {
      packages = forAllSystems (pkgs: rec {
        agent-vm = pkgs.buildGoModule {
          pname = "agent-vm";
          version = makeVar "NEXT_VERSION";
          src = self;

          # The downloaded modules only: a vendor folder would hold
          # third_party/ too (go.mod's replaces), and change with each patch.
          proxyVendor = true;
          # Changes with go.mod and go.sum: set pkgs.lib.fakeHash here, build,
          # and nix prints the new one. release.sh refuses a release when
          # this checksum of `cat go.mod go.sum` is not the current one:
          # update it with the hash.
          # go.mod+go.sum: d2f7908dea2c14beea6faa181d7a4cf4c709f35b94f0cc30392d4d2044f645ba
          vendorHash = "sha256-zfAasYQEKqcrGi4OI3UKJyq3VoUCmNE5lU4JKPtJDmc=";

          subPackages = [ "cmd/agent-vm" ];
          tags = pkgs.lib.splitString "," (makeVar "TAGS");
          env.CGO_ENABLED = "0";
          ldflags = [
            "-s"
            "-w"
            "-X github.com/sylvinus/agent-vm/internal/version.Version=${makeVar "NEXT_VERSION"}"
            "-X github.com/lima-vm/lima/v2/pkg/version.Version=${limaVersion}"
            # QEMU comes with it, first on its PATH (cmd/agent-vm/main.go), as
            # nixpkgs' lima does with a wrapper: a wrapped binary would make
            # `agent-vm install` link past the wrapper. qemu_kvm, this host's
            # architecture only, is a third smaller than qemu. ssh is the
            # system's.
            "-X main.extraPath=${pkgs.lib.makeBinPath [ pkgs.qemu_kvm ]}"
          ];

          nativeBuildInputs = [ pkgs.gzip ];

          # go.mod names the Go the project is developed with, and nixpkgs
          # has it a few days after a release: the build uses nixpkgs' (the
          # sandbox cannot download a toolchain).
          postPatch = ''
            sed -i 's/^go [0-9.]*$/go ${pkgs.go.version}/' go.mod
          '';

          # What the Makefile's `assets` target does: the guest agent runs in
          # the Linux guest, of this machine's architecture, and is embedded
          # in the binary with Lima's templates.
          preBuild =
            let
              guestArch = if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
              assets = "internal/limaembed/assets";
            in
            ''
              go build -trimpath -ldflags "-s -w -X github.com/lima-vm/lima/v2/pkg/version.Version=${limaVersion}" \
                -o ${assets}/lima-guestagent.Linux-${guestArch} github.com/lima-vm/lima/v2/cmd/lima-guestagent
              gzip -9 -n -f ${assets}/lima-guestagent.Linux-${guestArch}
              rm -rf ${assets}/templates
              cp -R third_party/lima/templates ${assets}/templates
            '';

          # The module download shares preBuild with the build, and has no
          # modules to build the guest agent from yet.
          overrideModAttrs = _: {
            preBuild = "";
          };

          # The tests run in CI, on the three platforms.
          doCheck = false;

          meta = {
            description = "Run AI coding agents in a disposable Linux VM per project";
            homepage = "https://www.agent-vm.org/";
            license = pkgs.lib.licenses.mit;
            mainProgram = "agent-vm";
            platforms = systems;
          };
        };
        default = agent-vm;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.agent-vm}/bin/agent-vm";
        };
      });
    };
}
