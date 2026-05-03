"""EUnifyer Drive — LibreOffice remote file access extension.

Adds "EUnifyer Drive" to the File → Open Remote dialog and provides
menu items for browsing, opening, and saving files to/from EUnifyer Drive.

v1 approach: download-to-temp on open, upload on save.
The local sync folder (~/EUnifyer) is handled by the Tauri sync engine;
this extension provides *direct* Drive access for files outside the sync scope.
"""

import logging
import os
import threading

import uno
from com.sun.star.beans import PropertyValue

# Sibling modules (bundled in the .oxt)
import drive_client

log = logging.getLogger("eunifyer.drive")

# Track open files: local_temp_path → (file_id, original_name)
_open_files: dict[str, tuple[str, str]] = {}
_open_files_lock = threading.Lock()


def _get_auth_token() -> str | None:
    """Get access token from the auth gate extension."""
    try:
        # Import from the auth extension (loaded before us)
        import eunifyer_auth
        gate = eunifyer_auth.get_auth_gate()
        return gate.get_access_token()
    except ImportError:
        log.warning("Auth extension not available, trying keychain directly")
        import keychain
        tokens = keychain.read_tokens()
        if tokens and tokens.is_valid():
            return tokens.access_token
        return None


def _get_client() -> drive_client.DriveClient:
    return drive_client.DriveClient(_get_auth_token)


