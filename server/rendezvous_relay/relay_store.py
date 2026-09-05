from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path
from typing import Any


class RelayStore:
    """Transactional durable queue for opaque encrypted sync envelopes."""

    def __init__(self, database_path: Path, *, max_events: int, ttl_seconds: int) -> None:
        self.database_path = database_path
        self.max_events = max_events
        self.ttl_seconds = ttl_seconds

    def initialize(self) -> None:
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.executescript(
                """
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                CREATE TABLE IF NOT EXISTS account_sequences (
                    account_id TEXT PRIMARY KEY,
                    next_seq INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS events (
                    account_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    operation_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    raw TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    PRIMARY KEY (account_id, seq),
                    UNIQUE (account_id, operation_id)
                );
                CREATE TABLE IF NOT EXISTS cursors (
                    account_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    PRIMARY KEY (account_id, device_id)
                );
                CREATE INDEX IF NOT EXISTS events_expiry_idx ON events(expires_at);
                """
            )

    def append(self, account_id: str, decoded: dict[str, Any], *, now: float | None = None) -> str:
        now = now or time.time()
        operation_id = str(decoded.get("operationId") or "").strip()
        if not operation_id:
            operation_id = self._legacy_operation_id(decoded)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            duplicate = connection.execute(
                "SELECT raw FROM events WHERE account_id = ? AND operation_id = ?",
                (account_id, operation_id),
            ).fetchone()
            if duplicate is not None:
                connection.commit()
                return str(duplicate[0])

            row = connection.execute(
                "SELECT next_seq FROM account_sequences WHERE account_id = ?",
                (account_id,),
            ).fetchone()
            seq = (int(row[0]) if row else 0) + 1
            connection.execute(
                """
                INSERT INTO account_sequences(account_id, next_seq) VALUES (?, ?)
                ON CONFLICT(account_id) DO UPDATE SET next_seq = excluded.next_seq
                """,
                (account_id, seq),
            )
            enriched = dict(decoded)
            enriched["relayQueueSeq"] = seq
            enriched["relayQueuedAt"] = now
            raw = json.dumps(enriched, ensure_ascii=False, separators=(",", ":"))
            connection.execute(
                """
                INSERT INTO events(
                    account_id, seq, operation_id, device_id, event_type,
                    raw, created_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    account_id,
                    seq,
                    operation_id,
                    str(decoded.get("deviceId") or ""),
                    str(decoded.get("type") or ""),
                    raw,
                    now,
                    now + self.ttl_seconds,
                ),
            )
            self._prune(connection, account_id, now=now)
            connection.commit()
            return raw

    def messages_for_device(self, account_id: str, device_id: str) -> list[str]:
        now = time.time()
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            self._prune(connection, account_id, now=now)
            cursor_row = connection.execute(
                "SELECT seq FROM cursors WHERE account_id = ? AND device_id = ?",
                (account_id, device_id),
            ).fetchone()
            cursor = int(cursor_row[0]) if cursor_row else 0
            rows = connection.execute(
                """
                SELECT raw FROM events
                WHERE account_id = ? AND seq > ? AND device_id != ?
                ORDER BY seq
                """,
                (account_id, cursor, device_id),
            ).fetchall()
            connection.commit()
            return [str(row[0]) for row in rows]

    def acknowledge(self, account_id: str, device_id: str, seq: int) -> None:
        safe_seq = max(0, seq)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """
                INSERT INTO cursors(account_id, device_id, seq) VALUES (?, ?, ?)
                ON CONFLICT(account_id, device_id) DO UPDATE SET
                    seq = MAX(cursors.seq, excluded.seq)
                """,
                (account_id, device_id, safe_seq),
            )
            connection.commit()

    def account_stats(self) -> dict[str, dict[str, int]]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT sequences.account_id, sequences.next_seq, COUNT(events.seq)
                FROM account_sequences AS sequences
                LEFT JOIN events ON events.account_id = sequences.account_id
                GROUP BY sequences.account_id, sequences.next_seq
                """
            ).fetchall()
        return {
            str(account_id): {"next_seq": int(next_seq), "events": int(event_count)}
            for account_id, next_seq, event_count in rows
        }

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.execute("PRAGMA busy_timeout=10000")
        return connection

    def _prune(self, connection: sqlite3.Connection, account_id: str, *, now: float) -> None:
        connection.execute(
            "DELETE FROM events WHERE account_id = ? AND expires_at < ?",
            (account_id, now),
        )
        count_row = connection.execute(
            "SELECT COUNT(*) FROM events WHERE account_id = ?",
            (account_id,),
        ).fetchone()
        excess = (int(count_row[0]) if count_row else 0) - self.max_events
        if excess > 0:
            connection.execute(
                """
                DELETE FROM events WHERE account_id = ? AND seq IN (
                    SELECT seq FROM events WHERE account_id = ? ORDER BY seq LIMIT ?
                )
                """,
                (account_id, account_id, excess),
            )

    @staticmethod
    def _legacy_operation_id(decoded: dict[str, Any]) -> str:
        return "legacy:" + ":".join(
            str(decoded.get(key) or "")
            for key in ("deviceId", "type", "createdAt")
        )
