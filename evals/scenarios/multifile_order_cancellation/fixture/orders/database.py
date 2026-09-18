from __future__ import annotations

from contextlib import contextmanager
import sqlite3
import threading
from typing import Callable

from .migrations import migrate


class Database:
    """One connection per repository, serializable write commands, nested savepoints.

    The fault callback is used by storage integration tests. Every checkpoint runs
    after the named write; do not catch it and continue a partially applied command.
    """
    def __init__(self, path: str = ":memory:", fault: Callable[[str], None] | None = None):
        self.connection = sqlite3.connect(path, isolation_level=None, timeout=5)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.fault = fault
        self._lock = threading.RLock()
        self._depth = 0
        migrate(self.connection)

    def checkpoint(self, name: str) -> None:
        if self.fault is not None:
            self.fault(name)

    @contextmanager
    def transaction(self):
        with self._lock:
            depth = self._depth
            savepoint = f"unit_{depth}"
            self.connection.execute("BEGIN IMMEDIATE" if depth == 0 else f"SAVEPOINT {savepoint}")
            self._depth += 1
            try:
                yield self
                self.connection.execute("COMMIT" if depth == 0 else f"RELEASE {savepoint}")
            except BaseException:
                if depth == 0:
                    self.connection.rollback()
                else:
                    self.connection.execute(f"ROLLBACK TO {savepoint}")
                    self.connection.execute(f"RELEASE {savepoint}")
                raise
            finally:
                self._depth -= 1

    def close(self) -> None:
        self.connection.close()
