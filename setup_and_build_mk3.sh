#!/usr/bin/env bash
# =============================================================================
#  setup_and_build.sh  —  HC-05 BT Controller
#  Author: Mark Harrington
#
#  Supports:  Debian 12 · Ubuntu 22.04+ · openSUSE Tumbleweed / Leap
#
#  Menu-driven build, sign, and deploy tool.
#  Run once to set up SDK, then use the menu for all subsequent operations.
#
#  Usage:  chmod +x setup_and_build.sh && ./setup_and_build.sh
# =============================================================================
set -euo pipefail

# ── Distro detection — must run before anything else ─────────────────────────
DISTRO="unknown"
DISTRO_PRETTY="Unknown Linux"
PKG_MGR="apt"          # apt | zypper

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    ID="${ID:-unknown}"
    case "$ID" in
        debian|ubuntu|raspbian|linuxmint|pop)
            DISTRO="debian"
            DISTRO_PRETTY="${PRETTY_NAME:-Debian/Ubuntu}"
            PKG_MGR="apt"
            ;;
        opensuse*|suse|sles)
            DISTRO="opensuse"
            DISTRO_PRETTY="${PRETTY_NAME:-openSUSE}"
            PKG_MGR="zypper"
            ;;
        *)
            # Fallback: check which package manager is present
            if command -v zypper &>/dev/null; then
                DISTRO="opensuse"
                DISTRO_PRETTY="${PRETTY_NAME:-openSUSE-compatible}"
                PKG_MGR="zypper"
            elif command -v apt-get &>/dev/null; then
                DISTRO="debian"
                DISTRO_PRETTY="${PRETTY_NAME:-Debian-compatible}"
                PKG_MGR="apt"
            else
                echo "  ERROR: Could not identify package manager (apt or zypper)."
                echo "  Supported distros: Debian, Ubuntu, openSUSE Tumbleweed/Leap."
                exit 1
            fi
            ;;
    esac
fi

# ── pkg_install: single function for all package installs ────────────────────
# Usage: pkg_install <pkg-deb> [pkg-zypper]
# If pkg-zypper is omitted the same name is used for both distros.
pkg_install() {
    local deb_pkg="$1"
    local zyp_pkg="${2:-$1}"
    case "$PKG_MGR" in
        apt)    sudo apt-get install -y "$deb_pkg" >/dev/null 2>&1 ;;
        zypper) sudo zypper --non-interactive install "$zyp_pkg"   >/dev/null 2>&1 ;;
    esac
}

pkg_update() {
    case "$PKG_MGR" in
        apt)    sudo apt-get update -q ;;
        zypper) sudo zypper --non-interactive refresh ;;
    esac
}

# Java 17 package names differ between distros
java17_pkg_install() {
    case "$PKG_MGR" in
        apt)    sudo apt-get install -y openjdk-17-jdk ;;
        zypper) sudo zypper --non-interactive install java-17-openjdk java-17-openjdk-devel ;;
    esac
}

# ── find_java17: locate Java 17 home directory on this system ─────────────────
# Sets and exports JAVA_HOME to the Java 17 installation.
# Also writes org.gradle.java.home to gradle.properties so Gradle always
# uses Java 17 regardless of the system default — no manual export needed.
find_java17() {
    local jh=""

    # 1. Search known distro-specific paths first
    local candidates=(
        # Debian/Ubuntu
        "/usr/lib/jvm/java-17-openjdk-amd64"
        "/usr/lib/jvm/java-17-openjdk"
        "/usr/lib/jvm/java-17"
        # openSUSE
        "/usr/lib64/jvm/java-17-openjdk"
        "/usr/lib64/jvm/java-17"
        "/usr/lib/jvm/java-17-openjdk"
    )
    for candidate in "${candidates[@]}"; do
        if [ -x "$candidate/bin/java" ]; then
            jh="$candidate"
            break
        fi
    done

    # 2. Fallback: use update-alternatives / readlink
    if [ -z "$jh" ] && command -v update-alternatives &>/dev/null; then
        local alt_java
        alt_java=$(update-alternatives --list java 2>/dev/null | grep "java-17" | head -1)
        if [ -n "$alt_java" ]; then
            # alt_java is e.g. /usr/lib/jvm/java-17-.../bin/java
            jh=$(dirname "$(dirname "$alt_java")")
        fi
    fi

    # 3. Fallback: find under /usr/lib/jvm or /usr/lib64/jvm
    if [ -z "$jh" ]; then
        jh=$(find /usr/lib/jvm /usr/lib64/jvm -maxdepth 2 \
                  -name "java" -path "*/java-17*/bin/java" 2>/dev/null \
             | head -1)
        [ -n "$jh" ] && jh=$(dirname "$(dirname "$jh")")
    fi

    if [ -z "$jh" ]; then
        return 1   # not found
    fi

    export JAVA_HOME="$jh"

    # Write org.gradle.java.home into the project's gradle.properties so
    # Gradle always picks Java 17 regardless of the shell's active java.
    local gp="$PROJECT_DIR/gradle.properties"
    if [ -f "$gp" ]; then
        # Update or append
        if grep -q "org.gradle.java.home" "$gp"; then
            sed -i "s|org.gradle.java.home=.*|org.gradle.java.home=$jh|" "$gp"
        else
            echo "org.gradle.java.home=$jh" >> "$gp"
        fi
    else
        echo "org.gradle.java.home=$jh" > "$gp"
    fi

    ok "Java 17 home: $jh  (written to gradle.properties)"
    ok "JAVA_HOME set for this session"
    return 0
}

