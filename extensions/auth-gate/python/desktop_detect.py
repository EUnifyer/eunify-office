"""Where EUnifyer Desktop is installed on Windows — pure helpers, no UNO.

Split out of auth_gate.py so the Windows matrix can be unit-tested off Windows
(see tests/test_desktop_detect.py). Nothing here touches the filesystem, the
registry or UNO; the caller injects `env`, `path_exists`,
`read_registry_value` and `listdir`.

Why this is a matrix and not a path: the Windows installer (Tauri's NSIS +
WiX bundles) keys the install directory, the uninstall entry, the Start-menu
shortcut and the Add/Remove-Programs name on the bundle's `productName`, and
names the executable after the cargo package unless
`bundle.mainBinaryName` is set. Both have changed over the product's life:

    productName   "EUnifyer" → "EUnifyer Desktop" → "DriveSync"
    executable    (productName.exe) → "eunify-desktop.exe"
    install dir   %LOCALAPPDATA%\\<productName>       (NSIS, installMode currentUser)
                  %ProgramFiles%\\<productName>       (WiX MSI, perMachine)

Installs from every era are still sitting on user machines — the app
auto-updates in place but an old directory is never renamed — so detection has
to accept every spelling in every location. Keeping `productName` pinned is a
deliberate choice on the Desktop side (renaming it would orphan existing
installs, which are keyed by it); this module absorbs the difference instead.

Keep the names below in sync with eunify-desktop's
`src-tauri/tauri.conf.json` (`productName`, `identifier`) and
`src-tauri/Cargo.toml` (`package.name`).
"""

import os

# Product names the Windows installer has registered the app under, newest
# first: current NSIS/WiX `productName`, the pre-rename bundle, and the
# pre-rename suite entry the NSIS installer hooks migrate away.
DESKTOP_PRODUCT_NAMES = ("DriveSync", "EUnifyer Desktop", "EUnifyer")

# Executable names: the cargo package binary (what the current bundles ship,
# since `bundle.mainBinaryName` is unset), plus the productName-derived names
# older bundles used.
DESKTOP_EXECUTABLE_NAMES = (
    "eunify-desktop.exe",
    "DriveSync.exe",
    "EUnifyer Desktop.exe",
    "EUnifyer.exe",
)

# Registry publishers: bundle `publisher`, else the second identifier
# segment (com.eunifyer.desktop → "eunifyer"), per tauri-bundler's
# `manufacturer`, which is what keys the install-location key.
DESKTOP_PUBLISHERS = ("eunifyer", "EUnifyer", "com.eunifyer.desktop")

# Value names the Desktop app itself writes under the HKCU Run key
# (platform/windows.rs AUTO_START_NAME, retained across the rename) plus the
# productName-derived name NSIS would use.
DESKTOP_RUN_VALUE_NAMES = ("EUnifyer", "DriveSync", "EUnifyer Desktop")

# Deep-link scheme registered by tauri-plugin-deep-link (tauri.conf.json
# plugins.deep-link.desktop.schemes).
DEEP_LINK_SCHEME = "eunify"

# %APPDATA%\<this> holds the token files Desktop mirrors for readers that
# cannot use the OS credential store (auth.rs token_file_path, via
# dirs::data_dir() → RoamingAppData on Windows).
APPDATA_DIR_NAME = "com.eunifyer.desktop"

# Shared keychain service (auth.rs KEYRING_SERVICE) and the account names
# keyring keys it with; on Windows keyring 3.x builds the credential target as
# "<account>.<service>" (keyring windows.rs new_with_target).
KEYRING_SERVICE = "com.eunifyer.auth"
LEGACY_KEYRING_ACCOUNT = "token"

_UNINSTALL_KEY = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
_CLASSES_KEY = r"SOFTWARE\Classes"
_RUN_KEY = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
_PUBLISHER_KEY = "SOFTWARE"
_HIVES = ("HKCU", "HKLM")


def _dedupe(values):
    seen = set()
    ordered = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            ordered.append(value)
    return ordered


