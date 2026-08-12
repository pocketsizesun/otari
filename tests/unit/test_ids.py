"""Unit tests for ``gateway.ids``, the UUIDv7 generator behind every stored id.

Two properties carry the whole point of the module and are pinned here: the ids
are well-formed UUIDv7 (RFC 9562 section 5.7), and they sort by creation time,
which is what keeps primary-key inserts at the right edge of the B-tree.

``uuid.uuid7`` is stdlib only from Python 3.14, so ``uuid7()`` resolves to one of
two implementations depending on the interpreter. ``_uuid7_fallback`` is
therefore exercised directly as well as through the public function, so the path
stays covered on the 3.14 CI runner where the public function does not reach it.
"""

import time
import uuid
from collections.abc import Callable

import pytest

from gateway.ids import _uuid7_fallback, uuid7

# Both implementations must satisfy every property below.
IMPLEMENTATIONS = pytest.mark.parametrize("generate", [uuid7, _uuid7_fallback], ids=["public", "fallback"])


def _timestamp_ms(value: uuid.UUID) -> int:
    """Return the 48-bit millisecond timestamp from a v7 id's high bits."""
    return value.int >> 80


@IMPLEMENTATIONS
def test_version_and_variant(generate: Callable[[], uuid.UUID]) -> None:
    value = generate()
    assert value.version == 7
    assert value.variant == uuid.RFC_4122


@IMPLEMENTATIONS
def test_timestamp_tracks_wall_clock(generate: Callable[[], uuid.UUID]) -> None:
    before = time.time_ns() // 1_000_000
    value = generate()
    after = time.time_ns() // 1_000_000
    assert before <= _timestamp_ms(value) <= after


@IMPLEMENTATIONS
def test_ids_are_unique(generate: Callable[[], uuid.UUID]) -> None:
    values = {generate() for _ in range(1000)}
    assert len(values) == 1000


@IMPLEMENTATIONS
def test_ids_sort_by_creation_time(generate: Callable[[], uuid.UUID]) -> None:
    """Ids minted in different milliseconds sort in creation order.

    Both the string form (what the columns store) and the integer form are
    checked: it is the lexical ordering of the stored text that the index sees.
    Successive ids are separated by more than a millisecond because ordering
    *within* one millisecond is a stdlib-only guarantee, not one this module
    makes.
    """
    minted = []
    for _ in range(5):
        minted.append(generate())
        time.sleep(0.002)

    assert [str(v) for v in minted] == sorted(str(v) for v in minted)
    assert minted == sorted(minted, key=lambda v: v.int)


def test_public_generator_matches_fallback_shape() -> None:
    """The stdlib and fallback paths are interchangeable at the byte level.

    Whichever one ``uuid7()`` resolves to on this interpreter, the ids differ
    only in their random bits, so a database holding both mixes them freely.
    """
    assert len(uuid7().bytes) == len(_uuid7_fallback().bytes) == 16
    assert uuid7().version == _uuid7_fallback().version
