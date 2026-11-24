"""File fingerprints and atomic writes for durable research records."""
from hashlib import sha256
import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import BinaryIO


def digest(data: bytes) -> str:
    return sha256(data).hexdigest()


def file_digest(stream: BinaryIO) -> str:
    fingerprint = sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        fingerprint.update(chunk)
    return fingerprint.hexdigest()


def atomic_write(path: Path, text: str) -> None:
    with NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                            delete=False, suffix=".tmp") as stream:
        tmp = Path(stream.name)
        try:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
            tmp.replace(path)
        finally:
            tmp.unlink(missing_ok=True)


def write_json(path: Path, value) -> None:
    atomic_write(path, json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