# ── Paths & versions ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_SDK_ROOT="${ANDROID_HOME:-$HOME/Android/Sdk}"
CMDLINE_TOOLS_VER="11076708"
BUILD_TOOLS_VER="34.0.0"
PLATFORM_VER="android-34"
GRADLE_VERSION="8.2"
APP_ID="com.mark.hc05controller"          # updated automatically when project is set
KEY_ALIAS="hc05key"

# PROJECT_DIR and APK paths are set by prompt_project_dir() at runtime
PROJECT_DIR=""
APK_DEBUG=""
APK_RELEASE_UNSIGNED=""
APK_RELEASE_SIGNED=""
KEYSTORE=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';      DIM='\033[2m';  NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()      { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()     { echo -e "  ${RED}✖${NC}  $1"; }
info()    { echo -e "  ${CYAN}ℹ${NC}  $1"; }
section() { echo -e "\n${BOLD}${CYAN}  ── $1${NC}"; }

# ── Set all path variables derived from PROJECT_DIR ───────────────────────────
set_project_paths() {
    APK_DEBUG="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
    APK_RELEASE_UNSIGNED="$PROJECT_DIR/app/build/outputs/apk/release/app-release-unsigned.apk"
    APK_RELEASE_SIGNED="$PROJECT_DIR/app/build/outputs/apk/release/app-release-signed.apk"
    KEYSTORE="$PROJECT_DIR/hc05_key.jks"

    # Try to read APP_ID from the project's build.gradle if it exists
    local gradle_app="$PROJECT_DIR/app/build.gradle"
    if [ -f "$gradle_app" ]; then
        local found_id
        found_id=$(grep -E "^\s*applicationId" "$gradle_app" \
                   | head -1 | sed "s/.*applicationId[[:space:]]*['\"]//;s/['\"].*//")
        if [ -n "$found_id" ]; then
            APP_ID="$found_id"
        fi
    fi
}

# ── Prompt the user for the project directory ─────────────────────────────────
prompt_project_dir() {
    local default_dir="$SCRIPT_DIR"

    # If there's already a PROJECT_DIR set (e.g. re-prompting from menu),
    # use that as the default instead.
    [ -n "$PROJECT_DIR" ] && default_dir="$PROJECT_DIR"

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Project Location                                       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Enter the path to your Android project root."
    info "This is the directory that contains  build.gradle  and  gradlew."
    echo ""
    echo -e "  ${DIM}Examples:${NC}"
    echo "    ~/Android_projects/HC05_BT_App"
    echo "    /home/mark/projects/MyApp"
    echo "    .   (current directory)"
    echo ""

    while true; do
        read -rp "  Project path [$default_dir]: " raw_input
        raw_input="${raw_input:-$default_dir}"

        # Expand ~ and resolve to absolute path
        raw_input="${raw_input/#\~/$HOME}"
        local resolved
        resolved="$(cd "$raw_input" 2>/dev/null && pwd)" || {
            # Directory doesn't exist — offer to create it
            echo ""
            warn "Directory does not exist: $raw_input"
            read -rp "  Create it? [Y/n]: " yn
            yn="${yn:-y}"
            if [[ "$yn" =~ ^[Yy] ]]; then
                mkdir -p "$raw_input" && {
                    resolved="$(cd "$raw_input" && pwd)"
                    ok "Created: $resolved"
                } || {
                    err "Could not create directory. Check permissions."
                    continue
                }
            else
                echo "  Enter a different path."
                continue
            fi
        }

        PROJECT_DIR="$resolved"

        # Warn if it doesn't look like an Android project yet
        local looks_ok=false
        [ -f "$PROJECT_DIR/build.gradle"  ] && looks_ok=true
        [ -f "$PROJECT_DIR/gradlew"       ] && looks_ok=true
        [ -f "$PROJECT_DIR/settings.gradle" ] && looks_ok=true

        if [ "$looks_ok" = false ]; then
            echo ""
            warn "No build.gradle, gradlew, or settings.gradle found in:"
            echo "    $PROJECT_DIR"
            warn "This may not be an Android project root, or it hasn't been"
            warn "scaffolded yet. The build options will set it up on first run."
            echo ""
            read -rp "  Use this directory anyway? [Y/n]: " yn
            yn="${yn:-y}"
            [[ "$yn" =~ ^[Yy] ]] || continue
        fi

        set_project_paths
        break
    done

    echo ""
    ok "Project directory: $PROJECT_DIR"
    ok "App ID:            $APP_ID"
    ok "Keystore:          $KEYSTORE"
    echo ""
    read -rp "  Press Enter to continue to the main menu..." _
}

print_banner() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   HC-05 BT Controller — Build & Deploy Tool             ║${NC}"
    echo -e "${CYAN}║   Mark Harrington  |  Oukitel C2                        ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  Distro  : ${DISTRO_PRETTY}"
    echo -e "${CYAN}║${NC}  Pkg mgr : ${PKG_MGR}"
    echo -e "${CYAN}║${NC}  Project : ${PROJECT_DIR:-not set}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

pause() {
    echo ""
    read -rp "  Press Enter to return to the menu..." _
}

apk_status() {
    # Show which APKs currently exist
    echo ""
    echo -e "  ${DIM}Current build status:${NC}"
    if [ -f "$APK_DEBUG" ]; then
        local sz; sz=$(du -h "$APK_DEBUG" | cut -f1)
        echo -e "    ${GREEN}●${NC}  Debug APK       $sz  →  $APK_DEBUG"
    else
        echo -e "    ${DIM}○  Debug APK       not built${NC}"
    fi
    if [ -f "$APK_RELEASE_SIGNED" ]; then
        local sz; sz=$(du -h "$APK_RELEASE_SIGNED" | cut -f1)
        echo -e "    ${GREEN}●${NC}  Release APK     $sz  →  $APK_RELEASE_SIGNED"
    elif [ -f "$APK_RELEASE_UNSIGNED" ]; then
        local sz; sz=$(du -h "$APK_RELEASE_UNSIGNED" | cut -f1)
        echo -e "    ${YELLOW}●${NC}  Release APK     $sz  (unsigned) →  $APK_RELEASE_UNSIGNED"
    else
        echo -e "    ${DIM}○  Release APK      not built${NC}"
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT  —  runs automatically before any build action
# ══════════════════════════════════════════════════════════════════════════════

preflight() {
    section "Pre-flight checks  (${DISTRO_PRETTY})"

    # ── Java 17 ───────────────────────────────────────────────────────────────
    # We always need Java 17 for AGP 8.x / Gradle 8.x regardless of what
    # the system default 'java' points to (you have 21 installed too).
    if ! find_java17; then
        warn "Java 17 not found — installing..."
        pkg_update
        java17_pkg_install
        if ! find_java17; then
            err "Java 17 installation failed or could not be located."
            err "Check:  sudo $([ "$PKG_MGR" = apt ] && echo 'apt-get install openjdk-17-jdk' || echo 'zypper install java-17-openjdk')"
            return 1
        fi
    fi

    # ── Core tools ────────────────────────────────────────────────────────────
    for cmd_pkg in "wget:wget" "unzip:unzip" "curl:curl"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            warn "$cmd missing — installing..."
            pkg_install "$pkg"
        fi
    done

    # ── Android SDK cmdline-tools ─────────────────────────────────────────────
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    if [ ! -f "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
        info "Downloading Android command-line tools..."
        wget -q --show-progress \
            "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VER}_latest.zip" \
            -O /tmp/cmdline-tools.zip
        unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_SDK_ROOT/cmdline-tools"
        if [ -d "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" ]; then
            mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" \
               "$ANDROID_SDK_ROOT/cmdline-tools/latest"
        fi
        rm /tmp/cmdline-tools.zip
        ok "Android cmdline-tools installed"
    else
        ok "Android cmdline-tools present"
    fi

    local SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

    # ── SDK components ────────────────────────────────────────────────────────
    if [ ! -d "$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VER" ]; then
        info "Installing SDK components (build-tools, platform)..."
        yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
        "$SDKMANAGER" \
            "platform-tools" \
            "build-tools;${BUILD_TOOLS_VER}" \
            "platforms;${PLATFORM_VER}"
        ok "SDK components installed"
    else
        ok "SDK components present"
    fi

    # Export for this session
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin"

    # Persist to ~/.bashrc (and ~/.profile on openSUSE for login shells)
    if ! grep -q "ANDROID_HOME" "$HOME/.bashrc" 2>/dev/null; then
        {
            echo ""
            echo "# Android SDK — added by setup_and_build.sh (${DISTRO_PRETTY})"
            echo "export ANDROID_HOME=\"$ANDROID_SDK_ROOT\""
            echo "export PATH=\"\$PATH:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin\""
        } >> "$HOME/.bashrc"
        ok "ANDROID_HOME added to ~/.bashrc"
    fi
    # openSUSE: also write to ~/.profile so login shells (e.g. KDE/GNOME terminals) pick it up
    if [ "$DISTRO" = "opensuse" ] && ! grep -q "ANDROID_HOME" "$HOME/.profile" 2>/dev/null; then
        {
            echo ""
            echo "# Android SDK — added by setup_and_build.sh (${DISTRO_PRETTY})"
            echo "export ANDROID_HOME=\"$ANDROID_SDK_ROOT\""
            echo "export PATH=\"\$PATH:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin\""
        } >> "$HOME/.profile"
        ok "ANDROID_HOME also added to ~/.profile (openSUSE login shells)"
    fi

    # ── Gradle wrapper ────────────────────────────────────────────────────────
    cd "$PROJECT_DIR"
    mkdir -p gradle/wrapper

    if [ ! -f "gradlew" ]; then
        info "Writing gradlew launcher..."
        cat > gradlew << 'GRADLEW'
#!/bin/sh
set -e
APP_HOME="$(cd "$(dirname "$0")" && pwd -P)"
exec java \
    -classpath "$APP_HOME/gradle/wrapper/gradle-wrapper.jar" \
    "-Dorg.gradle.appname=$(basename "$0")" \
    org.gradle.wrapper.GradleWrapperMain "$@"
GRADLEW
        chmod +x gradlew
        ok "gradlew launcher written"
    else
        ok "gradlew present"
    fi

    # Write wrapper properties every time (idempotent)
    cat > gradle/wrapper/gradle-wrapper.properties << PROPS
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
PROPS

    local WRAPPER_JAR="gradle/wrapper/gradle-wrapper.jar"
    local jar_ok=false
    [ -f "$WRAPPER_JAR" ] && unzip -t "$WRAPPER_JAR" >/dev/null 2>&1 && jar_ok=true

    if [ "$jar_ok" = false ]; then
        rm -f "$WRAPPER_JAR"
        info "Downloading gradle-wrapper.jar..."
        wget -q --show-progress \
            "https://github.com/gradle/gradle/raw/v${GRADLE_VERSION}.0/gradle/wrapper/gradle-wrapper.jar" \
            -O "$WRAPPER_JAR" 2>/dev/null || \
        wget -q --show-progress \
            "https://raw.githubusercontent.com/gradle/gradle/v${GRADLE_VERSION}.0/gradle/wrapper/gradle-wrapper.jar" \
            -O "$WRAPPER_JAR" || {
            err "All download attempts failed."
            echo "    Manually place gradle-wrapper.jar at: $PROJECT_DIR/$WRAPPER_JAR"
            return 1
        }
        if ! unzip -t "$WRAPPER_JAR" >/dev/null 2>&1; then
            rm -f "$WRAPPER_JAR"
            err "Downloaded jar is corrupt. Re-run to retry."
            return 1
        fi
        ok "gradle-wrapper.jar downloaded"
    else
        ok "gradle-wrapper.jar present"
    fi

    echo ""
    ok "Pre-flight complete"
}


# ══════════════════════════════════════════════════════════════════════════════
#  1. BUILD DEBUG APK
# ══════════════════════════════════════════════════════════════════════════════

build_debug() {
    print_banner
    section "Build — Debug APK"
    preflight || return 1

    echo ""
    info "Running:  ./gradlew assembleDebug"
    info "(First run downloads Gradle ${GRADLE_VERSION} — may take a minute)"
    echo ""
    cd "$PROJECT_DIR"
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    ./gradlew assembleDebug

    echo ""
    if [ -f "$APK_DEBUG" ]; then
        local sz; sz=$(du -h "$APK_DEBUG" | cut -f1)
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   ✅  DEBUG BUILD SUCCESSFUL                             ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  APK:  $APK_DEBUG"
        echo -e "${GREEN}║${NC}  Size: $sz"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    else
        err "Build reported success but APK not found. Check Gradle output above."
    fi
    pause
}


# ══════════════════════════════════════════════════════════════════════════════
#  2. BUILD RELEASE APK  (unsigned — sign separately via option 3)
# ══════════════════════════════════════════════════════════════════════════════

build_release() {
    print_banner
    section "Build — Release APK (unsigned)"
    preflight || return 1

    echo ""
    info "Running:  ./gradlew assembleRelease"
    echo ""
    cd "$PROJECT_DIR"
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    ./gradlew assembleRelease

    echo ""
    if [ -f "$APK_RELEASE_UNSIGNED" ]; then
        local sz; sz=$(du -h "$APK_RELEASE_UNSIGNED" | cut -f1)
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   ✅  RELEASE BUILD SUCCESSFUL (unsigned)                ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  APK:  $APK_RELEASE_UNSIGNED"
        echo -e "${GREEN}║${NC}  Size: $sz"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  Use option 3 from the main menu to sign this APK."
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    else
        err "Build reported success but APK not found. Check Gradle output above."
    fi
    pause
}


# ══════════════════════════════════════════════════════════════════════════════
#  3. SIGN APK
# ══════════════════════════════════════════════════════════════════════════════

sign_apk() {
    print_banner
    section "Sign Release APK"

    # ── Refresh paths — Gradle sometimes writes a slightly different filename ──
    # Always call set_project_paths() first so paths are current for this session.
    set_project_paths

    # If the exact filename doesn't exist, search the release output dir with find
    if [ ! -f "$APK_RELEASE_UNSIGNED" ]; then
        local release_dir="$PROJECT_DIR/app/build/outputs/apk/release"
        local found_unsigned
        found_unsigned=$(find "$release_dir" -maxdepth 1 \
                              -name "*release*unsigned*.apk" -o \
                              -name "*release*.apk" ! -name "*signed*" 2>/dev/null \
                         | head -1)
        if [ -n "$found_unsigned" ]; then
            APK_RELEASE_UNSIGNED="$found_unsigned"
            warn "APK found at non-standard path: $APK_RELEASE_UNSIGNED"
        fi
    fi

    local TOOLS="$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VER"
    local ZIPALIGN="$TOOLS/zipalign"
    local APKSIGNER="$TOOLS/apksigner"

    # Check tools exist
    if [ ! -f "$ZIPALIGN" ] || [ ! -f "$APKSIGNER" ]; then
        err "Build-tools not found at $TOOLS"
        warn "Run option 1 or 2 first to install the SDK."
        pause; return 1
    fi

    # Check unsigned APK exists — with clear diagnostic if not
    if [ ! -f "$APK_RELEASE_UNSIGNED" ]; then
        err "No unsigned release APK found."
        echo ""
        echo -e "  ${DIM}Looked in:${NC}"
        echo "    $APK_RELEASE_UNSIGNED"
        echo ""
        echo -e "  ${DIM}Release output directory contents:${NC}"
        local release_dir="$PROJECT_DIR/app/build/outputs/apk/release"
        if [ -d "$release_dir" ]; then
            ls -lh "$release_dir" 2>/dev/null || echo "    (empty)"
        else
            echo "    $release_dir  does not exist yet"
        fi
        echo ""
        warn "Run option 2 (Build Release APK) then return here."
        pause; return 1
    fi

    # ── Ensure Java 17 is active for apksigner ───────────────────────────────
    find_java17 >/dev/null 2>&1 || true   # best-effort; apksigner may work with 21 too

    echo ""
    info "Unsigned APK : $APK_RELEASE_UNSIGNED"
    info "Output (signed): $APK_RELEASE_SIGNED"
    echo ""

    # ── Generate keystore if it doesn't exist ─────────────────────────────────
    if [ ! -f "$KEYSTORE" ]; then
        warn "No keystore found. Generating a new one at:"
        echo "    $KEYSTORE"
        echo ""
        warn "You will be prompted for keystore and key passwords."
        warn "Remember these — you need them every time you sign an update."
        echo ""

        read -rp "  Enter keystore password (min 6 chars): " KS_PASS
        read -rp "  Confirm keystore password:             " KS_PASS2
        if [ "$KS_PASS" != "$KS_PASS2" ]; then
            err "Passwords do not match. Aborting."; pause; return 1
        fi
        read -rp "  Enter key password (or Enter to reuse keystore password): " KEY_PASS
        KEY_PASS="${KEY_PASS:-$KS_PASS}"

        keytool -genkey -v \
            -keystore "$KEYSTORE" \
            -alias "$KEY_ALIAS" \
            -keyalg RSA \
            -keysize 2048 \
            -validity 10000 \
            -dname "CN=Mark Harrington, OU=Dev, O=MH, L=Unknown, ST=Unknown, C=GB" \
            -storepass "$KS_PASS" \
            -keypass "$KEY_PASS" 2>&1 | grep -E "(Generating|keytool|Warning|stored)" || true

        ok "Keystore generated: $KEYSTORE"
        echo ""
        warn "Back up $KEYSTORE securely — losing it means you cannot update this app on the Play Store."
    else
        ok "Keystore found: $KEYSTORE"
        echo ""
        read -rp "  Enter keystore password: " KS_PASS
        KEY_PASS="$KS_PASS"
    fi

    # ── Zipalign ──────────────────────────────────────────────────────────────
    local ALIGNED="$PROJECT_DIR/app/build/outputs/apk/release/app-release-aligned.apk"
    echo ""
    info "Step 1/2 — Zipalign..."
    "$ZIPALIGN" -v 4 "$APK_RELEASE_UNSIGNED" "$ALIGNED" > /dev/null
    ok "Aligned: $ALIGNED"

    # ── Sign ─────────────────────────────────────────────────────────────────
    info "Step 2/2 — Signing..."
    "$APKSIGNER" sign \
        --ks "$KEYSTORE" \
        --ks-key-alias "$KEY_ALIAS" \
        --ks-pass "pass:$KS_PASS" \
        --key-pass "pass:$KEY_PASS" \
        --out "$APK_RELEASE_SIGNED" \
        "$ALIGNED"
    rm -f "$ALIGNED"

    local sz; sz=$(du -h "$APK_RELEASE_SIGNED" | cut -f1)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅  APK SIGNED SUCCESSFULLY                            ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  APK:  $APK_RELEASE_SIGNED"
    echo -e "${GREEN}║${NC}  Size: $sz"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    pause
}


# ══════════════════════════════════════════════════════════════════════════════
#  4. UPLOAD TO PHONE — sub-menu
# ══════════════════════════════════════════════════════════════════════════════

# ── Helper: let user choose which APK to upload ───────────────────────────────
# Sets SELECTED_APK and SELECTED_APK_LABEL.  Returns 1 if no APKs at all.
SELECTED_APK=""
SELECTED_APK_LABEL=""

choose_apk() {
    # Refresh paths for this session
    set_project_paths

    # Build list of available APKs with metadata
    local -a apk_paths=()
    local -a apk_labels=()

    if [ -f "$APK_RELEASE_SIGNED" ]; then
        apk_paths+=("$APK_RELEASE_SIGNED")
        local sz ts
        sz=$(du -h "$APK_RELEASE_SIGNED" | cut -f1)
        ts=$(date -r "$APK_RELEASE_SIGNED" "+%d %b %Y %H:%M" 2>/dev/null || echo "unknown date")
        apk_labels+=("Release SIGNED      ${sz}   built ${ts}")
    fi

    # Also search for signed APKs with non-standard names
    local extra_signed
    extra_signed=$(find "$PROJECT_DIR/app/build/outputs/apk/release" -maxdepth 1 \
                        -name "*signed*.apk" 2>/dev/null | grep -v "^$APK_RELEASE_SIGNED$" || true)
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        apk_paths+=("$f")
        local sz ts
        sz=$(du -h "$f" | cut -f1)
        ts=$(date -r "$f" "+%d %b %Y %H:%M" 2>/dev/null || echo "unknown")
        apk_labels+=("Release SIGNED (alt) ${sz}   built ${ts}   $(basename "$f")")
    done <<< "$extra_signed"

    if [ -f "$APK_RELEASE_UNSIGNED" ]; then
        apk_paths+=("$APK_RELEASE_UNSIGNED")
        local sz ts
        sz=$(du -h "$APK_RELEASE_UNSIGNED" | cut -f1)
        ts=$(date -r "$APK_RELEASE_UNSIGNED" "+%d %b %Y %H:%M" 2>/dev/null || echo "unknown date")
        apk_labels+=("Release UNSIGNED    ${sz}   built ${ts}   ⚠ not signed")
    fi

    if [ -f "$APK_DEBUG" ]; then
        apk_paths+=("$APK_DEBUG")
        local sz ts
        sz=$(du -h "$APK_DEBUG" | cut -f1)
        ts=$(date -r "$APK_DEBUG" "+%d %b %Y %H:%M" 2>/dev/null || echo "unknown date")
        apk_labels+=("Debug               ${sz}   built ${ts}   ⚠ debug build")
    fi

    if [ "${#apk_paths[@]}" -eq 0 ]; then
        err "No APK files found in $PROJECT_DIR"
        warn "Build the app first — options 1 (debug) or 2 (release)."
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}Select APK to upload:${NC}"
    echo ""
    local i
    for i in "${!apk_paths[@]}"; do
        echo -e "    $((i+1)))  ${apk_labels[$i]}"
    done
    echo ""

    local choice
    while true; do
        read -rp "  Enter number [1-${#apk_paths[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#apk_paths[@]} )); then
            SELECTED_APK="${apk_paths[$((choice-1))]}"
            SELECTED_APK_LABEL="${apk_labels[$((choice-1))]}"
            break
        fi
        warn "Enter a number between 1 and ${#apk_paths[@]}."
    done

    echo ""
    ok "Selected: $SELECTED_APK_LABEL"
    ok "Path    : $SELECTED_APK"
    echo ""
    return 0
}

# ── 4a. Wi-Fi / RF wireless (ADB over TCP/IP) ─────────────────────────────────
upload_wifi() {
    print_banner
    section "Upload via Wi-Fi (ADB over TCP/IP)"
    choose_apk || { pause; return; }

    echo ""
    info "Requirements:"
    echo "    • Phone and computer on the same Wi-Fi network"
    echo "    • USB Debugging enabled on the Oukitel C2"
    echo "    • On Android 11+: Wireless Debugging enabled in Developer Options"
    echo ""

    # Offer two sub-methods
    echo -e "  ${BOLD}Connection method:${NC}"
    echo "    1)  Android 11+  — Wireless Debugging  (no USB required at all)"
    echo "    2)  Any Android  — ADB-over-TCP  (connect USB once to enable, then unplug)"
    echo ""
    read -rp "  Enter choice [1/2]: " wifi_method

    if [ "${wifi_method:-1}" = "1" ]; then
        # ── Android 11+ Wireless Debugging ───────────────────────────────────
        echo ""
        info "On the phone:"
        echo "    Settings → Developer Options → Wireless Debugging → Enable"
        echo "    Tap 'Pair device with pairing code' — note the IP:port and code"
        echo ""
        read -rp "  Enter IP:port shown on phone (e.g. 192.168.1.42:37155): " PAIR_ADDR
        read -rp "  Enter 6-digit pairing code: " PAIR_CODE
        echo ""
        info "Pairing..."
        if adb pair "$PAIR_ADDR" "$PAIR_CODE"; then
            ok "Paired successfully"
            echo ""
            read -rp "  Enter connection IP:port (shown under 'Wireless Debugging'): " CONN_ADDR
            adb connect "$CONN_ADDR"
        else
            err "Pairing failed. Check the IP:port and code shown on the phone."
            pause; return
        fi
    else
        # ── ADB over TCP (any Android) ────────────────────────────────────────
        echo ""
        info "Step 1 — Connect the phone via USB and enable TCP:"
        echo "    (Phone must have USB Debugging on)"
        echo ""
        info "Enabling ADB over TCP on connected USB device..."
        if ! adb devices | grep -q "device$"; then
            err "No device found over USB. Connect the phone and enable USB Debugging."
            pause; return
        fi
        adb tcpip 5555
        ok "ADB TCP mode enabled on port 5555"
        echo ""
        warn "You can now unplug the USB cable."
        echo ""
        read -rp "  Enter phone IP address (Settings → About Phone → Status → IP): " PHONE_IP
        info "Connecting to $PHONE_IP:5555..."
        if ! adb connect "${PHONE_IP}:5555"; then
            err "Connection failed. Ensure phone and PC are on the same network."
            pause; return
        fi
        CONN_ADDR="${PHONE_IP}:5555"
    fi

    echo ""
    info "Installing $SELECTED_APK_LABEL..."
    info "File: $SELECTED_APK"
    if adb -s "$CONN_ADDR" install -r "$SELECTED_APK"; then
        ok "Installed successfully on $CONN_ADDR"
        ok "APK type: $SELECTED_APK_LABEL"
    else
        err "Installation failed. See adb output above."
    fi
    pause
}

# ── 4b. Via website (Python HTTP server + browser download) ──────────────────
upload_web() {
    print_banner
    section "Upload via Website (local HTTP server)"
    choose_apk || { pause; return; }

    echo ""
    info "This starts a local HTTP server on port 8080."
    info "Open the URL on the phone browser to download and install the APK."
    echo ""

    # Detect local IP (first non-loopback IPv4)
    local MY_IP
    MY_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ip route get 1 | awk '{print $7;exit}')
    local APK_FILENAME; APK_FILENAME=$(basename "$SELECTED_APK")
    local SERVE_DIR;    SERVE_DIR=$(dirname "$SELECTED_APK")

    info "Serving: $SELECTED_APK_LABEL"
    echo ""
    echo -e "  ${GREEN}On the phone, open:${NC}"
    echo -e "  ${BOLD}    http://${MY_IP}:8080/${APK_FILENAME}${NC}"
    echo ""
    warn "The phone browser may warn about installing unknown apps."
    warn "Allow 'Install from unknown sources' for the browser in phone Settings."
    echo ""
    info "Press Ctrl+C when the download is complete to stop the server."
    echo ""

    # Serve using Python 3 if available, otherwise Python 2
    cd "$SERVE_DIR"
    if command -v python3 &>/dev/null; then
        python3 -m http.server 8080
    elif command -v python &>/dev/null; then
        python -m SimpleHTTPServer 8080
    else
        err "Python not found."
        case "$PKG_MGR" in
            apt)    info "Install with:  sudo apt-get install python3" ;;
            zypper) info "Install with:  sudo zypper install python3"  ;;
        esac
    fi
    cd "$PROJECT_DIR"
    pause
}

