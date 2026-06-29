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

# ── pin_java_home: write JAVA_HOME path into gradle.properties ────────────────
# Called by find_java17() and switch_java() after a path is confirmed.
pin_java_home() {
    local jh="$1"
    export JAVA_HOME="$jh"
    local gp="$PROJECT_DIR/gradle.properties"
    if [ -f "$gp" ]; then
        if grep -q "org.gradle.java.home" "$gp"; then
            sed -i "s|org.gradle.java.home=.*|org.gradle.java.home=$jh|" "$gp"
        else
            echo "org.gradle.java.home=$jh" >> "$gp"
        fi
    else
        echo "org.gradle.java.home=$jh" > "$gp"
    fi
    ok "JAVA_HOME = $jh"
    ok "org.gradle.java.home written to gradle.properties"
}

# ── find_java17: locate Java 17 and pin it ────────────────────────────────────
find_java17() {
    local jh=""

    # 1. Known distro-specific paths
    local candidates=(
        "/usr/lib/jvm/java-17-openjdk-amd64"   # Debian/Ubuntu
        "/usr/lib/jvm/java-17-openjdk"
        "/usr/lib/jvm/java-17"
        "/usr/lib64/jvm/jre-17-openjdk"         # openSUSE (jre path used by alts)
        "/usr/lib64/jvm/java-17-openjdk"
        "/usr/lib64/jvm/java-17"
        "/usr/lib/jvm/java-17-openjdk"
    )
    for candidate in "${candidates[@]}"; do
        # Accept either bin/java in the dir itself or one level up (jre paths)
        if [ -x "$candidate/bin/java" ]; then
            jh="$candidate"; break
        fi
    done

    # 2. Fallback: update-alternatives (Debian)
    if [ -z "$jh" ] && command -v update-alternatives &>/dev/null; then
        local alt
        alt=$(update-alternatives --list java 2>/dev/null | grep "java-17" | head -1)
        [ -n "$alt" ] && jh=$(dirname "$(dirname "$alt")")
    fi

    # 3. Fallback: alts (openSUSE) — parse target path for priority ~2705
    if [ -z "$jh" ] && command -v alts &>/dev/null; then
        local alt
        alt=$(alts -l java 2>/dev/null | grep -i "17" | grep "Target:" | head -1 \
              | sed 's/.*Target:[[:space:]]*//' | sed 's|/bin/java||')
        [ -n "$alt" ] && [ -d "$alt" ] && jh="$alt"
    fi

    # 4. Last resort: find
    if [ -z "$jh" ]; then
        local found
        found=$(find /usr/lib/jvm /usr/lib64/jvm -maxdepth 3 \
                     -name "java" -path "*/java-17*/bin/java" \
                     -o -name "java" -path "*/jre-17*/bin/java" 2>/dev/null \
                | head -1)
        [ -n "$found" ] && jh=$(dirname "$(dirname "$found")")
    fi

    [ -z "$jh" ] && return 1

    pin_java_home "$jh"
    return 0
}

