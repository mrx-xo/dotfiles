"""Real ephemeral HTTP tests, using only temporary state and inert SDK stubs."""
from concurrent.futures import ThreadPoolExecutor
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'shared' / 'lights'))
sys.path.insert(0, str(ROOT / 'windows' / 'scripts'))
import effects
import icue_http


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.control = Path(self.temp.name) / 'control.json'
        self.status = Path(self.temp.name) / 'status.json'
        self.original = {'mode': 'rotation', 'preset': 'rotation', 'brightness': 1,
                         'fans': {'test': [1, 2, 3]}, 'params': {'saved': True}}
        self.control.write_text(json.dumps(self.original, indent=2))
        self.observed = {'on': False, 'effect': 'black', 'brightness': 0.2,
                         'mode': 'night', 'preset': 'rotation'}
        self.status.write_text(json.dumps(self.observed))
        self.server = icue_http.start_server(self.control, self.status, effects,
                                             host='127.0.0.1', port=0)
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()

    def request(self, method='GET', path='/status', body=None, headers=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=4)
        try:
            conn.request(method, path, body, headers or {})
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def post(self, value):
        return self.request('POST', '/control', json.dumps(value),
                            {'Content-Type': 'application/json'})

    def raw(self, request):
        with socket.create_connection(self.server.server_address, timeout=4) as sock:
            sock.sendall(request)
            data = b''
            while chunk := sock.recv(65536):
                data += chunk
        return int(data.split(b' ', 2)[1])

    def test_health_and_observed_status(self):
        self.assertEqual(self.request(path='/health'),
                         (200, {'ok': True, 'engine': 'icue-lights'}))
        code, data = self.request()
        self.assertEqual(code, 200)
        for key, value in self.observed.items():
            self.assertEqual(data[key], value)
        self.assertEqual(data['effect_list'], list(effects.EFFECTS) + ['random'] +
                         ['preset: ' + name for name in effects.PRESETS])
        self.assertEqual(data['descriptions'], effects.DESCRIPTIONS)
        self.assertEqual(data['effect_current'], 'preset: rotation')
        self.assertGreaterEqual(data['age'], 0)

    def test_stale_status_keeps_age_and_observation(self):
        old = time.time() - 120
        os.utime(self.status, (old, old))
        code, data = self.post({'force': 'on', 'effect': next(iter(effects.EFFECTS))})
        self.assertEqual(code, 200)
        self.assertTrue(data['accepted'])
        self.assertFalse(data['on'])
        self.assertEqual(data['effect'], 'black')
        self.assertEqual(data['brightness'], 0.2)
        self.assertGreaterEqual(data['age'], 120)

    def test_all_effects_presets_random_and_preserved_keys(self):
        for name in effects.EFFECTS:
            with self.subTest(effect=name):
                self.assertEqual(self.post({'effect': name})[0], 200)
                data = json.loads(self.control.read_text())
                self.assertEqual((data['mode'], data['effect']), ('pinned', name))
                self.assertEqual(self.request()[1]['effect_current'], name)
        for name in effects.PRESETS:
            self.assertEqual(self.post({'effect': 'preset: ' + name})[0], 200)
            data = json.loads(self.control.read_text())
            self.assertEqual((data['mode'], data['preset']), ('rotation', name))
        fresh_params = effects.random_params(seed=10)
        with patch.object(effects, 'random_params', return_value=fresh_params) as roll:
            self.assertEqual(self.post({'effect': 'random'})[0], 200)
            roll.assert_called_once_with()
        data = json.loads(self.control.read_text())
        self.assertEqual(data['params'], fresh_params)
        self.assertEqual(data['fans'], self.original['fans'])
        self.assertEqual(self.request()[1]['effect_current'], 'random')

    def test_brightness_clamp_and_force_expiry_clear(self):
        for value, expected in [(-5, .01), (0, .01), (.5, .5), (10, 1)]:
            self.assertEqual(self.post({'brightness': value})[0], 200)
            self.assertEqual(json.loads(self.control.read_text())['brightness'], expected)
        with patch.object(icue_http.schedule, 'next_boundary', return_value=12345):
            for force in ('on', 'off'):
                self.assertEqual(self.post({'force': force})[0], 200)
                data = json.loads(self.control.read_text())
                self.assertEqual((data['force'], data['force_until']), (force, 12345))
        self.assertEqual(self.post({'force': None})[0], 200)
        data = json.loads(self.control.read_text())
        self.assertNotIn('force', data)
        self.assertNotIn('force_until', data)
        self.assertEqual(data['params'], self.original['params'])

    def test_invalid_patches_are_byte_identical(self):
        before = self.control.read_bytes()
        invalid = [[], None, True, 42, 'text', {'unknown': 1},
                   {'effect': 'missing'}, {'effect': []}, {'effect': True},
                   {'effect': 'preset: missing'}, {'brightness': True},
                   {'brightness': False}, {'brightness': '0.5'},
                   {'brightness': None}, {'brightness': float('nan')},
                   {'brightness': float('inf')}, {'brightness': -float('inf')},
                   {'force': True}, {'force': []}, {'force': 'auto'},
                   {'effect': 'random', 'brightness': .4, 'force_until': 1},
                   {'effect': 'random', 'brightness': .4, 'force': 'invalid'}]
        for value in invalid:
            with self.subTest(value=value):
                self.assertEqual(self.post(value)[0], 400)
                self.assertEqual(self.control.read_bytes(), before)
        for body in (b'{', b'\xff', b'{"brightness":1e999}', b'{"brightness":NaN}',
                     b'[' * 1500 + b']' * 1500):
            self.assertEqual(self.request('POST', '/control', body,
                             {'Content-Type': 'application/json'})[0], 400)
            self.assertEqual(self.control.read_bytes(), before)

    def test_http_framing_and_limits(self):
        before = self.control.read_bytes()
        cases = [
            (b'Content-Length: 8193\r\nContent-Type: application/json\r\n', 413),
            (b'Content-Length: -1\r\nContent-Type: application/json\r\n', 400),
            (b'Content-Length: abc\r\nContent-Type: application/json\r\n', 400),
            (b'Content-Length: 2\r\nContent-Length: 2\r\nContent-Type: application/json\r\n', 400),
            (b'Transfer-Encoding: chunked\r\nContent-Type: application/json\r\n', 400),
            (b'Content-Type: application/json\r\n', 411),
            (b'Content-Length: 2\r\n', 415),
            (b'Content-Length: 2\r\nContent-Type: text/plain\r\n', 415),
        ]
        for headers, expected in cases:
            with self.subTest(headers=headers):
                self.assertEqual(self.raw(b'POST /control HTTP/1.1\r\nHost: localhost\r\n' +
                                          headers + b'\r\n'), expected)
                self.assertEqual(self.control.read_bytes(), before)
        self.assertEqual(self.request('POST', '/control', b'{}' + b' ' * 8190,
                         {'Content-Type': 'application/json; charset=utf-8'})[0], 200)
        self.assertEqual(self.request(path='/missing')[0], 404)

    def test_missing_corrupt_status_prevents_mutation(self):
        before = self.control.read_bytes()
        for content in (None, '{', '[]', '{}', '{"on":"false","effect":"black"}',
                        '{"on":false,"effect":"black","brightness":NaN}'):
            if content is None:
                self.status.unlink()
            else:
                self.status.write_text(content)
            self.assertEqual(self.request()[0], 503)
            self.assertEqual(self.post({'force': 'on'})[0], 503)
            self.assertEqual(self.control.read_bytes(), before)

    def test_corrupt_control_refused_missing_uses_defaults(self):
        for content in ('{', '[]', 'null', '{"brightness":NaN}',
                        '{"mode":"invalid"}', '{"brightness":true}',
                        '{"fans":{"test":"red"}}',
                        '{"fans":{"test":[1,true,3]}}',
                        '{"mode":"random","params":{"hue":0.5}}'):
            self.control.write_text(content)
            self.assertEqual(self.post({'force': 'on'})[0], 503)
            self.assertEqual(self.control.read_text(), content)
            self.assertEqual(self.request()[0], 503)
        self.control.unlink()
        self.assertEqual(self.request()[1]['effect_current'], 'preset: rotation')
        self.assertEqual(self.post({'force': 'off'})[0], 200)
        data = json.loads(self.control.read_text())
        self.assertEqual((data['mode'], data['preset'], data['brightness']),
                         ('rotation', 'rotation', 1.0))

    def test_concurrent_writes_do_not_lose_disjoint_updates(self):
        for _ in range(8):
            self.control.write_text(json.dumps(self.original))
            barrier = threading.Barrier(3)
            def send(value):
                barrier.wait()
                return self.post(value)[0]
            with ThreadPoolExecutor(3) as pool:
                results = list(pool.map(send, [{'effect': next(iter(effects.EFFECTS))},
                                               {'brightness': .7}, {'force': 'on'}]))
            self.assertEqual(results, [200] * 3)
            data = json.loads(self.control.read_text())
            self.assertEqual((data['mode'], data['brightness'], data['force']),
                             ('pinned', .7, 'on'))
            self.assertEqual(data['fans'], self.original['fans'])

    def test_atomic_write_failure_preserves_file_and_cleans_temp(self):
        before = self.control.read_bytes()
        with patch.object(icue_http.os, 'replace', side_effect=OSError('test failure')):
            self.assertEqual(self.post({'brightness': .6})[0], 503)
        self.assertEqual(self.control.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in self.control.parent.iterdir()),
                         ['control.json', 'status.json'])

    def test_allowlist_blocks_before_body_and_ignores_forwarded_headers(self):
        self.close_server()
        self.server = icue_http.start_server(self.control, self.status, effects,
                         host='127.0.0.1', port=0, allowed_networks=['::1/128'])
        before = self.control.read_bytes()
        started = time.monotonic()
        self.assertEqual(self.raw(b'POST /control HTTP/1.1\r\nHost: localhost\r\n'
                         b'X-Forwarded-For: ::1\r\nContent-Length: 8000\r\n'
                         b'Content-Type: application/json\r\n\r\n'), 403)
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(self.control.read_bytes(), before)
        self.assertEqual(self.request(path='/health')[0], 403)

    def test_slow_clients_timeout_without_blocking_health(self):
        before = self.control.read_bytes()
        self.server.socket_timeout = .25
        for prefix in (b'GET /health HTTP/1.1\r\n',
                       b'POST /control HTTP/1.1\r\nContent-Type: application/json\r\n'
                       b'Content-Length: 10\r\n\r\n{'):
            with socket.create_connection(self.server.server_address, timeout=3) as slow:
                slow.sendall(prefix)
                self.assertEqual(self.request(path='/health')[0], 200)
                # Either an explicit timeout response or EOF must arrive promptly.
                data = slow.recv(65536)
                if data:
                    self.assertIn(b'408', data)
        self.assertEqual(self.control.read_bytes(), before)

    def test_shutdown_closes_idle_clients_and_listener(self):
        slow = socket.create_connection(self.server.server_address, timeout=3)
        self.addCleanup(slow.close)
        slow.sendall(b'GET /health HTTP/1.1\r\n')
        self.assertEqual(self.request(path='/health')[0], 200)
        started = time.monotonic()
        address = self.server.server_address
        self.close_server()
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(slow.recv(1024), b'')
        with self.assertRaises(OSError):
            socket.create_connection(address, timeout=.2)

    def test_absolute_deadline_closes_trickling_headers(self):
        self.server.request_timeout = .3
        with socket.create_connection(self.server.server_address, timeout=2) as slow:
            slow.sendall(b'GET /health HTTP/1.1\r\nX-Slow: ')
            started = time.monotonic()
            closed = False
            for _ in range(15):
                time.sleep(.05)
                try:
                    slow.sendall(b'x')
                except OSError:
                    closed = True
                    break
            if not closed:
                self.assertEqual(slow.recv(1024), b'')
            self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual(self.request(path='/health')[0], 200)

    def test_connection_limit_rejects_excess_and_recovers(self):
        self.server.socket_timeout = 2
        clients = []
        try:
            for _ in range(self.server.max_connections):
                client = socket.create_connection(self.server.server_address, timeout=2)
                clients.append(client)
                client.sendall(b'GET /health HTTP/1.1\r\n')
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                with self.server.connections_lock:
                    if len(self.server.connections) == self.server.max_connections:
                        break
                time.sleep(.01)
            with self.server.connections_lock:
                self.assertEqual(len(self.server.connections), self.server.max_connections)
            with socket.create_connection(self.server.server_address, timeout=2) as excess:
                self.assertEqual(excess.recv(1024), b'')
        finally:
            for client in clients:
                client.close()
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            with self.server.connections_lock:
                if not self.server.connections:
                    break
            time.sleep(.01)
        self.assertEqual(self.request(path='/health')[0], 200)

    def test_readers_never_see_partial_http_writes(self):
        done = threading.Event()
        failures = []
        reads = []
        def reader():
            while not done.is_set():
                try:
                    data = json.loads(self.control.read_bytes())
                    reads.append(data['brightness'])
                except (ValueError, KeyError, OSError) as exc:
                    failures.append(exc)
        thread = threading.Thread(target=reader)
        thread.start()
        try:
            with ThreadPoolExecutor(6) as pool:
                codes = list(pool.map(lambda n: self.post({'brightness': n / 30})[0],
                                      range(1, 25)))
            self.assertEqual(codes, [200] * 24)
        finally:
            done.set()
            thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertTrue(reads)
        self.assertEqual(failures, [])


