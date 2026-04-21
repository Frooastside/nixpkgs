{
  agplLicensed ? true,
  buildGoModule,
  channel ? "stable",
  fetchFromGitHub,
  fetchPnpmDeps,
  installShellFiles,
  lib,
  makeBinaryWrapper,
  nodejs_20,
  pnpmConfigHook,
  pnpm,
  stdenvNoCC,
  terraform,
  zstd,
}:

let
  pnpm_nodejs_20 = pnpm.override {
    nodejs = nodejs_20;
  };
  channels = {
    stable = rec {
      version = "2.31.9";
      src = fetchFromGitHub {
        owner = "coder";
        repo = "coder";
        rev = "v${version}";
        hash = "sha256-8qZQ9lPPYYGoFOdo04aooekrwhZT9ND8YWlBdpUQesw=";
      };
      vendorHash = "sha256-CqkC1W+0ymTxKCDp1j8k0/f31/VSuD4BmCs1YWjyaaU=";
      pnpmDepsHash = "sha256-JlbjDBeBtz7vA9Ol+NmUdNYROzop9C6vnoDEsJTp0W8=";
    };
  };
  subPackage = (if agplLicensed then "cmd/coder" else "enterprise/cmd/coder");
  omitTags = [
    "ts_omit_aws"
    "ts_omit_bird"
    "ts_omit_tap"
    "ts_omit_kube"
  ];
  mkSlimBinary =
    {
      goos,
      goarch,
      goarm,
      ...
    }:
    (buildGoModule rec {
      pname = "coder-slim-${goos}-${goarch}";
      version = channels.${channel}.version;
      src = channels.${channel}.src;
      vendorHash = channels.${channel}.vendorHash;
      subPackages = [ subPackage ];
      ldflags = [
        "-s"
        "-w"
        "-X=github.com/coder/coder/v2/buildinfo.tag=${version}-slim-nixpkgs"
      ]
      ++ lib.optional agplLicensed "-X=github.com/coder/coder/v2/buildinfo.agpl=true";
      tags = [ "slim" ] ++ omitTags;
      env = {
        GOOS = goos;
        GOARCH = goarch;
        GOARM = goarm;
        CGO_ENABLED = "0";
      };
      postBuild =
        lib.optionalString
          (
            goos != stdenvNoCC.hostPlatform.go.GOOS
            || goarch != stdenvNoCC.hostPlatform.go.GOARCH
            || goarm != stdenvNoCC.hostPlatform.go.GOARM
          )
          ''
            dir=$GOPATH/bin/''${GOOS}_''${GOARCH}
            if [[ -n "$(shopt -s nullglob; echo $dir/*)" ]]; then
              mv $dir/* $dir/..
            fi
            if [[ -d $dir ]]; then
              rmdir $dir
            fi
          '';
      doCheck = false;
    }).overrideAttrs
      (
        finalAttrs: previousAttrs: {
          env = previousAttrs.env // {
            GOOS = goos;
            GOARCH = goarch;
            GOARM = goarm;
          };
        }
      );
  slimTargets = [
    "windows_amd64"
    "windows_arm64"
    "linux_amd64"
    "linux_arm64"
    "linux_arm_7"
    "darwin_amd64"
    "darwin_arm64"
  ];
  slimBinaries = builtins.listToAttrs (
    map (
      target:
      let
        parts = lib.splitString "_" target;
        goos = (builtins.elemAt parts 0);
        goarch = (builtins.elemAt parts 1);
        goarm = lib.optionalString (builtins.length parts > 2) (builtins.elemAt parts 2);
      in
      {
        name = target;
        value = mkSlimBinary {
          inherit goos goarch goarm;
        };
      }
    ) slimTargets
  );
  bundle = stdenvNoCC.mkDerivation {
    pname = "coder-slim-bundle";
    version = channels.${channel}.version;

    nativeBuildInputs = [ zstd ];

    unpackPhase = ''
      runHook preUnpack

      cp ${slimBinaries.linux_amd64}/bin/coder coder-linux-amd64
      cp ${slimBinaries.linux_arm64}/bin/coder coder-linux-arm64
      cp ${slimBinaries.linux_arm_7}/bin/coder coder-linux-armv7
      cp ${slimBinaries.windows_amd64}/bin/coder.exe coder-windows-amd64.exe
      cp ${slimBinaries.windows_arm64}/bin/coder.exe coder-windows-arm64.exe
      cp ${slimBinaries.darwin_amd64}/bin/coder coder-darwin-amd64
      cp ${slimBinaries.darwin_arm64}/bin/coder coder-darwin-arm64

      runHook postUnpack
    '';

    buildPhase = ''
      runHook preBuild

      sha1sum -b coder-* | tee coder.sha1
      tar cf coder.tar coder-*
      zstd -22 --ultra --force --long --no-progress -o coder.tar.zst coder.tar

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share
      cp coder.{sha1,tar.zst} $out/share

      runHook postInstall
    '';
  };
in
(buildGoModule rec {
  pname = "coder";
  version = channels.${channel}.version;

  src = channels.${channel}.src;

  frontend = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "coder-frontend";
    inherit version;

    src = "${src}/site";

    nativeBuildInputs = [
      nodejs_20
      pnpmConfigHook
      pnpm_nodejs_20
    ];

    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r out $out
      runHook postInstall
    '';

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pnpm_nodejs_20;
      fetcherVersion = 3;
      hash = channels.${channel}.pnpmDepsHash;
    };
  });

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
  ];

  vendorHash = channels.${channel}.vendorHash;
  subPackages = [ subPackage ];

  ldflags = [
    "-s"
    "-w"
    "-X=github.com/coder/coder/v2/buildinfo.tag=${version}-nixpkgs"
  ]
  ++ lib.optional agplLicensed "-X=github.com/coder/coder/v2/buildinfo.agpl=true";

  tags = [ "embed" ] ++ omitTags;

  preBuild = ''
    cp -r ${frontend} site/out
    cp -r ${bundle}/share site/out/bin
  '';

  postInstall = ''
    installShellCompletion --cmd coder \
      --bash <($out/bin/coder completion bash) \
      --fish <($out/bin/coder completion fish) \
      --zsh <($out/bin/coder completion zsh)

    wrapProgram $out/bin/coder \
      --prefix PATH : ${lib.makeBinPath [ terraform ]}
  '';

  doCheck = false;

  meta = {
    description = "Provision remote development environments via Terraform";
    homepage = "https://coder.com";
    license = lib.licenses.agpl3Only;
    mainProgram = "coder";
    maintainers = with lib.maintainers; [
      ghuntley
      kylecarbs
    ];
  };
})