# ── 4c. Via USB (standard ADB) ───────────────────────────────────────────────
upload_usb() {
    print_banner
    section "Upload via USB (ADB)"
    choose_apk || { pause; return; }

    echo ""
    info "USB Debugging setup on the Oukitel C2:"
    echo "    Settings → About Phone → tap Build Number 7 times"
    echo "    Developer Options → USB Debugging → ON"
    echo ""
    info "Checking for connected devices..."

    if ! command -v adb &>/dev/null; then
        warn "adb not found in PATH — trying SDK location..."
        export PATH="$PATH:$ANDROID_SDK_ROOT/platform-tools"
        if ! command -v adb &>/dev/null; then
            err "adb not found. Run option 1 or 2 first to install platform-tools."
            pause; return
        fi
    fi

    local devices; devices=$(adb devices | grep -v "^List" | grep "device$" | wc -l)
    if [ "$devices" -eq 0 ]; then
        err "No device found. Check USB cable and USB Debugging setting."
        echo ""
        echo "  Tip: run  adb devices  to see what's connected."
        pause; return
    fi

    if [ "$devices" -gt 1 ]; then
        warn "Multiple devices found:"
        adb devices
        echo ""
        read -rp "  Enter device serial (from list above): " DEV_SERIAL
        ADB_TARGET="-s $DEV_SERIAL"
    else
        ADB_TARGET=""
        ok "Device found: $(adb devices | grep "device$" | awk '{print $1}')"
    fi

    echo ""
    info "Installing $SELECTED_APK..."
    # shellcheck disable=SC2086
    if adb $ADB_TARGET install -r "$SELECTED_APK"; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   ✅  INSTALLED SUCCESSFULLY                             ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  APK type: $SELECTED_APK_LABEL"
        echo -e "${GREEN}║${NC}  File    : $SELECTED_APK"
        echo -e "${GREEN}║${NC}  App ID  : $APP_ID"
        echo -e "${GREEN}║${NC}  Launch  : adb shell monkey -p $APP_ID 1"
        echo -e "${GREEN}║${NC}  Logcat  : adb logcat | grep HC05"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    else
        err "Installation failed. See adb output above."
        warn "If you see INSTALL_FAILED_UPDATE_INCOMPATIBLE, uninstall the existing app first:"
        echo "    adb $ADB_TARGET uninstall $APP_ID"
    fi
    pause
}

