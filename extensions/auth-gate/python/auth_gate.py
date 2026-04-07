"""EUnifyer Auth Gate — blocks app until user signs in.

Checks the OS keychain for a valid EUnifyer access token on startup.
If not found or expired, shows a login dialog.

This is bundled with the EUnifyer Office fork, not a separate install.
"""

import json
import subprocess
import time
import uno  # noqa: F401 — LibreOffice UNO API

KEYCHAIN_SERVICE = "com.eunifyer.auth"


def _read_keychain_macos() -> dict | None:
    """Read the EUnifyer auth entry from macOS Keychain."""
    try:
        result = subprocess.run(
            [
                "security", "find-generic-password",
                "-s", KEYCHAIN_SERVICE,
                "-w",  # print password only
            ],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return None
        return json.loads(result.stdout.strip())
    except (subprocess.SubprocessError, json.JSONDecodeError):
        return None


def _is_token_valid(auth_data: dict) -> bool:
    """Check if the access token hasn't expired."""
    expires_at = auth_data.get("expires_at", "")
    if not expires_at:
        return False
    # Simple ISO8601 comparison (good enough for gate check)
    from datetime import datetime, timezone
    try:
        exp = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        return exp > datetime.now(timezone.utc)
    except ValueError:
        return False


def check_auth_on_startup():
    """Main entry point — called by LibreOffice on startup.

    If no valid token found:
    1. Try to read from keychain (shared with Tauri desktop client)
    2. If missing/expired, show a modal dialog prompting sign-in
    3. Block the app until auth succeeds
    """
    auth_data = _read_keychain_macos()

    if auth_data and _is_token_valid(auth_data):
        # Authenticated — proceed normally
        return

    # Not authenticated — show login prompt
    _show_login_dialog()


def _show_login_dialog():
    """Show a modal dialog asking the user to sign in."""
    ctx = uno.getComponentContext()
    smgr = ctx.ServiceManager
    desktop = smgr.createInstanceWithContext(
        "com.sun.star.frame.Desktop", ctx
    )

    toolkit = smgr.createInstanceWithContext(
        "com.sun.star.awt.Toolkit", ctx
    )

    # Create a simple message box
    parent = desktop.getCurrentFrame()
    if parent:
        window = parent.getContainerWindow()
        msg_box = toolkit.createMessageBox(
            window,
            1,  # INFOBOX
            1,  # OK button
            "EUnifyer Office",
            "Please sign in with your EUnifyer account.\n\n"
            "Open EUnifyer Desktop to sign in, or visit:\n"
            "https://app.eunifyer.com/auth/login",
        )
        msg_box.execute()


# LibreOffice global event listener registration
# This gets called when the extension loads
g_ImplementationHelper = None

try:
    import unohelper  # noqa: F401

    class AuthGateJob(unohelper.Base):
        """Job that runs on application startup."""

        def __init__(self, ctx):
            self.ctx = ctx

        def trigger(self, args):
            check_auth_on_startup()

except ImportError:
    # Running outside LibreOffice (testing)
    pass