# ── switch_java: interactive menu to change the active Java version ────────────
# Supports both openSUSE (alts) and Debian (update-alternatives).
# After switching, updates gradle.properties immediately.
switch_java() {
    print_banner
    section "Switch Java Version"
    echo ""
    info "Detected distro: $DISTRO_PRETTY"
    echo ""

    # ── Collect available Java installations ──────────────────────────────────
    local -a java_versions=()   # display labels
    local -a java_paths=()      # bin/java full paths
    local -a java_priorities=() # priority numbers (openSUSE only)

    if [ "$DISTRO" = "opensuse" ] && command -v alts &>/dev/null; then
        # Parse:  Priority: NNNN   Target: /path/to/bin/java
        # Note: the '!' suffix on priority means "currently selected by force"
        info "Reading installed JVMs via:  alts -l java"
        echo ""
        local raw_alts
        raw_alts=$(alts -l java 2>/dev/null)

        # Show raw output so user can see exactly what alts reports
        echo "$raw_alts" | grep -E "(Priority:|Target:)" | while read -r line; do
            echo "    $line"
        done
        echo ""

        # Parse Priority+Target pairs (they appear on consecutive lines)
        local prev_priority=""
        while IFS= read -r line; do
            if [[ "$line" =~ Priority:[[:space:]]*([0-9]+) ]]; then
                prev_priority="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ Target:[[:space:]]*(.+/bin/java) ]]; then
                local target="${BASH_REMATCH[1]}"
                local jh_path
                jh_path=$(dirname "$(dirname "$target")")
                local ver_label
                # Extract version hint from path
                ver_label=$(echo "$jh_path" | grep -oE "jre-[0-9.]+-openjdk|java-[0-9.]+-openjdk|jre-[0-9]+|java-[0-9]+" | head -1)
                [ -z "$ver_label" ] && ver_label=$(basename "$jh_path")
                local current_marker=""
                [ "${prev_priority}!" = "$(alts -l java 2>/dev/null \
                    | grep -A1 "Priority:.*!" | grep "Target:" \
                    | grep -F "$target" | head -1 | wc -l)" ] && current_marker=" ← ACTIVE"
                java_versions+=("Priority ${prev_priority}  ${ver_label}${current_marker}")
                java_paths+=("$target")
                java_priorities+=("$prev_priority")
            fi
        done <<< "$raw_alts"

    elif command -v update-alternatives &>/dev/null; then
        # Debian: update-alternatives --list java → one path per line
        info "Reading installed JVMs via:  update-alternatives --list java"
        echo ""
        local current_java
        current_java=$(readlink -f /usr/bin/java 2>/dev/null || true)
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            local ver_label
            ver_label=$(echo "$path" | grep -oE "java-[0-9]+" | head -1)
            [ -z "$ver_label" ] && ver_label=$(basename "$(dirname "$(dirname "$path")")")
            local current_marker=""
            [ "$path" = "$current_java" ] && current_marker=" ← ACTIVE"
            java_versions+=("${ver_label}  ${path}${current_marker}")
            java_paths+=("$path")
            java_priorities+=("")
        done < <(update-alternatives --list java 2>/dev/null)
    else
        err "No Java alternative management tool found (alts or update-alternatives)."
        warn "Manually set JAVA_HOME and re-run."
        pause; return 1
    fi

    if [ "${#java_paths[@]}" -eq 0 ]; then
        err "No Java installations found via alternatives system."
        warn "Install Java 17:  $([ "$PKG_MGR" = zypper ] && echo 'sudo zypper install java-17-openjdk' || echo 'sudo apt-get install openjdk-17-jdk')"
        pause; return 1
    fi

    # ── Display numbered menu ─────────────────────────────────────────────────
    echo -e "  ${BOLD}Available Java versions:${NC}"
    echo ""
    local i
    for i in "${!java_versions[@]}"; do
        echo "    $((i+1)))  ${java_versions[$i]}"
    done
    echo ""
    warn "For Gradle 8.x / AGP 8.x you must use Java 17."
    warn "Java 21+ will cause build failures with this project configuration."
    echo ""

    local choice
    while true; do
        read -rp "  Enter number to switch to [1-${#java_paths[@]}] or 0 to cancel: " choice
        [ "$choice" = "0" ] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#java_paths[@]} )); then
            break
        fi
        warn "Enter a number between 1 and ${#java_paths[@]}, or 0 to cancel."
    done

    local idx=$((choice - 1))
    local chosen_path="${java_paths[$idx]}"
    local chosen_priority="${java_priorities[$idx]}"
    local chosen_jh
    chosen_jh=$(dirname "$(dirname "$chosen_path")")

    echo ""
    info "Switching to: $chosen_path"

    if [ "$DISTRO" = "opensuse" ] && command -v alts &>/dev/null; then
        # openSUSE: sudo alts -s -n java -p <priority>
        if [ -n "$chosen_priority" ]; then
            info "Running: sudo alts -s -n java -p ${chosen_priority}"
            if sudo alts -s -n java -p "$chosen_priority"; then
                ok "System Java switched to priority ${chosen_priority}"
            else
                err "alts switch failed. You may need to run this manually:"
                echo "    sudo alts -s -n java -p ${chosen_priority}"
            fi
        else
            warn "Priority not parsed — cannot switch system default automatically."
            warn "Run manually:  sudo alts -s -n java -p <priority_number>"
        fi
    else
        # Debian: sudo update-alternatives --set java /path/to/bin/java
        info "Running: sudo update-alternatives --set java ${chosen_path}"
        if sudo update-alternatives --set java "$chosen_path"; then
            ok "System Java switched to: $chosen_path"
        else
            err "update-alternatives failed."
            echo "    sudo update-alternatives --set java ${chosen_path}"
        fi
    fi

    # ── Pin the chosen Java in gradle.properties regardless of system switch ──
    echo ""
    info "Pinning selected Java in gradle.properties..."
    if [ -n "$PROJECT_DIR" ]; then
        pin_java_home "$chosen_jh"
    else
        warn "PROJECT_DIR not set — gradle.properties not updated yet."
        warn "This will be done automatically when you select a project."
    fi

    echo ""
    info "Active java after switch:"
    java -version 2>&1 | head -1 | sed 's/^/    /'
    echo ""
    ok "Switch complete. Gradle is pinned to: $chosen_jh"
    pause
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
    KS_CONF="$PROJECT_DIR/hc05_key.conf"

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

        # ── Auto-correct: strip trailing /app — user gave module dir not root ──
        if [[ "$PROJECT_DIR" == */app ]]; then
            local corrected="${PROJECT_DIR%/app}"
            echo ""
            warn "Path ends in /app — that is the module directory, not the project root."
            warn "Auto-correcting to: $corrected"
            PROJECT_DIR="$corrected"
        fi

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

    # Locate the APK via find — handles:
    #   • Standard path  app/build/outputs/apk/debug/app-debug.apk
    #   • Non-standard module names (module name != "app")
    #   • Gradle "up-to-date" where no new file is written but old one exists
    local debug_dir="$PROJECT_DIR/app/build/outputs/apk/debug"
    local found_apk=""
    if [ -d "$debug_dir" ]; then
        found_apk=$(find "$debug_dir" -maxdepth 2 -name "*.apk" \
                    2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    fi
    # Also search the whole build tree in case module name differs
    if [ -z "$found_apk" ]; then
        found_apk=$(find "$PROJECT_DIR" -path "*/outputs/apk/debug/*.apk" \
                    -maxdepth 8 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    fi

    echo ""
    if [ -n "$found_apk" ] && [ -f "$found_apk" ]; then
        APK_DEBUG="$found_apk"   # update global for this session
        local sz ts
        sz=$(du -h "$found_apk" | cut -f1)
        ts=$(date -r "$found_apk" "+%d %b %Y %H:%M" 2>/dev/null || echo "")
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   ✅  DEBUG BUILD SUCCESSFUL                             ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  APK:  $found_apk"
        echo -e "${GREEN}║${NC}  Size: $sz   Built: $ts"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    else
        err "Gradle reported success but no debug APK was found."
        echo ""
        echo -e "  ${DIM}Searched under: $PROJECT_DIR/app/build/outputs/apk/debug${NC}"
        echo -e "  ${DIM}Full build tree: $PROJECT_DIR (paths matching */outputs/apk/debug/*.apk)${NC}"
        echo ""
        warn "Check that PROJECT_DIR is the project root (contains gradlew), not a module subdirectory."
        warn "Current PROJECT_DIR: $PROJECT_DIR"
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

    # Clean up any stale signed/aligned artifacts from previous runs so find
    # does not confuse them with the newly built unsigned APK.
    local release_dir="$PROJECT_DIR/app/build/outputs/apk/release"
    if [ -d "$release_dir" ]; then
        info "Removing stale signed/aligned APKs from previous builds..."
        find "$release_dir" -maxdepth 1 \
             \( -name "*signed*.apk" -o -name "*aligned*.apk" \) \
             -delete 2>/dev/null || true
    fi

    echo ""
    info "Running:  ./gradlew assembleRelease"
    echo ""
    cd "$PROJECT_DIR"
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
    ./gradlew assembleRelease

    # Find the actual output — wide scan so non-standard module names and
    # Gradle "up-to-date" cached builds are both detected correctly.
    local found_apk=""
    if [ -d "$release_dir" ]; then
        found_apk=$(find "$release_dir" -maxdepth 2 -name "*.apk" \
                         ! -name "*signed*" ! -name "*aligned*" \
                    2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    fi
    # Fallback: walk the full build tree (handles non-"app" module names)
    if [ -z "$found_apk" ]; then
        found_apk=$(find "$PROJECT_DIR" -path "*/outputs/apk/release/*.apk" \
                         ! -name "*signed*" ! -name "*aligned*" \
                    -maxdepth 10 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    fi

    echo ""
    if [ -n "$found_apk" ] && [ -f "$found_apk" ]; then
        APK_RELEASE_UNSIGNED="$found_apk"
        local sz ts
        sz=$(du -h "$found_apk" | cut -f1)
        ts=$(date -r "$found_apk" "+%d %b %Y %H:%M" 2>/dev/null || echo "")
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   ✅  RELEASE BUILD SUCCESSFUL (unsigned)                ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  APK:  $found_apk"
        echo -e "${GREEN}║${NC}  Size: $sz   Built: $ts"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  Use option 3 from the main menu to sign this APK."
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    else
        err "Gradle reported success but no unsigned APK was found."
        echo ""
        echo -e "  ${DIM}Searched: $release_dir and full build tree${NC}"
        if [ -d "$release_dir" ]; then
            echo -e "  ${DIM}Contents:${NC}"
            ls -lh "$release_dir" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
        else
            echo "    Directory does not exist yet."
        fi
        echo ""
        warn "Check that PROJECT_DIR is the project root (contains gradlew), not a module subdirectory."
        warn "Current PROJECT_DIR: $PROJECT_DIR"
    fi
    pause
}


# ══════════════════════════════════════════════════════════════════════════════
#  3. SIGN APK
# ══════════════════════════════════════════════════════════════════════════════

# Keystore sidecar config — stores all DN fields and alias beside the .jks.
# This file is PLAIN TEXT — do NOT store passwords in it.
# Path: $PROJECT_DIR/hc05_key.conf
KS_CONF=""   # set by set_project_paths()

# Read sidecar config into variables (non-fatal if missing)
load_ks_conf() {
    KS_CN=""; KS_OU=""; KS_O=""; KS_L=""; KS_ST=""; KS_C=""
    KS_ALIAS_CONF=""; KS_VALIDITY=""
    if [ -f "$KS_CONF" ]; then
        # shellcheck disable=SC1090
        source "$KS_CONF" 2>/dev/null || true
    fi
}

# Save sidecar config
save_ks_conf() {
    cat > "$KS_CONF" << CONF
# Keystore configuration — generated by setup_and_build_mk4.sh
# DO NOT store passwords here.
KS_CN="${KS_CN}"
KS_OU="${KS_OU}"
KS_O="${KS_O}"
KS_L="${KS_L}"
KS_ST="${KS_ST}"
KS_C="${KS_C}"
KS_ALIAS_CONF="${KS_ALIAS_CONF}"
KS_VALIDITY="${KS_VALIDITY}"
CONF
    ok "Keystore config saved: $KS_CONF"
}

# Prompt all DN fields interactively
prompt_ks_details() {
    echo ""
    echo -e "  ${BOLD}${CYAN}Keystore identity details${NC}"
    echo -e "  ${DIM}These are embedded in your signing certificate.${NC}"
    echo -e "  ${DIM}They identify you as the app publisher to Android and Google Play.${NC}"
    echo ""
    warn "Once you publish to the Play Store with a key, these details are"
    warn "permanent for that listing. Changing them requires a NEW key, which"
    warn "breaks Play Store update continuity."
    echo ""

    read -rp "  Full name / Common Name   (CN) [${KS_CN:-Mark Harrington}]: " _v
    KS_CN="${_v:-${KS_CN:-Mark Harrington}}"

    read -rp "  Organisational Unit       (OU) [${KS_OU:-Dev}]: " _v
    KS_OU="${_v:-${KS_OU:-Dev}}"

    read -rp "  Organisation              (O)  [${KS_O:-MH Software}]: " _v
    KS_O="${_v:-${KS_O:-MH Software}}"

    read -rp "  City / Locality           (L)  [${KS_L:-Unknown}]: " _v
    KS_L="${_v:-${KS_L:-Unknown}}"

    read -rp "  State / Province          (ST) [${KS_ST:-Unknown}]: " _v
    KS_ST="${_v:-${KS_ST:-Unknown}}"

    read -rp "  2-letter country code     (C)  [${KS_C:-GB}]: " _v
    KS_C="${_v:-${KS_C:-GB}}"
    KS_C="${KS_C^^}"   # force uppercase

    read -rp "  Key alias                      [${KS_ALIAS_CONF:-hc05key}]: " _v
    KS_ALIAS_CONF="${_v:-${KS_ALIAS_CONF:-hc05key}}"

    read -rp "  Validity in years              [${KS_VALIDITY:-27}]: " _v
    KS_VALIDITY="${_v:-${KS_VALIDITY:-27}}"
    # Clamp to sane range
    if ! [[ "$KS_VALIDITY" =~ ^[0-9]+$ ]] || (( KS_VALIDITY < 1 || KS_VALIDITY > 100 )); then
        KS_VALIDITY=27
    fi
    local validity_days=$(( KS_VALIDITY * 365 ))

    echo ""
    echo -e "  ${BOLD}Certificate DN will be:${NC}"
    echo "    CN=${KS_CN}, OU=${KS_OU}, O=${KS_O}, L=${KS_L}, ST=${KS_ST}, C=${KS_C}"
    echo "    Alias: ${KS_ALIAS_CONF}   Validity: ${KS_VALIDITY} years (${validity_days} days)"
    echo ""
}

sign_apk() {
    print_banner
    section "Sign Release APK"

    # ── Refresh paths for this session ────────────────────────────────────────
    set_project_paths
    load_ks_conf

    # ── Find the unsigned APK — wide scan so recompile is detected ────────────
    local release_dir="$PROJECT_DIR/app/build/outputs/apk/release"
    local unsigned_apk=""

    # Priority 1: standard Gradle filename
    [ -f "$APK_RELEASE_UNSIGNED" ] && unsigned_apk="$APK_RELEASE_UNSIGNED"

    # Priority 2: any release APK that is NOT signed/aligned (find newest)
    if [ -z "$unsigned_apk" ] && [ -d "$release_dir" ]; then
        unsigned_apk=$(find "$release_dir" -maxdepth 1 -name "*.apk" \
                            ! -name "*signed*" ! -name "*aligned*" \
                       2>/dev/null \
                       | xargs ls -t 2>/dev/null | head -1)
    fi

    local TOOLS="$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VER"
    local ZIPALIGN="$TOOLS/zipalign"
    local APKSIGNER="$TOOLS/apksigner"

    if [ ! -f "$ZIPALIGN" ] || [ ! -f "$APKSIGNER" ]; then
        err "Build-tools not found at $TOOLS"
        warn "Run option 1 or 2 first to install the SDK."
        pause; return 1
    fi

    if [ -z "$unsigned_apk" ] || [ ! -f "$unsigned_apk" ]; then
        err "No unsigned release APK found."
        echo ""
        echo -e "  ${DIM}Searched in: $release_dir${NC}"
        if [ -d "$release_dir" ]; then
            echo -e "  ${DIM}Contents:${NC}"
            ls -lh "$release_dir" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
        else
            echo "    Directory does not exist yet."
        fi
        echo ""
        warn "Run option 2 (Build Release APK) then return here."
        pause; return 1
    fi

    find_java17 >/dev/null 2>&1 || true

    echo ""
    info "Unsigned APK : $unsigned_apk"

    # ── Keystore management ───────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}${CYAN}══ Keystore ══${NC}"
    echo ""

    local ks_action="use_existing"

    if [ -f "$KEYSTORE" ]; then
        ok "Existing keystore found: $KEYSTORE"
        if [ -f "$KS_CONF" ]; then
            load_ks_conf
            echo ""
            echo -e "  ${DIM}Stored details:${NC}"
            echo "    CN=${KS_CN}, OU=${KS_OU}, O=${KS_O}"
            echo "    L=${KS_L}, ST=${KS_ST}, C=${KS_C}"
            echo "    Alias: ${KS_ALIAS_CONF}   Validity: ${KS_VALIDITY} years"
        fi
        echo ""
        echo -e "  ${BOLD}What would you like to do?${NC}"
        echo "    1)  Sign with existing keystore  (recommended)"
        echo "    2)  Edit identity details and regenerate keystore"
        echo "         ${RED}⚠ This creates a NEW key — Play Store updates will break${NC}"
        echo "    3)  Use a different external .jks file"
        echo ""
        read -rp "  Enter choice [1/2/3]: " ks_choice
        case "${ks_choice:-1}" in
            2) ks_action="regenerate" ;;
            3) ks_action="external"   ;;
            *) ks_action="use_existing" ;;
        esac
    else
        warn "No keystore found at: $KEYSTORE"
        echo ""
        echo -e "  ${BOLD}Keystore options:${NC}"
        echo "    1)  Create new keystore (enter your details)"
        echo "    2)  Use an existing external .jks file"
        echo ""
        read -rp "  Enter choice [1/2]: " ks_choice
        case "${ks_choice:-1}" in
            2) ks_action="external" ;;
            *) ks_action="create"   ;;
        esac
    fi

    # ── Handle each action ────────────────────────────────────────────────────
    local KS_PASS="" KEY_PASS=""

    case "$ks_action" in

        use_existing)
            # Use alias from conf if available, otherwise prompt
            local active_alias="${KS_ALIAS_CONF:-$KEY_ALIAS}"
            info "Using keystore: $KEYSTORE  (alias: $active_alias)"
            echo ""
            read -rsp "  Enter keystore password: " KS_PASS; echo
            KEY_PASS="$KS_PASS"
            KEY_ALIAS="$active_alias"
            ;;

        create|regenerate)
            if [ "$ks_action" = "regenerate" ]; then
                echo ""
                echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${NC}"
                echo -e "  ${RED}║  ⚠  REGENERATING THE KEYSTORE                           ║${NC}"
                echo -e "  ${RED}╠══════════════════════════════════════════════════════════╣${NC}"
                echo -e "  ${RED}║  This deletes the old key and creates a completely new   ║${NC}"
                echo -e "  ${RED}║  signing identity.                                       ║${NC}"
                echo -e "  ${RED}║                                                          ║${NC}"
                echo -e "  ${RED}║  Any app already published to the Play Store under the   ║${NC}"
                echo -e "  ${RED}║  old key CANNOT receive updates signed with the new key. ║${NC}"
                echo -e "  ${RED}║  Users would need to uninstall and reinstall the app.    ║${NC}"
                echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${NC}"
                echo ""
                read -rp "  Type YES to confirm regeneration: " confirm_regen
                if [ "$confirm_regen" != "YES" ]; then
                    warn "Regeneration cancelled."; pause; return 1
                fi
                rm -f "$KEYSTORE"
                info "Old keystore deleted."
            fi

            # Collect / update DN fields
            prompt_ks_details
            KEY_ALIAS="$KS_ALIAS_CONF"
            local validity_days=$(( KS_VALIDITY * 365 ))

            echo ""
            read -rsp "  Enter new keystore password (min 6 chars): " KS_PASS; echo
            read -rsp "  Confirm keystore password:                 " KS_PASS2; echo
            if [ "$KS_PASS" != "$KS_PASS2" ]; then
                err "Passwords do not match. Aborting."; pause; return 1
            fi
            read -rsp "  Enter key password (Enter to reuse keystore password): " KEY_PASS; echo
            KEY_PASS="${KEY_PASS:-$KS_PASS}"

            echo ""
            info "Generating keystore..."
            keytool -genkey -v \
                -keystore "$KEYSTORE" \
                -alias "$KEY_ALIAS" \
                -keyalg RSA \
                -keysize 2048 \
                -validity "$validity_days" \
                -dname "CN=${KS_CN}, OU=${KS_OU}, O=${KS_O}, L=${KS_L}, ST=${KS_ST}, C=${KS_C}" \
                -storepass "$KS_PASS" \
                -keypass  "$KEY_PASS" 2>&1 \
                | grep -E "(Generating|stored|Warning|Error)" || true

            save_ks_conf
            ok "Keystore created: $KEYSTORE"
            warn "Back up $KEYSTORE securely. Losing it breaks Play Store update continuity."
            ;;

        external)
            echo ""
            read -rp "  Full path to external .jks file: " ext_jks
            ext_jks="${ext_jks/#\~/$HOME}"
            if [ ! -f "$ext_jks" ]; then
                err "File not found: $ext_jks"
                pause; return 1
            fi
            KEYSTORE="$ext_jks"
            read -rp "  Key alias in this keystore: " KEY_ALIAS
            echo ""
            read -rsp "  Enter keystore password: " KS_PASS; echo
            KEY_PASS="$KS_PASS"
            info "Using external keystore: $KEYSTORE  alias: $KEY_ALIAS"
            ;;
    esac

    # ── Zipalign ──────────────────────────────────────────────────────────────
    local ALIGNED="$release_dir/app-release-aligned.apk"
    # Remove any leftover aligned file from a previous attempt
    rm -f "$ALIGNED"

    echo ""
    info "Step 1/2 — Zipalign..."
    "$ZIPALIGN" -v 4 "$unsigned_apk" "$ALIGNED" > /dev/null
    ok "Aligned: $ALIGNED"

    # ── Sign ──────────────────────────────────────────────────────────────────
    info "Step 2/2 — Signing..."
    # Output to a name derived from the unsigned APK so recompile never collides
    local signed_out="$release_dir/$(basename "${unsigned_apk/unsigned/signed}")"
    [ "$signed_out" = "$unsigned_apk" ] && signed_out="$release_dir/app-release-signed.apk"
    APK_RELEASE_SIGNED="$signed_out"

    "$APKSIGNER" sign \
        --ks        "$KEYSTORE" \
        --ks-key-alias "$KEY_ALIAS" \
        --ks-pass   "pass:$KS_PASS" \
        --key-pass  "pass:$KEY_PASS" \
        --out       "$signed_out" \
        "$ALIGNED"
    rm -f "$ALIGNED"

    local sz; sz=$(du -h "$signed_out" | cut -f1)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅  APK SIGNED SUCCESSFULLY                            ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  APK  : $signed_out"
    echo -e "${GREEN}║${NC}  Size : $sz"
    echo -e "${GREEN}║${NC}  Alias: $KEY_ALIAS"
    echo -e "${GREEN}║${NC}  Key  : $KEYSTORE"
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
        echo "    6)  Switch Java version          (currently: $(java -version 2>&1 | head -1 | grep -oE '\"[^\"]+\"' | tr -d '\"'))"
        echo ""
        echo "    0)  Exit"
        echo ""
        read -rp "  Enter choice [0-6]: " main_choice

        case "$main_choice" in
            1) build_debug        ;;
            2) build_release      ;;
            3) sign_apk           ;;
            4) upload_menu        ;;
            5) prompt_project_dir ;;
            6) switch_java        ;;
            0)
                echo ""
                echo -e "  ${CYAN}Goodbye.${NC}"
                echo ""
                exit 0
                ;;
            *)
                warn "Invalid choice — enter 0–6."
                sleep 1
                ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────────────────────
main_menu
