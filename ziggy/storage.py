"""Local-disk External Storage driver (claim-check pattern).

Temporal caps individual payloads at 2 MB. For a long meeting the full
transcript (passed to the summary Activity and returned as the Workflow result)
can approach or exceed that. External Storage offloads any oversized payload to
a store you control and records only a small reference ("claim check") in Event
History; the SDK retrieves it transparently on the way back in.

This driver writes to a local directory and is intended for development. For
production, swap it for the built-in S3 driver (``temporalio[aioboto3]``) -- see
``references/python/external-storage.md`` -- without touching business logic.
"""

from __future__ import annotations

import hashlib
import os
from typing import Sequence

from temporalio.api.common.v1 import Payload
from temporalio.converter import (
    StorageDriver,
    StorageDriverClaim,
    StorageDriverRetrieveContext,
    StorageDriverStoreContext,
    StorageDriverWorkflowInfo,
)


def _safe_segment(value: str) -> str:
    """Hash identifiers before using them as path segments -- Workflow/Activity
    ids can contain path separators or traversal sequences."""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


class LocalDiskStorageDriver(StorageDriver):
    """Content-addressed local-disk payload store (dev/testing only)."""

    def __init__(self, store_dir: str = ".payload-store") -> None:
        self._store_dir = os.path.abspath(store_dir)

    def name(self) -> str:
        return "ziggy-local-disk"

    def type(self) -> str:
        return "ziggy-local-disk"

    def _resolve_path(self, claim_path: str) -> str:
        """Reject claim data that points outside the store directory."""
        root = os.path.realpath(self._store_dir)
        resolved = os.path.realpath(claim_path)
        if resolved != root and not resolved.startswith(root + os.sep):
            raise ValueError(f"claim path {claim_path!r} escapes the store directory")
        return resolved

    async def store(
        self,
        context: StorageDriverStoreContext,
        payloads: Sequence[Payload],
    ) -> list[StorageDriverClaim]:
        prefix = self._store_dir
        target = context.target
        if isinstance(target, StorageDriverWorkflowInfo) and target.id:
            prefix = os.path.join(self._store_dir, _safe_segment(target.id))
        os.makedirs(prefix, exist_ok=True)

        claims: list[StorageDriverClaim] = []
        for payload in payloads:
            data = payload.SerializeToString()
            key = f"{hashlib.sha256(data).hexdigest()}.bin"
            file_path = os.path.join(prefix, key)
            # Content-addressed: writing the same bytes twice is idempotent.
            if not os.path.exists(file_path):
                tmp_path = f"{file_path}.tmp"
                with open(tmp_path, "wb") as f:
                    f.write(data)
                os.replace(tmp_path, file_path)
            claims.append(StorageDriverClaim(claim_data={"path": file_path}))
        return claims

    async def retrieve(
        self,
        context: StorageDriverRetrieveContext,
        claims: Sequence[StorageDriverClaim],
    ) -> list[Payload]:
        payloads: list[Payload] = []
        for claim in claims:
            file_path = self._resolve_path(claim.claim_data["path"])
            with open(file_path, "rb") as f:
                raw = f.read()
            payload = Payload()
            payload.ParseFromString(raw)
            payloads.append(payload)
        return payloads
