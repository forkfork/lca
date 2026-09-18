"""Append-only migrations. Existing version-1 databases must remain readable."""
import sqlite3

MIGRATIONS = [(1, (
    "CREATE TABLE orders (order_id TEXT PRIMARY KEY, customer_id TEXT NOT NULL, total_cents INTEGER NOT NULL, status TEXT NOT NULL, version INTEGER NOT NULL, currency TEXT NOT NULL, shipping_cents INTEGER NOT NULL)",
    "CREATE TABLE order_lines (order_id TEXT REFERENCES orders(order_id), position INTEGER, sku TEXT NOT NULL, quantity INTEGER NOT NULL, unit_price_cents INTEGER NOT NULL, PRIMARY KEY(order_id, position))",
    "CREATE TABLE stock (sku TEXT PRIMARY KEY, on_hand INTEGER NOT NULL CHECK(on_hand >= 0))",
    "CREATE TABLE reservations (order_id TEXT REFERENCES orders(order_id), sku TEXT REFERENCES stock(sku), quantity INTEGER NOT NULL, state TEXT NOT NULL, PRIMARY KEY(order_id, sku))",
    "CREATE TABLE payments (order_id TEXT PRIMARY KEY REFERENCES orders(order_id), amount_cents INTEGER NOT NULL, state TEXT NOT NULL, currency TEXT NOT NULL)",
    "CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, order_id TEXT REFERENCES orders(order_id), kind TEXT NOT NULL, request_id TEXT, payload TEXT NOT NULL)",
    "CREATE TABLE outbox (message_id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT NOT NULL, aggregate_id TEXT NOT NULL, payload TEXT NOT NULL, delivered INTEGER NOT NULL DEFAULT 0)",
    "CREATE TABLE returns (return_id TEXT PRIMARY KEY, order_id TEXT REFERENCES orders(order_id), amount_cents INTEGER NOT NULL, reason TEXT NOT NULL)",
    "CREATE INDEX orders_customer ON orders(customer_id)",
    "CREATE INDEX events_order ON events(order_id, sequence)",
))]


def migrate(connection: sqlite3.Connection) -> None:
    connection.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY)")
    applied = {row[0] for row in connection.execute("SELECT version FROM schema_migrations")}
    for version, statements in MIGRATIONS:
        if version in applied:
            continue
        connection.execute("BEGIN IMMEDIATE")
        try:
            for statement in statements:
                connection.execute(statement)
            connection.execute("INSERT INTO schema_migrations VALUES (?)", (version,))
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
