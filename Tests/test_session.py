"""Verify session lifetime independently of camera hardware."""
import io
import json
from pathlib import Path
import socket
import struct
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Engine'))
import bridge


class SessionTests(unittest.TestCase):
    def run_session(self, requests, fail_at=None, drop=False):
        app, engine = socket.socketpair()
        app.settimeout(5)
        events = []
        replies = []
        class Backend:
            def __init__(self, device): pass
            def start(self): events.append('start')
            def stop(self): events.append('stop')
        def command(**kwargs):
            events.append('enter')
            try: kwargs['complete'](object())
            finally: events.append('exit')
        def transact(backend, request, state):
            events.append(request['operation'])
            if len([e for e in events if e == 'read']) == fail_at:
                raise RuntimeError('simulated camera loss')
            return {'test': True}
        def worker():
            with engine:
                bridge.serve_camera(engine, io.StringIO())
        with patch('pmca.commands.usb.senserShellCommand', command), \
             patch('pmca.platform.backend.senser.SenserPlatformBackend', Backend), \
             patch.object(bridge, 'configure_usb'), patch.object(bridge, 'transact', transact):
            thread = threading.Thread(target=worker)
            thread.start()
            try:
                for request in requests:
                    bridge.send_message(app, request)
                    replies.append(bridge.receive_message(app))
                    if request['operation'] != 'disconnect' and replies[-1]['ok']:
                        self.assertNotIn('stop', events)
                        self.assertNotIn('exit', events)
                app.close()
                thread.join(5)
                self.assertFalse(thread.is_alive())
            finally:
                app.close()
        return events, replies

    def test_repeated_reads_keep_one_session_until_disconnect(self):
        events, replies = self.run_session([
            {'operation': 'read', 'mode': 'service'},
            {'operation': 'read', 'mode': 'service'},
            {'operation': 'disconnect'},
        ])
        self.assertEqual(events, ['enter', 'start', 'read', 'read', 'stop', 'exit'])
        self.assertTrue(all(r['ok'] for r in replies))

    def test_read_apply_read_uses_same_backend(self):
        events, replies = self.run_session([
            {'operation': 'read', 'mode': 'service'},
            {'operation': 'apply', 'mode': 'service', 'languages': [1] * 35,
             'expected': {'languages': [1] * 35, 'model': 'TEST', 'modelCode': 'TEST', 'serial': 'TEST', 'region': 'TEST'}},
            {'operation': 'read', 'mode': 'service'},
            {'operation': 'disconnect'},
        ])
        self.assertEqual(events, ['enter', 'start', 'read', 'apply', 'read', 'stop', 'exit'])
        self.assertTrue(all(r['ok'] for r in replies))

    def test_app_disappearance_closes_upstream_session(self):
        events, _ = self.run_session([{'operation': 'read', 'mode': 'service'}])
        self.assertEqual(events, ['enter', 'start', 'read', 'stop', 'exit'])

    def test_camera_error_ends_session_without_retry(self):
        events, replies = self.run_session([
            {'operation': 'read', 'mode': 'service'},
            {'operation': 'read', 'mode': 'service'},
        ], fail_at=2)
        self.assertEqual(events, ['enter', 'start', 'read', 'read', 'stop', 'exit'])
        self.assertFalse(replies[-1]['ok'])
        self.assertIn('simulated camera loss', replies[-1]['error'])

    def test_mode_change_requires_disconnect(self):
        events, replies = self.run_session([
            {'operation': 'read', 'mode': 'service'},
            {'operation': 'read', 'mode': 'updater'},
        ])
        self.assertFalse(replies[-1]['ok'])
        self.assertEqual(events.count('read'), 1)
        self.assertEqual(events[-2:], ['stop', 'exit'])


if __name__ == '__main__': unittest.main()
