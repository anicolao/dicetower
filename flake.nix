{
  description = "DiceTower Android build, emulator and model-export tools";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/9fbb54b33e91ee4ca368e35a78e0613c720600b3";
  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" ];
      each = nixpkgs.lib.genAttrs systems;
      tools = system:
        let
          pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; android_sdk.accept_license = true; }; };
          sdkFor = emulator: (pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "36" ]; buildToolsVersions = [ "36.0.0" ];
            includeCmake = false; includeNDK = false;
            includeEmulator = emulator; includeSystemImages = emulator;
            systemImageTypes = [ "google_apis" ];
            abiVersions = [ (if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64") ];
          }).androidsdk;
          sdk = sdkFor false;
          environment = selected: ''
            export ANDROID_HOME="${selected}/libexec/android-sdk"
            export ANDROID_SDK_ROOT="$ANDROID_HOME"
            export JAVA_HOME="${pkgs.jdk17.home}"
            export DICETOWER_ANDROID_ABI="${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64"}"
            export GRADLE_USER_HOME="''${DICETOWER_GRADLE_HOME:-$PWD/.gradle-home}"
            export GRADLE_OPTS="''${GRADLE_OPTS:-} -Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/36.0.0/aapt2"
          '';
          gradleApp = name: task: pkgs.writeShellApplication {
            inherit name; runtimeInputs = [ pkgs.gradle pkgs.jdk17 sdk pkgs.git ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              ${environment sdk}
              gradle --no-daemon --console=plain -p apps/android ${task} "$@"
            '';
          };
          exportModel = pkgs.writeShellApplication {
            name = "dicetower-export-android-model";
            runtimeInputs = [ pkgs.uv pkgs.python312 pkgs.git ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              export UV_PROJECT_ENVIRONMENT="$PWD/local-models/android-venv"
              uv run --project tools/android-model --locked --python ${pkgs.python312}/bin/python tools/android-model/export_model.py "$@"
            '';
          };
          deviceTest = pkgs.writeShellApplication {
            name = "dicetower-android-device-test";
            runtimeInputs = [ pkgs.gradle pkgs.jdk17 (sdkFor true) pkgs.git pkgs.bash pkgs.coreutils pkgs.gnugrep ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              ${environment (sdkFor true)}
              bash apps/android/scripts/device-test.sh "$@"
            '';
          };
        in { inherit pkgs sdkFor environment sdk exportModel deviceTest; build = gradleApp "dicetower-android-build" "assembleDebug";
          test = gradleApp "dicetower-android-test" "testDebugUnitTest lintDebug -PskipModelCheck=true"; };
    in {
      apps = each (system: let t = tools system; in {
        android-build = { type = "app"; program = "${t.build}/bin/dicetower-android-build"; };
        android-device-test = { type = "app"; program = "${t.deviceTest}/bin/dicetower-android-device-test"; };
        android-test = { type = "app"; program = "${t.test}/bin/dicetower-android-test"; };
        export-android-model = { type = "app"; program = "${t.exportModel}/bin/dicetower-export-android-model"; };
      });
      devShells = each (system: let t = tools system; shell = sdk: t.pkgs.mkShell {
        packages = [ sdk t.pkgs.jdk17 t.pkgs.gradle t.pkgs.uv t.pkgs.python312 t.pkgs.git t.pkgs.gh t.pkgs.curl t.pkgs.jq t.pkgs.unzip t.pkgs.firebase-tools t.pkgs.nodejs_24 ];
        shellHook = t.environment sdk;
      }; in { default = shell t.sdk; android-emulator = shell (t.sdkFor true); model-export = t.pkgs.mkShell { packages = [ t.pkgs.uv t.pkgs.python312 ]; };
        firebase = t.pkgs.mkShellNoCC { packages = [ t.pkgs.nodejs_24 t.pkgs.jdk21 t.pkgs.firebase-tools t.pkgs.git ]; shellHook = ''export JAVA_HOME="${t.pkgs.jdk21.home}"''; };
      });
    };
}