class ConfigTests(unittest.TestCase):
    def test_default_network_boundaries(self):
        nets = icue_http.DEFAULT_ALLOWED_NETWORKS
        for peer, expected in [('127.0.0.1', True), ('::1', True),
                               ('100.64.0.0', True), ('100.127.255.255', True),
                               ('100.63.255.255', False), ('100.128.0.0', False),
                               ('8.8.8.8', False), ('::ffff:127.0.0.1', True)]:
            self.assertEqual(icue_http.peer_allowed(peer, nets), expected)

    def test_invalid_config_fails_before_binding(self):
        for overrides in ({'ICUE_HTTP_PORT': 'bad'}, {'ICUE_HTTP_PORT': '0'},
                          {'ICUE_HTTP_PORT': '65536'}, {'ICUE_HTTP_HOST': ''},
                          {'ICUE_HTTP_ALLOWED_NETWORKS': ''},
                          {'ICUE_HTTP_ALLOWED_NETWORKS': 'garbage'}):
            with self.subTest(overrides=overrides), patch.dict(os.environ, overrides, clear=True):
                with self.assertRaises(ValueError):
                    icue_http.start_server('control.json', 'status.json', effects)
        for kwargs in ({'port': True}, {'port': -1}, {'host': 'bad host'}, {'host': True},
                       {'allowed_networks': []}, {'allowed_networks': ['bad']}):
            with self.assertRaises(ValueError):
                icue_http.start_server('control.json', 'status.json', effects, **kwargs)

    @unittest.skipUnless(socket.has_ipv6, 'IPv6 is unavailable')
    def test_ipv6_loopback_http(self):
        with tempfile.TemporaryDirectory() as directory:
            server = icue_http.start_server(Path(directory) / 'c', Path(directory) / 's',
                                            effects, host='::1', port=0)
            try:
                conn = http.client.HTTPConnection('::1', server.server_address[1], timeout=2)
                try:
                    conn.request('GET', '/health')
                    response = conn.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertTrue(json.loads(response.read())['ok'])
                finally:
                    conn.close()
            finally:
                server.shutdown()
                server.server_close()

    def test_environment_networks_replace_defaults(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
                'ICUE_HTTP_HOST': '127.0.0.1', 'ICUE_HTTP_ALLOWED_NETWORKS': '::1/128'}):
            server = icue_http.start_server(Path(directory) / 'c', Path(directory) / 's',
                                            effects, port=0)
            try:
                self.assertEqual(server.server_address[0], '127.0.0.1')
                self.assertFalse(icue_http.peer_allowed('127.0.0.1', server.allowed_networks))
            finally:
                server.shutdown()
                server.server_close()


