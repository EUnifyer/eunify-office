"""Tests for the bundled auth-gate extension's Windows detection.

Run from the repo root with the system python (no deps, no LibreOffice):

    python3 -m unittest discover -s tests -v

Covers the three things that made EUnifyer Office ask for an EUnifyer Desktop
install that was already there: the install-path matrix (desktop_detect), the
token lookup (token_store), and the prompts that never remembered an answer.
"""

import json
import os
import shutil
import sys
import tempfile
import types
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTENSION_PYTHON = os.path.join(
    REPO_ROOT, "extensions", "auth-gate", "python"
)
if EXTENSION_PYTHON not in sys.path:
    sys.path.insert(0, EXTENSION_PYTHON)

import desktop_detect
import token_store

LOCAL_APP_DATA = r"C:\Users\edi\AppData\Local"
PROGRAM_FILES = r"C:\Program Files"

WINDOWS_ENV = {
    "LOCALAPPDATA": LOCAL_APP_DATA,
    "PROGRAMFILES": PROGRAM_FILES,
    "PROGRAMFILES(X86)": r"C:\Program Files (x86)",
    "APPDATA": r"C:\Users\edi\AppData\Roaming",
}


def install_uno_stubs():
    """Stand in for the python-UNO modules auth_gate imports at load time."""
    uno = types.ModuleType("uno")
    uno.getComponentContext = lambda: None
    uno.fileUrlToSystemPath = lambda url: url
    sys.modules.setdefault("uno", uno)

    unohelper = types.ModuleType("unohelper")
    unohelper.Base = type("Base", (), {})
    unohelper.ImplementationHelper = type(
        "ImplementationHelper",
        (),
        {"addImplementation": lambda self, *args, **kwargs: None},
    )
    sys.modules.setdefault("unohelper", unohelper)

    for name in ("com", "com.sun", "com.sun.star", "com.sun.star.task"):
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.modules["com.sun.star.task"].XJob = type("XJob", (), {})


class WindowsInstallDetection(unittest.TestCase):
    """Report A: Office never saw a Desktop install that was present."""

    def find(self, existing=(), registry=None):
        existing = set(existing)
        return desktop_detect.find_windows_desktop(
            WINDOWS_ENV,
            path_exists=lambda path: path in existing,
            read_registry_value=(lambda h, s, v: (registry or {}).get((h, s, v))),
            listdir=lambda path: [],
        )

    def test_finds_current_per_user_install(self):
        # What the NSIS installer actually writes today: the productName
        # directory, the cargo binary name inside it.
        installed = os.path.join(LOCAL_APP_DATA, "DriveSync", "eunify-desktop.exe")
        self.assertEqual(self.find(existing=[installed]), installed)

    def test_finds_per_machine_msi_install(self):
        installed = os.path.join(PROGRAM_FILES, "DriveSync", "eunify-desktop.exe")
        self.assertEqual(self.find(existing=[installed]), installed)

    def test_finds_legacy_eunifyer_desktop_install(self):
        installed = os.path.join(
            LOCAL_APP_DATA, "EUnifyer Desktop", "EUnifyer Desktop.exe"
        )
        self.assertEqual(self.find(existing=[installed]), installed)

    def test_finds_legacy_eunifyer_install(self):
        installed = os.path.join(LOCAL_APP_DATA, "EUnifyer", "EUnifyer.exe")
        self.assertEqual(self.find(existing=[installed]), installed)

    def test_candidates_cover_every_name_era(self):
        paths = desktop_detect.windows_install_candidate_paths(WINDOWS_ENV)
        for expected in (
            os.path.join(LOCAL_APP_DATA, "DriveSync", "eunify-desktop.exe"),
            os.path.join(LOCAL_APP_DATA, "EUnifyer Desktop", "DriveSync.exe"),
            os.path.join(PROGRAM_FILES, "DriveSync", "eunify-desktop.exe"),
            os.path.join(LOCAL_APP_DATA, "Programs", "DriveSync", "DriveSync.exe"),
        ):
            self.assertIn(expected, paths)

    def test_ignores_unrelated_env(self):
        self.assertEqual(
            desktop_detect.windows_install_candidate_paths({}), []
        )

    def test_registry_install_location_when_directory_moved(self):
        moved = os.path.join(r"D:\Apps", "DriveSync")
        installed = os.path.join(moved, "eunify-desktop.exe")
        key = (
            "HKCU",
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DriveSync",
            "InstallLocation",
        )
        self.assertEqual(
            self.find(existing=[installed], registry={key: moved}), installed
        )

    def test_registry_install_location_is_written_quoted(self):
        # installer.nsi writes InstallLocation as "$INSTDIR" (with quotes).
        directory = os.path.join(LOCAL_APP_DATA, "DriveSync")
        installed = os.path.join(directory, "eunify-desktop.exe")
        key = (
            "HKCU",
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DriveSync",
            "InstallLocation",
        )
        self.assertEqual(
            self.find(existing=[installed], registry={key: f'"{directory}"'}),
            installed,
        )

    def test_registry_display_icon_is_unquoted(self):
        installed = os.path.join(LOCAL_APP_DATA, "Custom", "eunify-desktop.exe")
        key = (
            "HKLM",
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DriveSync",
            "DisplayIcon",
        )
        self.assertEqual(
            self.find(existing=[installed], registry={key: f'"{installed}"'}),
            installed,
        )

    def test_registry_publisher_key(self):
        installed = os.path.join(r"E:\Sync", "DriveSync", "eunify-desktop.exe")
        key = ("HKCU", r"SOFTWARE\eunifyer\DriveSync", "")
        self.assertEqual(
            self.find(existing=[installed], registry={key: os.path.dirname(installed)}),
            installed,
        )

    def test_deep_link_handler_is_a_hint_not_truth(self):
        command = r'"C:\Other\eunify-desktop.exe" "%1"'
        key = ("HKCU", r"SOFTWARE\Classes\eunify\shell\open\command", "")
        # The file the registry points at does not exist → not reported.
        self.assertIsNone(self.find(registry={key: command}))

    def test_run_key_finds_an_unusual_install(self):
        installed = os.path.join(r"D:\Tools\DriveSync", "eunify-desktop.exe")
        key = (
            "HKCU",
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "EUnifyer",
        )
        self.assertEqual(
            self.find(existing=[installed], registry={key: f'"{installed}" --minimized'}),
            installed,
        )

    def test_returns_none_when_nothing_matches(self):
        self.assertIsNone(self.find())

    def test_registry_read_failures_are_not_fatal(self):
        def boom(hive, subkey, value):
            raise OSError("registry unavailable")

        self.assertIsNone(
            desktop_detect.find_windows_desktop(
                WINDOWS_ENV,
                path_exists=lambda path: False,
                read_registry_value=boom,
                listdir=lambda path: [],
            )
        )


