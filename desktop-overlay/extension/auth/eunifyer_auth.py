"""EUnifyer Auth Gate — LibreOffice startup extension.

Blocks application usage until the user authenticates via EUnifyer (Keycloak).
Reads shared keychain tokens written by EUnifyer Desktop (Tauri).

Lifecycle:
  1. OnStartApp → check keychain for valid tokens
  2. If no token → show modal login dialog (blocks UI)
  3. If expired → attempt silent refresh
  4. If refresh fails → show login dialog
  5. Background timer refreshes token every 15 min

Registration: This file is declared in META-INF/manifest.xml and loaded
by LibreOffice's extension framework on startup.
"""

import json
import logging
import platform
import subprocess
import threading
import time
import webbrowser
from datetime import datetime, timezone
from urllib.parse import urlencode

import uno
from com.sun.star.task import XJobExecutor

log = logging.getLogger("eunifyer.auth")

# Import sibling module
import keychain

# Keycloak defaults (overridable via env or config)
KEYCLOAK_URL = "https://auth.eunifyer.com"
KEYCLOAK_REALM = "eunify"
OIDC_CLIENT_ID = "eunify-desktop"
REDIRECT_URI = "eunify://auth/callback"
REFRESH_INTERVAL_SECS = 15 * 60  # 15 minutes


class EUnifyerAuthGate:
    """Global event listener that gates app launch on authentication."""

    def __init__(self):
        self._tokens = None
        self._refresh_thread = None
        self._running = False

    def check_auth_on_startup(self):
        """Called during extension initialization. Blocks until authenticated."""
        tokens = keychain.read_tokens()

        if tokens and tokens.is_valid():
            if self._is_expired(tokens):
                tokens = self._try_refresh(tokens)

            if tokens and tokens.is_valid():
                self._tokens = tokens
                self._start_refresh_timer()
                log.info("Auth OK: %s (%s)", tokens.name, tokens.email)
                return True

        # No valid tokens — show login dialog
        return self._show_login_required()

    def sign_out(self):
        """Clear tokens and lock the app."""
        self._running = False
        keychain.clear_tokens()
        self._tokens = None
        log.info("User signed out")
        self._show_login_required()

    def get_user_info(self) -> dict | None:
        """Return current user info for UI display."""
        if self._tokens:
            return {
                "name": self._tokens.name,
                "email": self._tokens.email,
                "org_name": self._tokens.org_name,
            }
        return None

    def get_access_token(self) -> str | None:
        """Return current access token for API calls."""
        if self._tokens and self._tokens.is_valid():
            if self._is_expired(self._tokens):
                self._tokens = self._try_refresh(self._tokens)
            if self._tokens:
                return self._tokens.access_token
        return None

    # ----- Private -----

    def _is_expired(self, tokens: keychain.AuthTokens) -> bool:
        """Check if access token is expired or within 60s of expiry."""
        try:
            expires = datetime.fromisoformat(
                tokens.expires_at.replace("Z", "+00:00")
            )
            now = datetime.now(timezone.utc)
            return (expires - now).total_seconds() < 60
        except (ValueError, AttributeError):
            return True

    def _try_refresh(self, tokens: keychain.AuthTokens) -> keychain.AuthTokens | None:
        """Attempt silent token refresh via Keycloak."""
        try:
            import urllib.request
            import urllib.parse

            token_url = (
                f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}"
                f"/protocol/openid-connect/token"
            )
            data = urllib.parse.urlencode({
                "grant_type": "refresh_token",
                "client_id": OIDC_CLIENT_ID,
                "refresh_token": tokens.refresh_token,
            }).encode()

            req = urllib.request.Request(
                token_url, data=data,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read())

            # Decode ID token for user info
            id_token = result.get("id_token", "")
            claims = self._decode_jwt_payload(id_token)

            new_expires = datetime.now(timezone.utc).timestamp() + result["expires_in"]
            expires_at = datetime.fromtimestamp(
                new_expires, tz=timezone.utc
            ).isoformat()

            new_tokens = keychain.AuthTokens({
                "access_token": result["access_token"],
                "refresh_token": result["refresh_token"],
                "expires_at": expires_at,
                "user_id": claims.get("sub", tokens.user_id),
                "email": claims.get("email", tokens.email),
                "name": claims.get("name", tokens.name),
                "org_id": claims.get("org_id", tokens.org_id),
                "org_name": claims.get("org_name", tokens.org_name),
            })

            keychain.write_tokens(new_tokens)
            log.info("Token refreshed for %s", new_tokens.email)
            return new_tokens

        except Exception as e:
            log.warning("Token refresh failed: %s", e)
            return None

    def _decode_jwt_payload(self, token: str) -> dict:
        """Decode JWT payload (no signature verification — trusted source)."""
        import base64

        parts = token.split(".")
        if len(parts) != 3:
            return {}
        payload = parts[1]
        # Add padding
        payload += "=" * (4 - len(payload) % 4)
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)

    def _start_refresh_timer(self):
        """Background thread to refresh token periodically."""
        self._running = True

        def _refresh_loop():
            while self._running:
                time.sleep(REFRESH_INTERVAL_SECS)
                if not self._running:
                    break
                if self._tokens:
                    refreshed = self._try_refresh(self._tokens)
                    if refreshed:
                        self._tokens = refreshed

        self._refresh_thread = threading.Thread(
            target=_refresh_loop, daemon=True, name="eunifyer-token-refresh"
        )
        self._refresh_thread.start()

    def _show_login_required(self) -> bool:
        """Show a modal dialog requiring login.

        Returns True if login succeeded, False if user cancelled.
        """
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager

        # Create a simple message box via Toolkit
        toolkit = smgr.createInstanceWithContext(
            "com.sun.star.awt.Toolkit", ctx
        )
        desktop = smgr.createInstanceWithContext(
            "com.sun.star.frame.Desktop", ctx
        )

        # Try to get a parent window
        parent = None
        try:
            frame = desktop.getCurrentFrame()
            if frame:
                parent = frame.getContainerWindow()
        except Exception:
            pass

        if parent is None:
            parent = toolkit.getDesktopWindow()

        # Show dialog with two options
        msg_box = toolkit.createMessageBox(
            parent,
            1,  # QUERYBOX
            1 + 2,  # OK + CANCEL buttons
            "EUnifyer — Sign In Required",
            "You must sign in with your EUnifyer account to use this application.\n\n"
            "Click OK to open the sign-in page in your browser,\n"
            "or ensure EUnifyer Desktop is running and signed in.",
        )

        result = msg_box.execute()

        if result == 1:  # OK
            self._open_browser_login()
            # Poll keychain for tokens (user completes login in browser)
            return self._wait_for_login()

        # User cancelled — exit the app
        try:
            desktop.terminate()
        except Exception:
            pass
        return False

    def _open_browser_login(self):
        """Open Keycloak login in the system browser (PKCE flow)."""
        import hashlib
        import base64
        import os

        # Generate PKCE verifier + challenge
        verifier = base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()
        ).rstrip(b"=").decode()

        # Store verifier for later (not needed if Tauri handles callback)
        # The typical flow: user has EUnifyer Desktop which handles the callback.
        # If not installed, we just poll the keychain.

        auth_url = (
            f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}"
            f"/protocol/openid-connect/auth?"
            + urlencode({
                "response_type": "code",
                "client_id": OIDC_CLIENT_ID,
                "redirect_uri": REDIRECT_URI,
                "scope": "openid profile email offline_access",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            })
        )
        webbrowser.open(auth_url)

    def _wait_for_login(self, timeout_secs: int = 300) -> bool:
        """Poll keychain until tokens appear (login completed via browser/Tauri)."""
        start = time.time()
        while (time.time() - start) < timeout_secs:
            time.sleep(2)
            tokens = keychain.read_tokens()
            if tokens and tokens.is_valid():
                self._tokens = tokens
                self._start_refresh_timer()
                log.info("Login detected: %s", tokens.email)
                return True
        return False


