"""prune redundant usage_logs indexes and pair api_key_id with timestamp

Revision ID: a4c8e2b6d0f7
Revises: f0a1b2c3d4e5
Create Date: 2026-08-12 10:00:00.000000

"""

from collections.abc import Sequence

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a4c8e2b6d0f7"
down_revision: str | Sequence[str] | None = "f0a1b2c3d4e5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Drop three indexes no query needs and make the api_key_id one time-ordered.

    usage_logs takes one insert per attempt, so every index here is write
    amplification on the request path. Four of them did not pay for themselves:

    * ``ix_usage_logs_user_id`` duplicates the leading column of
      ``ix_usage_logs_user_id_timestamp``, which has served the user filter and the
      ``ondelete="SET NULL"`` lookup since revision 967575f779b7.
    * ``ix_usage_logs_source`` duplicates the leading column of
      ``uq_usage_logs_source_event``, which already covers both the source filter
      and the idempotent-import probe.
    * ``ix_usage_logs_policy_name`` is never filtered on: policy_name is only read
      back on a row.
    * ``ix_usage_logs_api_key_id`` is replaced by ``(api_key_id, timestamp)``. The
      key filter always arrives with a time window and a newest-first sort, and the
      composite still serves the foreign key as its leading column.

    ``ix_usage_logs_request_group_id`` stays single-column on purpose: it resolves a
    high-cardinality equality to one request's few attempt rows, so a trailing
    timestamp would cost every insert and save no read.
    """
    op.create_index(
        "ix_usage_logs_api_key_id_timestamp",
        "usage_logs",
        ["api_key_id", "timestamp"],
    )
    op.drop_index("ix_usage_logs_api_key_id", table_name="usage_logs")
    op.drop_index("ix_usage_logs_user_id", table_name="usage_logs")
    op.drop_index("ix_usage_logs_source", table_name="usage_logs")
    op.drop_index("ix_usage_logs_policy_name", table_name="usage_logs")


def downgrade() -> None:
    """Restore the single-column indexes and drop the composite."""
    op.create_index("ix_usage_logs_policy_name", "usage_logs", ["policy_name"])
    op.create_index("ix_usage_logs_source", "usage_logs", ["source"])
    op.create_index("ix_usage_logs_user_id", "usage_logs", ["user_id"])
    op.create_index("ix_usage_logs_api_key_id", "usage_logs", ["api_key_id"])
    op.drop_index("ix_usage_logs_api_key_id_timestamp", table_name="usage_logs")
