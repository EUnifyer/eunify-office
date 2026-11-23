"""EUnifyer Auth Gate — connects Office to the EUnifyer ecosystem.

On startup:
1. Check if EUnifyer Desktop (sync app) is installed
2. If not → prompt to download/install it
3. If installed but not logged in → launch it for OIDC login
4. Read auth token from OS keychain (shared with Tauri app)
5. Set default save location to ~/EUnifyer/ (the sync folder)

Bundled with EUnifyer Office, not a separate install.
"""

import json
import os
import platform
import subprocess
import sys

import uno  # noqa: F401

# Sibling modules (bundled alongside this file, not declared in META-INF:
# they hold no UNO components) for the Windows install matrix and tokens.
# Degrade to the legacy single-path check rather than break startup if the
# import ever fails.
#
# pythonloader keeps the extension's `python/` directory off sys.path on some
# builds, so make sure it is there before importing the siblings — same trick
# the auth overlay's `import keychain` relies on.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    import desktop_detect
    import token_store
except ImportError:  # pragma: no cover - only on a mis-installed bundle
    desktop_detect = None
    token_store = None

KEYCHAIN_SERVICE = "com.eunifyer.auth"
SYNC_FOLDER_NAME = "EUnifyer"
# EUnifyer Desktop download — the #desktop section of the unified download page
# (kept in sync with eunifyer-landing's /download route + anchors).
DOWNLOAD_URL = "https://eunifyer.com/download#desktop"

# --- Platform detection ---

SYSTEM = platform.system()  # "Darwin", "Windows", "Linux"

# com.sun.star.awt.XMessageBoxTypes / XMessageBoxResults, spelled out because
# the UNO constants are numeric and easy to swap (the old docstring on
# _show_message had them the wrong way round; QUERYBOX really is 1).
QUERYBOX = 1
BUTTONS_OK = 1
BUTTONS_OK_CANCEL = 1 + 2
MSG_OK = 1

# --- Desktop app detection ---

def _desktop_app_paths():
    """Return possible install paths for EUnifyer Desktop per platform."""
    home = os.path.expanduser("~")
    if SYSTEM == "Darwin":
        return [
            "/Applications/EUnifyer Desktop.app",
            os.path.join(home, "Applications", "EUnifyer Desktop.app"),
            # Dev location — next to Office in instdir
            _office_sibling_path("EUnifyer Desktop.app"),
        ]
    elif SYSTEM == "Windows":
        if desktop_detect is not None:
            # Every (install dir, exe) pair the installer has ever produced.
            return desktop_detect.windows_install_candidate_paths(os.environ)
        appdata = os.environ.get("LOCALAPPDATA", "")
        progfiles = os.environ.get("PROGRAMFILES", "C:\\Program Files")
        return [
            os.path.join(progfiles, "EUnifyer Desktop", "EUnifyer Desktop.exe"),
            os.path.join(appdata, "EUnifyer Desktop", "EUnifyer Desktop.exe"),
        ]
    else:  # Linux
        return [
            "/usr/bin/eunifyer-desktop",
            "/usr/local/bin/eunifyer-desktop",
            os.path.join(home, ".local", "bin", "eunifyer-desktop"),
            "/opt/eunifyer-desktop/eunifyer-desktop",
        ]


def _office_sibling_path(name):
    """Get path to an app next to this Office install."""
    try:
        # LibreOffice program dir
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        path_sub = smgr.createInstanceWithContext(
            "com.sun.star.util.PathSubstitution", ctx
        )
        prog_url = path_sub.getSubstituteVariableValue("$(prog)")
        # Convert file:// URL to local path
        from com.sun.star.uri import ExternalUriReferenceTranslator
        prog_path = uno.fileUrlToSystemPath(prog_url)
        # Go up to the app bundle parent
        if SYSTEM == "Darwin":
            # program/ → Contents/ → App.app/ → parent/
            parent = os.path.dirname(
                os.path.dirname(os.path.dirname(prog_path))
            )
        else:
            parent = os.path.dirname(prog_path)
        return os.path.join(parent, name)
    except Exception:
        return ""


