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

KEYCHAIN_SERVICE = "com.eunifyer.auth"
SYNC_FOLDER_NAME = "EUnifyer"
# EUnifyer Desktop download — the #desktop section of the unified download page
# (kept in sync with eunifyer-landing's /download route + anchors).
DOWNLOAD_URL = "https://eunifyer.com/download#desktop"

# --- Platform detection ---

SYSTEM = platform.system()  # "Darwin", "Windows", "Linux"


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


def _find_desktop_app():
    """Return the path to EUnifyer Desktop if installed, else None."""
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
    """Read from Windows Credential Manager via PowerShell."""
    try:
        ps_cmd = (
            f'(Get-StoredCredential -Target "{KEYCHAIN_SERVICE}").Password '
            f'| ConvertFrom-SecureString -AsPlainText'
        )
        result = subprocess.run(
            ["powershell", "-Command", ps_cmd],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout.strip())
    except (subprocess.SubprocessError, json.JSONDecodeError):
        return None


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
    expires_at = auth_data.get("expires_at", "")
    if not expires_at:
        return False
    from datetime import datetime, timezone
    try:
        exp = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        return exp > datetime.now(timezone.utc)
    except ValueError:
        return False


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


def _show_message(title, message, msg_type=1):
    """Show a message box. msg_type: 1=INFO, 2=WARNING, 3=ERROR, 4=QUERY."""
    try:
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        toolkit = smgr.createInstanceWithContext(
            "com.sun.star.awt.Toolkit", ctx
        )
        window = _get_window()
        if window:
            box = toolkit.createMessageBox(
                window, msg_type, 1, title, message
            )
            return box.execute()
    except Exception:
        pass
    return 0


def _show_install_prompt():
    """Prompt user to download EUnifyer Desktop."""
    _show_message(
        "EUnifyer Office",
        "EUnifyer Office works best with EUnifyer Desktop.\n\n"
        "Desktop keeps your documents synced across devices —\n"
        "like OneDrive or Google Drive, but yours — and signs you\n"
        "in once for both apps.\n\n"
        f"Download it at:\n{DOWNLOAD_URL}\n\n"
        "After installing, restart EUnifyer Office.",
    )
    # Open download page in browser
    try:
        if SYSTEM == "Darwin":
            subprocess.Popen(["open", DOWNLOAD_URL])
        elif SYSTEM == "Windows":
            subprocess.Popen(["start", DOWNLOAD_URL], shell=True)
        else:
            subprocess.Popen(["xdg-open", DOWNLOAD_URL])
    except Exception:
        pass


def _show_login_prompt():
    """Tell user to log in via the desktop app."""
    _show_message(
        "EUnifyer Office",
        "Please sign in with your EUnifyer account.\n\n"
        "The EUnifyer Desktop app has been opened.\n"
        "Sign in there, then restart EUnifyer Office.",
    )


# --- Main entry point ---

def check_auth_on_startup():
    """Called by LibreOffice on startup.

    Flow:
    1. Check for auth token in keychain
    2. If valid → set sync folder as default save path, done
    3. If no token → check if Desktop app is installed
    4. If not installed → prompt download
    5. If installed → launch it for login
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
        _show_install_prompt()
        return

    # Step 4: Desktop app exists but not logged in — launch it
    _launch_desktop_app(desktop_app)
    _show_login_prompt()


# --- LibreOffice extension registration ---

g_ImplementationHelper = None

try:
    import unohelper

    class AuthGateJob(unohelper.Base):
        """Job that runs on application startup."""

        def __init__(self, ctx):
            self.ctx = ctx

        def trigger(self, args):
            check_auth_on_startup()

except ImportError:
    pass
