# HC-05 BT Controller — Build & Deploy Tool
### `setup_and_build_mk4.sh`  ·  Mark Harrington  ·  Oukitel C2

> A fully menu-driven Bash script for building, signing, and deploying an Android Bluetooth controller APK on **Debian 12 / Ubuntu** or **openSUSE Tumbleweed / Leap** — no config file editing, no manual `export`, no guessing which APK was installed.

| | |
|---|---|
| **Author** | Mark Harrington |
| **Target hardware** | AMD Athlon II X2 215 (dual-core) |
| **Phone** | Oukitel C2 — Android 14 |
| **Distros** | Debian 12 · Ubuntu 22.04+ · openSUSE Tumbleweed / Leap |
| **Android SDK** | Build-tools 34.0.0 · Platform android-34 · Gradle 8.2 |
| **Java** | OpenJDK 17 (auto-located, pinned in `gradle.properties`) |
| **Version** | mk4 — June 2026 |

---

## Table of Contents

1. [What it does](#1-what-it-does)
2. [Startup flow — distro detection](#2-startup-flow--distro-detection)
3. [Code structure — function map](#3-code-structure--function-map)
4. [Interaction diagram — full script flow](#4-interaction-diagram--full-script-flow)
5. [Interaction diagram — Java detection and switching](#5-interaction-diagram--java-detection-and-switching)
6. [Interaction diagram — APK signing](#6-interaction-diagram--apk-signing)
7. [Interaction diagram — upload APK chooser](#7-interaction-diagram--upload-apk-chooser)
8. [Menu reference](#8-menu-reference)
9. [Pre-flight checks explained](#9-pre-flight-checks-explained)
10. [Keystore and signing explained](#10-keystore-and-signing-explained)
11. [Troubleshooting](#11-troubleshooting)
12. [Quick reference](#12-quick-reference)

---

## 1. What it does

`setup_and_build_mk4.sh` automates the complete Android APK lifecycle for the HC-05 Bluetooth controller project:

- **Detects** which Linux distro is running and routes all package installs through either `apt` or `zypper`
- **Installs** Java 17, Android SDK command-line tools, build-tools 34, platform android-34, and the Gradle 8.2 wrapper — once, automatically, before the first build
- **Locates** Java 17 even when Java 21 (or 25) is also installed, and pins it in `gradle.properties` so Gradle always uses the correct version without any manual `export`
- **Switches** the active Java version interactively — using `alts` on openSUSE or `update-alternatives` on Debian — and immediately re-pins the selection in `gradle.properties`
- **Auto-corrects** the project path if the user enters the module subdirectory (`/app`) instead of the project root
- **Builds** a debug APK or an unsigned release APK via Gradle, detecting the output with a full tree scan so cached "up-to-date" builds are found correctly
- **Signs** the release APK using `zipalign` + `apksigner`, collecting all certificate identity fields from the user and saving them to a sidecar config so they can be reviewed and changed without hunting through the script
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
setup_and_build_mk4.sh
│
├── [startup]  Distro detection  →  sets DISTRO, PKG_MGR
│
├── pkg_install()         Route package install to apt or zypper
├── pkg_update()          Route repo refresh to apt-get update or zypper refresh
├── java17_pkg_install()  Install OpenJDK 17 with correct package name per distro
│
├── pin_java_home()       Export JAVA_HOME + write org.gradle.java.home to gradle.properties
├── find_java17()         Locate Java 17 via path list → alts → update-alternatives → find
├── switch_java()         Option 6: interactive Java version switcher (alts / update-alternatives)
│
├── [globals]           SCRIPT_DIR, ANDROID_SDK_ROOT, versions, empty APK/keystore paths
│
├── set_project_paths()   Derive all APK, keystore, and KS_CONF paths from PROJECT_DIR
├── prompt_project_dir()  Prompt user for project root; auto-strip /app suffix; validate
│
├── print_banner()        Clear screen, print header with distro/project/java info
├── pause()               "Press Enter to return to menu"
├── apk_status()          Colour-coded build status panel (built / not built / unsigned)
│
├── preflight()           Auto-runs before any build:
│    ├── find_java17()    (installs if missing, always pins gradle.properties)
│    ├── core tools       wget, unzip, curl
│    ├── SDK cmdline-tools  (downloads if missing)
│    ├── SDK components   platform-tools, build-tools, platform
│    ├── ~/.bashrc + ~/.profile  ANDROID_HOME persistence
│    └── Gradle wrapper   gradlew + gradle-wrapper.jar + properties
│
├── build_debug()         Option 1 — ./gradlew assembleDebug
│    └── find scan        two-stage APK search (fixed dir then full tree)
│
├── build_release()       Option 2 — ./gradlew assembleRelease
│    ├── clean stale      delete old signed/aligned APKs before build
│    └── find scan        two-stage APK search; updates APK_RELEASE_UNSIGNED for session
│
├── load_ks_conf()        Read hc05_key.conf sidecar (DN fields, alias, validity)
├── save_ks_conf()        Write hc05_key.conf sidecar
├── prompt_ks_details()   Collect all six DN fields + alias + validity interactively
│
├── sign_apk()            Option 3:
│    ├── set_project_paths + load_ks_conf   refresh for this session
│    ├── wide APK scan    standard path → find newest non-signed APK
│    ├── find_java17()    ensure Java 17 active for apksigner
│    ├── keystore menu    use existing / edit+regenerate / use external .jks
│    ├── prompt_ks_details  (if creating or regenerating)
│    ├── keytool          generate RSA 2048 keystore with full DN from user input
│    ├── save_ks_conf     persist DN fields to sidecar
│    ├── zipalign         4-byte align APK
│    └── apksigner        sign aligned APK → app-release-signed.apk
│
├── choose_apk()          Interactive APK selector (used by all upload functions):
│    ├── set_project_paths
│    ├── scan for *signed*.apk, *unsigned*.apk, debug APK
│    ├── display numbered menu with type / size / timestamp
│    └── sets SELECTED_APK + SELECTED_APK_LABEL
│
├── upload_wifi()         Option 4a — ADB over TCP/IP (Android 11+ wireless or USB-once)
├── upload_web()          Option 4b — Python HTTP server, browser download on phone
├── upload_usb()          Option 4c — adb install over USB cable
├── upload_bluetooth()    Option 4d — obexftp / bluetooth-sendto / bt-obex
│
├── upload_menu()         Option 4 sub-menu (a/b/c/d/0)
│
└── main_menu()           Entry point:
     ├── prompt_project_dir()  (once at startup)
     └── loop:  1/2/3/4/5/6/0
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
              ┌───────────────────────────┐
              │    prompt_project_dir     │
              │  • Enter/create path      │
              │  • Auto-strip /app suffix │
              │  • Validate contents      │
              │  • set_project_paths      │
              └──────────┬────────────────┘
                         │
                         ▼
           ┌──────────────────────────────────┐
           │            MAIN MENU             │
           │  1) Debug build                  │
           │  2) Release build                │
           │  3) Sign APK                     │
           │  4) Upload to phone  ──────────┐ │
           │  5) Change project             │ │
           │  6) Switch Java version        │ │
           │  0) Exit                       │ │
           └────┬───────────────────────────┘ │
                │                             │
     ┌──────────┤                             ▼
     │  1 or 2  │                  ┌──────────────────┐
     ▼          │                  │  UPLOAD SUB-MENU  │
 ┌──────────┐   │                  │  a) Wi-Fi/TCP     │
 │preflight │   │                  │  b) Web server    │
 │ •Java17  │   │                  │  c) USB/ADB       │
 │ •SDK     │   │                  │  d) Bluetooth     │
 │ •Gradle  │   │                  │  0) Back          │
 └────┬─────┘   │                  └────────┬──────────┘
      │         │                           │
      ▼         │                           ▼
 ┌──────────┐   │                  ┌──────────────────┐
 │  Gradle  │   │                  │   choose_apk()   │
 │  build   │   │                  │ numbered menu:   │
 │ +find    │   │                  │ • Signed release │
 │  scan    │   │                  │ • Unsigned rel   │
 └────┬─────┘   │                  │ • Debug          │
      │         │                  └────────┬─────────┘
      ▼         │                           │
 APK found,     │                  ┌────────▼─────────┐
 path updated   │                  │ adb / obexftp /  │
 in session     │                  │ http.server      │
                │                  │ + label shown    │
                │                  └──────────────────┘
                │
                ▼  (option 3)
       ┌──────────────────────┐
       │      sign_apk()      │
       │  • refresh paths     │
       │  • wide APK scan     │
       │  • keystore menu     │
       │  • keytool (if new)  │
       │  • zipalign          │
       │  • apksigner         │
       └──────────────────────┘

                ▼  (option 6)
       ┌──────────────────────┐
       │     switch_java()    │
       │  • alts -l java      │
       │    OR                │
       │  • update-alts list  │
       │  • numbered menu     │
       │  • switch system     │
       │  • pin gradle.props  │
       └──────────────────────┘