def windows_install_roots(env):
    """Per-user and per-machine roots a Desktop install can live under."""
    roots = []
    for key in ("LOCALAPPDATA", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432"):
        root = (env.get(key) or "").strip()
        if not root:
            continue
        roots.append(root)
        if key == "LOCALAPPDATA":
            # Where several installers (and a future Tauri default) put
            # per-user apps; cheap to also look here.
            roots.append(os.path.join(root, "Programs"))
    return _dedupe(roots)


def windows_install_candidate_paths(env):
    """Every <root>\\<productName>\\<exe> the installer may have produced."""
    paths = [
        os.path.join(root, product, exe)
        for root in windows_install_roots(env)
        for product in DESKTOP_PRODUCT_NAMES
        for exe in DESKTOP_EXECUTABLE_NAMES
    ]
    return _dedupe(paths)


def windows_registry_lookups():
    """(hive, subkey, value-name) triples that name the Desktop install.

    Ordered most-authoritative first: the installer's own install-location
    key, then Add/Remove Programs, then the deep-link handler and the Run key
    the app writes itself.
    """
    lookups = []
    for hive in _HIVES:
        for publisher in DESKTOP_PUBLISHERS:
            for product in DESKTOP_PRODUCT_NAMES:
                # NSIS writes the chosen install dir to the default value of
                # Software\<manufacturer>\<productName>.
                lookups.append(
                    (hive, rf"{_PUBLISHER_KEY}\{publisher}\{product}", "")
                )
        for product in DESKTOP_PRODUCT_NAMES:
            key = rf"{_UNINSTALL_KEY}\{product}"
            lookups.append((hive, key, "InstallLocation"))
            lookups.append((hive, key, "DisplayIcon"))
            lookups.append((hive, key, "UninstallString"))
    for hive in _HIVES:
        lookups.append(
            (hive, rf"{_CLASSES_KEY}\{DEEP_LINK_SCHEME}\shell\open\command", "")
        )
    for value_name in DESKTOP_RUN_VALUE_NAMES:
        lookups.append(("HKCU", _RUN_KEY, value_name))
    return lookups


def parse_executable_value(raw):
    """Executable path from a registry command/icon value, or None.

    Handles the three shapes seen in the wild: a quoted
    `"C:\\…\\eunify-desktop.exe" --minimized` command line, a bare quoted path,
    and a bare path. Values that are not an .exe path return None so the
    caller can fall through to the directory-style readers.
    """
    text = (raw or "").strip()
    if not text:
        return None
    if text.startswith('"'):
        end = text.find('"', 1)
        text = text[1:end] if end > 0 else text.strip('"')
    if not text.lower().endswith(".exe"):
        return None
    return text


def parse_install_dir_value(raw):
    """Install directory from a registry value, or None.

    `InstallLocation` and the publisher key hold a bare directory; a value
    that names an executable is not a directory.
    """
    text = (raw or "").strip().strip('"').rstrip("\\")
    if not text or text.lower().endswith(".exe"):
        return None
    return text


def executables_in_dir(directory):
    """Executable candidates inside an install directory."""
    return _dedupe(
        os.path.join(directory, exe) for exe in DESKTOP_EXECUTABLE_NAMES
    )


def token_file_names(names):
    """auth*.json names from a listing of the Desktop data dir."""
    return _dedupe(
        name
        for name in names
        if name.startswith("auth") and name.endswith(".json")
    )


def account_ids_from_token_files(names):
    """Account ids implied by auth-<id>.json files (auth.rs per-account slots)."""
    ids = []
    for name in token_file_names(names):
        stem = name[len("auth"):-len(".json")]
        if stem.startswith("-"):
            ids.append(stem[1:])
    return _dedupe(ids)


def windows_token_file_paths(env, listdir=os.listdir):
    """Paths of the token files Desktop mirrors into %APPDATA%."""
    appdata = (env.get("APPDATA") or "").strip()
    if not appdata:
        return []
    directory = os.path.join(appdata, APPDATA_DIR_NAME)
    try:
        names = listdir(directory)
    except OSError:
        return []
    return _dedupe(
        os.path.join(directory, name) for name in token_file_names(names)
    )


def windows_credential_targets(account_ids=()):
    """Credential-store target names to probe for the shared auth blob.

    keyring's Windows backend identifies a credential by target alone and
    builds it as "<account>.<service>", so that is what Desktop wrote. The
    bare service name is kept for entries written by older readers.
    """
    # Newest first: Desktop keeps per-account entries and only falls back to
    # the legacy singleton slot during migration.
    accounts = [f"token-{account_id}" for account_id in account_ids]
    accounts.append(LEGACY_KEYRING_ACCOUNT)
    targets = [f"{account}.{KEYRING_SERVICE}" for account in accounts]
    targets.append(KEYRING_SERVICE)
    return _dedupe(targets)


def find_windows_desktop(env, path_exists=os.path.exists,
                         read_registry_value=None, listdir=os.listdir):
    """Locate the installed Desktop executable, or None.

    Filesystem first (the common case, and no registry access needed), then
    the registry values the installer and the app write, so a user who moved
    or customised the install directory is still found.
    """
    for path in windows_install_candidate_paths(env):
        if path_exists(path):
            return path

    if read_registry_value is None:
        return None

    for hive, subkey, value_name in windows_registry_lookups():
        try:
            raw = read_registry_value(hive, subkey, value_name)
        except OSError:
            raw = None
        if not raw:
            continue
        executable = parse_executable_value(raw)
        if executable:
            if path_exists(executable):
                return executable
            continue
        directory = parse_install_dir_value(raw)
        if directory:
            for candidate in executables_in_dir(directory):
                if path_exists(candidate):
                    return candidate
    return None