# ---------------------------------------------------------------------------
# Singleton instance — shared with Drive extension
# ---------------------------------------------------------------------------

_auth_gate = EUnifyerAuthGate()


def get_auth_gate() -> EUnifyerAuthGate:
    """Get the singleton auth gate instance."""
    return _auth_gate


# ---------------------------------------------------------------------------
# LibreOffice extension entry point
# ---------------------------------------------------------------------------

class AuthStartupJob:
    """UNO component that runs on application startup."""

    IMPLE_NAME = "com.eunifyer.auth.StartupJob"
    SERVICE_NAMES = ("com.sun.star.task.Job",)

    def __init__(self, ctx):
        self._ctx = ctx

    @staticmethod
    def getSupportedServiceNames():
        return AuthStartupJob.SERVICE_NAMES

    @staticmethod
    def getImplementationName():
        return AuthStartupJob.IMPLE_NAME

    def supportsService(self, name):
        return name in self.SERVICE_NAMES

    def execute(self, args):
        """Called by LibreOffice on startup (via Jobs.xcu)."""
        gate = get_auth_gate()
        gate.check_auth_on_startup()
        return ""


# UNO component registration
g_ImplementationHelper = uno.createRegistrationHelper()

g_ImplementationHelper.addImplementation(
    AuthStartupJob,
    AuthStartupJob.IMPLE_NAME,
    AuthStartupJob.SERVICE_NAMES,
)