```

---

## 5. Interaction diagram — Java detection and switching

### 5.1 find_java17() — automatic detection

`find_java17()` is called from both `preflight()` and `sign_apk()`. It searches for the Java 17 installation independently of whichever `java` the shell currently points to, then calls `pin_java_home()` to lock it in permanently.

```
find_java17() called
      │
      ▼
Check candidate paths (priority order):
  /usr/lib/jvm/java-17-openjdk-amd64    ← Debian / Ubuntu
  /usr/lib/jvm/java-17-openjdk
  /usr/lib/jvm/java-17
  /usr/lib64/jvm/jre-17-openjdk         ← openSUSE (alts jre path)
  /usr/lib64/jvm/java-17-openjdk
  /usr/lib64/jvm/java-17
      │
      ├─ Found? → jh = path ──────────────────────────────────────┐
      │                                                            │
      ▼  (not found)                                              │
  update-alternatives --list java | grep java-17                  │
      ├─ Found? → strip /bin/java → jh ──────────────────────────┤
      │                                                            │
      ▼  (not found)                                              │
  alts -l java | grep "17" | grep "Target:"                       │
      ├─ Found? → strip /bin/java → jh ──────────────────────────┤
      │                                                            │
      ▼  (not found)                                              │
  find /usr/lib/jvm /usr/lib64/jvm                                │
       -path "*/java-17*/bin/java"                                │
       -path "*/jre-17*/bin/java"                                 │
      ├─ Found? → strip /bin/java → jh ──────────────────────────┤
      └─ Still not found → return 1 (caller installs Java 17)    │
                                                                   │
                           ┌───────────────────────────────────────┘
                           │  jh = Java 17 home directory
                           ▼
               pin_java_home(jh):
                 export JAVA_HOME="$jh"
                 write org.gradle.java.home=$jh to gradle.properties
                 (update existing line, append, or create file)
                           │
                           ▼
               Gradle now ALWAYS uses Java 17.
               System default java (17/21/25) is irrelevant.
