	{ lib
	, stdenv
	, buildPackages
	, fetchFromGitHub
	, fetchurl
	, fetchpatch
	, fetchpatch2
	, runCommand
	, edk2
	, antlr
	, acpica-tools
	, dtc
	, python3
	, bc
	, imagemagick
	, unixtools
	, libuuid
	, applyPatches
	, nukeReferences
	, l4tVersion
	, # Optional path to a boot logo that will be converted and cropped into the format required
	  bootLogo ? null
	, # Patches to apply to edk2-nvidia source tree
	  edk2NvidiaPatches ? [ ]
	, # Patches to apply to edk2 source tree
	  edk2UefiPatches ? [ ]
	, debugMode ? false
	, errorLevelInfo ? debugMode
	, # Enables a bunch more info messages

	  # The root certificate (in PEM format) for authenticating capsule updates. By
	  # default, EDK2 authenticates using a test keypair commited upstream.
	  trustedPublicCertPemFile ? null
	, which
	, mono
	, 
	}:

	let
	  # TODO: Move this generation out of uefi-firmware.nix, because this .nix
	  # file is callPackage'd using an aarch64 version of nixpkgs, and we don't
	  # want to have to recompilie imagemagick
	  bootLogoVariants = runCommand "uefi-bootlogo" { nativeBuildInputs = [ buildPackages.buildPackages.imagemagick ]; } ''
	    mkdir -p $out
	    convert ${bootLogo} -resize 1920x1080 -gravity Center -extent 1920x1080 -format bmp -define bmp:format=bmp3 $out/logo1080.bmp
	    convert ${bootLogo} -resize 1280x720  -gravity Center -extent 1280x720  -format bmp -define bmp:format=bmp3 $out/logo720.bmp
	    convert ${bootLogo} -resize 640x480   -gravity Center -extent 640x480   -format bmp -define bmp:format=bmp3 $out/logo480.bmp
	  '';

	  ###


	  # See: https://github.com/NVIDIA/edk2-edkrepo-manifest/blob/main/edk2-nvidia/Jetson/NVIDIAJetsonManifest.xml
	  edk2-src = fetchFromGitHub {
	    owner = "NVIDIA";
	    repo = "edk2";
	    rev = "uefi-202405.0";
	    fetchSubmodules = true;
	    hash = "sha256-9+zIfreZchuLjeprvW/WIdSh0+1wDIExvCKp+LejYcw=";
	  };

	  edk2-platforms = fetchFromGitHub {
	    owner = "NVIDIA";
	    repo = "edk2-platforms";
	    rev = "uefi-202405.0";
	    hash = "sha256-27dKEi66UWBgJi3Sb2/naeeSC2CJ5+Dbtw8e0o5Y/Hg=";
	  };

	  edk2-non-osi = fetchFromGitHub {
	    owner = "NVIDIA";
	    repo = "edk2-non-osi";
	    rev = "uefi-202405.0";
	    sha256 = "sha256-FnznH8KsB3rD7sL5Lx2GuQZRPZ+uqAYqenjk+7x89mE=";
	  };

	  edk2-nvidia = fetchFromGitHub {
	    # src = fetchFromGitHub {
	    owner = "NVIDIA";
	    repo = "edk2-nvidia";
	    rev = "uefi-202405.0";
	    hash = "sha256-8T6GG1td3epnl+0wsgOebDTqYbhAmj7h/xH+avRWiZg=";
	  };

	  #  patches = edk2NvidiaPatches ++ [
	  # Fix Eqos driver to use correct TX clock name
	  # PR: https://github.com/NVIDIA/edk2-nvidia/pull/76
	  #./eqos-driver-fix-clock-name.patch

	  #./capsule-authentication.patch

	  # Have UEFI use the device tree compiled into the firmware, instead of
	  # using one from the kernel-dtb partition.
	  # See: https://github.com/anduril/jetpack-nixos/pull/18
	  # Upstream Fixed in e81614999?
	  #./edk2-uefi-dtb.patch
	  # ];
	  #    postPatch = lib.optionalString errorLevelInfo ''
	  #     sed -i 's#PcdDebugPrintErrorLevel|.*#PcdDebugPrintErrorLevel|0x8000004F#' Platform/NVIDIA/NVIDIA.common.dsc.inc
	  #  '' + lib.optionalString (bootLogo != null) ''
	  #   cp ${bootLogoVariants}/logo1080.bmp Silicon/NVIDIA/Assets/nvidiagray1080.bmp
	  #   cp ${bootLogoVariants}/logo720.bmp Silicon/NVIDIA/Assets/nvidiagray720.bmp
	  #   cp ${bootLogoVariants}/logo480.bmp Silicon/NVIDIA/Assets/nvidiagray480.bmp
	  # '';
	  # };

	  edk2-nvidia-non-osi = fetchFromGitHub {
	    owner = "NVIDIA";
	    repo = "edk2-nvidia-non-osi";
	    rev = "uefi-202405.0";
	    hash = "sha256-18LWNVZj1FoIigQAX/OHD+QGTxc879TolkFM8JOkXyw=";
	  };


	#  building uefi out of the tree and get it from here

	  edk2-bin-pack = fetchFromGitHub {
	    owner = "tiiuae";
	    repo =  "nv-uefi-build";
	    rev = "main";
	    hash = "sha256-qwlwY7XKfAjrdUXErZGeMfesiL+Wc2Ll72ALpNeNpXM=";
	  };

	  edk2-jetson = edk2.overrideAttrs (prev: {
	    # Upstream nixpkgs patch to use nixpkgs OpenSSL
	    # See https://github.com/NixOS/nixpkgs/blob/44733514b72e732bd49f5511bd0203dea9b9a434/pkgs/development/compilers/edk2/default.nix#L57
	    src = runCommand "edk2-unvendored-src" { } ''
	      cp --no-preserve=mode -r ${edk2-src} $out
	      rm -rf $out/CryptoPkg/Library/OpensslLib/openssl
	      mkdir -p $out/CryptoPkg/Library/OpensslLib/openssl
	      tar --strip-components=1 -xf ${buildPackages.openssl.src} -C $out/CryptoPkg/Library/OpensslLib/openssl
	      chmod -R +w $out/

	      # Fix missing INT64_MAX include that edk2 explicitly does not provide
	      # via it's own <stdint.h>. Let's pull in openssl's definition instead:
	      sed -i $out/CryptoPkg/Library/OpensslLib/openssl/crypto/property/property_parse.c \
		  -e '1i #include "internal/numbers.h"'
	    '';

	    depsBuildBuild = prev.depsBuildBuild ++ [ libuuid ];

	  });

	  pythonEnv = buildPackages.python3.withPackages ( pythonPkgs: with pythonPkgs;  [ipython pip setuptools virtualenvwrapper wheel ]);
	  # ps: [ ps.tkinter ] 
	  targetArch =
	    if stdenv.isi686 then
	      "IA32"
	    else if stdenv.isx86_64 then
	      "X64"
	    else if stdenv.isAarch64 then
	      "AARCH64"
	    else
	      throw "Unsupported architecture";

	  buildType =
	    if stdenv.isDarwin then
	      "CLANGPDB"
	    else
	      "GCC5";

	  buildTarget = if debugMode then "DEBUG" else "RELEASE";

	  jetson-edk2-uefi =
	    # TODO: edk2.mkDerivation doesn't have a way to override the edk version used!
	    # Make it not via passthru ?
	    stdenv.mkDerivation (finalAttrs: {
	      pname = "jetson-edk2-uefi";
	      version = l4tVersion;

	      # Initialize the build dir with the build tools from edk2
	      src = edk2-src;

	      depsBuildBuild = [ buildPackages.stdenv.cc  ];
	      nativeBuildInputs = [ bc pythonEnv acpica-tools dtc unixtools.whereis python3  mono ];
	      strictDeps = true;

	      NIX_CFLAGS_COMPILE = [
		"-Wno-error=format-security" # TODO: Fix underlying issue

		# Workaround for ../Silicon/NVIDIA/Drivers/EqosDeviceDxe/nvethernetrm/osi/core/osi_hal.c:1428: undefined reference to `__aarch64_ldadd4_sync'
		"-mno-outline-atomics"
	      ];

	      ${"GCC5_${targetArch}_PREFIX"} = stdenv.cc.targetPrefix;

	      # From edk2-nvidia/Silicon/NVIDIA/edk2nv/stuart/settings.py
	      PACKAGES_PATH = lib.concatStringsSep ":" [
		"${finalAttrs.src}/BaseTools" # TODO: Is this needed?
		finalAttrs.src
		edk2-platforms
		edk2-non-osi
		edk2-nvidia
		edk2-nvidia-non-osi
		edk2-bin-pack
		"${edk2-platforms}/Features/Intel/OutOfBandManagement"
	      ];

	      enableParallelBuilding = true;

	      prePatch = ''
		rm -rf BaseTools
		cp -r ${edk2-jetson}/BaseTools BaseTools
		chmod -R u+w BaseTools
	      '';

	      patches = edk2UefiPatches ++ [
		#    (fetchurl {
		#      # Patch format does not play well with fetchpatch, it should be fine this is a static attachment in a ticket
		#      name = "CVE-2023-45229_CVE-2023-45230_CVE-2023-45231_CVE-2023-45232_CVE-2023-45233_CVE-2023-45234_CVE-2023-45235.patch";
		#      url = "https://bugzilla.tianocore.org/attachment.cgi?id=1457";
		#     hash = "sha256-CF41lbjnXbq/6DxMW6q1qcLJ8WAs+U0Rjci+jRwJYYY=";
		#    })
		#    (fetchpatch {
		#      name = "CVE-2022-36764.patch";
		#      url = "https://bugzilla.tianocore.org/attachment.cgi?id=1436";
		#      hash = "sha256-czku8DgElisDv6minI67nNt6BS+vH6txslZdqiGaQR4=";
		#      excludes = [
		#        "SecurityPkg/Test/SecurityPkgHostTest.dsc"
		#      ];
		#    })
	      ];



	      unpackPhase = ''
		runHook preUnpack


		  chmod -R u+w .
	#         mkdir edk2 && cp -r  --no-preserve=ownership ${edk2-src}/* ./edk2/ && chmod -R u+w .        mkdir edk2-platforms && cp -r  --no-preserve=ownership ${edk2-platforms}/* ./edk2-platforms/ && chmod -R u+w .
	#         mkdir edk2-non-osi && cp -r  --no-preserve=ownership ${edk2-non-osi}/* ./edk2-non-osi/ && chmod -R u+w .
	#         mkdir edk2-nvidia && cp -r  --no-preserve=ownership ${edk2-nvidia}/* ./edk2-nvidia/ && chmod -R u+w .
	#         mkdir edk2-nvidia-non-osi && cp -r  --no-preserve=ownership ${edk2-nvidia-non-osi}/* ./edk2-nvidia-non-osi/ && chmod -R u+w .

	#         find ./edk2-nvidia/Silicon/NVIDIA/scripts -type f -exec sed -i "44 s|which|${which}/bin/which|" {} \;     
	#         sed -i '55d' ./edk2-nvidia/Silicon/NVIDIA/scripts/setenv_stuart.sh    

	#         find ./ -type f -exec sed -i "1 s|^#!.*python3|${python3}/bin/python3|" {} \;
	#         patchShebangs ./


		 mkdir ./Build && tar xzvf ${edk2-bin-pack}/nv-efi-bin-280524.tgz -C ./Build


		runHook postUnpack
	      '';



	      configurePhase = ''
		runHook preConfigure
		export WORKSPACE="$PWD"


		${lib.optionalString (trustedPublicCertPemFile != null) ''
		echo Using ${trustedPublicCertPemFile} as public certificate for capsule verification
		${lib.getExe buildPackages.openssl} x509 -outform DER -in ${trustedPublicCertPemFile} -out PublicCapsuleKey.cer
		python3 BaseTools/Scripts/BinToPcd.py -p gEfiSecurityPkgTokenSpaceGuid.PcdPkcs7CertBuffer -i PublicCapsuleKey.cer -o PublicCapsuleKey.cer.gEfiSecurityPkgTokenSpaceGuid.PcdPkcs7CertBuffer.inc
		python3 BaseTools/Scripts/BinToPcd.py -x -p gFmpDevicePkgTokenSpaceGuid.PcdFmpDevicePkcs7CertBufferXdr -i PublicCapsuleKey.cer -o PublicCapsuleKey.cer.gFmpDevicePkgTokenSpaceGuid.PcdFmpDevicePkcs7CertBufferXdr.inc
		''}

		runHook postConfigure
	      '';

	      buildPhase = ''
		    runHook preBuild

		 #    source ./edk2fin/edksetup.sh BaseTools

		 # The BUILDID_STRING and BUILD_DATE_TIME are used
		 # just by nvidia, not generic edk2
		 #    build -a ${targetArch} -b ${buildTarget} -t ${buildType} -p edk2-nvidia/Platform/NVIDIA/NVIDIA.common.dsc -n $NIX_BUILD_CORES \
		 #    -D BUILDID_STRING=${l4tVersion} \
		 #    -D BUILD_DATE_TIME="$(date --utc --iso-8601=seconds --date=@$SOURCE_DATE_EPOCH)" \
		 #    ${lib.optionalString (trustedPublicCertPemFile != null) "-D CUSTOM_CAPSULE_CERT"} \
		 #    $buildFlags

		    runHook postBuild
	      '';

	      installPhase = ''
		runHook preInstall
		echo ---INSTALL---
		mkdir $out
		cp -Rp * $out
		runHook postInstall
	      '';
	    });

	   # /edk2-nvidia/Silicon/NVIDIA/edk2nv/FormatUefiBinary.py

	  uefi-firmware = runCommand "uefi-firmware-${l4tVersion}"
	    {
	      nativeBuildInputs = [ python3 nukeReferences ];
	    } ''

	    echo ---MAKE FIRMWARE---
	    mkdir -p $out

