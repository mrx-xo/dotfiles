"""Bounded, trusted-network HTTP transport for the resident lighting driver.

No SDK dependency. HTTP writers serialize; the legacy SSH writer does not share
this lock and can race a read/modify/replace. POST preflights observed status and
acknowledges acceptance, never physical application. See windows/README.md.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import socket
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'shared' / 'lights'))
import schedule  # noqa: E402

DEFAULT_ALLOWED_NETWORKS = ('127.0.0.0/8', '::1/128', '100.64.0.0/10')
MAX_BODY = 8192


def parse_networks(values):
    if isinstance(values, str):
        values = values.split(',')
    try:
        networks = tuple(ipaddress.ip_network(str(value).strip()) for value in values)
    except (TypeError, ValueError) as exc:
        raise ValueError('allowed networks must be comma-separated network CIDRs') from exc
    if not networks:
        raise ValueError('at least one allowed network is required')
    return networks


def peer_allowed(peer, networks):
    address = ipaddress.ip_address(peer)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    return any(address in network for network in parse_networks(networks))


def reject_constant(value):
    raise ValueError('non-finite JSON number')


def finite_number(value):
    # Integers are always finite; avoid float overflow on large JSON integers.
    return type(value) is int or (type(value) is float and math.isfinite(value))


def check_finite(value):
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError('non-finite JSON number')
    if isinstance(value, dict):
        for item in value.values():
            check_finite(item)
    elif isinstance(value, list):
        for item in value:
            check_finite(item)


def decode_object(raw):
    data = json.loads(raw, parse_constant=reject_constant)
    if not isinstance(data, dict):
        raise ValueError('JSON object required')
    check_finite(data)
    return data


def read_object(path):
    with path.open('rb') as stream:
        data = decode_object(stream.read())
        age = max(0.0, time.time() - os.fstat(stream.fileno()).st_mtime)
    return data, age


def read_control(path, effects):
    try:
        control, _ = read_object(path)
    except FileNotFoundError:
        return {'mode': 'rotation', 'preset': 'rotation', 'brightness': 1.0}
    mode = control.get('mode', 'rotation')
    if mode not in ('rotation', 'pinned', 'random'):
        raise ValueError('invalid stored mode')
    if not finite_number(control.get('brightness', 1.0)):
        raise ValueError('invalid stored brightness')
    if not 0 <= control.get('brightness', 1.0) <= 1:
        raise ValueError('invalid stored brightness')
    for key, choices in (('preset', effects.PRESETS), ('effect', effects.EFFECTS)):
        if key in control and (not isinstance(control[key], str) or control[key] not in choices):
            raise ValueError('invalid stored selection')
    if control.get('force') not in (None, 'on', 'off'):
        raise ValueError('invalid stored force')
    if control.get('force_until') is not None and not finite_number(control['force_until']):
        raise ValueError('invalid stored expiry')
    for key in ('fans', 'params'):
        if control.get(key) is not None and not isinstance(control[key], dict):
            raise ValueError('invalid stored settings')
    for color in (control.get('fans') or {}).values():
        if (not isinstance(color, list) or len(color) != 3 or
                any(not finite_number(v) or not 0 <= v <= 255 for v in color)):
            raise ValueError('invalid stored fan color')
    if mode == 'random' and control.get('params'):
        params = control['params']
        if not all(finite_number(v) for v in params.values()):
            raise ValueError('invalid stored random parameters')
        try:
            # Let the effects module own its parameter schema.
            effects.make_parametric(params)(0.5, 0.0)
        except (KeyError, TypeError, ValueError, ArithmeticError) as exc:
            raise ValueError('invalid stored random parameters') from exc
    if mode == 'pinned' and 'effect' not in control:
        raise ValueError('missing stored effect')
    return control


def observed_status(path):
    status, age = read_object(path)
    if (type(status.get('on')) is not bool or
            not isinstance(status.get('effect'), str) or
            not finite_number(status.get('brightness'))):
        raise ValueError('invalid observed status')
    return dict(status, age=age)


def augment(status, control, effects):
    mode = control.get('mode', 'rotation')
    current = ('random' if mode == 'random' else control['effect'] if mode == 'pinned'
               else 'preset: ' + control.get('preset', 'rotation'))
    return dict(status, effect_current=current,
                effect_list=list(effects.EFFECTS) + ['random'] +
                ['preset: ' + name for name in effects.PRESETS],
                descriptions=effects.DESCRIPTIONS)


def validate_patch(patch, effects):
    if set(patch) - {'effect', 'brightness', 'force'}:
        raise ValueError('unknown control key')
    if 'effect' in patch:
        selection = patch['effect']
        choices = list(effects.EFFECTS) + ['random'] + ['preset: ' + p for p in effects.PRESETS]
        if not isinstance(selection, str) or selection not in choices:
            raise ValueError('unknown effect')
    if 'brightness' in patch and not finite_number(patch['brightness']):
        raise ValueError('brightness must be finite numeric input, not boolean')
    if 'force' in patch and patch['force'] not in (None, 'on', 'off'):
        raise ValueError('force must be on, off, or null')


def apply_patch(control, patch, effects):
    control = dict(control)
    if 'effect' in patch:
        name = patch['effect']
        if name == 'random':
            control.update(mode='random', params=effects.random_params())
        elif name.startswith('preset: '):
            control.update(mode='rotation', preset=name[len('preset: '):])
        else:
            control.update(mode='pinned', effect=name)
    if 'brightness' in patch:
        control['brightness'] = max(.01, min(1.0, patch['brightness']))
    if 'force' in patch:
        if patch['force'] is None:
            control.pop('force', None)
            control.pop('force_until', None)
        else:
            control.update(force=patch['force'], force_until=schedule.next_boundary())
    return control


def atomic_write(path, control):
    payload = json.dumps(control, allow_nan=False).encode('utf-8')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + '.',
                                         suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def close_connection(connection):
    try:
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


class LightsServer(ThreadingHTTPServer):
    # Bound both simultaneous workers and slow trickling clients, not just size.
    request_queue_size = 16
    socket_timeout = 2.0
    request_timeout = 5.0
    max_connections = 16
    daemon_threads = False
    block_on_close = True

    def __init__(self, address, handler):
        self.write_lock = threading.Lock()
        self.connections_lock = threading.Lock()
        self.connections = set()
        self.slots = threading.BoundedSemaphore(self.max_connections)
        super().__init__(address, handler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(self.socket_timeout)
        return connection, address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        with self.connections_lock:
            self.connections.add(request)
        try:
            super().process_request(request, client_address)
        except Exception:
            with self.connections_lock:
                self.connections.discard(request)
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.connections_lock:
                self.connections.discard(request)
            self.slots.release()

    def server_close(self):
        with self.connections_lock:
            for connection in self.connections:
                close_connection(connection)
        super().server_close()
        thread = getattr(self, 'serving_thread', None)
        if thread is not None and thread is not threading.current_thread():
            thread.join()


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.deadline = threading.Timer(self.server.request_timeout,
                                         close_connection, args=(self.connection,))
        self.deadline.daemon = True
        self.deadline.start()

    def finish(self):
        self.deadline.cancel()
        try:
            super().finish()
        except OSError:
            pass

    def log_message(self, format, *args):
        pass  # No request data or peer identities in logs.

    def respond(self, code, data):
        body = json.dumps(data, allow_nan=False).encode('utf-8')
        self.close_connection = True
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            pass

    def parse_request(self):
        if not super().parse_request():
            return False
        # Authorize the socket peer before dispatch or any body read.
        # Forwarded headers are intentionally irrelevant.
        if not peer_allowed(self.client_address[0], self.server.allowed_networks):
            self.respond(403, {'error': 'peer not allowed'})
            return False
        return True

    def do_GET(self):
        if self.path == '/health':
            self.respond(200, {'ok': True, 'engine': 'icue-lights'})
        elif self.path == '/status':
            try:
                status = observed_status(self.server.status_file)
                with self.server.write_lock:
                    control = read_control(self.server.control_file, self.server.effects)
                self.respond(200, augment(status, control, self.server.effects))
            except (OSError, ValueError, RecursionError):
                self.respond(503, {'error': 'state unavailable'})
        else:
            self.respond(404, {'error': 'unknown endpoint'})

    def do_POST(self):
        if self.path != '/control':
            self.respond(404, {'error': 'unknown endpoint'})
            return
        if self.headers.get_all('Transfer-Encoding'):
            self.respond(400, {'error': 'transfer-encoding is not supported'})
            return
        lengths = self.headers.get_all('Content-Length', [])
        if not lengths:
            self.respond(411, {'error': 'content-length required'})
            return
        if len(lengths) != 1 or not re.fullmatch(r'[0-9]{1,10}', lengths[0]):
            self.respond(400, {'error': 'invalid content-length'})
            return
        length = int(lengths[0])
        if length > MAX_BODY:
            self.respond(413, {'error': 'body exceeds 8192 bytes'})
            return
        types = self.headers.get_all('Content-Type', [])
        if len(types) != 1 or self.headers.get_content_type() != 'application/json':
            self.respond(415, {'error': 'application/json required'})
            return
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError('incomplete body')
            patch = decode_object(raw)
            validate_patch(patch, self.server.effects)
        except TimeoutError:
            self.respond(408, {'error': 'request timed out'})
            return
        except (ValueError, RecursionError):
            self.respond(400, {'error': 'invalid control patch'})
            return
        except OSError:
            return
        try:
            with self.server.write_lock:
                control = read_control(self.server.control_file, self.server.effects)
                # Capture observed data before committing. Failure cannot mutate control.
                status = observed_status(self.server.status_file)
                updated = apply_patch(control, patch, self.server.effects)
                response = dict(augment(status, updated, self.server.effects), accepted=True)
                atomic_write(self.server.control_file, updated)
            self.respond(200, response)
        except (OSError, ValueError, RecursionError):
            self.respond(503, {'error': 'state unavailable or control write failed'})


def start_server(control_file, status_file, effects_module, host=None, port=None,
                 allowed_networks=None):
    """Start serving in a daemon thread and return the lifecycle handle.

    None arguments read ICUE_HTTP_HOST/PORT/ALLOWED_NETWORKS. Explicit arguments
    override the environment; explicit port=0 supports ephemeral test listeners.
    Environment networks REPLACE defaults. Call shutdown(), then server_close()
    from outside the serving thread before exiting the driver.
    """
    host = os.environ.get('ICUE_HTTP_HOST', '0.0.0.0') if host is None else host
    if not isinstance(host, str):
        raise ValueError('ICUE_HTTP_HOST must be an IP literal')
    try:
        address = ipaddress.ip_address(host)
    except (ValueError, TypeError) as exc:
        raise ValueError('ICUE_HTTP_HOST must be an IP literal') from exc
    if port is None:
        raw_port = os.environ.get('ICUE_HTTP_PORT', '7790')
        if not re.fullmatch(r'[0-9]{1,5}', raw_port) or not 1 <= int(raw_port) <= 65535:
            raise ValueError('ICUE_HTTP_PORT must be 1..65535')
        port = int(raw_port)
    if type(port) is not int or not 0 <= port <= 65535:
        raise ValueError('port must be an integer in 0..65535')
    networks = parse_networks(allowed_networks if allowed_networks is not None else
                             os.environ.get('ICUE_HTTP_ALLOWED_NETWORKS', DEFAULT_ALLOWED_NETWORKS))
    class ConfiguredServer(LightsServer):
        address_family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
    server = ConfiguredServer((str(address), port), Handler)
    server.allowed_networks = networks
    server.control_file = Path(control_file)
    server.status_file = Path(status_file)
    server.effects = effects_module
    server.serving_thread = threading.Thread(target=server.serve_forever,
                                             kwargs={'poll_interval': .1}, daemon=True)
    try:
        server.serving_thread.start()
    except Exception:
        # No serving loop exists to shut down or join if thread creation failed.
        del server.serving_thread
        server.server_close()
        raise
    return server
