#!/usr/bin/env bash
# build_ce_cams.sh - builds the "CE Cams" desktop client for Linux (a .deb) from Network Optix's
# open-source nx_open (MPL 2.0), the same way build_ce_cams.bat does on Windows:
#   * source: the public 6.1.2.42921 release tag (protocol 6113, same as CE Cams Server)
#   * licensing: your license public key instead of Network Optix's (ce_cams_patch_fork.py)
#   * branding: "CE Cams" name, ids and artwork (ce_cams_branding.py), customization id "cecams"
#   * cloud: your CE Cams Cloud built in (cloudHost), so the client needs no desktop_client.ini
#
# Needs Ubuntu 20.04, 22.04 or 24.04 x64 (a VM, a Proxmox container or WSL2 works), about 80 GB of
# free disk and 16 GB of RAM. The first build downloads several GB and takes hours.
#
#   ./build_ce_cams.sh                          release build -> nx_open-build/distrib/*.deb
#   ./build_ce_cams.sh --dev                    faster developer build, run from the bin folder
#   ./build_ce_cams.sh --root ~/ce              where to put sources and build (default ~/ce)
#   ./build_ce_cams.sh --cloud-host cloud.example.com   (default: "cloud-url" in ./nxstub.json;
#                                                "none" for Nx's cloud)
#   ./build_ce_cams.sh --public-key license_public.pem  (default: downloaded from your cloud with
#                                                --cloud-host, so licenses it issues are valid)
#   ./build_ce_cams.sh --package my.zip         use a customization package you made instead
#   ./build_ce_cams.sh --android                the Android app instead (64-bit ARM phones):
#                                                a signed .apk in nx_open-build-android/distrib
#
# Run it from the folder with ce_cams_branding.py, ce_cams_patches.py, ce_cams_fetch_sources.py,
# ce_cams_bundle_libs.sh and ce_cams_patch_fork.py (this repository).
#
# Android notes: the build runs ce_cams_patches.py (Java for apidoctool, a C++23 shim for the
# NDK's libc++), points Nx recipes that download from Nx's internal server at the public
# sources (ce_cams_fetch_sources.py), skips Gradle's release lint and signs the .apk.
# Desktop on Ubuntu 25.10+: the client .deb also comes as *-bundled.deb with libxml2.so.2 inside
# (ce_cams_bundle_libs.sh), because those releases dropped it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HOME/ce"
PACKAGE=""
DEV=0
NAME="CE Cams"
ID="cecams"
COMPANY="CE"
CLOUD_HOST=""
PUBLIC_KEY=""
ANDROID=0

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT=$2; shift 2 ;;
        --package) PACKAGE=$2; shift 2 ;;
        --dev) DEV=1; shift ;;
        --name) NAME=$2; shift 2 ;;
        --id) ID=$2; shift 2 ;;
        --company) COMPANY=$2; shift 2 ;;
        --cloud-host) CLOUD_HOST=$2; shift 2 ;;
        --public-key) PUBLIC_KEY=$2; shift 2 ;;
        --android) ANDROID=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option $1 (see --help)"; exit 2 ;;
    esac
done

TAG='vms/6.1.2/release_42921_all'
BUILD_NUMBER='42921'
REPO='https://github.com/networkoptix/nx_open.git'
SRC="$ROOT/nx_open"
BUILD_DIR="$SRC-build"
ENV_DIR="$ROOT/buildenv"
PY="$ENV_DIR/bin/python"
DEFAULT_PKG_URL='https://artifactory.nxvms.dev/artifactory/artifacts/customization/metavms/package.zip'

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mERROR: %s\033[0m\n' "$*"; exit 1; }
step() { printf '\n\033[32m[%s/7] %s\033[0m\n' "$1" "$2"; }

case "$ROOT" in *" "*) fail "Use a folder path without spaces for --root." ;; esac
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd)
SRC="$ROOT/nx_open"; BUILD_DIR="$SRC-build"; ENV_DIR="$ROOT/buildenv"; PY="$ENV_DIR/bin/python"
# The Android app has its own build folder, so the desktop build stays as it is.
[ "$ANDROID" = 1 ] && BUILD_DIR="$SRC-build-android"

