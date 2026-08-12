"""Time-ordered identifier generation.

Generated ids are UUIDv7 (RFC 9562) rather than random UUIDv4. The 48-bit
millisecond timestamp in the high bits makes ids sort by creation time, so
inserts land at the right edge of each primary key's B-tree instead of
scattering across it: the hot page set stays small, leaves pack densely, and on
PostgreSQL the WAL is spared the full-page images that random insert positions
provoke. A v4 id costs the same bytes and gives none of that.

The trade is that a v7 id carries its creation time in the clear. Every id
minted here belongs to a row that already exposes a creation timestamp of its
own, so nothing new is disclosed.

``uuid.uuid7`` is stdlib from Python 3.14 and is used when present; the fallback
covers the 3.13 floor this package still supports (``requires-python``) and can
go, along with this module, once that floor moves.
"""

from __future__ import annotations

import os
import time
import uuid
from typing import Callable

# RFC 9562 section 4.1: the two-bit variant field is 0b10 for every UUID this
# module produces.
_VARIANT_RFC_4122 = 0b10

_stdlib_uuid7: Callable[[], uuid.UUID] | None = getattr(uuid, "uuid7", None)


def _uuid7_fallback() -> uuid.UUID:
    """Build a UUIDv7 on an interpreter without ``uuid.uuid7``.

    Layout per RFC 9562 section 5.7: 48 bits of Unix time in milliseconds, the
    4-bit version, 12 random bits, the 2-bit variant, then 62 random bits.

    Ordering within a single millisecond is not guaranteed here (the stdlib
    implementation keeps a counter for that). The index locality this exists for
    comes from the millisecond prefix, which both spellings share, so the
    difference costs nothing that matters.
    """
    unix_ts_ms = time.time_ns() // 1_000_000
    rand = int.from_bytes(os.urandom(10), "big")
    value = (unix_ts_ms & 0xFFFFFFFFFFFF) << 80
    value |= 0x7 << 76
    value |= ((rand >> 62) & 0xFFF) << 64
    value |= _VARIANT_RFC_4122 << 62
    value |= rand & ((1 << 62) - 1)
    return uuid.UUID(int=value)


def uuid7() -> uuid.UUID:
    """Return a new time-ordered UUIDv7."""
    if _stdlib_uuid7 is not None:
        return _stdlib_uuid7()
    return _uuid7_fallback()
