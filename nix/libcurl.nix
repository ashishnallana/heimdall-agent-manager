# The libcurl every Heimdall binary links (src/lib/httpc), at the ONE version
# pinned in ./libcurl-pin.json. scripts/windows/build.ps1 reads the same file.
#
# Feature set (identical in every variant): HTTP and HTTPS only, WebSockets
# (ws/wss, for the curl_ws_* migration), zlib for gzip/deflate, the threaded
# resolver, proxies compiled in (httpc disables them per request). Left out:
# every other protocol, HTTP/2 (httpc pins HTTP/1.1 on a fresh connection per
# request, so nghttp2 would never be used), HTTP/3, brotli, zstd, libpsl, IDN,
# libssh2, GSS-API/Kerberos/NTLM, cookies, netrc, alt-svc, HSTS, MIME/form.
# No CA bundle, CA path or OpenSSL default-path fallback is compiled in: those
# would be /nix/store paths. httpc picks the trust anchors at run time.
#
# Variants:
#   linuxStatic  pkgsStatic (musl): libcurl.a + OpenSSL 3 libssl.a/libcrypto.a
#                + libz.a, for the fully static release binaries.
#   darwinStatic the default Darwin set with static OpenSSL 3 and zlib, and
#                Apple SecTrust verification (--with-apple-sectrust: the system
#                keychain/trust settings verify the chain, OpenSSL does TLS).
#   native       dynamic libcurl.so/.dylib against nixpkgs' OpenSSL and zlib,
#                for the Nix-native packages (NixOS hub units, nix run, the dev
#                shell). Same version and feature set (on Darwin also Apple
#                SecTrust); its store path is fixed by the flake, so it cannot
#                drift on a host. Kept dynamic because these binaries only run
#                from their own closure: static linking would buy nothing but
#                a second OpenSSL build per system.
#
# Bumping: edit ./libcurl-pin.json (version, urls, sha256 of the .tar.gz,
# verified against the release's .asc signature), then build every
# release-* attr and run the httpc suite. The same file pins zlib.
{ lib, pkgs }:
let
  pin = lib.importJSON ./libcurl-pin.json;

  pinnedSrc = what: pkgs.fetchurl {
    inherit (pin.${what}) urls sha256;
  };

  withPinnedZlib = zlib: zlib.overrideAttrs (_: {
    inherit (pin.zlib) version;
    src = pinnedSrc "zlib";
  });

  configureExtra = [
    "--disable-ftp" "--disable-file" "--disable-ldap" "--disable-ldaps"
    "--disable-rtsp" "--disable-dict" "--disable-telnet" "--disable-tftp"
    "--disable-pop3" "--disable-imap" "--disable-smtp" "--disable-gopher"
    "--disable-mqtt" "--disable-ipfs"
    "--disable-ntlm" "--disable-kerberos-auth" "--disable-negotiate-auth"
    "--disable-aws" "--disable-cookies" "--disable-netrc" "--disable-alt-svc"
    "--disable-hsts" "--disable-mime" "--disable-form-api" "--disable-unix-sockets"
    "--disable-libcurl-option"
    "--enable-websockets" "--enable-threaded-resolver"
    "--without-nghttp2" "--without-nghttp3" "--without-ngtcp2"
    "--without-brotli" "--without-zstd" "--without-libpsl" "--without-libidn2"
    # SMB goes with NTLM; libssh2 and GSS-API are opt-in (--with-*).
    "--without-ca-bundle" "--without-ca-path" "--without-ca-fallback"
    # Never read openssl.cnf (OPENSSL_CONF or the build's OPENSSLDIR, a
    # /nix/store path): the environment must not be able to load providers or
    # engines, or change TLS policy, behind httpc's back.
    "--disable-openssl-auto-load-config"
  ];

  # A variant: the curl derivation plus the TLS and zlib it was built with, and
  # the directories holding their link-time libraries (static variants: only
  # .a archives, so -L<dir> -lcurl -lssl -lcrypto -lz cannot pick a shared one).
  mkVariant = { set, openssl, zlib, static }:
    let
      isDarwin = set.stdenv.hostPlatform.isDarwin;
      curl = (set.curlMinimal.override {
        inherit openssl zlib;
        opensslSupport = true;
        zlibSupport = true;
        http2Support = false;
        scpSupport = false;
        gssSupport = false;
        websocketSupport = true;
      }).overrideAttrs (old: {
        inherit (pin.curl) version;
        src = pinnedSrc "curl";
        # nixpkgs adds --with-ca-fallback for OpenSSL; nothing may point at the
        # build machine's (or the store's) CA locations.
        configureFlags =
          (lib.filter (f: f != "--with-ca-fallback" && f != "--disable-websockets") old.configureFlags)
          ++ configureExtra
          # macOS: verify through the system trust store (keychains, admin and
          # user trust settings) whenever no CA file/path is configured.
          ++ lib.optionals isDarwin [ "--with-apple-sectrust" ]
          ++ lib.optionals static [ "--enable-static" "--disable-shared" ];
        dontDisableStatic = static;
      });
    in
    {
      inherit curl openssl zlib static;
      inherit (pin.curl) version;
      libDirs = [ "${lib.getLib curl}/lib" "${lib.getLib openssl}/lib" "${lib.getLib zlib}/lib" ];
    };
in
{
  inherit pin;
  inherit (pin.curl) version;

  # Fully static Linux (musl). `pkgs.pkgsStatic` is native musl on the build
  # host's architecture; pass pkgsCross.<x>.pkgsStatic for a cross build.
  linuxStatic = staticPkgs: mkVariant {
    set = staticPkgs;
    openssl = staticPkgs.openssl;
    zlib = withPinnedZlib staticPkgs.zlib;
    static = true;
  };

  darwinStatic = mkVariant {
    set = pkgs;
    openssl = pkgs.openssl.override { static = true; };
    zlib = withPinnedZlib (pkgs.zlib.override { shared = false; splitStaticOutput = false; });
    static = true;
  };

  # Shared libcurl for the Nix-native packages; nixpkgs' own OpenSSL and zlib
  # (one libz.so per process).
  native = mkVariant {
    set = pkgs;
    openssl = pkgs.openssl;
    zlib = pkgs.zlib;
    static = false;
  };
}
