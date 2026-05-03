"""Cross-platform OS keychain access for EUnifyer auth tokens.

Reads/writes the same keychain entry as the Tauri desktop app:
  Service: com.eunifyer.auth
  Account: default

Supports macOS Keychain, Windows Credential Manager, Linux Secret Service.
"""

import json
import platform
import subprocess
import logging

log = logging.getLogger("eunifyer.keychain")

SERVICE = "com.eunifyer.auth"
ACCOUNT = "default"


class AuthTokens:
    """Parsed auth token bundle from keychain."""

    __slots__ = (
        "access_token", "refresh_token", "expires_at",
        "user_id", "email", "name", "org_id", "org_name",
    )

    def __init__(self, data: dict):
        self.access_token = data.get("access_token", "")
        self.refresh_token = data.get("refresh_token", "")
        self.expires_at = data.get("expires_at", "")
        self.user_id = data.get("user_id", "")
        self.email = data.get("email", "")
        self.name = data.get("name", "")
        self.org_id = data.get("org_id", "")
        self.org_name = data.get("org_name", "")

    def is_valid(self) -> bool:
        return bool(self.access_token and self.user_id)

    def to_dict(self) -> dict:
        return {s: getattr(self, s) for s in self.__slots__}


def read_tokens() -> AuthTokens | None:
    """Read auth tokens from OS keychain. Returns None if not found."""
    system = platform.system()
    try:
        if system == "Darwin":
            return _read_macos()
        elif system == "Windows":
            return _read_windows()
        else:
            return _read_linux()
    except Exception as e:
        log.warning("Failed to read keychain: %s", e)
        return None


def write_tokens(tokens: AuthTokens) -> bool:
    """Write auth tokens to OS keychain."""
    system = platform.system()
    try:
        data = json.dumps(tokens.to_dict())
        if system == "Darwin":
            return _write_macos(data)
        elif system == "Windows":
            return _write_windows(data)
        else:
            return _write_linux(data)
    except Exception as e:
        log.error("Failed to write keychain: %s", e)
        return False


def clear_tokens() -> bool:
    """Remove auth tokens from OS keychain."""
    system = platform.system()
    try:
        if system == "Darwin":
            return _clear_macos()
        elif system == "Windows":
            return _clear_windows()
        else:
            return _clear_linux()
    except Exception as e:
        log.warning("Failed to clear keychain: %s", e)
        return False


# ---------------------------------------------------------------------------
# macOS — uses `security` CLI (no extra dependencies)
# ---------------------------------------------------------------------------

def _read_macos() -> AuthTokens | None:
    result = subprocess.run(
        ["security", "find-generic-password",
         "-s", SERVICE, "-a", ACCOUNT, "-w"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    data = json.loads(result.stdout.strip())
    return AuthTokens(data)


def _write_macos(json_str: str) -> bool:
    # Delete existing first (security add fails if exists)
    _clear_macos()
    result = subprocess.run(
        ["security", "add-generic-password",
         "-s", SERVICE, "-a", ACCOUNT, "-w", json_str,
         "-U"],  # -U = update if exists
        capture_output=True, text=True,
    )
    return result.returncode == 0


def _clear_macos() -> bool:
    result = subprocess.run(
        ["security", "delete-generic-password",
         "-s", SERVICE, "-a", ACCOUNT],
        capture_output=True, text=True,
    )
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Windows — uses PowerShell + CredentialManager
# ---------------------------------------------------------------------------

def _read_windows() -> AuthTokens | None:
    ps_cmd = (
        f'$c = Get-StoredCredential -Target "{SERVICE}";'
        f'if ($c) {{ $c.Password | ConvertFrom-SecureString -AsPlainText }}'
    )
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps_cmd],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        # Fallback: try cmdkey + manual extraction via WinCred API
        return _read_windows_wincred()
    data = json.loads(result.stdout.strip())
    return AuthTokens(data)


def _read_windows_wincred() -> AuthTokens | None:
    """Fallback using ctypes to call CredRead directly."""
    try:
        import ctypes
        import ctypes.wintypes

        advapi32 = ctypes.windll.advapi32
        CRED_TYPE_GENERIC = 1

        class CREDENTIAL(ctypes.Structure):
            _fields_ = [
                ("Flags", ctypes.wintypes.DWORD),
                ("Type", ctypes.wintypes.DWORD),
                ("TargetName", ctypes.wintypes.LPWSTR),
                ("Comment", ctypes.wintypes.LPWSTR),
                ("LastWritten", ctypes.wintypes.FILETIME),
                ("CredentialBlobSize", ctypes.wintypes.DWORD),
                ("CredentialBlob", ctypes.POINTER(ctypes.c_byte)),
                ("Persist", ctypes.wintypes.DWORD),
                ("AttributeCount", ctypes.wintypes.DWORD),
                ("Attributes", ctypes.c_void_p),
                ("TargetAlias", ctypes.wintypes.LPWSTR),
                ("UserName", ctypes.wintypes.LPWSTR),
            ]

        pcred = ctypes.POINTER(CREDENTIAL)()
        ok = advapi32.CredReadW(SERVICE, CRED_TYPE_GENERIC, 0, ctypes.byref(pcred))
        if not ok:
            return None

        cred = pcred.contents
        blob = ctypes.string_at(cred.CredentialBlob, cred.CredentialBlobSize)
        advapi32.CredFree(pcred)
        data = json.loads(blob.decode("utf-16-le").rstrip("\x00"))
        return AuthTokens(data)
    except Exception:
        return None


def _write_windows(json_str: str) -> bool:
    ps_cmd = (
        f'$pw = ConvertTo-SecureString "{json_str}" -AsPlainText -Force;'
        f'New-StoredCredential -Target "{SERVICE}" -UserName "{ACCOUNT}" '
        f'-SecurePassword $pw -Type Generic -Persist LocalMachine | Out-Null'
    )
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps_cmd],
        capture_output=True, text=True,
    )
    return result.returncode == 0


def _clear_windows() -> bool:
    result = subprocess.run(
        ["cmdkey", "/delete:" + SERVICE],
        capture_output=True, text=True,
    )
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Linux — uses secret-tool (GNOME Keyring / KWallet via Secret Service)
# ---------------------------------------------------------------------------

def _read_linux() -> AuthTokens | None:
    result = subprocess.run(
        ["secret-tool", "lookup", "service", SERVICE, "account", ACCOUNT],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    data = json.loads(result.stdout.strip())
    return AuthTokens(data)


def _write_linux(json_str: str) -> bool:
    result = subprocess.run(
        ["secret-tool", "store", "--label", "EUnifyer Auth",
         "service", SERVICE, "account", ACCOUNT],
        input=json_str, capture_output=True, text=True,
    )
    return result.returncode == 0


def _clear_linux() -> bool:
    result = subprocess.run(
        ["secret-tool", "clear", "service", SERVICE, "account", ACCOUNT],
        capture_output=True, text=True,
    )
    return result.returncode == 0