```

### 5.2 switch_java() — interactive switching (option 6)

```
switch_java() called
      │
      ▼
DISTRO = opensuse?
  ├─ YES → alts -l java
  │         Parses Priority: NNN  Target: /path/bin/java pairs
  │         Shows raw alts output + numbered menu
  │         User picks number
  │         sudo alts -s -n java -p <priority>
  │
  └─ NO  → update-alternatives --list java
            Parses one path per line
            Marks ← ACTIVE against current symlink target
            Shows numbered menu
            User picks number
            sudo update-alternatives --set java <path>
      │
      ▼
pin_java_home(chosen_jh)
  → exports JAVA_HOME for this session
  → writes org.gradle.java.home to gradle.properties
      │
      ▼
Shows: java -version  (confirms system switch took effect)

openSUSE priority numbers seen in practice:
  Priority 1805  →  jre-1.8.0-openjdk   (Java 8)
  Priority 2705  →  jre-17-openjdk       (Java 17)  ← use this for Gradle 8
  Priority 3105  →  jre-21-openjdk       (Java 21)
  Priority 3505  →  jre-25-openjdk       (Java 25)
```

---

## 6. Interaction diagram — APK signing

```
sign_apk() called
      │
      ▼
set_project_paths() + load_ks_conf()    ← refresh paths AND stored DN fields
      │
      ▼