class DriverTests(unittest.TestCase):
    def load_driver(self):
        sdk_module = Mock()
        spec = importlib.util.spec_from_file_location('test_driver',
                                      ROOT / 'windows' / 'scripts' / 'icue-lights.py')
        driver = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'cuesdk': sdk_module}):
            spec.loader.exec_module(driver)
        return driver

    def test_bind_failure_keeps_engine_scheduling(self):
        driver = self.load_driver()
        stop = Mock()
        stop.exists.side_effect = [False, True]
        with patch.object(driver, 'STOP_FLAG', stop), \
             patch.object(driver, 'start_server', side_effect=OSError('address in use')), \
             patch.object(driver.connected, 'wait', return_value=True), \
             patch.object(driver, 'build_rig', return_value=['inert']), \
             patch.object(driver, 'read_control', return_value={}), \
             patch.object(driver, 'lights_on', return_value=(False, False)) as schedule_on, \
             patch.object(driver, 'write_status'), patch.object(driver, 'paint') as paint, \
             patch.object(driver.time, 'sleep'), self.assertLogs(level='ERROR') as logs:
            driver.main()
        schedule_on.assert_called_once()
        paint.assert_called_once()
        self.assertIn('HTTP API unavailable; lighting schedule continues', ' '.join(logs.output))

    def test_stop_closes_http_and_releases_layer(self):
        driver = self.load_driver()
        stop, server = Mock(), Mock()
        stop.exists.return_value = True
        with patch.object(driver, 'STOP_FLAG', stop), \
             patch.object(driver, 'start_server', return_value=server), \
             patch.object(driver.time, 'sleep'):
            driver.main()
        self.assertEqual(server.mock_calls, [unittest.mock.call.shutdown(),
                                             unittest.mock.call.server_close()])
        driver.CueSdk.return_value.set_layer_priority.assert_called_once_with(0)

    def test_interrupt_closes_http_and_releases_layer(self):
        driver = self.load_driver()
        stop, server = Mock(), Mock()
        stop.exists.return_value = False
        with patch.object(driver, 'STOP_FLAG', stop), \
             patch.object(driver, 'start_server', return_value=server), \
             patch.object(driver.connected, 'wait', side_effect=KeyboardInterrupt), \
             patch.object(driver.time, 'sleep'):
            with self.assertRaises(KeyboardInterrupt):
                driver.main()
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()
        driver.CueSdk.return_value.set_layer_priority.assert_called_once_with(0)
