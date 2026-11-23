"""Reading the token EUnifyer Desktop stores for us — Windows specifics.

Split out of auth_gate.py so the credential lookup can be unit-tested without
UNO (see tests/test_auth_gate.py). Deliberately *not* called keychain.py: the
drive/auth overlay extensions ship a module of that name and both land on the
same LibreOffice python path, so a shared name would collide.

Desktop (eunify-desktop, src-tauri/src/auth.rs) is file-first: every
login/refresh mirrors the token JSON to
``%APPDATA%\\com.eunifyer.desktop\\auth[-<id>].json`` and *also* writes the OS
credential store. Reads must follow the same order or Office disagrees with
Desktop about who is signed in — the old code asked PowerShell for
``Get-StoredCredential``, a cmdlet Windows does not ship (it comes from the
third-party PSCredMan module), so the lookup always failed and Office decided
nobody was signed in on every startup.
"""

import json
import os

try:
    import desktop_detect
except ImportError:  # pragma: no cover - only on a mis-installed bundle
    desktop_detect = None

KEYRING_SERVICE = "com.eunifyer.auth"
# Desktop's legacy single-account mirror; the current layout is one
# `auth-<id>.json` per signed-in account (auth.rs::token_file_path).
LEGACY_TOKEN_FILE = "auth.json"


def _ordered_token_files(paths):
    """Per-account token files ahead of the legacy shared ``auth.json``.

    ``os.listdir`` order is arbitrary, so without this a stale legacy file can
    shadow a current per-account token and Office would ask a signed-in user
    to sign in again — the same symptom as the original report, one layer
    down. Desktop itself prefers the per-account slot, so we read in that
    order too.
    """
    return sorted(
        paths,
        key=lambda path: (os.path.basename(path) == LEGACY_TOKEN_FILE, path),
    )


def is_token_valid(auth_data):
    """True when the stored bundle carries a token we can still use.

    Desktop writes `expires_at` as ISO-8601 but omits it when it never
    learned one (`skip_serializing_if = "Option::is_none"`); a bundle without
    an expiry is treated as usable, because rejecting it re-asks for a
    sign-in on every launch and Office's use of the token is best-effort.
    """
    if not isinstance(auth_data, dict) or not auth_data.get("access_token"):
        return False
    expires_at = auth_data.get("expires_at") or ""
    if not expires_at:
        return True
    from datetime import datetime, timezone
    try:
        expiry = datetime.fromisoformat(str(expires_at).replace("Z", "+00:00"))
    except ValueError:
        return False
    return expiry > datetime.now(timezone.utc)


def read_json_file(path):
    """Parse a JSON object file, or None when it is missing or malformed."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def cred_read_generic(target):
    """Generic-credential blob for `target` via CredReadW, decoded, or None.

    keyring (the crate Desktop uses) writes the password with CredWriteW, so
    the blob is UTF-16; the target name is what identifies the credential.
    """
    try:
        import ctypes
        import ctypes.wintypes
    except ImportError:  # pragma: no cover - ctypes is always present
        return None
    try:
        advapi32 = ctypes.windll.advapi32

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

        credential = ctypes.POINTER(CREDENTIAL)()
        CRED_TYPE_GENERIC = 1
        if not advapi32.CredReadW(target, CRED_TYPE_GENERIC, 0,
                                  ctypes.byref(credential)):
            return None
        try:
            blob = ctypes.string_at(
                credential.contents.CredentialBlob,
                credential.contents.CredentialBlobSize,
            )
        finally:
            advapi32.CredFree(credential)
    except Exception:
        return None
    try:
        return blob.decode("utf-16-le").rstrip("\x00")
    except UnicodeDecodeError:
        return blob.decode("utf-8", "replace")


def read_credential_store(targets, cred_read=cred_read_generic):
    """First usable auth blob among credential-store `targets`."""
    candidates = []
    for target in targets:
        raw = cred_read(target)
        if not raw:
            continue
        try:
            data = json.loads(raw)
        except ValueError:
            continue
        if isinstance(data, dict) and data.get("access_token"):
            candidates.append(data)
    for data in candidates:
        if is_token_valid(data):
            return data
    return candidates[0] if candidates else None


def read_windows_tokens(env, listdir=os.listdir, cred_read=cred_read_generic):
    """Auth blob Desktop left on Windows, or None.

    File first (what Desktop itself reads), then the credential store. The
    credential targets depend on which accounts have signed in, and the
    per-account token files name them — hence the file listing does double
    duty.
    """
    paths = []
    if desktop_detect is not None:
        paths = desktop_detect.windows_token_file_paths(env, listdir=listdir)

    file_fallback = None
    for path in _ordered_token_files(paths):
        data = read_json_file(path)
        if not data or not data.get("access_token"):
            # Missing, unparseable, or cleared by a sign-out: not evidence
            # that anybody is signed in.
            continue
        if is_token_valid(data):
            return data
        if file_fallback is None:
            file_fallback = data

    if desktop_detect is not None:
        account_ids = desktop_detect.account_ids_from_token_files(
            [os.path.basename(path) for path in paths]
        )
        targets = desktop_detect.windows_credential_targets(account_ids)
    else:  # pragma: no cover - degraded bundle
        targets = [KEYRING_SERVICE]
    return read_credential_store(targets, cred_read=cred_read) or file_fallback
