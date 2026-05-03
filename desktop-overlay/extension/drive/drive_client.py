"""EUnifyer Drive REST API client for LibreOffice extension.

Provides file listing, download, and upload operations against the
EUnifyer Drive API. Authentication via shared keychain tokens.

v1: download-to-temp on open, upload on save (simple, works offline after open).
v2: WOPI integration for real-time co-editing.
"""

import json
import logging
import os
import tempfile
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("eunifyer.drive")

API_BASE = "https://api.eunifyer.com/api/v1"


class DriveFile:
    """Represents a file/folder from the Drive API."""

    __slots__ = (
        "id", "name", "parent_id", "is_folder",
        "size", "mime_type", "updated_at",
    )

    def __init__(self, data: dict):
        self.id = data.get("id", "")
        self.name = data.get("name", "")
        self.parent_id = data.get("parent_id")
        self.is_folder = data.get("is_folder", False)
        self.size = data.get("size", 0)
        self.mime_type = data.get("mime_type", "")
        self.updated_at = data.get("updated_at", "")


class DriveClient:
    """REST client for EUnifyer Drive API."""

    def __init__(self, get_token_fn):
        """
        Args:
            get_token_fn: Callable that returns a valid access token string.
        """
        self._get_token = get_token_fn

    def list_folder(self, folder_id: str | None = None) -> list[DriveFile]:
        """List files in a Drive folder (root if folder_id is None)."""
        path = f"{API_BASE}/drive/"
        if folder_id:
            path = f"{API_BASE}/drive/{folder_id}/children"

        data = self._api_get(path)
        if data is None:
            return []

        items = data if isinstance(data, list) else data.get("items", [])
        return [DriveFile(item) for item in items]

    def download_to_temp(self, file_id: str, filename: str) -> str | None:
        """Download a file to a temp directory. Returns local path."""
        # Get download URL
        info = self._api_get(f"{API_BASE}/drive/{file_id}/download")
        if not info:
            return None

        download_url = info.get("url") or info.get("download_url", "")
        if not download_url:
            return None

        # Download to temp
        temp_dir = os.path.join(tempfile.gettempdir(), "eunifyer-drive")
        os.makedirs(temp_dir, exist_ok=True)
        local_path = os.path.join(temp_dir, filename)

        try:
            req = urllib.request.Request(download_url)
            with urllib.request.urlopen(req, timeout=60) as resp:
                with open(local_path, "wb") as f:
                    while True:
                        chunk = resp.read(1024 * 1024)
                        if not chunk:
                            break
                        f.write(chunk)
            log.info("Downloaded %s -> %s", file_id, local_path)
            return local_path
        except Exception as e:
            log.error("Download failed for %s: %s", file_id, e)
            return None

    def upload_file(
        self,
        local_path: str,
        name: str,
        parent_id: str | None = None,
    ) -> str | None:
        """Upload a local file to Drive. Returns file ID on success."""
        mime_type = self._guess_mime(name)

        # Step 1: Request upload URL
        upload_req = {
            "name": name,
            "mime_type": mime_type,
            "size": os.path.getsize(local_path),
        }
        if parent_id:
            upload_req["parent_id"] = parent_id

        info = self._api_post(f"{API_BASE}/drive/upload", upload_req)
        if not info:
            return None

        file_id = info.get("file", {}).get("id", "")
        upload_url = info.get("upload_url", "")

        if not upload_url or not file_id:
            return None

        # Step 2: PUT file bytes to presigned URL
        try:
            with open(local_path, "rb") as f:
                file_bytes = f.read()

            req = urllib.request.Request(
                upload_url, data=file_bytes, method="PUT",
                headers={"Content-Type": mime_type},
            )
            urllib.request.urlopen(req, timeout=120)
        except Exception as e:
            log.error("Upload PUT failed: %s", e)
            return None

        # Step 3: Confirm upload
        self._api_post(f"{API_BASE}/drive/{file_id}/confirm", {})

        log.info("Uploaded %s -> %s", local_path, file_id)
        return file_id

    def update_file(self, file_id: str, local_path: str) -> bool:
        """Re-upload content for an existing file (overwrite)."""
        mime_type = self._guess_mime(os.path.basename(local_path))

        info = self._api_post(
            f"{API_BASE}/drive/{file_id}/upload",
            {"mime_type": mime_type, "size": os.path.getsize(local_path)},
        )
        if not info:
            return False

        upload_url = info.get("upload_url", "")
        if not upload_url:
            return False

        try:
            with open(local_path, "rb") as f:
                file_bytes = f.read()

            req = urllib.request.Request(
                upload_url, data=file_bytes, method="PUT",
                headers={"Content-Type": mime_type},
            )
            urllib.request.urlopen(req, timeout=120)
        except Exception as e:
            log.error("Update PUT failed: %s", e)
            return False

        self._api_post(f"{API_BASE}/drive/{file_id}/confirm", {})
        return True

    # ---- Private ----

    def _api_get(self, url: str) -> dict | list | None:
        token = self._get_token()
        if not token:
            return None
        try:
            req = urllib.request.Request(
                url, headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/json",
                },
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            log.warning("API GET %s -> %s", url, e.code)
            return None
        except Exception as e:
            log.warning("API GET %s failed: %s", url, e)
            return None

    def _api_post(self, url: str, body: dict) -> dict | None:
        token = self._get_token()
        if not token:
            return None
        try:
            data = json.dumps(body).encode()
            req = urllib.request.Request(
                url, data=data, method="POST",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            log.warning("API POST %s -> %s", url, e.code)
            return None
        except Exception as e:
            log.warning("API POST %s failed: %s", url, e)
            return None

    @staticmethod
    def _guess_mime(filename: str) -> str:
        ext = os.path.splitext(filename)[1].lower()
        mime_map = {
            ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            ".odt": "application/vnd.oasis.opendocument.text",
            ".ods": "application/vnd.oasis.opendocument.spreadsheet",
            ".odp": "application/vnd.oasis.opendocument.presentation",
            ".pdf": "application/pdf",
            ".txt": "text/plain",
            ".csv": "text/csv",
            ".rtf": "application/rtf",
        }
        return mime_map.get(ext, "application/octet-stream")