# The cloud: --cloud-host, else the last one used, else "cloud-url" in ./nxstub.json.
SAVED="$HERE/ce_cams_build_linux.json"
if [ -z "$CLOUD_HOST" ] && [ -f "$SAVED" ]; then
    CLOUD_HOST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cloudHost",""))' "$SAVED" || true)
fi
if [ -z "$CLOUD_HOST" ] && [ -f "$HERE/nxstub.json" ]; then
    CLOUD_HOST=$(python3 -c 'import json,sys,urllib.parse as u; print(u.urlsplit(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("cloud-url","")).hostname or "")' "$HERE/nxstub.json" || true)
fi
python3 -c 'import json,sys; json.dump({"root": sys.argv[1], "cloudHost": sys.argv[2] or "none"}, open(sys.argv[3], "w"))' "$ROOT" "$CLOUD_HOST" "$SAVED"
[ "$CLOUD_HOST" = none ] && CLOUD_HOST=""

# ---- 1. prerequisites ------------------------------------------------------------------------

step 1 'Checking prerequisites'
# (read in a subshell: os-release sets NAME and ID, which are this script's options too)
os_id=$( . /etc/os-release 2>/dev/null && echo "${ID:-}:${VERSION_ID:-}")
os_name=$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}")
case "$os_id" in
    ubuntu:20.04|ubuntu:22.04|ubuntu:24.04) echo "  $os_name" ;;
    *) warn "  ${os_name:-This system} isn't one nx_open supports (Ubuntu 20.04/22.04/24.04); trying anyway" ;;
esac
[ "$(uname -m)" = x86_64 ] || fail "Build on an x64 machine (nx_open cross-compiles for ARM from x64)."
missing=""
# chrpath and pkg-config: nx_open's Conan recipes check for them on every configure.
for c in git python3 curl chrpath pkg-config; do
    command -v "$c" >/dev/null || missing="$missing $c"
done
python3 -c 'import venv, ensurepip' 2>/dev/null || missing="$missing python3-venv"
if [ -n "$missing" ]; then
    warn "  Missing:$missing"
    say "  Installing them: sudo apt install -y git python3 python3-venv python3-pip curl chrpath pkg-config"
    sudo apt-get update && sudo apt-get install -y git python3 python3-venv python3-pip curl \
        chrpath pkg-config
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || fail "Python 3.8+ is needed."
free_gb=$(df -Pk "$ROOT" | awk 'NR==2 {print int($4/1024/1024)}')
[ "$free_gb" -ge 60 ] || warn "  Only ${free_gb} GB free in $ROOT; the build needs about 80 GB."

# ---- 2. sources --------------------------------------------------------------------------------

step 2 "Getting nx_open $TAG"
if [ -d "$SRC/.git" ]; then
    echo "  Using existing checkout $SRC"
else
    git clone --depth 1 --branch "$TAG" "$REPO" "$SRC"
fi

# ---- 3. build tools ----------------------------------------------------------------------------

step 3 'Setting up build tools (CMake, Ninja, Conan) in buildenv'
# nx_open's CMake (cmake/find_python.cmake) accepts Python 3.8 to 3.13 only. On a newer system
# (Ubuntu 26.04 has 3.14) a standalone Python 3.12 is fetched for the build alone.
py_ok() { "$1" -c 'import sys; sys.exit(not (3, 8) <= sys.version_info[:2] <= (3, 13))' 2>/dev/null; }
if [ -x "$PY" ] && ! py_ok "$PY"; then
    warn "  buildenv uses $("$PY" --version 2>&1), which nx_open doesn't accept; recreating it"
    rm -rf "$ENV_DIR"