# ── 4d. Via Bluetooth (obexftp / bluez-tools) ────────────────────────────────
upload_bluetooth() {
    print_banner
    section "Upload via Bluetooth"
    choose_apk || { pause; return; }

    echo ""
    info "Requirements:"
    echo "    • Bluetooth enabled on both PC and phone"
    echo "    • Phone set to visible/discoverable"
    echo "    • obexftp or bluez-tools installed on this PC"
    echo ""

    # Check for obexftp or bt-obex
    local BT_TOOL=""
    if command -v obexftp &>/dev/null; then
        BT_TOOL="obexftp"
    elif command -v bluetooth-sendto &>/dev/null; then
        BT_TOOL="bluetooth-sendto"
    elif command -v bt-obex &>/dev/null; then
        BT_TOOL="bt-obex"
    fi

    if [ -z "$BT_TOOL" ]; then
        warn "No Bluetooth file-transfer tool found. Installing obexftp + bluez..."
        if pkg_install "obexftp" "obexftp" && pkg_install "bluez" "bluez"; then
            BT_TOOL="obexftp"
        else
            err "Could not install obexftp."
            echo ""
            info "Manual install:"
            case "$PKG_MGR" in
                apt)    echo "    sudo apt-get install obexftp bluez" ;;
                zypper) echo "    sudo zypper install obexftp bluez"  ;;
            esac
            pause; return
        fi
    fi

    ok "Tool: $BT_TOOL"
    echo ""

    # Scan for devices
    info "Scanning for nearby Bluetooth devices (10 seconds)..."
    echo "    Make sure the Oukitel C2 is discoverable."
    echo ""
    local scan_results
    if command -v hcitool &>/dev/null; then
        scan_results=$(timeout 10 hcitool scan 2>/dev/null || true)
        if [ -n "$scan_results" ]; then
            echo "$scan_results"
        else
            warn "No devices found by scan. Entering address manually."
        fi
    else
        warn "hcitool not available. Skipping scan."
    fi

    echo ""
    read -rp "  Enter phone Bluetooth MAC address (e.g. AA:BB:CC:DD:EE:FF): " BT_MAC
    BT_MAC=$(echo "$BT_MAC" | tr '[:lower:]' '[:upper:]')

    if [[ ! "$BT_MAC" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; then
        err "Invalid MAC address format. Expected AA:BB:CC:DD:EE:FF"
        pause; return
    fi

    local APK_FILENAME; APK_FILENAME=$(basename "$SELECTED_APK")
    echo ""
    info "Sending: $SELECTED_APK_LABEL"
    info "File   : $APK_FILENAME  →  $BT_MAC"
    info "Accept the incoming file transfer on the phone when prompted."
    echo ""

    case "$BT_TOOL" in
        obexftp)
            if obexftp --nopath --noconn --uuid none \
                        --bluetooth "$BT_MAC" --channel 9 \
                        --put "$SELECTED_APK"; then
                ok "File sent via obexftp"
            else
                warn "Channel 9 failed — trying channel auto-detection..."
                obexftp --bluetooth "$BT_MAC" --put "$SELECTED_APK" || {
                    err "Transfer failed. Check the phone is discoverable and accepting files."
                }
            fi
            ;;
        bluetooth-sendto)
            bluetooth-sendto --device="$BT_MAC" "$SELECTED_APK" && ok "File sent."
            ;;
        bt-obex)
            bt-obex -p "$BT_MAC" "$SELECTED_APK" && ok "File sent."
            ;;
    esac

    echo ""
    info "After the transfer completes on the phone:"
    echo "    Open the file manager or notification → tap the APK to install."
    warn "Allow 'Install from unknown sources' for the file manager in Settings."
    pause
}

