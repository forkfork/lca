from __future__ import annotations

import json

from .models import OutboxMessage
from .validation import integer


class Outbox:
    def __init__(self, repository):
        self.repository = repository

    def enqueue(self, topic: str, order_id: str, payload: dict) -> int:
        cursor = self.repository.connection.execute(
            "INSERT INTO outbox(topic,aggregate_id,payload) VALUES (?,?,?)",
            (topic, order_id, json.dumps(payload, sort_keys=True)),
        )
        self.repository.db.checkpoint("outbox_enqueued")
        return cursor.lastrowid

    def pending(self, limit: int = 100) -> list[OutboxMessage]:
        limit = integer(limit, "limit", 1)
        return [OutboxMessage(row["message_id"], row["topic"], row["aggregate_id"],
                             json.loads(row["payload"]), bool(row["delivered"]))
                for row in self.repository.connection.execute(
                    "SELECT * FROM outbox WHERE delivered=0 ORDER BY message_id LIMIT ?", (limit,))]

    def acknowledge(self, message_id: int) -> bool:
        integer(message_id, "message_id", 1)
        return bool(self.repository.connection.execute(
            "UPDATE outbox SET delivered=1 WHERE message_id=? AND delivered=0", (message_id,)).rowcount)
