"""Integration tests for the migrate_from_sqlite management command.

Regression: periodic tasks with interval_id FK were not migrated because
django_celery_beat_intervalschedule was missing from the TABLES list.
"""

import sqlite3
import tempfile
from pathlib import Path
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.db import connection
from django.test import TransactionTestCase

from app.models import Item, MediaTypes, Sources


def _sqlite_column_types(table):
    """Return {column: data_type} for a table in the Django test DB (SQLite).

    Replaces the PostgreSQL-specific _get_target_column_types so the
    migration command can run against a SQLite test database.
    """
    with connection.cursor() as cur:
        cur.execute(f"PRAGMA table_info([{table}])")
        rows = cur.fetchall()
    type_map = {}
    for row in rows:
        col_name = row[1]
        col_type = row[2].lower()
        if "bool" in col_type:
            type_map[col_name] = "boolean"
        elif "int" in col_type:
            type_map[col_name] = "integer"
        else:
            type_map[col_name] = "text"
    return type_map


def _copy_schema(target_table, src_conn):
    """Copy the table schema from the Django test DB into the source SQLite.

    Copies column definitions but strips CHECK constraints so test INSERTs
    don't need to satisfy Django model validation rules.
    """
    with connection.cursor() as cur:
        cur.execute(f"PRAGMA table_info([{target_table}])")
        cols = cur.fetchall()

    col_defs = []
    for col in cols:
        name, col_type, notnull, default, pk = col[1], col[2], col[3], col[4], col[5]
        parts = [f'"{name}" {col_type}']
        if pk:
            parts.append("PRIMARY KEY")
        elif notnull and default is not None:
            parts.append(f"NOT NULL DEFAULT {default}")
        elif notnull:
            parts.append("NOT NULL DEFAULT ''")
        col_defs.append(" ".join(parts))

    ddl = f'CREATE TABLE [{target_table}] ({", ".join(col_defs)})'
    src_conn.execute(ddl)


def _create_source_db(path, user_id, item_id):
    """Create a minimal SQLite source database with realistic test data.

    The user and item are pre-created via Django ORM so their IDs exist
    in the target.  The source references these same rows so the
    migration's idempotency logic maps old→new IDs correctly.
    """
    src = sqlite3.connect(path)
    src.execute("PRAGMA foreign_keys = OFF")

    tables_to_copy = [
        "users_user",
        "app_item",
        "events_event",
        "django_celery_beat_intervalschedule",
        "django_celery_beat_crontabschedule",
        "django_celery_beat_periodictask",
    ]
    for table in tables_to_copy:
        _copy_schema(table, src)

    # -- users_user (same username as Django ORM user → migration will map IDs) --
    src.execute(
        "INSERT INTO users_user (id, username, password, date_joined) "
        "VALUES (100, 'testmigrate', 'pbkdf2_sha256$1$salt$hash', "
        "'2024-01-01 00:00:00')"
    )

    # -- app_item (same media_id/source/media_type → migration will map IDs) --
    src.execute(
        "INSERT INTO app_item (id, media_id, source, media_type, title) "
        "VALUES (100, 'test-migrate-1', 'tmdb', 'tv', 'Test Show')"
    )

    # -- django_celery_beat_intervalschedule --
    src.execute(
        "INSERT INTO django_celery_beat_intervalschedule (id, every, period) "
        "VALUES (1, 30, 'seconds')"
    )
    src.execute(
        "INSERT INTO django_celery_beat_intervalschedule (id, every, period) "
        "VALUES (2, 5, 'minutes')"
    )

    # -- django_celery_beat_crontabschedule --
    src.execute(
        "INSERT INTO django_celery_beat_crontabschedule "
        "(id, minute, hour, day_of_week, day_of_month, month_of_year, timezone) "
        "VALUES (1, '0', '3', '*', '*', '*', 'UTC')"
    )

    # -- django_celery_beat_periodictask --
    # Task with interval_id FK — this is the regression case
    src.execute(
        "INSERT INTO django_celery_beat_periodictask "
        "(id, name, task, interval_id, crontab_id, enabled, total_run_count, "
        "date_changed, one_off, args, kwargs, headers, description) "
        "VALUES (1, 'poll-every-30s', 'app.tasks.poll', 1, NULL, 1, 0, "
        "'2024-01-01 00:00:00', 0, '[]', '{}', '{}', '')"
    )
    # Task with crontab_id FK — already worked before the fix
    src.execute(
        "INSERT INTO django_celery_beat_periodictask "
        "(id, name, task, interval_id, crontab_id, enabled, total_run_count, "
        "date_changed, one_off, args, kwargs, headers, description) "
        "VALUES (2, 'nightly-cleanup', 'app.tasks.cleanup', NULL, 1, 1, 0, "
        "'2024-01-01 00:00:00', 0, '[]', '{}', '{}', '')"
    )

    # -- events_event (exercise FK to app_item) --
    src.execute(
        "INSERT INTO events_event (id, item_id, content_number, datetime) "
        "VALUES (1, 100, 1, '2024-06-15 12:00:00+00:00')"
    )

    src.commit()
    return src