def _read_registry_value(hive_name, subkey, value_name):
    """Read a string registry value, checking every WOW64 registry view.

    The NSIS installer is a 32-bit process, so its HKCU/HKLM writes can land
    under WOW6432Node while soffice.exe is 64-bit; checking one view finds
    half the installs. Returns None when the value is absent or unreadable.
    """
    if SYSTEM != "Windows":
        return None
    try:
        import winreg
    except ImportError:  # pragma: no cover - winreg is Windows-only
        return None
    hives = {
        "HKCU": winreg.HKEY_CURRENT_USER,
        "HKLM": winreg.HKEY_LOCAL_MACHINE,
    }
    hive = hives.get(hive_name)
    if hive is None:
        return None
    views = [
        winreg.KEY_READ,
        winreg.KEY_READ | getattr(winreg, "KEY_WOW64_64KEY", 0),
        winreg.KEY_READ | getattr(winreg, "KEY_WOW64_32KEY", 0),
    ]
    for access in views:
        try:
            with winreg.OpenKey(hive, subkey, 0, access) as key:
                value, _ = winreg.QueryValueEx(key, value_name)
        except OSError:
            continue
        if isinstance(value, str) and value.strip():
            return value
    return None


def _find_desktop_app():
    """Return the path to EUnifyer Desktop if installed, else None.

    On Windows this also consults the registry, so an install the user moved
    or customised is still found — the previous filesystem guess at
    ``<ProgramFiles>\\EUnifyer Desktop\\EUnifyer Desktop.exe`` matched nothing
    the installer actually writes, which is why Office asked for a Desktop
    install that was already there.
    """
    if SYSTEM == "Windows" and desktop_detect is not None:
        return desktop_detect.find_windows_desktop(
            os.environ,
            path_exists=os.path.exists,
            read_registry_value=_read_registry_value,
        )
    for path in _desktop_app_paths():
        if path and os.path.exists(path):
            return path
    return None


def _launch_desktop_app(app_path):
    """Launch the desktop app (non-blocking)."""
    try:
        if SYSTEM == "Darwin":
            subprocess.Popen(["open", "-a", app_path])
        elif SYSTEM == "Windows":
            subprocess.Popen([app_path], shell=False)
        else:
            subprocess.Popen([app_path])
    except Exception:
        pass


# --- Keychain / credential store ---

def _read_auth_token():
    """Read auth data from OS credential store (shared with Tauri app)."""
    if SYSTEM == "Darwin":
        return _read_keychain_macos()
    elif SYSTEM == "Windows":
        return _read_credential_windows()
    else:
        return _read_keyring_linux()


