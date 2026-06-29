# HC-05 BT Controller — Build & Deploy Tool
### `setup_and_build_mk3.sh` · Mark Harrington . London UK .  Kent · Oukitel C2

> A fully menu-driven Bash script for building, signing, and deploying an Android Bluetooth controller APK on **Debian 12 / Ubuntu** or **openSUSE Tumbleweed / Leap** — no config file editing, no manual `export`, no guessing which APK was installed. 
Now you can do all of this yourselves , no need to use Google Play Stall and you can sign these yourselves 

| | |
|---|---|
| **Author** | Mark Harrington |
| **Target hardware** | AMD Athlon II X2 215 (dual-core) |
| **Phone** | Oukitel C2 — Android 14 |
| **Distros** | Debian 12 · Ubuntu 22.04+ · openSUSE Tumbleweed / Leap |
| **Android SDK** | Build-tools 34.0.0 · Platform android-34 · Gradle 8.2 |
| **Java** | OpenJDK 17 (auto-located, pinned in `gradle.properties`) |
| **Version** | mk3 — June 2026 |

---

## Table of Contents

1. [What it does](#1-what-it-does)
2. [Startup flow — distro detection](#2-startup-flow--distro-detection)
3. [Code structure — function map](#3-code-structure--function-map)
4. [Interaction diagram — full script flow](#4-interaction-diagram--full-script-flow)
5. [Interaction diagram — Java 17 detection](#5-interaction-diagram--java-17-detection)
6. [Interaction diagram — APK signing](#6-interaction-diagram--apk-signing)
7. [Interaction diagram — upload APK chooser](#7-interaction-diagram--upload-apk-chooser)
8. [Menu reference](#8-menu-reference)
9. [Pre-flight checks explained](#9-pre-flight-checks-explained)
10. [Bug fixes in mk3](#10-bug-fixes-in-mk3)
11. [Troubleshooting](#11-troubleshooting)
12. [Quick reference](#12-quick-reference)

---

## 1. What it does

`setup_and_build_mk3.sh` automates the complete Android APK lifecycle for the HC-05 Bluetooth controller project:

- **Detects** which Linux distro is running and routes all package installs through either `apt` or `zypper`
- **Installs** Java 17, Android SDK command-line tools, build-tools 34, platform android-34, and the Gradle 8.2 wrapper — once, automatically, before the first build
- **Locates** Java 17 even when Java 21 is also installed, and pins it in `gradle.properties` so Gradle never picks up the wrong version
- **Builds** a debug APK or an unsigned release APK via Gradle
- **Signs** the release APK using `zipalign` + `apksigner` with a generated or existing keystore
- **Deploys** to the phone via any of four methods: Wi-Fi (ADB over TCP/IP), local HTTP server (browser download), USB (ADB direct), or Bluetooth (obexftp)
- **Shows** an interactive APK selection menu on upload so you always know exactly which build — debug / unsigned release / signed release — lands on the phone

---

## 2. Startup flow — distro detection

The very first thing the script does — before any function is called — is read `/etc/os-release` and set two globals that everything else depends on:

```
DISTRO    →  "debian"  |  "opensuse"
PKG_MGR   →  "apt"     |  "zypper"
```

```
Script starts
     │
     ▼
/etc/os-release exists?
     ├─ YES → read $ID
     │         ├─ debian/ubuntu/mint/pop  → DISTRO=debian,  PKG_MGR=apt
     │         ├─ opensuse*/suse/sles     → DISTRO=opensuse, PKG_MGR=zypper
     │         └─ unknown $ID → fallback:
     │                   ├─ zypper in PATH? → opensuse/zypper
     │                   ├─ apt-get in PATH? → debian/apt
     │                   └─ neither → EXIT with error
     └─ NO  → same fallback path above
```

Every package install anywhere in the script goes through `pkg_install()` or `pkg_update()`, which route to the correct tool:

```bash
pkg_install "openjdk-17-jdk" "java-17-openjdk"
#            └── Debian pkg    └── openSUSE pkg
```

If both names are the same (e.g. `wget`, `unzip`, `curl`, `obexftp`, `bluez`) only one argument is needed.

---

## 3. Code structure — function map

```
setup_and_build_mk3.sh
│
├── [startup]  Distro detection  →  sets DISTRO, PKG_MGR
│
├── pkg_install()       Route package install to apt or zypper
├── pkg_update()        Route repo refresh to apt-get update or zypper refresh
├── java17_pkg_install()  Install OpenJDK 17 with correct package name per distro
├── find_java17()       Locate Java 17 home, set JAVA_HOME, write gradle.properties
│
├── [globals]           SCRIPT_DIR, ANDROID_SDK_ROOT, versions, empty APK paths
│
├── set_project_paths() Derive all APK/keystore paths from PROJECT_DIR
├── prompt_project_dir()  Prompt user for project root, validate, call set_project_paths
│
├── print_banner()      Clear screen, print header with distro/project info
├── pause()             "Press Enter to return to menu"
├── apk_status()        Show coloured build status panel (built / not built / unsigned)
│
├── preflight()         Auto-runs before any build:
│    ├── find_java17()  (installs if missing)
│    ├── core tools     wget, unzip, curl
│    ├── SDK cmdline-tools  (downloads if missing)
│    ├── SDK components  platform-tools, build-tools, platform
│    ├── ~/.bashrc + ~/.profile  ANDROID_HOME persistence
│    └── Gradle wrapper  gradlew + gradle-wrapper.jar + properties
│
├── build_debug()       Option 1 — ./gradlew assembleDebug
├── build_release()     Option 2 — ./gradlew assembleRelease
│
├── sign_apk()          Option 3:
│    ├── set_project_paths()   refresh paths for this session
│    ├── find fallback         search release dir with find if standard path missing
│    ├── find_java17()         ensure 17 active for apksigner
│    ├── keytool               generate keystore if none exists
│    ├── zipalign              4-byte align APK
│    └── apksigner             sign aligned APK → app-release-signed.apk
│
├── choose_apk()        Interactive APK selector (used by all upload functions):
│    ├── set_project_paths()
│    ├── scan for *signed*.apk, *unsigned*.apk, debug APK
│    ├── display numbered menu with type / size / timestamp
│    └── sets SELECTED_APK + SELECTED_APK_LABEL
│
├── upload_wifi()       Option 4a — ADB over TCP/IP (Android 11+ wireless or USB-once)
├── upload_web()        Option 4b — Python HTTP server, browser download on phone
├── upload_usb()        Option 4c — adb install over USB cable
├── upload_bluetooth()  Option 4d — obexftp / bluetooth-sendto / bt-obex
│
├── upload_menu()       Option 4 sub-menu (a/b/c/d/0)
│
└── main_menu()         Entry point:
     ├── prompt_project_dir()  (once at startup)
     └── loop:  1/2/3/4/5/0
```

---

## 4. Interaction diagram — full script flow

```
┌─────────────────────────────────────────────────────────┐
│                    SCRIPT START                         │
│  Read /etc/os-release → set DISTRO / PKG_MGR           │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  prompt_project_dir  │
              │  • Enter/create path │
              │  • Validate contents │
              │  • set_project_paths │
              └──────────┬───────────┘
                         │
                         ▼
           ┌─────────────────────────────┐
           │         MAIN MENU           │
           │  1) Debug build             │
           │  2) Release build           │
           │  3) Sign APK                │
           │  4) Upload to phone ──────┐ │
           │  5) Change project        │ │
           │  0) Exit                  │ │
           └──────┬───────────────────┘ │
                  │                     │
        ┌─────────┤                     ▼
        │    1 or 2│          ┌──────────────────┐
        ▼         │           │  UPLOAD SUB-MENU  │
  ┌───────────┐   │           │  a) Wi-Fi/TCP     │
  │ preflight │   │           │  b) Web server    │
  │  • Java17 │   │           │  c) USB/ADB       │
  │  • SDK    │   │           │  d) Bluetooth     │
  │  • Gradle │   │           │  0) Back          │
  └─────┬─────┘   │           └────────┬──────────┘
        │         │                    │
        ▼         │                    ▼
  ┌───────────┐   │           ┌──────────────────┐
  │  Gradle   │   │           │   choose_apk()   │
  │  build    │   │           │  numbered menu:  │
  │  debug or │   │           │  • Signed release│
  │  release  │   │           │  • Unsigned rel  │
  └─────┬─────┘   │           │  • Debug         │
        │         │           └────────┬──────────┘
        ▼         │                    │
  ┌───────────┐   │           ┌────────▼──────────┐
  │  APK      │   │           │  adb / obexftp /  │
  │  result   │   │           │  http.server      │
  │  reported │   │           │  + label shown    │
  └───────────┘   │           └───────────────────┘
                  │
                  ▼  (option 3)
         ┌─────────────────┐
         │   sign_apk()    │
         │  • refresh paths│
         │  • find fallback│
         │  • keytool      │
         │  • zipalign     │
         │  • apksigner    │
         └─────────────────┘
```

---

## 5. Interaction diagram — Java 17 detection

`find_java17()` is called from both `preflight()` and `sign_apk()`. It never relies on which `java` the shell currently points to — instead it locates the Java 17 installation directory directly, then permanently pins it in `gradle.properties`.

```
find_java17() called
        │
        ▼
Check candidate paths in order:
  /usr/lib/jvm/java-17-openjdk-amd64   ← Debian/Ubuntu
  /usr/lib/jvm/java-17-openjdk
  /usr/lib/jvm/java-17
  /usr/lib64/jvm/java-17-openjdk       ← openSUSE
  /usr/lib64/jvm/java-17
        │
        ├─ Found (bin/java executable)?
        │     └─ YES → jh = that path  ──────────────────┐
        │                                                 │
        ▼ (not found yet)                                 │
update-alternatives --list java | grep java-17            │
        │                                                 │
        ├─ Found?                                         │
        │     └─ YES → strip /bin/java → jh  ────────────┤
        │                                                 │
        ▼ (not found yet)                                 │
find /usr/lib/jvm /usr/lib64/jvm                          │
     -name "java" -path "*/java-17*/bin/java"             │
        │                                                 │
        ├─ Found?                                         │
        │     └─ YES → strip /bin/java → jh  ────────────┤
        │                                                 │
        └─ Still not found → return 1 (FAIL)             │
                                                          │
                              ┌───────────────────────────┘
                              │  jh = Java 17 home path
                              ▼
                    export JAVA_HOME="$jh"
                              │
                              ▼
                    gradle.properties exists?
                    ├─ YES + has org.gradle.java.home?
                    │      └─ sed replace existing line
                    ├─ YES, line missing?
                    │      └─ append line
                    └─ NO file?
                           └─ create file with line
                              │
                              ▼
                    org.gradle.java.home=/path/to/java-17
                    (Gradle now ALWAYS uses Java 17
                     regardless of system default java)
```

**Why this matters with Java 21 also installed:**  
Gradle reads `org.gradle.java.home` from `gradle.properties` before looking at `$JAVA_HOME` or `$PATH`. Once `find_java17()` writes that line, you never need to manually `export JAVA_HOME` again, and changing the system default `java` (e.g. back to 21 for other work) has no effect on Gradle builds.

---

## 6. Interaction diagram — APK signing

```
sign_apk() called
        │
        ▼
set_project_paths()          ← refresh APK paths for THIS session
        │                       (fixes the terminal-restart false-negative bug)
        ▼
APK_RELEASE_UNSIGNED exists?
        ├─ YES ──────────────────────────────────────────────────┐
        │                                                        │
        └─ NO → find release dir with find:                      │
                  *release*unsigned*.apk                         │
                  *release*.apk (not *signed*)                   │
                      │                                          │
                      ├─ found? → use it (with warning)  ───────┤
                      └─ not found → list release dir           │
                                     show diagnostics           │
                                     return 1 (abort)           │
                                                                 │
                         ┌───────────────────────────────────────┘
                         │  unsigned APK confirmed
                         ▼
               find_java17() (best-effort for apksigner)
                         │
                         ▼
               KEYSTORE file exists?
               ├─ YES → prompt password only
               └─ NO  → prompt new passwords (with confirm)
                         keytool -genkey
                           RSA 2048-bit
                           validity 10,000 days
                           DN: CN=Mark Harrington, C=GB
                         warn: back it up!
                         │
                         ▼
               zipalign -v 4
               (4-byte boundary alignment — required before signing)
                         │
                         ▼
               apksigner sign
               --ks hc05_key.jks
               --ks-key-alias hc05key
               --out app-release-signed.apk
                         │
                         ▼
               rm intermediate aligned APK
                         │
                         ▼
                   Success banner:
                  APK path + file size shown
```

---

## 7. Interaction diagram — upload APK chooser

`choose_apk()` replaced the old silent `pick_apk()` and is called by all four upload methods.

```
choose_apk() called
        │
        ▼
set_project_paths()   ← refresh for this session
        │
        ▼
Scan for available APKs (in this priority order for display):
  1. APK_RELEASE_SIGNED          (app-release-signed.apk)
  2. Extra *signed*.apk files    (find scan — non-standard names)
  3. APK_RELEASE_UNSIGNED        (app-release-unsigned.apk)
  4. APK_DEBUG                   (app-debug.apk)
        │
        ├─ 0 APKs found → error + "build first" message → return 1
        │
        └─ 1+ APKs found →
             Display numbered menu:
             ┌──────────────────────────────────────────────────┐
             │  Select APK to upload:                           │
             │                                                  │
             │  1)  Release SIGNED      4.2M   built 15 Jun ... │
             │  2)  Release UNSIGNED    4.1M   built 14 Jun ... │
             │  3)  Debug               5.8M   built 13 Jun ... │
             └──────────────────────────────────────────────────┘
                       │
                       ▼
             User enters number
                       │
                       ▼
             SELECTED_APK       = full file path
             SELECTED_APK_LABEL = type + size + timestamp
                       │
             ┌─────────┴────────────────────────────────┐
             │  Label shown in every subsequent message: │
             │  • "Serving: Release SIGNED 4.2M ..."    │
             │  • "Sending: Release SIGNED 4.2M ..."    │
             │  • "APK type: Release SIGNED 4.2M ..."   │
             │    (in install success banner)            │
             └───────────────────────────────────────────┘
```

---

## 8. Menu reference

### Main menu

```
╔══════════════════════════════════════════════════════════╗
║   HC-05 BT Controller — Build & Deploy Tool             ║
║   Mark Harrington  |  Oukitel C2                        ║
╠══════════════════════════════════════════════════════════╣
║  Distro  : openSUSE Tumbleweed 20260610                 ║
║  Pkg mgr : zypper                                       ║
║  Project : /home/mark/Android_projects/HC05_BT_App      ║
╚══════════════════════════════════════════════════════════╝

  Current build status:
    ●  Debug APK       5.8M  →  .../app-debug.apk
    ●  Release APK     4.2M  →  .../app-release-signed.apk

  Main Menu:
    1)  Build Debug APK
    2)  Build Release APK
    3)  Sign Release APK
    4)  Upload APK to Phone
    5)  Change project directory
    0)  Exit
```

### Upload sub-menu (option 4)

```
    a)  Wi-Fi / RF Wireless   (ADB over TCP/IP — same network)
    b)  Website               (local HTTP server — phone browser)
    c)  USB                   (ADB direct — fastest, most reliable)
    d)  Bluetooth             (obexftp / bluez — no cable or network)
    0)  Back to main menu
```

### Wi-Fi sub-options (option 4a)

```
    1)  Android 11+  — Wireless Debugging  (no USB required)
    2)  Any Android  — ADB-over-TCP  (USB once to enable, then unplug)
```

---

## 9. Pre-flight checks explained

`preflight()` runs automatically before every build (options 1 and 2). It is **idempotent** — safe to run repeatedly, skips anything already installed.

| Check | Action if missing | Notes |
|---|---|---|
| Java 17 | `find_java17()` → install if needed | Searches 6 known paths on both distros |
| `wget` | `pkg_install wget` | Same package name both distros |
| `unzip` | `pkg_install unzip` | Same package name both distros |
| `curl` | `pkg_install curl` | Same package name both distros |
| SDK cmdline-tools | Download from `dl.google.com` | Installed to `~/Android/Sdk/cmdline-tools/latest/` |
| build-tools 34.0.0 | `sdkmanager "build-tools;34.0.0"` | Checked by directory existence |
| platform android-34 | `sdkmanager "platforms;android-34"` | Checked by directory existence |
| `ANDROID_HOME` in `~/.bashrc` | Appended with marker comment | Once only |
| `ANDROID_HOME` in `~/.profile` | Appended (openSUSE only) | For login shells (KDE/GNOME terminals) |
| `gradlew` launcher | Written from here-doc | A minimal Java launcher script |
| `gradle-wrapper.properties` | Always written (idempotent) | Points to Gradle 8.2 distribution |
| `gradle-wrapper.jar` | Downloaded from GitHub raw | Verified with `unzip -t` |

---

## 10. Bug fixes 

### Bug 1 — sign_apk false negative after terminal restart

**Root cause:** `APK_RELEASE_UNSIGNED` is a shell variable set when the project directory is chosen. Closing the terminal destroys the variable. The next session started fresh — the path variable was an empty string — so the `[ ! -f ]` check always failed even though the APK was on disk.

**Fix:** `sign_apk()` calls `set_project_paths()` at the very top of the function, rebuilding all paths from `PROJECT_DIR` for the current session. If the standard filename still doesn't exist, a `find` scan searches the entire release output directory for any `*release*unsigned*.apk` or any `*release*.apk` not named `*signed*`. If that also finds nothing, the directory listing is shown so you can see exactly what Gradle produced.

### Bug 2 — Java 17 / 21 coexistence

**Root cause:** The old code tested `if java -version | grep "17"` — checking the *system default* `java`. With Java 21 as default, it tried to install 17 on every run. Even when it exported `JAVA_HOME`, Gradle ignores the shell environment if `gradle.properties` contains `org.gradle.java.home`, and ignores `JAVA_HOME` in favour of the system `java` if neither is set.

**Fix:** New `find_java17()` searches a priority list of known installation paths independently of which `java` the shell points to. Once located, it writes `org.gradle.java.home=<path>` into `gradle.properties` — Gradle's own configuration file — which takes highest precedence. Your system `java` (21) is left completely unchanged for other work.

### Bug 3 — No visibility into which APK was uploaded

**Root cause:** The old `pick_apk()` silently chose signed → unsigned → debug with only a brief `info` line, easily missed when scrolling.

**Fix:** Replaced with `choose_apk()` — an interactive numbered menu showing every APK currently on disk with type label, file size, and build timestamp. The chosen label (`SELECTED_APK_LABEL`) is then printed in every progress and success message across all four upload methods (Wi-Fi, web, USB, Bluetooth), so there is no ambiguity about what landed on the phone.

---

## 11. Troubleshooting

| Problem | Solution |
|---|---|
| `ERROR: Could not identify package manager` | Run on Debian, Ubuntu, or openSUSE. Other distros not yet supported. |
| `Java 17 not found` after install | Run `sudo update-alternatives --config java` and check paths. The script will find it next run. |
| `gradle-wrapper.jar is corrupt` | Delete `gradle/wrapper/gradle-wrapper.jar` in project dir and re-run. Script re-downloads. |
| `No unsigned release APK found` | The release dir is listed in the error. If empty, run option 2 first. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Uninstall the existing app: `adb uninstall com.mark.hc05controller` |
| ADB TCP connection refused | Run option 4a → choose method 2 → connect USB → enable TCP → then unplug. |
| Bluetooth transfer fails on channel 9 | Script auto-retries with channel auto-detection. If still failing, ensure the phone's file-receive is active. |
| Web server URL not opening on phone | Check phone and PC are on the same Wi-Fi. Try `http://` not `https://`. |
| `Permission denied on gradlew` | `chmod +x gradlew` inside the project directory. |
| openSUSE: `ANDROID_HOME` not set in terminal | Run `source ~/.profile`. Written to `.profile` (not just `.bashrc`) for openSUSE login shells. |

---

## 12. Quick reference

### First run

```bash
chmod +x setup_and_build_mk3.sh
./setup_and_build_mk3.sh
# → enter project path → menu → option 1 to build debug
```

### Rebuild without re-running SDK setup

```bash
cd ~/Android_projects/HC05_BT_App
bash gradlew assembleDebug
# or
bash gradlew assembleRelease
```

### Manual APK signing (without the script)

```bash
TOOLS=$ANDROID_HOME/build-tools/34.0.0
$TOOLS/zipalign -v 4 app-release-unsigned.apk app-release-aligned.apk
$TOOLS/apksigner sign \
    --ks hc05_key.jks \
    --ks-key-alias hc05key \
    --out app-release-signed.apk \
    app-release-aligned.apk
```

### Force Java 17 for a manual Gradle build

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64   # Debian
# or
export JAVA_HOME=/usr/lib64/jvm/java-17-openjdk        # openSUSE
bash gradlew assembleRelease
```

### Check which APKs are built

```bash
find ~/Android_projects/HC05_BT_App/app/build/outputs/apk \
     -name "*.apk" -exec ls -lh {} \;
```

### ADB useful commands

```bash
adb devices                                    # list connected devices
adb install -r app-release-signed.apk         # install / update
adb uninstall com.mark.hc05controller          # remove
adb shell monkey -p com.mark.hc05controller 1 # launch
adb logcat | grep HC05                        # filter logs
adb tcpip 5555                                 # enable wireless ADB
adb connect 192.168.1.x:5555                  # connect wirelessly
```

---

> **Keystore warning** — `hc05_key.jks` is added to `.gitignore` automatically. Back it up securely. If lost, you cannot publish updates to the same Play Store listing.

---

*`setup_and_build_mk3.sh` — Mark Harrington — openSUSE Tumbleweed / Debian 12 — June 2026*