class EUnifyerDriveMenu:
    """UNO dispatch command handler for EUnifyer Drive menu items."""

    IMPLE_NAME = "com.eunifyer.drive.MenuHandler"
    SERVICE_NAMES = ("com.sun.star.frame.ProtocolHandler",)

    PROTOCOL = "com.eunifyer.drive:"

    def __init__(self, ctx):
        self._ctx = ctx

    @staticmethod
    def getSupportedServiceNames():
        return EUnifyerDriveMenu.SERVICE_NAMES

    @staticmethod
    def getImplementationName():
        return EUnifyerDriveMenu.IMPLE_NAME

    def supportsService(self, name):
        return name in self.SERVICE_NAMES

    # --- XDispatchProvider ---

    def queryDispatch(self, url, target_frame, flags):
        if url.Protocol == self.PROTOCOL:
            return self
        return None

    def queryDispatches(self, requests):
        return [self.queryDispatch(r.FeatureURL, r.FrameName, r.SearchFlags)
                for r in requests]

    # --- XDispatch ---

    def dispatch(self, url, args):
        cmd = url.Path
        if cmd == "Browse":
            self._browse_drive()
        elif cmd == "SaveToDrive":
            self._save_to_drive()

    def addStatusListener(self, listener, url):
        pass

    def removeStatusListener(self, listener, url):
        pass

    # --- Drive operations ---

    def _browse_drive(self):
        """Show a folder browser dialog for EUnifyer Drive."""
        client = _get_client()

        # Build folder tree via recursive listing
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        desktop = smgr.createInstanceWithContext(
            "com.sun.star.frame.Desktop", ctx
        )
        toolkit = smgr.createInstanceWithContext(
            "com.sun.star.awt.Toolkit", ctx
        )

        # For v1: show a simple folder picker using ListBox dialog
        parent = None
        try:
            frame = desktop.getCurrentFrame()
            if frame:
                parent = frame.getContainerWindow()
        except Exception:
            pass

        if parent is None:
            parent = toolkit.getDesktopWindow()

        # List root folder
        files = client.list_folder(None)
        if not files:
            self._show_message(parent, toolkit, "EUnifyer Drive",
                               "No files found or unable to connect.")
            return

        # Build selection list
        items = []
        for f in files:
            prefix = "[Folder] " if f.is_folder else ""
            items.append(f"{prefix}{f.name}")

        # Simple selection via message (v1 — a proper tree dialog comes in v2)
        # For now, create a dialog with a list
        selected = self._show_file_picker(parent, toolkit, items)
        if selected is None or selected < 0 or selected >= len(files):
            return

        chosen = files[selected]
        if chosen.is_folder:
            # Recurse into folder
            self._open_folder(client, chosen.id, chosen.name, parent, toolkit, desktop)
        else:
            # Download and open
            self._open_file(client, chosen, desktop)

    def _open_folder(self, client, folder_id, folder_name, parent, toolkit, desktop):
        """Open a subfolder listing."""
        files = client.list_folder(folder_id)
        if not files:
            self._show_message(parent, toolkit, folder_name, "Folder is empty.")
            return

        items = ["[..] Go back"]
        for f in files:
            prefix = "[Folder] " if f.is_folder else ""
            items.append(f"{prefix}{f.name}")

        selected = self._show_file_picker(parent, toolkit, items)
        if selected is None or selected < 0:
            return

        if selected == 0:
            # Go back to root
            self._browse_drive()
            return

        chosen = files[selected - 1]
        if chosen.is_folder:
            self._open_folder(client, chosen.id, chosen.name, parent, toolkit, desktop)
        else:
            self._open_file(client, chosen, desktop)

    def _open_file(self, client, drive_file, desktop):
        """Download file to temp and open in LibreOffice."""
        local_path = client.download_to_temp(drive_file.id, drive_file.name)
        if not local_path:
            log.error("Failed to download %s", drive_file.name)
            return

        # Track for save-back
        with _open_files_lock:
            _open_files[local_path] = (drive_file.id, drive_file.name)

        # Open in LibreOffice
        url = uno.systemPathToFileUrl(local_path)
        props = []
        desktop.loadComponentFromURL(url, "_blank", 0, tuple(props))
        log.info("Opened %s from Drive", drive_file.name)

    def _save_to_drive(self):
        """Save current document back to EUnifyer Drive."""
        ctx = uno.getComponentContext()
        smgr = ctx.ServiceManager
        desktop = smgr.createInstanceWithContext(
            "com.sun.star.frame.Desktop", ctx
        )

        doc = desktop.getCurrentComponent()
        if not doc:
            return

        # Get the local file path
        doc_url = doc.getURL()
        if not doc_url:
            return

        local_path = uno.fileUrlToSystemPath(doc_url)

        # Save the document first
        doc.store()

        client = _get_client()

        # Check if this file was opened from Drive
        with _open_files_lock:
            drive_info = _open_files.get(local_path)

        if drive_info:
            # Update existing file
            file_id, name = drive_info
            if client.update_file(file_id, local_path):
                log.info("Saved %s back to Drive", name)
                self._show_status("Saved to EUnifyer Drive")
            else:
                log.error("Failed to save %s to Drive", name)
        else:
            # New upload — ask for target folder (v1: upload to root)
            name = os.path.basename(local_path)
            file_id = client.upload_file(local_path, name, parent_id=None)
            if file_id:
                with _open_files_lock:
                    _open_files[local_path] = (file_id, name)
                log.info("Uploaded %s to Drive", name)
                self._show_status("Uploaded to EUnifyer Drive")

    def _show_message(self, parent, toolkit, title, message):
        msg_box = toolkit.createMessageBox(parent, 0, 1, title, message)
        msg_box.execute()

    def _show_file_picker(self, parent, toolkit, items) -> int | None:
        """Show a simple selection dialog. Returns selected index or None."""
        # Build numbered list for simple input
        text = "Select a file:\n\n"
        for i, item in enumerate(items):
            text += f"  {i + 1}. {item}\n"
        text += "\nEnter number (or cancel):"

        # Use InputBox approach
        msg_box = toolkit.createMessageBox(
            parent, 0, 1,
            "EUnifyer Drive", text,
        )
        # v1: Simple message showing available files
        # A proper tree/list dialog will be built in v2
        msg_box.execute()

        # For v1, we open the first non-folder file as a demo
        # TODO(v2): proper file picker dialog with tree view
        for i, item in enumerate(items):
            if not item.startswith("["):
                return i
        return None

    def _show_status(self, message: str):
        """Show a brief status notification."""
        try:
            ctx = uno.getComponentContext()
            smgr = ctx.ServiceManager
            desktop = smgr.createInstanceWithContext(
                "com.sun.star.frame.Desktop", ctx
            )
            frame = desktop.getCurrentFrame()
            if frame:
                frame.getContainerWindow().setTitle(
                    frame.getContainerWindow().getTitle() + f" — {message}"
                )
        except Exception:
            pass


# UNO registration for protocol handler
g_ImplementationHelper = uno.createRegistrationHelper()

g_ImplementationHelper.addImplementation(
    EUnifyerDriveMenu,
    EUnifyerDriveMenu.IMPLE_NAME,
    EUnifyerDriveMenu.SERVICE_NAMES,
)
