{
  lib,
  stdenv,
  buildPackages,
  fetchFromGitHub,
  fetchpatch,
  runCommand,
  python3,
  libuuid,
  applyPatches,
  nukeReferences,
  l4tVersion,
  # Optional path to a boot logo that will be converted and cropped into the format required
  bootLogo ? null,
  # Patches to apply to edk2-nvidia source tree
  edk2NvidiaPatches ? [ ],
  # Patches to apply to edk2 source tree
  edk2UefiPatches ? [ ],
  debugMode ? false,
  errorLevelInfo ? debugMode, # Enables a bunch more info messages

  # The root certificate (in PEM format) for authenticating capsule updates. By
  # default, EDK2 authenticates using a test keypair commited upstream.
  trustedPublicCertPemFile ? null,
}:

#
# Note:
#
# Adjust following check when target/platform is tested!
#

if l4tVersion != "36.4.3" then
  throw "Only tested with l4tVersion 36.4.3"
else

  let

    targetArch =
      if stdenv.isAarch64 then "AARCH64" else throw "Only supported target architecture is AARCH64";

    buildType = if stdenv.isLinux then "GCC5" else throw "Only supported build platform is Linux/GCC";

    buildTarget = if debugMode then "DEBUG" else "RELEASE";

    # TODO: Move this generation out of uefi-firmware.nix, because this .nix
    # file is callPackage'd using an aarch64 version of nixpkgs, and we don't
    # want to have to recompilie imagemagick
    bootLogoVariants =
      runCommand "uefi-bootlogo" { nativeBuildInputs = [ buildPackages.buildPackages.imagemagick ]; }
        ''
          mkdir -p $out
          convert ${bootLogo} -resize 1920x1080 -gravity Center -extent 1920x1080 -format bmp -define bmp:format=bmp3 $out/logo1080.bmp
          convert ${bootLogo} -resize 1280x720  -gravity Center -extent 1280x720  -format bmp -define bmp:format=bmp3 $out/logo720.bmp
          convert ${bootLogo} -resize 640x480   -gravity Center -extent 640x480   -format bmp -define bmp:format=bmp3 $out/logo480.bmp
        '';

    ###

    # See: https://github.com/NVIDIA/edk2-edkrepo-manifest/blob/main/edk2-nvidia/Jetson/NVIDIAJetsonManifest.xml
    edk2-src = applyPatches {
      src =
        (fetchFromGitHub {
          name = "edk2-src";
          owner = "NVIDIA";
          repo = "edk2";
          rev = "r${l4tVersion}";
          fetchSubmodules = true;
          sha256 = "sha256-TBroMmFyZt6ypooDtSzScjA3POPr76rJKfLQfAkRwdU=";
        }).overrideAttrs
          {
            # Workaround to for unavailable https://github.com/Zeex/subhook
            # Change subhook url from https://github.com/Zeex/subhook to
            # https://github.com/tianocore/edk2-subhook because old url is
            # no longer available.
            #
            # Will be fixed after r36.5.0, so delete then.
            GIT_CONFIG_COUNT = 1;
            GIT_CONFIG_KEY_0 = "url.https://github.com/tianocore/edk2-subhook.git.insteadOf";
            GIT_CONFIG_VALUE_0 = "https://github.com/Zeex/subhook.git";
          };
      patches = edk2UefiPatches ++ [
        (fetchpatch {
          name = "CVE-2022-36764.patch";
          url = "https://raw.githubusercontent.com/tianocore/user-attachments/147607ddbc1751a297d15e1293cecf4c08037366/tianocore/edk2/BZ-1436-4118.patch";
          hash = "sha256-czku8DgElisDv6minI67nNt6BS+vH6txslZdqiGaQR4=";
          excludes = [
            "SecurityPkg/Test/SecurityPkgHostTest.dsc"
          ];
        })
        # https://github.com/tianocore/edk2/pull/5658
        # (cross-compilation fix)
        (fetchpatch {
          url = "https://github.com/tianocore/edk2/commit/a34ff4a8f69a7b8a52b9b299153a8fac702c7df1.patch";
          hash = "sha256-u+niqwjuLV5tNPykW4xhb7PW2XvUmXhx5uvftG1UIbU=";
        })
      ];
    };

    edk2-platforms = fetchFromGitHub {
      name = "edk2-platforms";
      owner = "NVIDIA";
      repo = "edk2-platforms";
      rev = "r${l4tVersion}";
      fetchSubmodules = true;
      sha256 = "sha256-Z89AkLvoG7pSOHUlU7IWLREM3R79kABpHj7KS5XpX0o=";
    };

    edk2-non-osi = fetchFromGitHub {
      name = "edk2-non-osi";
      owner = "NVIDIA";
      repo = "edk2-non-osi";
      rev = "r${l4tVersion}";
      sha256 = "sha256-FnznH8KsB3rD7sL5Lx2GuQZRPZ+uqAYqenjk+7x89mE=";
    };

    edk2-nvidia = applyPatches {
      src = fetchFromGitHub {
        name = "edk2-nvidia";
        owner = "NVIDIA";
        repo = "edk2-nvidia";
        rev = "r${l4tVersion}";
        sha256 = "sha256-Ri+0vrxvd7eE7TP/KBM0ET2jX0fupdC3+Dli+IshUP8=";
      };
      patches = edk2NvidiaPatches ++ [
        # Fix Eqos driver to use correct TX clock name
        # PR: https://github.com/NVIDIA/edk2-nvidia/pull/76
        (fetchpatch {
          url = "https://github.com/NVIDIA/edk2-nvidia/commit/26f50dc3f0f041d20352d1656851c77f43c7238e.patch";
          hash = "sha256-cc+eGLFHZ6JQQix1VWe/UOkGunAzPb8jM9SXa9ScIn8=";
        })

        (lib.optionalString (trustedPublicCertPemFile != null) ./capsule-authentication.patch)

        # Have UEFI use the device tree compiled into the firmware, instead of
        # using one from the kernel-dtb partition.
        # See: https://github.com/anduril/jetpack-nixos/pull/18
        # Note: Patch ported to 36.3
        # ./edk2-uefi-dtb.patch
      ];
      postPatch =
        lib.optionalString errorLevelInfo ''
          sed -i 's#PcdDebugPrintErrorLevel|.*#PcdDebugPrintErrorLevel|0x8000004F#' Platform/NVIDIA/NVIDIA.common.dsc.inc
        ''
        + lib.optionalString (bootLogo != null) ''
          cp ${bootLogoVariants}/logo1080.bmp Silicon/NVIDIA/Assets/nvidiagray1080.bmp
          cp ${bootLogoVariants}/logo720.bmp Silicon/NVIDIA/Assets/nvidiagray720.bmp
          cp ${bootLogoVariants}/logo480.bmp Silicon/NVIDIA/Assets/nvidiagray480.bmp
        '';
    };

    edk2-nvidia-non-osi = fetchFromGitHub {
      name = "edk2-nvidia-non-osi";
      owner = "NVIDIA";
      repo = "edk2-nvidia-non-osi";
      rev = "r${l4tVersion}";
      sha256 = "sha256-qQs1jO/h6+j9WLfz1OtYpgZutEeX284BlcUKJWvghEE=";
    };

    edk2-open-gpu-kernel-modules = fetchFromGitHub {
      name = "edk2-open-gpu-kernel-modules";
      owner = "NVIDIA";
      repo = "open-gpu-kernel-modules";
      rev = "dac2350c7f6496ef0d7fb20fe6123a1270329bc8"; # 525.78.01
      sha256 = "sha256-fxpyXVl735ZJ3NnK7jN95gPstu7YopYH/K7UK0iAC7k=";
    };

    pythonEnv = buildPackages.python3.withPackages (ps: [
      ps.edk2-pytool-library
      (ps.callPackage ./edk2-pytool-extensions.nix { })
      ps.tkinter
      ps.regex
      ps.kconfiglib
    ]);

    jetson-edk2-uefi =

      stdenv.mkDerivation {

        pname = "jetson-edk2-uefi";
        version = l4tVersion;

        srcs = [
          edk2-open-gpu-kernel-modules
          edk2-nvidia-non-osi
          edk2-nvidia
          edk2-non-osi
          edk2-platforms
          edk2-src
        ];
        sourceRoot = edk2-src.name;

        depsHostHost = [
          libuuid
        ];
        depsBuildBuild = [
          buildPackages.stdenv.cc
          buildPackages.bash
        ];
        nativeBuildInputs = [
          pythonEnv
          buildPackages.libuuid
          buildPackages.dtc
          buildPackages.acpica-tools
          buildPackages.gnat
          buildPackages.bash
        ];

        strictDeps = true;

        buildPhase = ''
          runHook preBuild

          # Prepare sources into expected tree structure
          cd ..
          mkdir edk2-nvidia-server-gpu-sdk
          ln -s open-gpu-kernel-modules edk2-nvidia-server-gpu-sdk/open-gpu-kernel-modules
          mv edk2-src-patched edk2
          mv edk2-nvidia-patched edk2-nvidia
          chmod -R +w edk2-nvidia edk2

          # delete this so it doesn't trigger a nuget download
          rm ./edk2/BaseTools/Bin/nasm_ext_dep.yaml ./edk2-nvidia/Platform/NVIDIA/iasl_ext_dep.yaml

          # nvidia expects gcc-ar and ar to be in the same directory as gcc
          rm -rf bin && mkdir bin && chmod +x bin
          for tool in gcc cc g++ c++ gcc-ar ar cpp objcopy; do
            ln -s $(command -v ${stdenv.cc.targetPrefix}$tool) bin/${stdenv.cc.targetPrefix}$tool
          done

          export CROSS_COMPILER_PREFIX="$PWD"/bin/${stdenv.cc.targetPrefix}
          ''${CROSS_COMPILER_PREFIX}gcc --version
          export ${"GCC5_${targetArch}_PREFIX"}=$CROSS_COMPILER_PREFIX

          # patchShebangs fails to see these when cross compiling
          for i in edk2/BaseTools/BinWrappers/PosixLike/*; do
            chmod +x "$i"
            patchShebangs --build "$i"
          done

          # Prepare for build

          # -D BUILDID_STRING
          # Format: {l4tVersion}-{edk2-nvidia repos HEAD sha}
          export FIRMWARE_VERSION_BASE=${l4tVersion}

          export WORKSPACE="$PWD"
          export PYTHONPATH="$PWD"/edk2-nvidia/Silicon/NVIDIA/scripts/..

          ${lib.optionalString (trustedPublicCertPemFile != null) ''
            echo Using ${trustedPublicCertPemFile} as public certificate for capsule verification
            ${lib.getExe buildPackages.openssl} x509 -outform DER -in ${trustedPublicCertPemFile} -out PublicCapsuleKey.cer
            python3 ./edk2/BaseTools/Scripts/BinToPcd.py -p gEfiSecurityPkgTokenSpaceGuid.PcdPkcs7CertBuffer -i PublicCapsuleKey.cer -o PublicCapsuleKey.cer.gEfiSecurityPkgTokenSpaceGuid.PcdPkcs7CertBuffer.inc
            python3 ./edk2/BaseTools/Scripts/BinToPcd.py -x -p gFmpDevicePkgTokenSpaceGuid.PcdFmpDevicePkcs7CertBufferXdr -i PublicCapsuleKey.cer -o PublicCapsuleKey.cer.gFmpDevicePkgTokenSpaceGuid.PcdFmpDevicePkcs7CertBufferXdr.inc
          ''}

          stuart_update -c "$PWD"/edk2-nvidia/Platform/NVIDIA/Jetson/PlatformBuild.py
          python edk2/BaseTools/Edk2ToolsBuild.py -t ${buildType}

          # Use iasl-tool from pkgs
          mkdir -p edk2-nvidia/Platform/NVIDIA/edk2-acpica-iasl_extdep/Linux-x86
          rm -f edk2-nvidia/Platform/NVIDIA/edk2-acpica-iasl_extdep/Linux-x86/iasl
          ln -s $(command -v iasl) edk2-nvidia/Platform/NVIDIA/edk2-acpica-iasl_extdep/Linux-x86/iasl

          # Actual build
          stuart_build -c "$PWD"/edk2-nvidia/Platform/NVIDIA/Jetson/PlatformBuild.py --target ${buildTarget}

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mv -v Build/*/* $out
          runHook postInstall
        '';
      };

    uefi-firmware =
      runCommand "uefi-firmware-${l4tVersion}"
        {
          nativeBuildInputs = [
            python3
            nukeReferences
          ];
        }
        ''
          mkdir -p $out
          python3 ${edk2-nvidia}/Silicon/NVIDIA/edk2nv/FormatUefiBinary.py \
            ${jetson-edk2-uefi}/FV/UEFI_NS.Fv \
            $out/uefi_jetson.bin

          python3 ${edk2-nvidia}/Silicon/NVIDIA/edk2nv/FormatUefiBinary.py \
            ${jetson-edk2-uefi}/AARCH64/L4TLauncher.efi \
            $out/L4TLauncher.efi

          mkdir -p $out/dtbs
          for filename in ${jetson-edk2-uefi}/AARCH64/Silicon/NVIDIA/Tegra/DeviceTree/DeviceTree/OUTPUT/*.dtb; do
            cp $filename $out/dtbs/$(basename "$filename" ".dtb").dtbo
          done

          # Get rid of any string references to source(s)
          nuke-refs $out/uefi_jetson.bin
        '';
  in
  {
    inherit edk2-src uefi-firmware;
  }
