import tempfile
from pathlib import Path
import unittest

from orders import Order, OrderLine, OrderRepository, OrderService, OrderStatus, StorageError
from orders.migrations import MIGRATIONS


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = str(Path(self.tmp.name) / "orders.db")
        self.repo = OrderRepository(database=self.path)
        self.addCleanup(lambda: self.repo.close())
        self.service = OrderService(self.repo)
        self.service.inventory.replenish("sku", 10)

    def test_reopen_retains_all_order_effects(self):
        order = self.service.place_order("one", "c", [OrderLine("sku", 2, 100)])
        self.repo.close()
        self.repo = OrderRepository(database=self.path)
        service = OrderService(self.repo)
        self.assertEqual(self.repo.get("one"), order)
        self.assertEqual(service.inventory.available("sku"), 8)
        self.assertEqual(service.payments.get("one").state, "authorized")
        self.assertEqual(len(self.repo.events_for("one")), 1)
        self.assertEqual(len(service.outbox.pending()), 1)

    def test_placement_faults_roll_back_every_table(self):
        for stage in ("order_added", "inventory_reserved", "payment_authorized", "event_appended", "outbox_enqueued"):
            def fault(name):
                if name == stage:
                    raise StorageError(stage)
            self.repo.db.fault = fault
            with self.subTest(stage=stage), self.assertRaises(StorageError):
                self.service.place_order("one", "c", [OrderLine("sku", 2, 100)])
            self.assertIsNone(self.repo.get("one"))
            self.assertEqual(self.service.inventory.available("sku"), 10)
            self.assertIsNone(self.service.payments.get("one"))
            self.assertEqual(self.service.outbox.pending(), [])
        self.repo.db.fault = None
        self.service.place_order("one", "c", [OrderLine("sku", 2, 100)])

    def test_shipping_fault_rolls_back_payment_and_stock(self):
        self.service.place_order("one", "c", [OrderLine("sku", 2, 100)])
        def fault(name):
            if name == "outbox_enqueued":
                raise StorageError(name)
        self.repo.db.fault = fault
        with self.assertRaises(StorageError):
            self.service.ship_order("one")
        self.assertEqual(self.repo.get("one").status, OrderStatus.PENDING)
        self.assertEqual(self.service.payments.get("one").state, "authorized")
        self.assertEqual(self.repo.connection.execute("SELECT on_hand FROM stock").fetchone()[0], 10)
        self.assertEqual(self.service.inventory.reservations_for("one")[0].state, "active")

    def test_nested_rollback_preserves_outer_work(self):
        with self.repo.transaction():
            self.repo.add(Order("outer", "c", 1))
            with self.assertRaises(ValueError):
                with self.repo.transaction():
                    self.repo.add(Order("inner", "c", 2))
                    raise ValueError("rollback only savepoint")
            self.repo.add(Order("after", "c", 3))
        self.assertEqual([o.order_id for o in self.repo.all()], ["after", "outer"])

    def test_outer_rollback_discards_inner_commit(self):
        with self.assertRaises(ValueError):
            with self.repo.transaction():
                with self.repo.transaction():
                    self.repo.add(Order("inner", "c", 2))
                raise ValueError("abort command")
        self.assertEqual(self.repo.all(), [])

    def test_migrations_applied_once(self):
        expected = [number for number, _ in MIGRATIONS]
        self.repo.close()
        self.repo = OrderRepository(database=self.path)
        actual = [r[0] for r in self.repo.connection.execute("SELECT version FROM schema_migrations ORDER BY version")]
        self.assertEqual(actual, expected)

    def test_outbox_ack_is_idempotent(self):
        self.service.place_order("one", "c", [OrderLine("sku", 1, 10)])
        message = self.service.outbox.pending()[0]
        self.assertTrue(self.service.outbox.acknowledge(message.message_id))
        self.assertFalse(self.service.outbox.acknowledge(message.message_id))
        self.assertFalse(self.service.outbox.acknowledge(999))
        self.assertEqual(self.service.outbox.pending(), [])
