"""Migrate all data from a SQLite database to the current PostgreSQL database.

Usage:
    yamtrack-manage migrate_from_sqlite --sqlite-path /path/to/db.sqlite3

Reads every table from the source SQLite file, remaps foreign keys, and
inserts rows into the already-migrated PostgreSQL target using raw SQL to
bypass model save() side-effects (API calls, signals, auto_now fields).
The command is idempotent: existing rows are detected and skipped.
"""

from __future__ import annotations

import sqlite3

from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction

# Regular tables in dependency order: (table_name, {fk_col: referenced_table})
TABLES: list[tuple[str, dict[str, str]]] = [
    ("users_user", {}),
    ("app_item", {}),
    ("app_usermessage", {"user_id": "users_user"}),
    ("app_tv", {"item_id": "app_item", "user_id": "users_user"}),
    (
        "app_season",
        {
            "item_id": "app_item",
            "user_id": "users_user",
            "related_tv_id": "app_tv",
        },
    ),
    ("app_episode", {"item_id": "app_item", "related_season_id": "app_season"}),
    ("app_basicmedia", {"item_id": "app_item", "user_id": "users_user"}),
    ("app_manga", {"item_id": "app_item", "user_id": "users_user"}),
    ("app_anime", {"item_id": "app_item", "user_id": "users_user"}),
    ("app_movie", {"item_id": "app_item", "user_id": "users_user"}),
    ("app_game", {"item_id": "app_item", "user_id": "users_user"}),
    ("app_book", {"item_id": "app_item", "user_id": "users_user"}),
    ("app_comic", {"item_id": "app_item", "user_id": "users_user"}),
    ("app_boardgame", {"item_id": "app_item", "user_id": "users_user"}),
    ("lists_customlist", {"owner_id": "users_user"}),
    (
        "lists_customlistitem",
        {"item_id": "app_item", "custom_list_id": "lists_customlist"},
    ),
    ("events_event", {"item_id": "app_item"}),
    ("django_celery_beat_intervalschedule", {}),
    ("django_celery_beat_crontabschedule", {}),
    (
        "django_celery_beat_periodictask",
        {
            "crontab_id": "django_celery_beat_crontabschedule",
            "interval_id": "django_celery_beat_intervalschedule",
        },
    ),
]

# Many-to-many junction tables.
M2M_TABLES: list[tuple[str, dict[str, str]]] = [
    (
        "lists_customlist_collaborators",
        {"customlist_id": "lists_customlist", "user_id": "users_user"},
    ),
    (
        "users_user_notification_excluded_items",
        {"user_id": "users_user", "item_id": "app_item"},
    ),
    ("users_user_groups", {"user_id": "users_user"}),
    ("users_user_user_permissions", {"user_id": "users_user"}),
]

# Fields used for idempotent duplicate detection.
# Tables not listed fall back to all FK columns.
UNIQUE_FIELDS: dict[str, list[str]] = {
    "users_user": ["username"],
    "app_item": [
        "media_id",
        "source",
        "media_type",
        "season_number",
        "episode_number",
    ],
    "app_tv": ["user_id", "item_id"],
    "app_season": ["related_tv_id", "item_id"],
    "app_usermessage": ["user_id", "message", "level"],
    "lists_customlist": ["name", "owner_id"],
    "lists_customlistitem": ["item_id", "custom_list_id"],
    "events_event": ["item_id", "content_number"],
    "django_celery_beat_intervalschedule": ["every", "period"],
    "django_celery_beat_crontabschedule": [
        "minute",
        "hour",
        "day_of_week",
        "day_of_month",
        "month_of_year",
    ],
    "django_celery_beat_periodictask": ["name"],
}


