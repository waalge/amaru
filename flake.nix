{
  description = "Amaru: a cardano node";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;}
    {
      systems = ["x86_64-linux" "aarch64-darwin"];

      flake.nixosModules = {
        amaru = import ./nix/modules/amaru.nix;
        default = import ./nix/modules/amaru.nix;
      };

      perSystem = {
        system,
        ...
      }: let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [(import inputs.rust-overlay)];
        };

        toolchain = (pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml).override {
          extensions = ["rust-src" "rust-analyzer" "clippy"];
        };

        craneLib = (inputs.crane.mkLib pkgs).overrideToolchain toolchain;

        # Deliberately broader than `craneLib.cleanCargoSource` (which keeps only .rs/.toml):
        # test code throughout the workspace pulls in binary/text fixtures via `include_bytes!`.
        # Scoped to what cargo actually touches, though: everything under `crates/` (so fixtures
        # stay included wherever they live) plus the handful of root config files cargo/rustc
        # read. This keeps repo-root docs/CHANGELOG/EDR/etc. edits from busting the derivation
        # cache and forcing a full rebuild.
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./crates
            ./Cargo.toml
            ./Cargo.lock
            ./rust-toolchain.toml
            ./rustfmt.toml
            ./.cargo
          ];
        };

        nativeBuildInputs = with pkgs; [pkg-config rustPlatform.bindgenHook rocksdb git];
        buildInputs = [pkgs.openssl.dev];

        commonArgs = {
          inherit src nativeBuildInputs buildInputs;
          inherit (craneLib.crateNameFromCargoToml {cargoToml = ./crates/amaru/Cargo.toml;}) pname version;
          strictDeps = true;

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          # The fetch (from cardano-foundation/cardano-configurations) needs network
          # access, which the Nix sandbox doesn't have. CI instead stages the real snapshots
          # before building (.github/actions/stage-peer-snapshots) and sets this same flag so
          # build.rs skips fetching and reuses them. Here we only stage empty placeholders, an
          # explicitly supported offline fallback (see peer_snapshot.rs's own error message) --
          # it keeps the build working, but a `nix build`-produced binary ships with no embedded
          # big-ledger-pool peers, unlike CI/release binaries. At runtime that's not fatal (the
          # node falls back to a single default bootstrap peer per network), just less robust.
          AMARU_SKIP_PEER_SNAPSHOT_FETCH = "1";

          postPatch = ''
            if [ ! -d .git ]; then
              git init -q
              git config user.email "nix@localhost"
              git config user.name "nix"
              git add -A
              git commit -q -m "nix build" --allow-empty
            fi

            for net_magic in mainnet:764824073 preprod:1 preview:2; do
              net=''${net_magic%%:*}
              magic=''${net_magic##*:}
              mkdir -p "crates/amaru-node/config/peer-snapshots/$net"
              cat > "crates/amaru-node/config/peer-snapshots/$net/peer-snapshot.json" <<EOF
            { "NetworkMagic": $magic, "NodeToClientVersion": 23, "Point": { "blockPointHash": "0000000000000000000000000000000000000000000000000000000000000000", "blockPointSlot": 0 }, "bigLedgerPools": [] }
            EOF
            done
          '';
        };

        cargoArtifacts = craneLib.buildDepsOnly (commonArgs
          // {
            pname = "amaru-workspace";
            cargoExtraArgs = "--workspace";
          });

        amaru = craneLib.buildPackage (commonArgs
          // {
            inherit cargoArtifacts;
            cargoExtraArgs = "-p amaru";
            # `buildPackage` defaults to also running `cargo test` here. 
            doCheck = false;
            meta.description = "A Cardano blockchain node implementation";
          });
      in {
        packages = {
          default = amaru;
          inherit amaru;
        };

        checks = {
          inherit amaru;

          clippy = craneLib.cargoClippy (commonArgs
            // {
              inherit cargoArtifacts;
              pname = "amaru-workspace";
              cargoClippyExtraArgs = "--workspace --all-targets -- -D warnings";
            });

          fmt = craneLib.cargoFmt {inherit src;};

          # Mirrors the `cargo doc --no-deps --workspace` step in ci-coding-practices.yml.
          doc = craneLib.cargoDoc (commonArgs
            // {
              inherit cargoArtifacts;
              pname = "amaru-workspace";
              cargoExtraArgs = "--workspace";
              env.RUSTDOCFLAGS = "-D warnings";
            });
        };

        devShells.default = pkgs.mkShell {
          name = "dev-shell";
          packages = [toolchain] ++ nativeBuildInputs;
          inherit buildInputs;
          LIBCLANG_PATH = commonArgs.LIBCLANG_PATH;
        };
      };
    };
}