Find unsigned APK:
  Priority 1: APK_RELEASE_UNSIGNED (standard Gradle filename)
  Priority 2: find release dir → newest *.apk not named *signed* or *aligned*
      │
      ├─ Found ──────────────────────────────────────────────────────────────┐
      └─ Not found → show release dir contents → warn → return 1            │
                                                                              │
                         ┌────────────────────────────────────────────────────┘
                         │  unsigned APK confirmed
                         ▼
            find_java17()  (best-effort for apksigner)
                         │
                         ▼
            KEYSTORE exists?
            ├─ YES → show stored details from hc05_key.conf
            │         Menu:
            │           1) Sign with existing keystore  → prompt password only
            │           2) Edit details + regenerate    → type "YES" to confirm
            │                                             ⚠ breaks Play Store updates
            │           3) Use external .jks file       → prompt path + alias
            │
            └─ NO  → Menu:
                        1) Create new keystore  → prompt_ks_details() → keytool
                        2) Use external .jks   → prompt path + alias
                         │
                         ▼
            prompt_ks_details() (if creating or regenerating):
              CN  Full name / Common Name
              OU  Organisational Unit
              O   Organisation
              L   City / Locality
              ST  State / Province
              C   2-letter country code  (forced uppercase)
              Alias + Validity in years
              → save_ks_conf() writes hc05_key.conf
                         │
                         ▼
            keytool -genkey  RSA 2048  DN from user input  validity N×365 days
                         │
                         ▼
            zipalign -v 4  (4-byte boundary — mandatory before signing)
                         │
                         ▼
            apksigner sign  --ks hc05_key.jks  --ks-key-alias <alias>
                            --out app-release-signed.apk
                         │
                         ▼
            rm intermediate aligned APK
                         │
                         ▼
            ✅  Success banner: path, size, alias, keystore path
```

---

## 7. Interaction diagram — upload APK chooser

```
choose_apk() called  (by all four upload methods)
      │
      ▼
set_project_paths()   ← refresh for this session
      │
      ▼
Scan for available APKs (display-priority order):
  1. app-release-signed.apk
  2. Extra *signed*.apk files  (find scan — non-standard Gradle names)
  3. app-release-unsigned.apk
  4. app-debug.apk
      │
      ├─ 0 found → error + "Build first" message → return 1
      │
      └─ 1+ found → display numbered menu:

   ┌────────────────────────────────────────────────────────┐
   │  Select APK to upload:                                 │
   │                                                        │
   │  1)  Release SIGNED      4.2M   built 15 Jun 14:32    │
   │  2)  Release UNSIGNED    4.1M   built 14 Jun 11:08  ⚠ │
   │  3)  Debug               5.8M   built 13 Jun 09:45  ⚠ │
   └────────────────────────────────────────────────────────┘
      │
      ▼
SELECTED_APK       = full file path
SELECTED_APK_LABEL = "Release SIGNED  4.2M  built 15 Jun 14:32"
      │
      └─ Label shown in ALL subsequent output:
           Serving: Release SIGNED  4.2M  built 15 Jun 14:32
           Sending: Release SIGNED  4.2M  built 15 Jun 14:32
           APK type: Release SIGNED  4.2M ...  (install success banner)
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
║  Project : /home/mark/AndroidProjects/BluetoothArduino  ║
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
    6)  Switch Java version          (currently: 17.0.x)
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

### Java switch menu (option 6 — openSUSE example)