fi
if [ ! -x "$PY" ]; then
    BASE_PY=""
    for c in python3.12 python3.11 python3.10 python3.13 python3; do
        if command -v "$c" >/dev/null && py_ok "$(command -v "$c")"; then BASE_PY=$(command -v "$c"); break; fi
    done
    if [ -z "$BASE_PY" ]; then
        say "  $(python3 --version 2>&1) is too new for nx_open; getting Python 3.12 with uv (just for the build)"
        UV="$ROOT/uv/bin/uv"
        if [ ! -x "$UV" ]; then
            # uv from PyPI, in its own small environment (nothing system-wide)
            python3 -m venv "$ROOT/uv" && "$ROOT/uv/bin/pip" install -q --disable-pip-version-check uv ||
                fail "Couldn't install uv. Install Python 3.12 yourself (e.g. from the deadsnakes PPA: python3.12-venv) and run this again."
        fi
        UV_PYTHON_INSTALL_DIR="$ROOT/python" "$UV" python install 3.12 ||
            fail "uv couldn't get Python 3.12."
        BASE_PY=$(UV_PYTHON_INSTALL_DIR="$ROOT/python" "$UV" python find 3.12)
    fi
    echo "  Build Python: $BASE_PY ($("$BASE_PY" --version 2>&1))"
    "$BASE_PY" -m venv "$ENV_DIR" || fail "Couldn't create the build environment with $BASE_PY (python3-venv missing?)."
fi
# The 6.1.2 tag pins PyYAML 5.1.1, which has no wheels for current Python; 6.x works the same.
sed 's/^PyYAML==.*$/PyYAML==6.0.2/' "$SRC/requirements.txt" > "$ROOT/requirements_ce_cams.txt"
"$PY" -m pip install --disable-pip-version-check -q -r "$ROOT/requirements_ce_cams.txt" pillow cryptography
export PATH="$ENV_DIR/bin:$PATH"                 # python (the build wants "python"), cmake, ninja, conan
export NX_CONAN_DOWNLOAD_CACHE="$ROOT/conan_cache"
mkdir -p "$NX_CONAN_DOWNLOAD_CACHE"

# ---- 4. licensing ------------------------------------------------------------------------------

step 4 'Putting your license public key into the client'
KEYDIR="$ROOT/license_key"
mkdir -p "$KEYDIR"
if [ -n "$PUBLIC_KEY" ]; then
    cp "$PUBLIC_KEY" "$KEYDIR/license_public.pem"
    echo "  From $PUBLIC_KEY"
elif [ -f "$HERE/nxstub_state/license_public.pem" ]; then
    cp "$HERE/nxstub_state/license_public.pem" "$KEYDIR/license_public.pem"
    echo "  From nxstub_state/license_public.pem"
elif [ -n "$CLOUD_HOST" ]; then
    # Only the public half: what the client checks licenses with. The cloud signs with the rest.
    curl -fsS "https://$CLOUD_HOST/cdb/ce/licenses/public-key" |
        "$PY" -c 'import json,sys; print(json.load(sys.stdin)["publicKey"], end="")' > "$KEYDIR/license_public.pem" ||
        fail "Couldn't get the license key from https://$CLOUD_HOST (is licensing on in the cloud?). Use --public-key FILE."
    echo "  From your cloud (https://$CLOUD_HOST)"
else
    fail "No license public key: pass --public-key FILE (license_public.pem from your server's state folder)."
fi
"$PY" "$HERE/ce_cams_patch_fork.py" --public-key "$KEYDIR/license_public.pem" "$SRC"
"$PY" "$HERE/ce_cams_patches.py" "$SRC" || fail "ce_cams_patches.py failed."

# ---- 5. branding -------------------------------------------------------------------------------

step 5 "Branding: $NAME"
if [ -n "$PACKAGE" ]; then
    [ -f "$PACKAGE" ] || fail "Customization package not found: $PACKAGE"
    PACKAGE_FILE=$(cd "$(dirname "$PACKAGE")" && pwd)/$(basename "$PACKAGE")
    echo "  Using your package $PACKAGE_FILE"