def _read_keychain_macos():
    """Read from macOS Keychain."""
    try:
        result = subprocess.run(
            ["security", "find-generic-password",
             "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout.strip())
    except (subprocess.SubprocessError, json.JSONDecodeError):
        return None


def _read_credential_windows():
    """Read the auth blob Desktop stored on Windows.

    File mirror first, then the credential store — the same order Desktop
    itself uses, so the two apps agree about who is signed in. See
    token_store.py for why the old PowerShell lookup never worked.
    """
    if token_store is None:  # pragma: no cover - degraded bundle
        return None
    return token_store.read_windows_tokens(os.environ)


def _read_keyring_linux():
    """Read from Linux secret-tool (freedesktop Secret Service)."""
    try:
        result = subprocess.run(
            ["secret-tool", "lookup", "service", KEYCHAIN_SERVICE],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout.strip())
    except (subprocess.SubprocessError, json.JSONDecodeError, FileNotFoundError):
        return None


def _is_token_valid(auth_data):
    """Check if the access token hasn't expired."""
    if token_store is not None:
        return token_store.is_token_valid(auth_data)
    # Degraded bundle: accept anything that carries a token rather than
    # nagging a signed-in user.
    return bool(isinstance(auth_data, dict) and auth_data.get("access_token"))


# --- Default save location ---

def _set_default_save_path():
    """Set Office default save location to ~/EUnifyer/ (sync folder)."""
    sync_folder = os.path.join(os.path.expanduser("~"), SYNC_FOLDER_NAME)
    os.makedirs(sync_folder, exist_ok=True)

    try:
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        config_provider = smgr.createInstanceWithContext(
            "com.sun.star.configuration.ConfigurationProvider", ctx
        )
        args = uno.createUnoStruct(
            "com.sun.star.beans.NamedValue"
        )
        args.Name = "nodepath"
        args.Value = "/org.openoffice.Office.Paths/Paths/Work"

        config_access = config_provider.createInstanceWithArguments(
            "com.sun.star.configuration.ConfigurationUpdateAccess",
            (args,),
        )

        # Convert to file:// URL
        sync_url = uno.systemPathToFileUrl(sync_folder)
        config_access.setPropertyValue("WritePath", sync_url)
        config_access.commitChanges()
    except Exception:
        # Non-fatal — user can still save anywhere
        pass


# --- UI dialogs ---

def _get_window():
    """Get the top-level window for dialog parenting."""
    try:
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        desktop = smgr.createInstanceWithContext(
            "com.sun.star.frame.Desktop", ctx
        )
        frame = desktop.getCurrentFrame()
        if frame:
            return frame.getContainerWindow()
    except Exception:
        pass
    return None


def _show_message(title, message, msg_type=QUERYBOX, buttons=BUTTONS_OK):
    """Show a message box and return the clicked result (OK = 1).

    `msg_type` / `buttons` are the numeric com.sun.star.awt.XMessageBoxTypes /
    XMessageBoxButtons values; QUERYBOX with OK-only renders like an info
    box, which is what the previous hard-coded call did.
    """
    try:
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        toolkit = smgr.createInstanceWithContext(
            "com.sun.star.awt.Toolkit", ctx
        )
        window = _get_window()
        if window:
            box = toolkit.createMessageBox(
                window, msg_type, buttons, title, message
            )
            return box.execute()
    except Exception:
        pass
    return 0


def _open_url(url):
    """Open `url` in the user's browser (best effort)."""
    try:
        if SYSTEM == "Darwin":
            subprocess.Popen(["open", url])
        elif SYSTEM == "Windows":
            subprocess.Popen(["start", url], shell=True)
        else:
            subprocess.Popen(["xdg-open", url])
    except Exception:
        pass


def _show_install_prompt():
    """Offer to download EUnifyer Desktop; remember if the user declines.

    OK opens the download page. Anything else — Cancel, Enter on a dialog we
    could not raise, or a dialog that failed to appear — is remembered so
    Office stops asking on every start. Previously this fired on every launch
    *and* opened the browser unconditionally, which reads as a broken install
    rather than an invitation.
    """
    answer = _show_message(
        "EUnifyer Office",
        "EUnifyer Office works best with EUnifyer Desktop.\n\n"
        "Desktop keeps your documents synced across devices —\n"
        "like OneDrive or Google Drive, but yours — and signs you\n"
        "in once for both apps.\n\n"
        "Open the download page?",
        msg_type=QUERYBOX,
        buttons=BUTTONS_OK_CANCEL,
    )
    if answer == MSG_OK:
        _open_url(DOWNLOAD_URL)
        return True
    _write_marker(DESKTOP_PROMPT_MARKER)
    return False


def _show_login_prompt():
    """Tell the user to sign in via Desktop — once per profile."""
    answer = _show_message(
        "EUnifyer Office",
        "Please sign in with your EUnifyer account.\n\n"
        "The EUnifyer Desktop app has been opened.\n"
        "Sign in there, then restart EUnifyer Office.",
        msg_type=QUERYBOX,
        buttons=BUTTONS_OK_CANCEL,
    )
    _write_marker(LOGIN_HINT_MARKER)
    return answer == MSG_OK


# --- First-run notices ---

# Bumped if the welcome copy changes and we want to re-show it once.
FIRST_RUN_MARKER = "eunifyer_firstrun_v1"
# Both auth prompts used to fire on every launch (report A). Each is now a
# one-shot per LibreOffice profile, in the spirit of the first-run notice:
# dismissing it leaves a marker behind, and deleting the file brings it back.
DESKTOP_PROMPT_MARKER = "eunifyer_desktop_prompt_v1"
LOGIN_HINT_MARKER = "eunifyer_login_hint_v1"


def _user_profile_dir():
    """Return the LibreOffice user profile dir ($(user)) as a system path."""
    try:
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        path_sub = smgr.createInstanceWithContext(
            "com.sun.star.util.PathSubstitution", ctx
        )
        user_url = path_sub.getSubstituteVariableValue("$(user)")
        return uno.fileUrlToSystemPath(user_url)
    except Exception:
        return ""


def _marker_path(name):
    """Absolute path of a per-profile marker file, or '' without a profile."""
    profile_dir = _user_profile_dir()
    return os.path.join(profile_dir, name) if profile_dir else ""


def _marker_exists(name):
    marker = _marker_path(name)
    return bool(marker) and os.path.exists(marker)


def _write_marker(name):
    marker = _marker_path(name)
    if not marker:
        return
    try:
        with open(marker, "w") as handle:
            handle.write("1\n")
    except OSError:
        pass


def _maybe_show_first_run_notice():
    """Show the Tabbed-UI welcome exactly once per profile."""
    profile_dir = _user_profile_dir()
    if not profile_dir:
        return
    marker = os.path.join(profile_dir, FIRST_RUN_MARKER)
    if os.path.exists(marker):
        return
    _show_message(
        "Welcome to EUnifyer Office",
        "EUnifyer Office opens with a modern Tabbed interface —\n"
        "your tools are grouped into ribbon-style tabs at the top,\n"
        "so the most common actions are always one click away.\n\n"
        "Prefer the classic toolbars? Switch any time via\n"
        "View ▸ User Interface.",
    )
    try:
        with open(marker, "w") as fh:
            fh.write("1\n")
    except OSError:
        pass


# --- Main entry point ---

def check_auth_on_startup():
    """Called by LibreOffice on startup.

    Flow:
    1. Check for auth token in keychain
    2. If valid → set sync folder as default save path, done
    3. If no token → check if Desktop app is installed
    4. If not installed → offer the download, once per profile
    5. If installed → launch it, and hint about signing in once per profile

    Steps 4 and 5 were the "asks me to install Desktop every startup" report:
    detection never matched the real install (desktop_detect.py) and neither
    dialog remembered that it had already been answered.
    """
    # Step 1: Check existing auth
    auth_data = _read_auth_token()

    if auth_data and _is_token_valid(auth_data):
        # Authenticated — set sync folder and proceed
        _set_default_save_path()
        return

    # Step 2: Not authenticated — check for desktop app
    desktop_app = _find_desktop_app()

    if not desktop_app:
        # Step 3: Desktop app not installed — prompt download
        if not _marker_exists(DESKTOP_PROMPT_MARKER):
            _show_install_prompt()
        return

    # Step 4: Desktop app exists but not logged in — launch it
    _launch_desktop_app(desktop_app)
    if not _marker_exists(LOGIN_HINT_MARKER):
        _show_login_prompt()


# --- LibreOffice extension registration ---
#
# Registered as a com.sun.star.task.Job and bound (via Jobs.xcu) to the
# onFirstVisibleTask event, so it runs once each time the app starts, after
# the first window is visible (so dialogs have a parent).

import unohelper
from com.sun.star.task import XJob

IMPL_NAME = "com.eunifyer.AuthGateJob"


class AuthGateJob(unohelper.Base, XJob):
    """Job that runs on application startup."""

    def __init__(self, ctx):
        self.ctx = ctx

    def execute(self, args):
        # Each step is independent and best-effort — a failure in one must not
        # block the others or break startup.
        try:
            _maybe_show_first_run_notice()
        except Exception:
            pass
        try:
            check_auth_on_startup()
        except Exception:
            pass
        return None


g_ImplementationHelper = unohelper.ImplementationHelper()
g_ImplementationHelper.addImplementation(
    AuthGateJob, IMPL_NAME, ("com.sun.star.task.Job",),
)
