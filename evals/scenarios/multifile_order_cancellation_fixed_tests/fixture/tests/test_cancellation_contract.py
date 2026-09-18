"""Supplied cancellation acceptance contract; do not modify."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest

# Supplied by the grader; the subject is the candidate package, not this folder.
ORDER_WORKSPACE = str(Path(__file__).resolve().parents[1])
sys.path.insert(0, ORDER_WORKSPACE)
from orders import ConflictError, NotFoundError, Order, OrderAPI, OrderLine, OrderRepository, OrderService, OrderStatus, StorageError
from orders.reporting import Reports
from orders.serialization import order_body


class CancellationContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = str(Path(self.tmp.name) / 'orders.db')
        self.repo = OrderRepository(database=self.path)
        self.addCleanup(lambda: self.repo.close())
        self.service = OrderService(self.repo)
        self.service.inventory.replenish('book', 30)
        self.service.inventory.replenish('pen', 50)
        for name in ('a', 'b', 'c'):
            self.service.place_order(name, 'customer', [OrderLine('book', 2, 500), OrderLine('pen', 3, 50)], shipping_cents=100)
        self.api = OrderAPI(self.service)

    def dump(self):
        return '\n'.join(self.repo.connection.iterdump())

    def receipts(self):
        return list(self.repo.connection.execute('SELECT * FROM cancellations ORDER BY order_id,request_id'))

    def cancel(self, name='a', key='req', **kwargs):
        return self.service.cancel_order(name, key, **kwargs)

    def test_complete_effects_and_unchanged_other_order(self):
        before = self.repo.get('a')
        other = self.repo.get('b')
        result = self.cancel(reason='fraud', expected_version=0)
        self.assertEqual(result.status.value, 'cancelled')
        expected = order_body(before); expected.update(status='cancelled', version=1)
        self.assertEqual(order_body(result), expected)
        self.assertEqual(self.repo.get('b'), other)
        self.assertEqual(self.service.payments.get('b').state, 'authorized')
        self.assertTrue(all(r.state == 'active' for r in self.service.inventory.reservations_for('b')))
        self.assertEqual(self.service.inventory.available('book'), 26)
        self.assertEqual(self.service.inventory.available('pen'), 44)
        self.assertEqual(self.repo.connection.execute("SELECT on_hand FROM stock WHERE sku='book'").fetchone()[0], 30)
        self.assertTrue(all(r.state == 'released' for r in self.service.inventory.reservations_for('a')))
        payment = self.service.payments.get('a')
        self.assertEqual((payment.state, payment.amount_cents, payment.currency), ('voided', 1250, 'AUD'))
        events = [e for e in self.repo.events_for('a') if e.kind == 'cancelled']
        self.assertEqual(len(events), 1)
        payload = {'reason':'fraud', 'released_units':5, 'voided_cents':1250}
        self.assertEqual(events[0].payload, payload)
        self.assertEqual(events[0].request_id, 'req')
        messages = [m for m in self.service.outbox.pending() if m.topic == 'order.cancelled']
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0].aggregate_id, 'a')
        self.assertEqual(messages[0].payload, dict(payload, request_id='req', version=1))
        receipt = self.receipts()[0]
        self.assertEqual((receipt['order_id'],receipt['request_id'],receipt['reason']), ('a','req','fraud'))
        self.assertEqual(json.loads(receipt['response_json']), expected)

    def test_replay_normalizes_key_and_has_no_effects(self):
        original = self.cancel(key='  req  ', reason='duplicate', expected_version=0)
        before = self.dump()
        self.assertEqual(self.cancel(reason='duplicate', expected_version=0), original)
        self.assertEqual(self.cancel(reason='duplicate', expected_version=999), original)
        self.assertEqual(self.dump(), before)
        with self.assertRaises(ConflictError):
            self.cancel(reason='fraud')
        with self.assertRaises(ConflictError):
            self.cancel(key='different')
        self.assertEqual(self.dump(), before)

    def test_receipt_returns_original_snapshot_after_restart(self):
        original = self.cancel()
        self.repo.connection.execute("UPDATE orders SET version=9,shipping_cents=777 WHERE order_id='a'")
        self.repo.close(); self.repo = OrderRepository(database=self.path)
        self.service = OrderService(self.repo)
        before = self.dump()
        self.assertEqual(self.cancel(expected_version=0), original)
        self.assertEqual(self.dump(), before)

    def test_key_scope_per_order(self):
        self.cancel('a', 'shared')
        self.cancel('b', 'shared')
        self.assertEqual(len(self.receipts()), 2)

    def test_invalid_input_including_retry_types_never_mutates(self):
        self.cancel()
        before = self.dump()
        for key in (None, True, 42, '', '  ', 'x'*65, [], {}):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.cancel('b', key)
        for reason in ('', 'other', None, 1, [], {}):
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                self.cancel('b', reason=reason)
        for version in (True, -1, 0.0, '0', [], {}):
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.cancel('a', expected_version=version)
        self.assertEqual(self.dump(), before)
        self.cancel('b', ' '+('x'*64)+' ')

    def test_version_mismatch_and_missing_order(self):
        before = self.dump()
        with self.assertRaises(ConflictError): self.cancel(expected_version=1)
        with self.assertRaises(NotFoundError): self.cancel('absent')
        self.assertEqual(self.dump(), before)

    def test_paid_shipped_and_inconsistent_dependencies_conflict(self):
        self.service.pay_order('a'); self.service.ship_order('b')
        for order in ('a','b'):
            before = self.dump()
            with self.assertRaises(ConflictError): self.cancel(order)
            self.assertEqual(self.dump(), before)
        for state in ('captured','voided'):
            self.repo.connection.execute("UPDATE payments SET state=? WHERE order_id='c'", (state,))
            before = self.dump()
            with self.assertRaises(ConflictError): self.cancel('c')
            self.assertEqual(self.dump(), before)
        self.repo.connection.execute("UPDATE payments SET state='authorized' WHERE order_id='c'")
        for state in ('committed','released'):
            self.repo.connection.execute("UPDATE reservations SET state=? WHERE order_id='c'", (state,))
            before = self.dump()
            with self.assertRaises(ConflictError): self.cancel('c')
            self.assertEqual(self.dump(), before)

    def test_legacy_without_dependencies(self):
        self.repo.add(Order('legacy','customer',500))
        result = self.cancel('legacy')
        self.assertEqual(result.status.value, 'cancelled')
        self.assertEqual(self.repo.events_for('legacy')[0].payload,
                         {'reason':'customer_request','released_units':0,'voided_cents':0})

    def test_each_write_checkpoint_rolls_back_and_allows_retry(self):
        for stage in ('inventory_released','payment_voided','order_status','event_appended','outbox_enqueued','cancellation_saved'):
            before = self.dump()
            def fault(name):
                if name == stage: raise StorageError(stage)
            self.repo.db.fault = fault
            with self.subTest(stage=stage), self.assertRaises(StorageError): self.cancel()
            self.assertEqual(self.dump(), before, stage+' failed to roll back')
        self.repo.db.fault = None
        self.assertEqual(self.cancel().status.value, 'cancelled')
        self.assertEqual(len(self.receipts()), 1)

    def test_batch_order_replays_and_mixed_new_commands(self):
        self.cancel('b','same')
        items = [{'order_id':'b','request_id':'same'}, {'order_id':'a','request_id':'same','reason':'fraud'}]
        result = self.service.cancel_orders(items)
        self.assertEqual([o.order_id for o in result], ['b','a'])
        before = self.dump()
        self.assertEqual(self.service.cancel_orders(items), result)
        self.assertEqual(self.dump(), before)
        self.assertEqual(len(self.receipts()), 2)

    def test_batch_invalid_input_never_mutates(self):
        good = {'order_id':'a','request_id':'r'}
        invalid = [None, {}, [], 'bad', [good]*2, [good]*51, [good,{}], [good,None],
                   [good,dict(order_id='b',request_id='r',extra=1)],
                   [good,dict(order_id='b',request_id='r',expected_version=True)],
                   [good,dict(order_id='b',request_id='')], [dict(order_id=1,request_id='r')]]
        before = self.dump()
        for items in invalid:
            with self.subTest(items=items), self.assertRaises(ValueError):
                self.service.cancel_orders(items)
            self.assertEqual(self.dump(), before)
        # Validation must precede ANY mutation, not merely roll it back.
        self.repo.db.fault = lambda name: self.fail('write before full batch validation: '+name)
        with self.assertRaises(ValueError): self.service.cancel_orders([good, {}])

    def test_batch_domain_failure_rolls_back_and_keeps_prior_receipts(self):
        self.cancel('c','old')
        self.service.ship_order('b')
        for failing,error in [('b',ConflictError),('absent',NotFoundError)]:
            before = self.dump()
            with self.assertRaises(error):
                self.service.cancel_orders([{'order_id':'c','request_id':'old'},
                                            {'order_id':'a','request_id':'new'},
                                            {'order_id':failing,'request_id':'new'}])
            self.assertEqual(self.dump(), before)

    def test_batch_second_write_fault_rolls_back_first(self):
        count = 0
        def fault(name):
            nonlocal count
            if name == 'cancellation_saved':
                count += 1
                if count == 2: raise StorageError('second receipt')
        self.repo.db.fault = fault
        before = self.dump()
        with self.assertRaises(StorageError):
            self.service.cancel_orders([{'order_id':name,'request_id':'r'} for name in ('a','b')])
        self.assertEqual(self.dump(), before)

    def test_api_validation_and_error_mapping(self):
        before = self.dump()
        for body in ('{','null','[]','1','{}','{"request_id":"r","extra":1}',
                     '{"request_id":"r","expected_version":true}'):
            response = self.api.handle('POST','/orders/a/cancel',body)
            self.assertEqual((response.status,response.body['error']), (400,'invalid_request'))
        for body in ('{}','[]','{"items":[]}','{"items":[],"extra":1}'):
            self.assertEqual(self.api.handle('POST','/orders/cancel-batch',body).status,400)
        self.assertEqual(self.dump(),before)
        self.assertEqual(self.api.handle('POST','/orders/absent/cancel','{"request_id":"r"}').status,404)
        self.assertEqual(self.api.handle('POST','/orders/a/cancel','{"request_id":"r","expected_version":99}').status,409)
        def fault(name):
            if name == 'event_appended': raise StorageError('test')
        self.repo.db.fault = fault
        response = self.api.handle('POST','/orders/a/cancel','{"request_id":"r"}')
        self.assertEqual((response.status,response.body), (503,{'error':'storage_unavailable'}))
        self.assertEqual(self.dump(),before)

    def test_api_success_and_batch(self):
        response = self.api.handle('POST','/orders/a/cancel','{"request_id":"r","reason":"duplicate"}')
        self.assertEqual(response.status,200)
        self.assertEqual(response.body,order_body(self.repo.get('a')))
        items=[{'order_id':'c','request_id':'r'}, {'order_id':'b','request_id':'r'}]
        response=self.api.handle('POST','/orders/cancel-batch',json.dumps({'items':items}))
        self.assertEqual(response.status,200)
        self.assertEqual(response.body,{'orders':[order_body(self.repo.get(n)) for n in ('c','b')]})

    def cli(self,*args):
        return subprocess.run([sys.executable,'-B','-m','orders','--database',self.path,*args],
                              cwd=ORDER_WORKSPACE,capture_output=True,text=True,timeout=10)

    def test_cli_replay_batch_and_failure(self):
        args=('cancel','a','--request-id','r','--reason','fraud','--expected-version','0')
        first=self.cli(*args)
        self.assertEqual(first.returncode,0,first.stderr)
        self.assertEqual(first.stderr,'')
        self.assertEqual(json.loads(first.stdout),order_body(self.repo.get('a')))
        self.assertEqual(self.cli(*args).stdout,first.stdout)
        batch=self.cli('cancel-batch','--items-json',json.dumps([{'order_id':n,'request_id':'r'} for n in ('c','b')]))
        self.assertEqual(batch.returncode,0,batch.stderr)
        self.assertEqual([o['order_id'] for o in json.loads(batch.stdout)],['c','b'])
        for args in [('cancel','a','--request-id','other'),('cancel-batch','--items-json','{'),
                     ('cancel-batch','--items-json','null')]:
            before=self.dump();result=self.cli(*args)
            self.assertEqual(result.returncode,2)
            self.assertEqual(result.stdout,'')
            self.assertIsInstance(json.loads(result.stderr)['error'],str)
            self.assertEqual(self.dump(),before)

    def test_reporting_excludes_cancelled_money_but_counts_orders(self):
        self.repo.add(Order('usd','customer',400,currency='USD'))
        self.cancel('usd'); self.cancel('a'); self.service.ship_order('b')
        self.service.pay_order('c')
        summary=Reports(self.repo).customer_summary('customer')
        self.assertEqual(summary['order_count'],4)
        self.assertEqual(summary['status_counts'],{'cancelled':2,'paid':1,'shipped':1})
        self.assertEqual(summary['totals'],{'AUD':{'open_cents':1250,'shipped_cents':1250},
                                            'USD':{'open_cents':0,'shipped_cents':0}})

    def test_same_key_concurrent_connections_have_one_effect(self):
        self.concurrent(['shared','shared'],2)

    def test_different_keys_concurrent_connections_have_one_winner(self):
        self.concurrent(['one','two'],1)

    def concurrent(self,keys,successes):
        barrier=threading.Barrier(2); results=[];errors=[]
        def worker(key):
            repo=None
            try:
                repo=OrderRepository(database=self.path)
                barrier.wait(timeout=5)
                results.append(OrderService(repo).cancel_order('a',key))
            except Exception as exc: errors.append(exc)
            finally:
                if repo: repo.close()
        threads=[threading.Thread(target=worker,args=(key,)) for key in keys]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=10)
        self.assertFalse(any(t.is_alive() for t in threads))
        self.assertEqual(len(results),successes,repr(errors))
        self.assertTrue(all(isinstance(exc,ConflictError) for exc in errors),repr(errors))
        if successes==2: self.assertEqual(results[0],results[1])
        self.assertEqual(len([e for e in self.repo.events_for('a') if e.kind=='cancelled']),1)
        self.assertEqual(len([m for m in self.service.outbox.pending() if m.topic=='order.cancelled']),1)
        self.assertEqual(len(self.receipts()),1)

    def test_batch_accepts_fifty_and_blocks_shipping_after_cancel(self):
        for n in range(50): self.repo.add(Order('bulk'+str(n),'bulk',n))
        result=self.service.cancel_orders([{'order_id':'bulk'+str(n),'request_id':'r'} for n in range(50)])
        self.assertEqual(len(result),50)
        self.assertTrue(all(o.status.value=='cancelled' for o in result))
        before=self.dump()
        for command in (self.service.pay_order,self.service.ship_order):
            with self.assertRaises(ConflictError): command('bulk0')
        self.assertEqual(self.dump(),before)

    def test_receipt_schema_and_delivery_state_survive_replay(self):
        self.cancel()
        columns=list(self.repo.connection.execute('PRAGMA table_info(cancellations)'))
        keys=[row['name'] for row in sorted(columns,key=lambda r:r['pk']) if row['pk']]
        self.assertEqual(keys,['order_id','request_id'])
        for message in self.service.outbox.pending():self.service.outbox.acknowledge(message.message_id)
        before=self.dump();self.cancel()
        self.assertEqual(self.dump(),before)
        self.assertEqual(self.service.outbox.pending(),[])

    def test_upgrade_real_v1_database_preserves_all_rows(self):
        # The old schema is a frozen external oracle, never taken from candidate code.
        spec=json.loads(Path(__file__).with_name('v1_schema.json').read_text())
        legacy=str(Path(self.tmp.name)/'v1.db')
        conn=sqlite3.connect(legacy,isolation_level=None)
        conn.execute('CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY)')
        for statement in spec: conn.execute(statement)
        conn.execute('INSERT INTO schema_migrations VALUES (1)')
        conn.execute("INSERT INTO orders VALUES ('old','c',100,'pending',0,'AUD',0)")
        conn.execute("INSERT INTO order_lines VALUES ('old',0,'sku',1,100)")
        conn.execute("INSERT INTO stock VALUES ('sku',10)")
        conn.execute("INSERT INTO reservations VALUES ('old','sku',1,'active')")
        conn.execute("INSERT INTO payments VALUES ('old',100,'authorized','AUD')")
        conn.execute("INSERT INTO events(order_id,kind,payload) VALUES ('old','placed','{}')")
        conn.execute("INSERT INTO outbox(topic,aggregate_id,payload) VALUES ('order.placed','old','{}')")
        conn.execute("INSERT INTO returns VALUES ('historical','old',1,'imported')")
        tables=['orders','order_lines','stock','reservations','payments','events','outbox','returns']
        before={t:conn.execute('SELECT * FROM '+t).fetchall() for t in tables};conn.close()
        for _ in range(2):
            repo=OrderRepository(database=legacy)
            try:
                self.assertEqual([r[0] for r in repo.connection.execute('SELECT version FROM schema_migrations ORDER BY version')],[1,2])
                for table in tables:
                    self.assertEqual([tuple(r) for r in repo.connection.execute('SELECT * FROM '+table)],before[table])
            finally:repo.close()
        repo=OrderRepository(database=legacy)
        try:self.assertEqual(OrderService(repo).cancel_order('old','r').status.value,'cancelled')
        finally:repo.close()


if __name__=='__main__':
    unittest.main(verbosity=2)