class MigrateFromSqliteTest(TransactionTestCase):
    """Integration tests for the SQLite-to-target migration command."""

    def setUp(self):
        # Create real Django ORM objects so the target DB has valid rows
        # with proper defaults/CHECK constraints satisfied.
        self.user = get_user_model().objects.create_user(
            username="testmigrate", password="testpass"
        )
        self.item = Item.objects.create(
            media_id="test-migrate-1",
            source=Sources.TMDB.value,
            media_type=MediaTypes.TV.value,
            title="Test Show",
        )

        self.tmp = tempfile.NamedTemporaryFile(suffix=".sqlite3", delete=False)
        self.tmp.close()
        self.src = _create_source_db(self.tmp.name, self.user.pk, self.item.pk)

    def tearDown(self):
        self.src.close()
        Path(self.tmp.name).unlink(missing_ok=True)

    def _run_migration(self):
        """Run the command with patches so it works against a SQLite target."""
        with (
            patch(
                "app.management.commands.migrate_from_sqlite.connection"
            ) as mock_conn,
            patch(
                "app.management.commands.migrate_from_sqlite._get_target_column_types",
                side_effect=_sqlite_column_types,
            ),
        ):
            mock_conn.vendor = "postgresql"
            mock_conn.cursor = connection.cursor
            mock_conn.ensure_connection = connection.ensure_connection
            call_command(
                "migrate_from_sqlite",
                sqlite_path=self.tmp.name,
                stdout=open("/dev/null", "w"),  # noqa: SIM115, PTH123
            )

    def test_interval_schedule_migrated(self):
        """Regression: interval schedules must be migrated so periodic tasks
        referencing interval_id don't violate FK constraints."""
        self._run_migration()

        with connection.cursor() as cur:
            cur.execute(
                "SELECT every, period FROM django_celery_beat_intervalschedule "
                "ORDER BY every"
            )
            rows = cur.fetchall()

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0], (5, "minutes"))
        self.assertEqual(rows[1], (30, "seconds"))

    def test_periodic_task_with_interval_fk(self):
        """The periodic task referencing an interval schedule must be migrated
        with its interval_id correctly remapped."""
        self._run_migration()

        with connection.cursor() as cur:
            cur.execute(
                "SELECT name, task, interval_id, crontab_id "
                "FROM django_celery_beat_periodictask ORDER BY name"
            )
            rows = cur.fetchall()

        self.assertEqual(len(rows), 2)
        names = {r[0] for r in rows}
        self.assertIn("nightly-cleanup", names)
        self.assertIn("poll-every-30s", names)

        interval_task = [r for r in rows if r[0] == "poll-every-30s"][0]
        self.assertIsNotNone(interval_task[2], "interval_id should be set")

        crontab_task = [r for r in rows if r[0] == "nightly-cleanup"][0]
        self.assertIsNotNone(crontab_task[3], "crontab_id should be set")

    def test_interval_fk_points_to_correct_schedule(self):
        """The remapped interval_id must reference the correct schedule row."""
        self._run_migration()

        with connection.cursor() as cur:
            cur.execute(
                "SELECT pt.name, ivs.every, ivs.period "
                "FROM django_celery_beat_periodictask pt "
                "JOIN django_celery_beat_intervalschedule ivs "
                "  ON pt.interval_id = ivs.id "
                "WHERE pt.name = 'poll-every-30s'"
            )
            row = cur.fetchone()

        self.assertIsNotNone(row, "JOIN should find the interval schedule")
        self.assertEqual(row[1], 30)
        self.assertEqual(row[2], "seconds")

    def test_event_with_item_fk(self):
        """Basic FK remapping: events_event.item_id -> app_item."""
        self._run_migration()

        with connection.cursor() as cur:
            cur.execute(
                "SELECT e.content_number, i.title "
                "FROM events_event e "
                "JOIN app_item i ON e.item_id = i.id"
            )
            row = cur.fetchone()

        self.assertIsNotNone(row)
        self.assertEqual(row[0], 1)
        self.assertEqual(row[1], "Test Show")

    def test_idempotent_rerun(self):
        """Running the migration twice must not duplicate rows."""
        self._run_migration()
        self._run_migration()

        with connection.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM django_celery_beat_intervalschedule")
            self.assertEqual(cur.fetchone()[0], 2)

            cur.execute("SELECT COUNT(*) FROM django_celery_beat_periodictask")
            self.assertEqual(cur.fetchone()[0], 2)

            cur.execute("SELECT COUNT(*) FROM events_event")
            self.assertEqual(cur.fetchone()[0], 1)