else
    DEFAULT_PKG="$ROOT/metavms_package.zip"
    if [ ! -f "$DEFAULT_PKG" ]; then
        echo '  Downloading the default open-source customization package'
        curl -fL -o "$DEFAULT_PKG" "$DEFAULT_PKG_URL" || fail "Could not download $DEFAULT_PKG_URL"
    fi
    PACKAGE_FILE="$ROOT/ce_cams_customization.zip"
    brand_args=(--name "$NAME" --id "$ID" --company "$COMPANY" --preview "$ROOT/ce_cams_icon.png")
    if [ -n "$CLOUD_HOST" ]; then
        brand_args+=(--cloud-host "$CLOUD_HOST")
        echo "  Cloud: $CLOUD_HOST (built in; no desktop_client.ini needed)"
    else
        warn '  No cloud host: the client uses the package default (Nx Cloud)'
    fi
    "$PY" "$HERE/ce_cams_branding.py" "$DEFAULT_PKG" "$PACKAGE_FILE" "${brand_args[@]}"
fi
PKG_ID=$("$PY" "$SRC/build_utils/customization/pack.py" get_value "$PACKAGE_FILE" id | tr -d '\r\n ')
echo "  Customization id: $PKG_ID (CE Cams Server's \"customization\" and \"brand\" must match)"

# ---- 6-7. build --------------------------------------------------------------------------------

step 6 'Building (the first run downloads dependencies and takes a long time)'
# A build folder generated for another source location can't be reused.
if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    home=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$BUILD_DIR/CMakeCache.txt")
    if [ -n "$home" ] && [ "$home" != "$SRC" ]; then
        warn "  $BUILD_DIR was generated for $home; starting it fresh"
        rm -rf "$BUILD_DIR"
    fi
fi
first=0
[ -f "$BUILD_DIR/CMakeCache.txt" ] || first=1
# Regenerate every time so the package and options in effect are exactly these.
rm -f "$BUILD_DIR/CMakeCache.txt"
args=("-DbuildNumber=$BUILD_NUMBER" "-DcustomizationPackageFile=$PACKAGE_FILE" -DwithTests=OFF)
if [ "$ANDROID" = 1 ]; then
    # Push notifications go through Firebase, which needs a google-services.json even to build.
    # This placeholder builds the app with push notifications off (the app copes: it just gets
    # no push token). A real file from your own Firebase project turns them on later.
    FIREBASE_JSON="$ROOT/android/google-services.json"
    if [ ! -f "$FIREBASE_JSON" ]; then
        mkdir -p "$(dirname "$FIREBASE_JSON")"
        cat > "$FIREBASE_JSON" <<FIREBASE
{
  "project_info": {"project_number": "100000000000", "project_id": "${ID}-placeholder",
                   "storage_bucket": "${ID}-placeholder.appspot.com"},
  "client": [{
    "client_info": {"mobilesdk_app_id": "1:100000000000:android:0000000000000000",
                    "android_client_info": {"package_name": "com.${ID}.mobile"}},
    "oauth_client": [],
    "api_key": [{"current_key": "AIzaSyA-placeholder-not-a-real-key-00000"}],
    "services": {"appinvite_service": {"other_platform_oauth_client": []}}
  }],
  "configuration_version": "1"
}
FIREBASE
        echo "  Push notifications: off (placeholder $FIREBASE_JSON)"
    fi
    args+=(-DtargetDevice=android_arm64 -DwithDesktopClient=OFF -DwithMobileClient=ON
           -DwithSdk=OFF -DwithDocumentation=OFF -DdeveloperBuild=OFF
           "-DfirebasePushNotificationSettingsFile=$FIREBASE_JSON"
           # Nx publishes Android builds of most dependencies, but not of Qt, ffmpeg, OpenAL and
           # SVT-AV1: Conan builds those from source on the first run (hours, ~40 GB). Later
           # runs reuse them from the build folder.
           -DextraConanArgs=--build=missing)
    if [ "$first" = 1 ] || [ ! -d "$BUILD_DIR/.conan/data/qt/6.9.1/_/_/package" ]; then
        warn "  First Android build: Qt, ffmpeg, OpenAL and SVT-AV1 are built from source for"
        warn "  Android (Nx doesn't publish them). Expect several extra hours and ~40 GB."
    fi
    # Conan brings the Android SDK, NDK and Java that nx_open was made with; one installed on this
    # machine (Android Studio) would be picked up instead and may not match.
    unset ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK ANDROID_NDK_HOME JAVA_HOME
    # Gradle's release lint task (lintVitalAnalyzeRelease) can't start its worker on the Java
    # Conan brings ("Could not initialize class AndroidLintWorkAction"). It only checks code, so
    # skip it, with an init script Gradle loads for every build.
    gradle_init="${GRADLE_USER_HOME:-$HOME/.gradle}/init.d/cecams-skip-lint.gradle"
    mkdir -p "$(dirname "$gradle_init")"
    cat > "$gradle_init" <<'GRADLE'
