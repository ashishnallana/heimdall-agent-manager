{
  description = "Heimdall Agent Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-darwin-x86.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    # crane: hermetic Rust builds for the ham-pty-host spike (PTYH-4). Follows
    # our nixpkgs so the Rust toolchain comes from the same pinned set.
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, nixpkgs-darwin-x86, crane }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system:
        if system == "x86_64-darwin" then
          import nixpkgs-darwin-x86 {
            inherit system;
            config.allowDeprecatedx86_64Darwin = true;
          }
        else
          import nixpkgs { inherit system; };

      # Keep appVersion in sync with src/contracts/protocol.odin APP_VERSION.
      appVersion = "0.4.40";
      npmDepsHash = "sha256-yqdyHi5qX8vpKt6LfHFcln3+adOfndg5QIiUBTeSB48=";

      mkOdinPackage = pkgs: odin: name: srcDir: pkgs.stdenv.mkDerivation {
        pname = name;
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          # BT-6: regenerate the static-skills table from src/prompts/skills/ before
          # compiling any package that embeds the hub agent service (the golden test
          # imports it). Committed + regenerated-clean so local `odin build` also works.
          ${if name == "ham-bootstrap-golden-test" then "odin run tools/gen_static_skills -collection:odin_test=src -- src/prompts/skills src/hub/service/agent/static_skills_gen.odin" else ""}
          odin build ${srcDir} -collection:odin_test=src -define:HAM_APP_VERSION=${appVersion} -out:$out/bin/${name}
          ${if name == "ham-test-agent" then "ln -s ham-test-agent $out/bin/bc-test-agent" else ""}
          runHook postBuild
        '';
      };

      mkOdinPackageWithRuntime = pkgs: odin: name: srcDir: runtimeInputs: pkgs.stdenv.mkDerivation {
        pname = name;
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin pkgs.makeWrapper ];
        buildInputs = runtimeInputs;
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          # BT-6: regenerate the static-skills table from src/prompts/skills/ before
          # the hub compile so the STATIC_SKILLS set can never drift from the folder.
          # Committed to the repo (reviewable) + regenerated here (verify-clean).
          ${if name == "ham-hub" then "odin run tools/gen_static_skills -collection:odin_test=src -- src/prompts/skills src/hub/service/agent/static_skills_gen.odin" else ""}
          odin build ${srcDir} -collection:odin_test=src -define:HAM_APP_VERSION=${appVersion} -out:$out/bin/${name}
          wrapProgram $out/bin/${name} --prefix PATH : ${pkgs.lib.makeBinPath runtimeInputs}
          # Bundle the hub migrations SQL into the store output so the apps.hub
          # wrapper can inject an absolute --migrations-dir (NRX-1/NRX-4) and
          # `nix run .#hub` works from any CWD.
          ${if name == "ham-hub" then "mkdir -p $out/share/ham-hub && cp -r src/hub/repository/sqlite/migrations $out/share/ham-hub/migrations" else ""}
          ${if name == "ham-bridge" then "mkdir -p $out/share/heimdall && cp -r extensions $out/share/heimdall/extensions" else ""}
          ${if name == "ham-bridge" then "ln -s ${pkgs.openssl}/bin/openssl $out/bin/openssl" else ""}
          # SOCAT-1: socat is the default bridge->hub TLS transport (HAM_TLS_BACKEND);
          # openssl above stays for the s_client fallback + socat's OpenSSL engine.
          ${if name == "ham-bridge" then "ln -s ${pkgs.socat}/bin/socat $out/bin/socat" else ""}
          ${if name == "ham-test-agent" then "ln -s ham-test-agent $out/bin/bc-test-agent" else ""}
          runHook postBuild
        '';
      };

      mkOdinCtlPackage = pkgs: odin: pkgs.stdenv.mkDerivation {
        pname = "ham-ctl";
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build src/ctl -collection:odin_test=src -define:HAM_APP_VERSION=${appVersion} -out:$out/bin/ham-ctl
          runHook postBuild
        '';
      };

      # REQ-INST-16: portable release binaries. The regular attrs above are
      # Nix-native (wrapProgram + nix-store runtime deps, ELF interpreter
      # under /nix/store) and CANNOT run on hosts without /nix/store -- which
      # is every machine the public tarballs target. The release workflow
      # used to build the regular attrs, which is how bin/ham-bridge shipped
      # as a 652-byte nix wrapper script. These release attrs build the same
      # sources for the tarball:
      #   Linux (Odin): fully static glibc via -static -no-pie against
      #     glibc.static. odin's own -lm/-lc land earlier in the link line
      #     but GNU ld resolves them from -L${glibc.static}/lib anyway.
      #   Darwin (Odin): plain build; the Mach-O load commands are already
      #     clean (/usr/lib/libSystem + system frameworks).
      # Never wrapProgram and never stage nix-store runtime deps here.
      mkReleaseOdinPackage = pkgs: odin: name: srcDir: pkgs.stdenv.mkDerivation {
        pname = "release-${name}";
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        buildInputs = pkgs.lib.optionals (name == "ham-bridge") [ pkgs.sqlite ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build ${srcDir} -collection:odin_test=src -define:HAM_APP_VERSION=${appVersion} -out:$out/bin/${name} \
            ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''-extra-linker-flags:"-static -no-pie -L${pkgs.glibc.static}/lib ${pkgs.lib.optionalString (name == "ham-bridge") "-L${pkgs.sqlite.out}/lib"}"''}
          runHook postBuild
        '';
      };

      # T12: the termux-arm64 bundle's Odin binaries. Android's app seccomp
      # allowlist is bionic-derived and SIGSYS-kills a process on syscalls bionic
      # never makes; static glibc calls set_robust_list unconditionally in
      # __libc_setup_tls (device trace, Android 15: execve, brk, brk,
      # set_tid_address, set_robust_list -> SIGSYS SYS_SECCOMP), so NO
      # glibc-static binary starts under Termux. musl registers no robust list at
      # start-up, uses clone (not clone3) and never calls rseq.
      # Odin hard-codes `-lpthread -lm -lc` on its link line and links through
      # `clang`, unless ODIN_CLANG_PATH names another driver (Odin
      # src/linker.cpp). Pointing it at the musl cross cc-wrapper makes that
      # wrapper supply musl's crt1/crti/crtn, libc.a and libgcc -- libgcc matters
      # on aarch64, where musl's long-double code calls the soft-float __*tf3
      # helpers. -static -no-pie: a plain static ELF, no PT_INTERP.
      # Built for linux_arm64 from either Linux host (Odin cross-codegens
      # natively; the wrapper is pkgsCross, the same set mkReleasePtyHost uses).
      # The linux-* release attrs above stay glibc-static and untouched.
      # HAM_RELEASE_TARGET=termux-arm64 (src/contracts/release_target.odin) makes
      # the bridge hello, Hub update catalog and `heimdall update` resolve the
      # termux bundle instead of linux-arm64, whose glibc dies under Android's
      # seccomp filter (REQ-T13-1).
      mkTermuxOdinPackage = pkgs: odin: name: srcDir:
        let
          muslPkgs = pkgs.pkgsCross.aarch64-multiplatform-musl;
          muslCc = muslPkgs.stdenv.cc;
          # sqlite's own test suite (make devtest) fails under the aarch64-musl
          # cross build; we only need the static library, so skip its checks.
          muslSqlite = muslPkgs.sqlite.overrideAttrs (_: { doCheck = false; });
        in
        pkgs.stdenv.mkDerivation {
          pname = "release-termux-${name}";
          version = appVersion;
          src = ./.;
          nativeBuildInputs = [ odin ];
          buildInputs = pkgs.lib.optionals (name == "ham-bridge") [ muslSqlite ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            runHook preBuild
            mkdir -p $out/bin
            ODIN_CLANG_PATH=${muslCc}/bin/${muslCc.targetPrefix}cc \
              odin build ${srcDir} -target:linux_arm64 -collection:odin_test=src -define:HAM_APP_VERSION=${appVersion} -define:HAM_RELEASE_TARGET=termux-arm64 \
              -out:$out/bin/${name} -extra-linker-flags:"-static -no-pie ${pkgs.lib.optionalString (name == "ham-bridge") "-L${muslSqlite.out}/lib"}"
            runHook postBuild
          '';
        };

      mkOdinUiPackage = pkgs: pkgs.buildNpmPackage {
        pname = "heimdall";
        version = appVersion;
        src = ./.;
        inherit npmDepsHash;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        npmBuildScript = "build";
        npmFlags = [ "--ignore-scripts" "--legacy-peer-deps" ];
        npmInstallFlags = [ "--ignore-scripts" "--legacy-peer-deps" ];
        installPhase = ''
          runHook preInstall
          mkdir -p $out/share/heimdall/{dist,electron-dist}
          cp -r dist/* $out/share/heimdall/dist/
          cp -r electron-dist/* $out/share/heimdall/electron-dist/
          mkdir -p $out/bin
          makeWrapper ${pkgs.electron}/bin/electron $out/bin/heimdall \
            --add-flags "$out/share/heimdall/electron-dist/main.cjs"
          runHook postInstall
        '';
      };

      mkNodeModules = pkgs: pkgs.buildNpmPackage {
        pname = "heimdall-node-modules";
        version = appVersion;
        src = ./.;
        inherit npmDepsHash;
        dontBuild = true;
        npmFlags = [ "--ignore-scripts" "--legacy-peer-deps" ];
        npmInstallFlags = [ "--ignore-scripts" "--legacy-peer-deps" ];
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r node_modules $out/node_modules
          runHook postInstall
        '';
      };

      # PTYH-4: hermetic Rust build for tools/pty_host via crane. Kept fully
      # separate from the Odin targets. Uses the default rustc/cargo from the
      # pinned nixpkgs (no rustup, no network fetches at build time).
      mkPtyHost = pkgs:
        let
          craneLib = crane.mkLib pkgs;
          src = craneLib.cleanCargoSource ./tools/pty_host;
          commonArgs = {
            inherit src;
            strictDeps = true;
            # portable-pty / crossterm need no extra system libs on Linux; on
            # Darwin the default clang stdenv suffices. Keep buildInputs minimal.
            buildInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin [ ];
          };
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        in
        craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          pname = "ham-pty-host";
          version = appVersion;
          doCheck = true;
          # Server/host tests bind unix sockets + spawn shells; run them serially
          # to avoid cross-test socket contention. Tests that need a POSIX shell
          # skip gracefully when one isn't on PATH (the nix sandbox has no
          # /bin/sh), so the suite stays green hermetically.
          cargoTestExtraArgs = "-- --test-threads=1";
        });

      # REQ-INST-16: release ham-pty-host. Linux cross-builds against musl via
      # crane (pkgsCross.*-musl) with +crt-static, yielding a static-PIE binary
      # with no loader at all -- cargo's link invocation is fully controllable,
      # which is what makes musl practical here where odin's hard-coded
      # -lc/-lm makes glibc-static the simpler path. Darwin keeps the plain
      # clang build; package-local-binary-tarball.sh rewrites its single nix
      # dylib (libiconv) to /usr/lib when staging the tarball.
      mkReleasePtyHost = pkgs:
        if pkgs.stdenv.hostPlatform.isDarwin then
          mkPtyHost pkgs
        else
          let
            crossPkgs =
              if pkgs.stdenv.hostPlatform.isAarch64 then
                pkgs.pkgsCross.aarch64-multiplatform-musl
              else
                pkgs.pkgsCross.musl64;
            craneLib = crane.mkLib crossPkgs;
            src = craneLib.cleanCargoSource ./tools/pty_host;
            rustTarget = crossPkgs.stdenv.hostPlatform.rust.rustcTarget;
            rustflagsEnv = "CARGO_TARGET_${pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] rustTarget)}_RUSTFLAGS";
            commonArgs = {
              inherit src;
              strictDeps = true;
            };
            cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
              pname = "ham-pty-host";
              version = appVersion;
              cargoToml = ./tools/pty_host/Cargo.toml;
            });
          in
          craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;
            pname = "ham-pty-host";
            version = appVersion;
            # Cross-built: cargo cannot execute the foreign test binaries
            # without qemu; the native ham-pty-host attr keeps doCheck=true.
            doCheck = false;
          } // pkgs.lib.listToAttrs [
            (pkgs.lib.nameValuePair rustflagsEnv "-C target-feature=+crt-static")
          ]);

      mkOdin = pkgs:
        let
          # x86_64-darwin builds from nixpkgs-26.05-darwin (26.11 dropped it), whose
          # Odin (dev-2026-05) predates the core:crypto ecdsa/ecdh API the vault uses
          # (`private_key_public_bytes`, `curve`). Build that target's Odin from the
          # main nixpkgs recipe so every release target compiles with one compiler;
          # callPackage on the recipe keeps its patches matched to its source.
          baseOdin =
            if pkgs.stdenv.hostPlatform.system == "x86_64-darwin" then
              pkgs.callPackage "${nixpkgs}/pkgs/by-name/od/odin/package.nix" { }
            else
              pkgs.odin;
          fArgs = baseOdin.override.__functionArgs or {};
        in
        if fArgs ? llvmPackages then
          baseOdin.override { llvmPackages = pkgs.llvmPackages_21; }
        else if fArgs ? llvmPackages_18 then
          baseOdin.override { llvmPackages_18 = pkgs.llvmPackages_21; }
        else
          baseOdin;

      homeManagerModule = import ./nix/home-manager.nix { inherit self; };
    in
    {
      homeModules.default = homeManagerModule;
      homeManagerModules.default = homeManagerModule;

      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          # On current nixpkgs-unstable Darwin, pkgs.odin's default LLVM 18 path can
          # try to locally build compiler-rt against a newer Apple SDK/libc++ and fail.
          # Building Odin with LLVM 21 avoids that compiler-rt mismatch and stays on
          # nixpkgs-unstable.
          odin = mkOdin pkgs;
        in
        {
          # sqlite backs the hub repository. openssl + socat are the OUTBOUND https
          # transport: the hub's own REST calls (e.g. the Paddle billing API) go through
          # src/lib/http_client, which terminates TLS by launching `socat` (the default)
          # or `openssl s_client` (HAM_TLS_BACKEND=s_client). Without both on the wrapped
          # PATH every outbound https call fails at subprocess spawn — the hub never
          # reaches the remote and reports a generic "could not contact" error. Same
          # shared contract as ham-bridge below; keep the two in sync.
          ham-hub = mkOdinPackageWithRuntime pkgs odin "ham-hub" "src/hub" [ pkgs.sqlite pkgs.openssl pkgs.socat ];
          # SOCAT-1: socat is the DEFAULT bridge->hub TLS transport (HAM_TLS_BACKEND),
          # openssl stays for the s_client fallback (and socat's own OpenSSL engine).
          # curl handles release downloads; all three are runtimeInputs so the
          # wrapped bridge has deterministic tools on PATH.
          ham-bridge = mkOdinPackageWithRuntime pkgs odin "ham-bridge" "src/bridge" [ pkgs.sqlite pkgs.curl pkgs.openssl pkgs.socat ];
          ham-dev-proxy = mkOdinPackage pkgs odin "ham-dev-proxy" "src/dev_proxy";
          ham-ctl = mkOdinCtlPackage pkgs odin;
          ham-test-agent = mkOdinPackage pkgs odin "ham-test-agent" "src/test_agent";
          ham-task-store-repository-test = mkOdinPackageWithRuntime pkgs odin "ham-task-store-repository-test" "tests/task_store_repository_test" [ pkgs.sqlite ];
          # Web Push (WP-TEST-SERVER): the crypto vector test reproduces the RFC
          # 8291 Appendix A example; the repo test exercises the push_subscriptions
          # sqlite repo (needs sqlite for the migration run).
          ham-push-crypto-test = mkOdinPackage pkgs odin "ham-push-crypto-test" "tests/push_crypto_test";
          ham-push-repo-test = mkOdinPackageWithRuntime pkgs odin "ham-push-repo-test" "tests/push_repo_test" [ pkgs.sqlite ];
          # TC-API: unit-tests the project-grouped / per-project task-chains list
          # helpers (grouping, 5-preview cap, updated_at cursor pagination,
          # Unassigned bucket, wire serializer). Pure transport helpers — no sqlite.
          ham-taskchain-grouping-test = mkOdinPackage pkgs odin "ham-taskchain-grouping-test" "tests/taskchain_grouping_test";
          ham-bootstrap-golden-test = mkOdinPackage pkgs odin "ham-bootstrap-golden-test" "tests/hub_bootstrap_golden_test";
          ham-vcs-backend-test = mkOdinPackageWithRuntime pkgs odin "ham-vcs-backend-test" "tests/vcs_backend_test" [ pkgs.git pkgs.jujutsu ];
          # BUG-14 / REQ-MIGRATE-1: boots an EMPTY database to migration head on
          # both the embedded-constant path (what a packaged binary uses when
          # --migrations-dir is absent) and the on-disk path, and fails if the
          # two build different schemas. Pass the migrations dir as argv[1] to
          # enable the disk half from outside the repo root.
          ham-migration-bootstrap-test = mkOdinPackageWithRuntime pkgs odin "ham-migration-bootstrap-test" "tests/migration_bootstrap_test" [ pkgs.sqlite ];
          ham-pty-host = mkPtyHost pkgs;
          # REQ-DIST-1: user-facing `heimdall` management CLI (src/manager),
          # shipped as bin/heimdall in the release tarballs. The flake attribute
          # is `ham-manager` because `heimdall` below is the desktop UI package.
          ham-manager = mkOdinPackage pkgs odin "heimdall" "src/manager";
          heimdall = mkOdinUiPackage pkgs;
          heimdall-node-modules = mkNodeModules pkgs;
          # REQ-INST-16: portable release attrs consumed by
          # scripts/release/package-local-binary-tarball.sh. Static on Linux,
          # clean load commands on Darwin; nothing references /nix/store.
          release-ham-bridge = mkReleaseOdinPackage pkgs odin "ham-bridge" "src/bridge";
          release-ham-ctl = mkReleaseOdinPackage pkgs odin "ham-ctl" "src/ctl";
          release-heimdall = mkReleaseOdinPackage pkgs odin "heimdall" "src/manager";
          release-ham-pty-host = mkReleasePtyHost pkgs;
        } // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # T12: termux-arm64 bundle (musl-static Odin binaries; see
          # mkTermuxOdinPackage). Its pty host is release-ham-pty-host, already
          # musl-static, built on the aarch64-linux runner.
          release-termux-ham-bridge = mkTermuxOdinPackage pkgs odin "ham-bridge" "src/bridge";
          release-termux-ham-ctl = mkTermuxOdinPackage pkgs odin "ham-ctl" "src/ctl";
          release-termux-heimdall = mkTermuxOdinPackage pkgs odin "heimdall" "src/manager";
        } // {
          bc-test-agent = self.packages.${system}.ham-test-agent;
          default = self.packages.${system}.ham-hub;
        });

      apps = forAllSystems (system: 
        let pkgs = pkgsFor system;
        in {
        # hub: wraps ham-hub so `nix run .#hub` works from any CWD. The ham-hub
        # package bundles its migrations under share/ham-hub/migrations; this
        # wrapper injects the absolute store path via --migrations-dir and
        # forwards all user args (e.g. `nix run .#hub -- --port 9000 --db x.db`).
        hub = {
          type = "app";
          program = "${(pkgs.writeShellScriptBin "ham-hub" ''
            #!/usr/bin/env bash
            set -euo pipefail
            HAM_HUB="${self.packages.${system}.ham-hub}/bin/ham-hub"
            MIGRATIONS="${self.packages.${system}.ham-hub}/share/ham-hub/migrations"
            exec "$HAM_HUB" --migrations-dir "$MIGRATIONS" "$@"
          '')}/bin/ham-hub";
        };
        bridge = {
          type = "app";
          program = "${(pkgs.writeShellScriptBin "ham-bridge" ''
            #!/usr/bin/env bash
            set -euo pipefail
            export HEIMDALL_HAM_PTY_HOST_BIN="${self.packages.${system}.ham-pty-host}/bin/ham-pty-host"
            export HEIMDALL_BRIDGE_PTY_HOST="true"
            export HEIMDALL_HAM_CTL_BIN="${self.packages.${system}.ham-ctl}/bin/ham-ctl"
            exec "${self.packages.${system}.ham-bridge}/bin/ham-bridge" "$@"
          '')}/bin/ham-bridge";
        };
        pty-host = {
          type = "app";
          program = "${self.packages.${system}.ham-pty-host}/bin/ham-pty-host";
        };
        dev-proxy = {
          type = "app";
          program = "${self.packages.${system}.ham-dev-proxy}/bin/ham-dev-proxy";
        };
        ctl = {
          type = "app";
          program = "${self.packages.${system}.ham-ctl}/bin/ham-ctl";
        };
        test-agent = {
          type = "app";
          program = "${self.packages.${system}.ham-test-agent}/bin/ham-test-agent";
        };
        heimdall = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "heimdall" ''
            #!/usr/bin/env bash
            set -euo pipefail

            WATCH=0
            PORT=5173
            REST=()
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --watch)
                  WATCH=1
                  shift
                  ;;
                --port)
                  if [ "$#" -lt 2 ]; then
                    echo "[heimdall] --port requires a value" >&2
                    exit 2
                  fi
                  PORT="$2"
                  shift 2
                  ;;
                --help|-h)
                  echo "Usage: nix run .#heimdall -- [--watch] [--port PORT] [electron args...]"
                  echo "  default: release build; Electron loads dist/index.html (no Vite watcher/HMR)"
                  echo "  --watch: run Vite dev server and launch Electron against it"
                  exit 0
                  ;;
                --)
                  shift
                  REST+=("$@")
                  break
                  ;;
                *)
                  REST+=("$1")
                  shift
                  ;;
              esac
            done

            echo "[heimdall] Checking for node_modules..."
            if [ ! -d "node_modules" ]; then
              echo "[heimdall] node_modules not found. Running npm install..."
              ${pkgs.nodejs}/bin/npm install
            fi

            if [ "$WATCH" -eq 0 ]; then
              echo "[heimdall] Building release UI (no Vite watcher/HMR)..."
              ${pkgs.nodejs}/bin/npm run build
              unset VITE_DEV_SERVER_URL
              echo "[heimdall] Launching Electron in release mode..."
              exec ${pkgs.electron}/bin/electron electron-dist/main.cjs "''${REST[@]}"
            fi

            echo "[heimdall] Building Electron TypeScript for watch mode..."
            ${pkgs.nodejs}/bin/npm run build:electron

            while ! (${pkgs.python3}/bin/python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', $PORT)); s.close()" 2>/dev/null); do
              PORT=$((PORT + 1))
            done

            echo "[heimdall] Starting Vite dev server on port $PORT (--watch mode)..."
            ${pkgs.nodejs}/bin/npx vite --host 127.0.0.1 --port "$PORT" &
            VITE_PID=$!
            cleanup() {
              echo "[heimdall] Cleaning up Vite dev server (PID: $VITE_PID)..."
              kill "$VITE_PID" 2>/dev/null || true
            }
            trap cleanup EXIT INT TERM

            echo "[heimdall] Waiting for Vite server at http://127.0.0.1:$PORT..."
            while ! ${pkgs.curl}/bin/curl -s "http://127.0.0.1:$PORT" > /dev/null 2>&1; do
              if ! kill -0 "$VITE_PID" 2>/dev/null; then
                echo "[heimdall] Vite server process died unexpectedly." >&2
                exit 1
              fi
              sleep 0.1
            done

            echo "[heimdall] Vite ready. Launching Electron in watch/dev mode..."
            export VITE_DEV_SERVER_URL="http://127.0.0.1:$PORT"
            exec ${pkgs.electron}/bin/electron electron-dist/main.cjs "''${REST[@]}"
          ''}/bin/heimdall";
        };
        heimdall-browser = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "heimdall-browser" ''
            #!/usr/bin/env bash
            MODE="dev"
            PORT="5173"

            while [[ "$#" -gt 0 ]]; do
                case $1 in
                    --dev) MODE="dev"; shift ;;
                    --release) MODE="release"; shift ;;
                    --port) PORT="$2"; shift 2 ;;
                    *) echo "Unknown parameter passed: $1"; exit 1 ;;
                esac
            done

            echo "[heimdall] Starting Vite server ($MODE mode) on port $PORT..."
            if [ ! -d "node_modules" ]; then
              echo "[heimdall] node_modules not found. Copying from Nix store..."
              cp -r "${self.packages.${system}.heimdall-node-modules}/node_modules" node_modules
              chmod -R u+w node_modules
            fi

            if [ "$MODE" == "release" ]; then
              echo "[heimdall] Building for release..."
              ${pkgs.nodejs}/bin/npm run build
              ${pkgs.nodejs}/bin/npx vite preview --host 127.0.0.1 --port $PORT
            else
              ${pkgs.nodejs}/bin/npx vite --host 127.0.0.1 --port $PORT
            fi
          ''}/bin/heimdall-browser";
        };
        ham-ui-server = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "ham-ui-server" ''
            #!/usr/bin/env bash
            PORT="5173"

            while [[ "$#" -gt 0 ]]; do
                case $1 in
                    --port) PORT="$2"; shift 2 ;;
                    *) echo "Unknown parameter passed: $1"; exit 1 ;;
                esac
            done

            echo "[ham-ui-server] Starting Vite production server on port $PORT..."
            if [ ! -d "node_modules" ]; then
              echo "[ham-ui-server] node_modules not found. Copying from Nix store..."
              cp -r "${self.packages.${system}.heimdall-node-modules}/node_modules" node_modules
              chmod -R u+w node_modules
            fi

            echo "[ham-ui-server] Building UI..."
            ${pkgs.nodejs}/bin/npm run build
            exec ${pkgs.nodejs}/bin/npx vite preview --host 127.0.0.1 --port "$PORT"
          ''}/bin/ham-ui-server";
        };
        default = self.apps.${system}.hub;
      });

      devShells = forAllSystems (system:
        let
          pkks = pkgsFor system;
          odin = mkOdin pkks;
          ols = pkks.ols.override { inherit odin; };
        in
        {
          default = pkks.mkShell {
            packages = [
              odin
              ols
              pkks.tmux
              pkks.curl
              pkks.jq
              pkks.sqlite
              # PTYH-4: Rust toolchain for tools/pty_host so `nix develop` gives
              # cargo/rustc/clippy without rustup.
              pkks.cargo
              pkks.rustc
              pkks.rustfmt
              pkks.clippy
              pkks.rust-analyzer
            ];
          };
        });
    };
}