#    python3 ${edk2-nvidia}/Silicon/NVIDIA/Tools/FormatUefiBinary.py \
#      ${jetson-edk2-uefi}/FV/UEFI_NS.Fv \
#      $out/uefi_jetson.bin
      cp ${jetson-edk2-uefi}/Build/uefi_jetson.bin $out/uefi_jetson.bin


#    python3 ${edk2-nvidia}/Silicon/NVIDIA/Tools/FormatUefiBinary.py \
#      ${jetson-edk2-uefi}/AARCH64/L4TLauncher.efi \
#      $out/L4TLauncher.efi
     cp ${jetson-edk2-uefi}/Build/BOOTAA64.efi $out/L4TLauncher.efi


    mkdir -p $out/dtbs
   
    #for filename in ${jetson-edk2-uefi}/Build/DeviceTree/OUTPUT/*.dtb; do
    #  cp $filename $out/dtbs/$(basename "$filename" ".dtb").dtbo
    #done
    cp ${jetson-edk2-uefi}/Build/DeviceTree/OUTPUT/L4TConfiguration.dtb $out/dtbs/L4TConfiguration.dtbo
 
    # Get rid of any string references to source(s)
    #nuke-refs $out/uefi_jetson.bin
  '';
in
{
  inherit edk2-jetson uefi-firmware;
}
