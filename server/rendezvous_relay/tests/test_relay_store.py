from __future__ import annotations

import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from relay_store import RelayStore


class RelayStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.store = RelayStore(
            Path(self.temp.name) / "relay.sqlite3",
            max_events=1000,
            ttl_seconds=3600,
        )
        self.store.initialize()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_concurrent_appends_are_transactional_and_lossless(self) -> None:
        def append(index: int) -> None:
            self.store.append(
                "account",
                {
                    "type": "library_snapshot",
                    "accountId": "account",
                    "deviceId": "a",
                    "protocolVersion": 3,
                    "operationId": f"op-{index}",
                    "payload": {"e2ee": {"ciphertext": str(index)}},
                },
            )

        with ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(append, range(50)))

        messages = [json.loads(raw) for raw in self.store.messages_for_device("account", "b")]
        self.assertEqual(50, len(messages))
        self.assertEqual(set(range(1, 51)), {message["relayQueueSeq"] for message in messages})

    def test_operation_id_is_idempotent_across_restart(self) -> None:
        event = {
            "type": "library_snapshot",
            "accountId": "account",
            "deviceId": "a",
            "protocolVersion": 3,
            "operationId": "same-operation",
            "payload": {"e2ee": {"ciphertext": "opaque"}},
        }
        first = self.store.append("account", event)
        restarted = RelayStore(
            self.store.database_path,
            max_events=1000,
            ttl_seconds=3600,
        )
        restarted.initialize()
        second = restarted.append("account", event)

        self.assertEqual(first, second)
        self.assertEqual(1, len(restarted.messages_for_device("account", "b")))

    def test_ack_cursor_survives_restart(self) -> None:
        for index in range(3):
            self.store.append(
                "account",
                {
                    "type": "library_snapshot",
                    "accountId": "account",
                    "deviceId": "a",
                    "operationId": f"op-{index}",
                    "payload": {"e2ee": {}},
                },
            )
        self.store.acknowledge("account", "b", 2)
        restarted = RelayStore(self.store.database_path, max_events=1000, ttl_seconds=3600)
        restarted.initialize()
        pending = [json.loads(raw) for raw in restarted.messages_for_device("account", "b")]
        self.assertEqual([3], [message["relayQueueSeq"] for message in pending])


if __name__ == "__main__":
    unittest.main()