# ── Upload sub-menu ───────────────────────────────────────────────────────────
upload_menu() {
    while true; do
        print_banner
        section "Upload to Phone"
        apk_status
        echo -e "  ${BOLD}Choose upload method:${NC}"
        echo ""
        echo "    a)  Wi-Fi / RF Wireless   (ADB over TCP/IP — same network)"
        echo "    b)  Website               (local HTTP server — phone browser)"
        echo "    c)  USB                   (ADB direct — fastest, most reliable)"
        echo "    d)  Bluetooth             (obexftp / bluez — no cable or network)"
        echo "    0)  Back to main menu"
        echo ""
        read -rp "  Enter choice [a/b/c/d/0]: " upload_choice

        case "${upload_choice,,}" in
            a) upload_wifi      ;;
            b) upload_web       ;;
            c) upload_usb       ;;
            d) upload_bluetooth ;;
            0) return           ;;
            *) warn "Invalid choice — enter a, b, c, d, or 0." ; sleep 1 ;;
        esac
    done
}


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════════════

main_menu() {
    # Ask for project location once before entering the menu loop
    prompt_project_dir

    while true; do
        print_banner
        apk_status
        echo -e "  ${BOLD}Main Menu:${NC}"
        echo ""
        echo "    1)  Build Debug APK             (fast, includes debug symbols)"
        echo "    2)  Build Release APK            (optimised, ProGuard minified)"
        echo "    3)  Sign Release APK             (zipalign + apksigner)"
        echo "    4)  Upload APK to Phone          (Wi-Fi / Web / USB / Bluetooth)"
        echo "    5)  Change project directory     (currently: ${PROJECT_DIR:-not set})"
        echo ""
        echo "    0)  Exit"
        echo ""
        read -rp "  Enter choice [0-5]: " main_choice

        case "$main_choice" in
            1) build_debug        ;;
            2) build_release      ;;
            3) sign_apk           ;;
            4) upload_menu        ;;
            5) prompt_project_dir ;;
            0)
                echo ""
                echo -e "  ${CYAN}Goodbye.${NC}"
                echo ""
                exit 0
                ;;
            *)
                warn "Invalid choice — enter 0, 1, 2, 3, 4, or 5."
                sleep 1
                ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────────────────────
main_menu