class Command(BaseCommand):
    """Django management command for SQLite-to-PostgreSQL data migration."""

    help = "Migrate all data from a SQLite database to PostgreSQL."

    def add_arguments(self, parser):
        """Define the --sqlite-path argument."""
        parser.add_argument(
            "--sqlite-path",
            required=True,
            help="Path to the source SQLite database file.",
        )

    def handle(self, *_args, **options):
        """Execute the migration."""
        sqlite_path = options["sqlite_path"]

        if connection.vendor == "sqlite":
            msg = (
                "Target database is SQLite. "
                "Configure PostgreSQL before running this command."
            )
            raise CommandError(msg)

        try:
            src = sqlite3.connect(sqlite_path)
            src.row_factory = sqlite3.Row
        except sqlite3.Error as e:
            msg = f"Cannot open SQLite database: {e}"
            raise CommandError(msg) from e

        source_tables = _get_source_tables(src)

        try:
            with transaction.atomic():
                id_maps: dict[str, dict[int, int]] = {}

                for table, fk_maps in TABLES:
                    if table not in source_tables:
                        self.stdout.write(f"  {table}: not in source, skipping")
                        id_maps[table] = {}
                        continue
                    id_maps[table] = self._migrate_table(src, table, fk_maps, id_maps)

                for table, fk_maps in M2M_TABLES:
                    if table not in source_tables:
                        self.stdout.write(f"  {table}: not in source, skipping")
                        continue
                    self._migrate_m2m(src, table, fk_maps, id_maps)
        finally:
            src.close()

        self.stdout.write(self.style.SUCCESS("Migration completed successfully."))

    def _migrate_table(self, src, table, fk_maps, id_maps):
        """Migrate a single table from SQLite to PostgreSQL via raw SQL."""
        src_cols = _get_source_columns(src, table)
        tgt_types = _get_target_column_types(table)

        columns = [c for c in src_cols if c in tgt_types and c != "id"]
        rows = _select_all(src, table)

        id_map: dict[int, int] = {}
        created = 0
        skipped = 0

        for row in rows:
            old_id = row["id"]
            values: dict[str, object] = {}
            bad_fk = False

            for col in columns:
                raw = row[col]
                if col in fk_maps and raw is not None:
                    mapped = id_maps[fk_maps[col]].get(raw)
                    if mapped is None:
                        self.stderr.write(
                            f"  {table} id={old_id}: "
                            f"dangling FK {col}={raw}, skipping row"
                        )
                        bad_fk = True
                        break
                    raw = mapped
                values[col] = _coerce(raw, tgt_types[col])

            if bad_fk:
                continue

            existing = _find_existing(table, values, fk_maps)
            if existing is not None:
                id_map[old_id] = existing
                skipped += 1
                continue

            new_id = _insert_returning_id(table, values)
            id_map[old_id] = new_id
            created += 1

        self.stdout.write(f"  {table}: {created} created, {skipped} skipped")
        return id_map

    def _migrate_m2m(self, src, table, fk_maps, id_maps):
        """Migrate a many-to-many junction table."""
        src_cols = _get_source_columns(src, table)
        tgt_types = _get_target_column_types(table)
        columns = [c for c in src_cols if c in tgt_types and c != "id"]

        rows = _select_all(src, table)
        created = 0

        for row in rows:
            values: dict[str, object] = {}
            bad_fk = False

            for col in columns:
                raw = row[col]
                if col in fk_maps and raw is not None:
                    mapped = id_maps[fk_maps[col]].get(raw)
                    if mapped is None:
                        bad_fk = True
                        break
                    raw = mapped
                values[col] = _coerce(raw, tgt_types.get(col, ""))

            if bad_fk:
                continue

            # Check all non-id columns for idempotency
            clauses, params = _build_where({c: values[c] for c in columns})
            if _row_exists(table, clauses, params):
                continue

            _insert_row(table, values)
            created += 1

        self.stdout.write(f"  {table}: {created} created")


# -- pure helpers (no self) --------------------------------------------------
# Table and column names come from the hard-coded constants above, not from
# user input, so the dynamic SQL construction is safe.


def _get_source_tables(src):
    """Return the set of table names in the source SQLite database."""
    cursor = src.execute("SELECT name FROM sqlite_master WHERE type='table'")
    return {row["name"] for row in cursor}


def _get_source_columns(src, table):
    """Return column names for *table* in the source database."""
    sql = f"PRAGMA table_info([{table}])"
    cursor = src.execute(sql)
    return [row["name"] for row in cursor]


def _get_target_column_types(table):
    """Return {column_name: pg_data_type} for *table* in the target database."""
    with connection.cursor() as cur:
        cur.execute(
            "SELECT column_name, data_type "
            "FROM information_schema.columns WHERE table_name = %s",
            [table],
        )
        return {r[0]: r[1] for r in cur.fetchall()}


def _coerce(value, pg_type):
    """Convert a SQLite value to a Python type suitable for PostgreSQL."""
    if value is None:
        return None
    if pg_type == "boolean":
        return bool(value)
    return value


def _select_all(src, table):
    """Read all rows from a SQLite table ordered by id."""
    sql = f"SELECT * FROM [{table}] ORDER BY id"  # noqa: S608
    return src.execute(sql).fetchall()


def _insert_returning_id(table, values):
    """INSERT a row into the target table and return its new id."""
    col_list = ", ".join(f'"{c}"' for c in values)
    placeholders = ", ".join(["%s"] * len(values))
    sql = f'INSERT INTO "{table}" ({col_list}) VALUES ({placeholders}) RETURNING id'  # noqa: S608
    with connection.cursor() as cur:
        cur.execute(sql, list(values.values()))
        return cur.fetchone()[0]


def _insert_row(table, values):
    """INSERT a row into the target table (no RETURNING)."""
    col_list = ", ".join(f'"{c}"' for c in values)
    placeholders = ", ".join(["%s"] * len(values))
    sql = f'INSERT INTO "{table}" ({col_list}) VALUES ({placeholders})'  # noqa: S608
    with connection.cursor() as cur:
        cur.execute(sql, list(values.values()))


def _row_exists(table, clauses, params):
    """Return True if a row matching *clauses* exists in *table*."""
    sql = f'SELECT 1 FROM "{table}" WHERE {clauses} LIMIT 1'  # noqa: S608
    with connection.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone() is not None


def _build_where(field_values):
    """Build a WHERE clause with IS NULL handling."""
    clauses = []
    params = []
    for field, val in field_values.items():
        if val is None:
            clauses.append(f'"{field}" IS NULL')
        else:
            clauses.append(f'"{field}" = %s')
            params.append(val)
    return " AND ".join(clauses), params


def _find_existing(table, values, fk_maps):
    """Return the id of an existing row matching the unique-check fields."""
    check = UNIQUE_FIELDS.get(table)
    if check is None:
        check = list(fk_maps.keys())
    if not check:
        return None

    clauses, params = _build_where({f: values.get(f) for f in check})
    if not clauses:
        return None

    sql = f'SELECT id FROM "{table}" WHERE {clauses} LIMIT 1'  # noqa: S608
    with connection.cursor() as cur:
        cur.execute(sql, params)
        row = cur.fetchone()
        return row[0] if row else None