```
  Reading installed JVMs via:  alts -l java

    Priority: 1805   Target: /usr/lib64/jvm/jre-1.8.0-openjdk/bin/java
    Priority: 2705!  Target: /usr/lib64/jvm/jre-17-openjdk/bin/java
    Priority: 3105   Target: /usr/lib64/jvm/jre-21-openjdk/bin/java
    Priority: 3505   Target: /usr/lib64/jvm/jre-25-openjdk/bin/java

  Available Java versions:

    1)  Priority 1805  jre-1.8.0-openjdk
    2)  Priority 2705  jre-17-openjdk  ← ACTIVE
    3)  Priority 3105  jre-21-openjdk
    4)  Priority 3505  jre-25-openjdk

  ⚠  For Gradle 8.x / AGP 8.x you must use Java 17.
  ⚠  Java 21+ will cause build failures with this project configuration.

  Enter number to switch to [1-4] or 0 to cancel:
```

---

## 9. Pre-flight checks explained

`preflight()` runs automatically before every build (options 1 and 2). It is **idempotent** — safe to run repeatedly, skips anything already installed.

| Check | Action if missing | Notes |
|---|---|---|
| Java 17 | `find_java17()` → install if needed | 4-stage search: paths → update-alts → alts → find |
| `wget` | `pkg_install wget` | Same package name both distros |
| `unzip` | `pkg_install unzip` | Same package name both distros |
| `curl` | `pkg_install curl` | Same package name both distros |
| SDK cmdline-tools | Download from `dl.google.com` | Installed to `~/Android/Sdk/cmdline-tools/latest/` |
| build-tools 34.0.0 | `sdkmanager "build-tools;34.0.0"` | Checked by directory existence |
| platform android-34 | `sdkmanager "platforms;android-34"` | Checked by directory existence |
| `ANDROID_HOME` in `~/.bashrc` | Appended with marker comment | Once only |
| `ANDROID_HOME` in `~/.profile` | Appended (openSUSE only) | For login shells (KDE/GNOME terminals) |
| `gradlew` launcher | Written from here-doc | Minimal Java launcher, always executable |
| `gradle-wrapper.properties` | Always written (idempotent) | Points to Gradle 8.2 distribution URL |
| `gradle-wrapper.jar` | Downloaded from GitHub raw | Verified with `unzip -t` after download |

---

## 10. Keystore and signing explained

### 10.1 The sidecar config file — `hc05_key.conf`

When a keystore is created, a plain-text sidecar file is written alongside the `.jks`:

```
$PROJECT_DIR/hc05_key.jks    ← the keystore (binary, password-protected)
$PROJECT_DIR/hc05_key.conf   ← the sidecar (plain text, NO passwords)
```

The sidecar stores all six Distinguished Name (DN) fields, the key alias, and the validity period. On the next run these are loaded as defaults so you are not re-entering everything from scratch, and so you can see what the current certificate identity is before deciding whether to re-sign or regenerate.

```
# hc05_key.conf — example content
KS_CN="Mark Harrington"
KS_OU="Dev"
KS_O="MH Software"
KS_L="London"
KS_ST="England"
KS_C="GB"
KS_ALIAS_CONF="hc05key"
KS_VALIDITY="27"
```

### 10.2 DN fields — what they mean

| Field | Name | Purpose |
|---|---|---|
| `CN` | Common Name | Your full name — shown on the certificate |
| `OU` | Organisational Unit | Team or department (e.g. "Dev") |
| `O` | Organisation | Company or project name |
| `L` | Locality | City or town |
| `ST` | State / Province | County, region, or state |
| `C` | Country | ISO 2-letter code — must be uppercase (e.g. `GB`, `US`, `DE`) |

### 10.3 Keystore actions menu

When option 3 is selected and a keystore already exists, three choices are offered:

| Choice | What happens | When to use |
|---|---|---|
| **1 — Sign with existing** | Prompts password only, signs immediately | Normal signing of any recompiled APK |
| **2 — Edit + regenerate** | Prompts new DN details, requires typing `YES`, deletes old `.jks` and creates new one | Correcting wrong details before first Play Store submission |
| **3 — Use external .jks** | Prompts path + alias, uses that file directly | Migrating from another tool's keystore |

> ⚠️ **Regeneration warning** — choice 2 creates an entirely new signing key. Any APK already published to the Play Store under the old key **cannot receive updates** signed with the new key. Users would need to uninstall and reinstall the app. Only regenerate before your first Play Store submission, or if you are intentionally abandoning the old listing.