// CE Cams (build_ce_cams.sh): skip AGP's release lint; its worker can't start on the Conan JDK.
gradle.allprojects { p ->
    p.tasks.configureEach { t ->
        if (t.name.startsWith("lintVital")) { t.enabled = false }
    }
}
GRADLE
else
    # The mobile client isn't needed for the desktop build; skipping it saves hours.
    args+=(-DwithMobileClient=OFF)
    [ "$DEV" = 1 ] || args+=(-DdeveloperBuild=OFF)
fi
# Lets Conan apt-install any other system package it finds missing (only then does sudo ask for
# your password). Always on: a first build that failed half-way still needs it.
[ "$first" = 1 ] && say "  First build: Conan installs the system packages nx_open needs"
args+=(-DinstallSystemRequirements=ON)
# Conan 1 (which nx_open uses) describes this machine from the system GCC, and only knows GCC up
# to 14. The real compiler is a downloaded toolchain, so on a newer system describe the machine
# as Ubuntu 24.04 does (GCC 13): what Nx's prebuilt dependencies expect.
gcc_major=$(gcc -dumpversion 2>/dev/null | cut -d. -f1 || true)
if [ -n "$gcc_major" ] && [ "$gcc_major" -gt 13 ] 2>/dev/null; then
    profile="$BUILD_DIR/.conan/profiles/default"
    mkdir -p "$(dirname "$profile")"
    cat > "$profile" <<'PROFILE'
[settings]
os=Linux
os_build=Linux
arch=x86_64
arch_build=x86_64
compiler=gcc
compiler.version=13
compiler.libcxx=libstdc++
build_type=Release
[options]
[build_requires]
[env]
PROFILE
    echo "  System GCC $gcc_major is newer than Conan 1 knows; the build machine is described as GCC 13"
fi
LOG="$ROOT/build$([ "$ANDROID" = 1 ] && echo -android).log"
echo "  Log: $LOG"
for attempt in 1 2 3 4; do
    set +e
    # (nx_open's build.sh: configure into the build folder, then build; here with our own folder)
    { cmake "$SRC" -B "$BUILD_DIR" -GNinja "${args[@]}" && cmake --build "$BUILD_DIR"; } 2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
    set -e
    [ "$status" = 0 ] && break
    # Some recipes Nx doesn't publish binaries for download their sources from Nx's internal
    # server. Get those from the projects' own sites (checked against the recipe) and retry.
    "$PY" "$HERE/ce_cams_fetch_sources.py" "$LOG" "$BUILD_DIR/.conan/data" "$NX_CONAN_DOWNLOAD_CACHE" || break
    rm -f "$BUILD_DIR/CMakeCache.txt"
    say "  Retrying the build with those sources"
done
[ "$status" = 0 ] || fail "The build failed. See $LOG (search for 'error')."