class RegistryValueParsing(unittest.TestCase):
    def test_quoted_command_line(self):
        self.assertEqual(
            desktop_detect.parse_executable_value(
                r'"C:\Program Files\DriveSync\eunify-desktop.exe" --minimized'
            ),
            r"C:\Program Files\DriveSync\eunify-desktop.exe",
        )

    def test_bare_path_and_empty(self):
        self.assertEqual(
            desktop_detect.parse_executable_value(r"C:\a\eunify-desktop.exe"),
            r"C:\a\eunify-desktop.exe",
        )
        self.assertIsNone(desktop_detect.parse_executable_value(""))
        self.assertIsNone(desktop_detect.parse_executable_value(None))

    def test_directory_values_are_not_executables(self):
        self.assertIsNone(
            desktop_detect.parse_executable_value(r"C:\Users\edi\AppData\Local\DriveSync")
        )
        self.assertEqual(
            desktop_detect.parse_install_dir_value('"C:\\x\\DriveSync\\"'),
            r"C:\x\DriveSync",
        )
        self.assertIsNone(
            desktop_detect.parse_install_dir_value(r"C:\x\eunify-desktop.exe")
        )


class TokenLookup(unittest.TestCase):
    """Report A, second half: Office could not see Desktop's token."""

    def token(self, **overrides):
        data = {"access_token": "tok", "refresh_token": "ref"}
        data.update(overrides)
        return data

    def test_credential_targets_match_keyring_naming(self):
        targets = desktop_detect.windows_credential_targets(["abc123"])
        self.assertEqual(
            targets,
            [
                "token-abc123.com.eunifyer.auth",
                "token.com.eunifyer.auth",
                "com.eunifyer.auth",
            ],
        )

    def test_account_ids_come_from_the_token_files(self):
        names = ["auth.json", "auth-abc123.json", "settings.json", "auth-x.log"]
        self.assertEqual(desktop_detect.account_ids_from_token_files(names), ["abc123"])

    def test_reads_the_file_mirror_first(self):
        directory = tempfile.mkdtemp(prefix="eunifyer-token-", dir="/tmp")
        try:
            # dirs::data_dir() on Windows is %APPDATA%, and auth.rs keeps the
            # mirror under <APPDATA>\com.eunifyer.desktop.
            payload_dir = os.path.join(directory, "com.eunifyer.desktop")
            os.makedirs(payload_dir)
            payload = os.path.join(payload_dir, "auth-abc123.json")
            with open(payload, "w", encoding="utf-8") as handle:
                json.dump(self.token(email="edi@eunifyer.com"), handle)
            called = []

            def cred_read(target):
                called.append(target)
                return json.dumps(self.token(access_token="stale"))

            found = token_store.read_windows_tokens(
                {"APPDATA": directory},
                listdir=os.listdir,
                cred_read=cred_read,
            )
            self.assertEqual(found["access_token"], "tok")
            self.assertEqual(called, [])  # the file is authoritative
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_falls_back_to_the_credential_store(self):
        found = token_store.read_windows_tokens(
            {"APPDATA": r"C:\Users\edi\AppData\Roaming"},
            listdir=lambda path: ["auth-abc123.json"],
            cred_read=lambda target: (
                json.dumps(self.token())
                if target == "token-abc123.com.eunifyer.auth"
                else None
            ),
        )
        self.assertEqual(found, self.token())

    def test_malformed_token_file_is_skipped(self):
        directory = tempfile.mkdtemp(prefix="eunifyer-token-", dir="/tmp")
        try:
            payload_dir = os.path.join(directory, "com.eunifyer.desktop")
            os.makedirs(payload_dir)
            with open(os.path.join(payload_dir, "auth.json"), "w") as handle:
                handle.write("{not json")
            found = token_store.read_windows_tokens(
                {"APPDATA": directory},
                listdir=os.listdir,
                cred_read=lambda target: json.dumps(self.token(access_token="cred")),
            )
            self.assertEqual(found["access_token"], "cred")
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_prefers_the_unexpired_credential(self):
        blobs = {
            "token.com.eunifyer.auth": json.dumps(
                self.token(access_token="expired", expires_at="2020-01-01T00:00:00Z")
            ),
            "token-abc123.com.eunifyer.auth": json.dumps(
                self.token(access_token="live", expires_at="2999-01-01T00:00:00Z")
            ),
        }
        found = token_store.read_credential_store(
            list(blobs), cred_read=lambda target: blobs.get(target)
        )
        self.assertEqual(found["access_token"], "live")

    def test_per_account_file_wins_over_legacy_auth_json(self):
        # Both mirrors are usable, so only the read order decides — and
        # os.listdir order is arbitrary. Desktop prefers the per-account slot,
        # so a stale legacy auth.json must not shadow it.
        directory = tempfile.mkdtemp(prefix="eunifyer-token-", dir="/tmp")
        try:
            payload_dir = os.path.join(directory, "com.eunifyer.desktop")
            os.makedirs(payload_dir)
            for name, token in (
                ("auth.json", "legacy"),
                ("auth-abc123.json", "current"),
            ):
                with open(os.path.join(payload_dir, name), "w", encoding="utf-8") as handle:
                    json.dump(self.token(access_token=token), handle)
            found = token_store.read_windows_tokens(
                {"APPDATA": directory},
                # Legacy file first in the listing, the worst case.
                listdir=lambda path: ["auth.json", "auth-abc123.json"],
                cred_read=lambda target: None,
            )
            self.assertEqual(found["access_token"], "current")
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_cleared_token_file_falls_through_to_credential_store(self):
        # A sign-out leaves a file behind; returning it would report "signed
        # out" while the credential store still holds a usable token.
        directory = tempfile.mkdtemp(prefix="eunifyer-token-", dir="/tmp")
        try:
            payload_dir = os.path.join(directory, "com.eunifyer.desktop")
            os.makedirs(payload_dir)
            with open(os.path.join(payload_dir, "auth.json"), "w", encoding="utf-8") as handle:
                json.dump({"access_token": "", "email": "edi@eunifyer.com"}, handle)
            found = token_store.read_windows_tokens(
                {"APPDATA": directory},
                listdir=os.listdir,
                cred_read=lambda target: json.dumps(self.token(access_token="cred")),
            )
            self.assertEqual(found["access_token"], "cred")
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_token_without_expiry_is_usable(self):
        # Desktop omits expires_at when it never learned one; rejecting that
        # re-asks a signed-in user to log in on every launch.
        self.assertTrue(token_store.is_token_valid(self.token()))

    def test_rejects_expired_or_empty(self):
        self.assertFalse(
            token_store.is_token_valid(
                self.token(expires_at="2020-01-01T00:00:00Z")
            )
        )
        self.assertFalse(token_store.is_token_valid({"expires_at": "later"}))
        self.assertFalse(token_store.is_token_valid({"refresh_token": "ref"}))
        self.assertFalse(token_store.is_token_valid(None))