### 10.4 Validity period

The script defaults to **27 years** (9,855 days). Google Play requires that the signing certificate is valid until at least **October 22, 2033**. 27 years from 2026 covers this comfortably. The maximum practical value is 100 years; `keytool` accepts any positive integer of days.

---

## 11. Troubleshooting

| Problem | Solution |
|---|---|
| `ERROR: Could not identify package manager` | Run on Debian, Ubuntu, or openSUSE. Other distros not yet supported. |
| `Java 17 not found` after install | Run option 6 (Switch Java) — the script will scan and list all installed JVMs. |
| `gradle-wrapper.jar is corrupt` | Delete `gradle/wrapper/gradle-wrapper.jar` in project dir and re-run option 1 or 2. |
| `No unsigned release APK found` | Release dir contents are listed in the error. Run option 2 first. |
| `Build reported success but APK not found` | Check `PROJECT_DIR` does not end in `/app` — use option 5 to correct it. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Run: `adb uninstall com.mark.hc05controller` then reinstall. |
| ADB TCP connection refused | Use option 4a → method 2: connect USB → enable TCP → unplug. |
| Bluetooth transfer fails on channel 9 | Script auto-retries with auto-detection. Ensure phone file-receive is active. |
| Web server URL not opening on phone | Confirm phone and PC on same Wi-Fi. Use `http://` not `https://`. |
| `Permission denied on gradlew` | Run: `chmod +x gradlew` inside the project directory. |
| openSUSE: `ANDROID_HOME` not set in new terminal | Run: `source ~/.profile` — written to `.profile` (not just `.bashrc`) for login shells. |
| `alts switch failed` | Run manually: `sudo alts -s -n java -p 2705` (or the priority shown in the menu). |
| Keystore password forgotten | The keystore cannot be recovered. Delete `hc05_key.jks` and `hc05_key.conf`, then use option 3 to create a new one. See the regeneration warning in section 10.3. |

---

## 12. Quick reference

### First run

```bash
chmod +x setup_and_build_mk4.sh
./setup_and_build_mk4.sh
# → enter project path → main menu → option 1 to build debug
```

### Rebuild without re-running SDK setup

```bash
cd ~/AndroidProjects/BluetoothArduino
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

### Switch Java manually (openSUSE)

```bash
# List all installed JVMs and their priorities:
alts -l java

# Switch to Java 17 (priority 2705 in your setup):
sudo alts -s -n java -p 2705

# Verify:
java -version
```

### Switch Java manually (Debian)

```bash
# List all installed JVMs:
update-alternatives --list java

# Switch non-interactively:
sudo update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java

# Or interactively:
sudo update-alternatives --config java
```

### Pin Java 17 in gradle.properties manually

```bash
# openSUSE:
echo "org.gradle.java.home=/usr/lib64/jvm/jre-17-openjdk" >> gradle.properties

# Debian:
echo "org.gradle.java.home=/usr/lib/jvm/java-17-openjdk-amd64" >> gradle.properties
```

### Check which APKs are built

```bash
find ~/AndroidProjects/BluetoothArduino/app/build/outputs/apk \
     -name "*.apk" -exec ls -lh {} \;
```

### ADB useful commands

```bash
adb devices                                      # list connected devices
adb install -r app-release-signed.apk           # install / update
adb uninstall com.mark.hc05controller            # remove
adb shell monkey -p com.mark.hc05controller 1   # launch
adb logcat | grep HC05                          # filter logs
adb tcpip 5555                                   # enable wireless ADB
adb connect 192.168.1.x:5555                    # connect wirelessly
```

---

> **Keystore warning** — `hc05_key.jks` and `hc05_key.conf` are both added to `.gitignore` automatically. Back up `hc05_key.jks` securely. If lost, you cannot publish updates to the same Play Store listing.

---

*`setup_and_build_mk4.sh` — Mark Harrington — openSUSE Tumbleweed / Debian 12 — June 2026*