step 7 'Done'
if [ "$ANDROID" = 1 ]; then
    # nx_open signs only with Network Optix's key, so the .apk comes out unsigned, and Android
    # won't install that. Sign it with CE Cams' own key, made once and kept in $ROOT/android.
    # Keep that folder: an update installs over the app only if it's signed with the same key.
    conan_data="$BUILD_DIR/.conan/data"
    keytool=$(find "$conan_data" -path '*openjdk*' -type f -name keytool 2>/dev/null | head -1)
    buildtools=$(find "$conan_data" -path '*AndroidSDK*' -type f -name apksigner 2>/dev/null |
                 sort -V | tail -1)
    buildtools=$(dirname "${buildtools:-/missing/x}")
    [ -x "$keytool" ] || fail "keytool (Java) not found under $conan_data"
    [ -x "$buildtools/apksigner" ] && [ -x "$buildtools/zipalign" ] ||
        fail "apksigner/zipalign (Android build tools) not found under $conan_data"
    java_home=$(dirname "$(dirname "$keytool")")
    KEYSTORE="$ROOT/android/${ID}.keystore"
    PASSFILE="$ROOT/android/${ID}.keystore.password"
    if [ ! -f "$KEYSTORE" ]; then
        say "  Creating the app signing key: $KEYSTORE (back it up)"
        ( umask 077; "$PY" -c 'import secrets; print(secrets.token_urlsafe(24))' > "$PASSFILE" )
        "$keytool" -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ID" \
            -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=$NAME" \
            -storepass:file "$PASSFILE" -keypass:file "$PASSFILE" >/dev/null ||
            fail "Couldn't create the signing key."
        chmod 600 "$KEYSTORE"
    fi
    # apksigner reads --ks-pass and --key-pass from the same file line by line: the keystore
    # password, then the key password. Both are the same here, so the file needs it twice.
    if [ "$(grep -c '' "$PASSFILE")" -lt 2 ]; then
        pass=$(head -n1 "$PASSFILE")
        ( umask 077; printf '%s\n%s\n' "$pass" "$pass" > "$PASSFILE" )
    fi
    unsigned=$(ls -t "$BUILD_DIR"/distrib/*.apk 2>/dev/null | grep -v -- '-signed\.apk$' | head -1 || true)
    [ -n "$unsigned" ] || fail "The build made no .apk in $BUILD_DIR/distrib."
    signed="${unsigned%.apk}-signed.apk"
    "$buildtools/zipalign" -p -f 4 "$unsigned" "$signed.aligned" || fail "zipalign failed."
    JAVA_HOME="$java_home" PATH="$java_home/bin:$PATH" "$buildtools/apksigner" sign \
        --ks "$KEYSTORE" --ks-key-alias "$ID" --ks-pass "file:$PASSFILE" \
        --key-pass "file:$PASSFILE" --out "$signed" "$signed.aligned" || fail "apksigner failed."
    rm -f "$signed.aligned" "$signed.idsig"
    say "  Android app: $signed"
    echo
    echo "Copy it to the phone and open it (allow \"install unknown apps\" for the file manager"
    echo "or browser you open it from), or with USB debugging on: adb install -r \"$signed\""
    echo "Back up $ROOT/android: updates must be signed with the same key."
elif [ "$DEV" = 1 ]; then
    say "  Run it from $BUILD_DIR/bin"
else
    # Ubuntu 25.10+ no longer has libxml2.so.2, which the client's web view is linked against:
    # there the client .deb gets its own copy (from Ubuntu 24.04) so it can be installed.
    if ! apt-get -s install libxml2 libxslt1.1 >/dev/null 2>&1; then
        for f in "$BUILD_DIR"/distrib/*client*.deb; do
            [ -e "$f" ] || continue
            case "$f" in *-bundled.deb) continue ;; esac
            say "  This Ubuntu has no libxml2.so.2: bundling it into $(basename "$f")"
            "$HERE/ce_cams_bundle_libs.sh" "$f" || fail "Bundling libxml2 into the client package failed."
        done
    fi
    say "  Packages: $BUILD_DIR/distrib"
    for f in "$BUILD_DIR"/distrib/*client*.deb; do
        [ -e "$f" ] && echo "    $(basename "$f")"
    done
    echo
    echo "Install on Ubuntu/Debian (from a folder apt can read, e.g. /tmp):"
    echo "  cp $BUILD_DIR/distrib/<the client .deb> /tmp/ && sudo apt install /tmp/<the client .deb>"
    echo "On Ubuntu 25.10 or newer, install the one ending in -bundled.deb."
fi