class StartupPrompts(unittest.TestCase):
    """Report A, third half: the prompts never remembered an answer."""

    def setUp(self):
        install_uno_stubs()
        import auth_gate

        self.gate = auth_gate
        self.calls = []

        def patch(name, value):
            original = getattr(auth_gate, name)
            setattr(auth_gate, name, value)
            self.addCleanup(setattr, auth_gate, name, original)

        patch("_read_auth_token", lambda: None)
        patch("_set_default_save_path", lambda: self.calls.append("save-path"))
        patch("_launch_desktop_app", lambda path: self.calls.append(("launch", path)))
        patch("_open_url", lambda url: self.calls.append(("open", url)))
        patch("_write_marker", lambda name: self.calls.append(("write", name)))
        self.markers = set()
        patch("_marker_exists", lambda name: name in self.markers)
        self.answers = []
        patch(
            "_show_message",
            lambda title, message, msg_type=1, buttons=1: (
                self.calls.append(("dialog", title))
                or (self.answers.pop(0) if self.answers else 1)
            ),
        )

    def test_signed_in_user_sees_no_dialog(self):
        self.gate._read_auth_token = lambda: {"access_token": "tok"}
        self.gate.check_auth_on_startup()
        self.assertEqual(self.calls, ["save-path"])

    def test_install_prompt_asks_once_and_remembers_a_decline(self):
        self.gate._find_desktop_app = lambda: None
        self.answers.append(2)  # Cancel
        self.gate.check_auth_on_startup()
        self.assertIn(("dialog", "EUnifyer Office"), self.calls)
        self.assertIn(
            ("write", self.gate.DESKTOP_PROMPT_MARKER), self.calls
        )
        self.assertNotIn(("open", self.gate.DOWNLOAD_URL), self.calls)

        self.calls.clear()
        self.markers.add(self.gate.DESKTOP_PROMPT_MARKER)
        self.gate.check_auth_on_startup()
        self.assertEqual(self.calls, [])  # no second nag

    def test_install_prompt_opens_download_only_on_ok(self):
        self.gate._find_desktop_app = lambda: None
        self.answers.append(1)  # OK
        self.gate.check_auth_on_startup()
        self.assertIn(("open", self.gate.DOWNLOAD_URL), self.calls)
        self.assertNotIn(
            ("write", self.gate.DESKTOP_PROMPT_MARKER), self.calls
        )

    def test_declined_dialog_without_a_window_does_not_loop(self):
        self.gate._find_desktop_app = lambda: None
        self.answers.append(0)  # dialog could not be shown
        self.gate.check_auth_on_startup()
        self.assertIn(
            ("write", self.gate.DESKTOP_PROMPT_MARKER), self.calls
        )

    def test_login_hint_shown_once_but_desktop_still_launches(self):
        self.gate._find_desktop_app = lambda: r"C:\Users\edi\AppData\Local\DriveSync\eunify-desktop.exe"
        self.gate.check_auth_on_startup()
        self.assertIn(("dialog", "EUnifyer Office"), self.calls)
        self.assertIn(
            ("launch", r"C:\Users\edi\AppData\Local\DriveSync\eunify-desktop.exe"),
            self.calls,
        )

        self.calls.clear()
        self.markers.add(self.gate.LOGIN_HINT_MARKER)
        self.gate.check_auth_on_startup()
        self.assertEqual(
            self.calls,
            [("launch", r"C:\Users\edi\AppData\Local\DriveSync\eunify-desktop.exe")],
        )

    def test_markers_live_in_the_profile_dir(self):
        self.assertEqual(self.gate._marker_path("x"), "")
        original = self.gate._user_profile_dir
        self.gate._user_profile_dir = lambda: r"C:\Users\edi\AppData\Roaming\libreoffice\4"
        self.addCleanup(setattr, self.gate, "_user_profile_dir", original)
        self.assertEqual(
            self.gate._marker_path(self.gate.DESKTOP_PROMPT_MARKER),
            os.path.join(
                r"C:\Users\edi\AppData\Roaming\libreoffice\4",
                self.gate.DESKTOP_PROMPT_MARKER,
            ),
        )


if __name__ == "__main__":
    unittest.main()
