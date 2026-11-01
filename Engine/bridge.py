"""Restricted JSON interface to unmodified Sony-PMCA-RE. No general shell API."""
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import traceback
import tempfile

import socket
import struct

ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).parent))
if not getattr(sys, 'frozen', False):
    sys.path.insert(0, str(ROOT / 'vendor' / 'Sony-PMCA-RE'))

from pmca.platform.backup import BackupInterface, BackupPatchDataInterface
from pmca.platform.properties import FirmwareVersionProperty
from pmca.platform.tweaks import RecLimitTweak, RecLimit4kTweak, BooleanBackupTweak

LAYOUT = 'sony-pmca-35-v1'
ENGINE_REVISION = 'a82f5baaa8e9c3d9f28f94699e860fb2e48cc8e0'


TWEAKS = {
    'recLimit': lambda backup: RecLimitTweak(backup),
    'recLimit4k': lambda backup: RecLimit4kTweak(backup),
    'palNtscSelector': lambda backup: BooleanBackupTweak(backup, 'palNtscSelector'),
}


def read_tweaks(backup):
    result = {}
    for key, factory in TWEAKS.items():
        tweak = factory(backup)
        if tweak.available():
            result[key] = {'enabled': tweak.enabled(), 'raw': list(backup.readProp(key))}
    return result


def validate_tweaks(values):
    if not isinstance(values, dict) or any(key not in TWEAKS or type(value) is not bool for key, value in values.items()):
        raise ValueError('Unsupported camera tweak.')
    return values


def validate_languages(values):
    if not isinstance(values, list) or len(values) != 35:
        raise ValueError('A language selection must contain exactly 35 bytes.')
    if any(type(v) is not int or v not in (1, 2) for v in values):
        raise ValueError('Language bytes must be 01 (enabled) or 02 (disabled).')
    if 1 not in values:
        raise ValueError('Keep at least one language enabled.')
    return values


def validate_request(request):
    if not isinstance(request, dict) or request.get('operation') not in ('read', 'apply'):
        raise ValueError('Unsupported operation.')
    if request.get('mode') not in ('service', 'updater'):
        raise ValueError('Choose service or updater mode.')
    if request['operation'] == 'apply':
        validate_languages(request.get('languages'))
        validate_tweaks(request.get('tweaks', {}))
        expected = request.get('expected', {})
        if not isinstance(expected, dict):
            raise ValueError('Read and back up the target camera before applying changes.')
        validate_languages(expected.get('languages'))
        for key in ('model', 'modelCode', 'serial', 'region'):
            if not isinstance(expected.get(key), str) or not expected[key]:
                raise ValueError('The target camera identity is incomplete.')
    return request


def snapshot(patch, firmware):
    backup = BackupInterface(patch)
    values = validate_languages(list(backup.readProp('language')))
    data = patch.file.getvalue()
    return {
        'layout': LAYOUT,
        'model': backup.readProp('modelName').decode('latin1').rstrip('\0'),
        'modelCode': backup.readProp('modelCode').hex(),
        'serial': backup.readProp('serialNumber').hex(),
        'region': backup.getRegion(),
        'firmware': firmware,
        'languages': values,
        'tweaks': read_tweaks(backup),
        # Match upstream readback: the first 0x100 bytes are volatile header data.
        'fingerprint': hashlib.sha256(data[0x100:patch.getSize()]).hexdigest(),
        'backupBase64': base64.b64encode(data).decode('ascii'),
        'engineRevision': ENGINE_REVISION,
    }


def check_target(current, expected):
    for key in ('model', 'modelCode', 'serial', 'region', 'firmware', 'languages'):
        if current.get(key) != expected.get(key):
            raise ValueError('The camera identity or language settings changed after the last reading. Read the camera again before applying.')


def check_preset(current, source):
    if not isinstance(source, dict) or source.get('layout') != LAYOUT:
        raise ValueError('This preset uses an unsupported language layout.')
    validate_languages(source.get('languages'))
    if source.get('model') != current['model']:
        raise ValueError('This preset was saved from a different camera model.')
    if source.get('serial') == current['serial'] and source.get('firmware') == current['firmware']:
        return
    if not source.get('firmware') or source['firmware'] != current.get('firmware'):
        raise ValueError('Copying between cameras requires a matching, known firmware version.')


def transact(backend, request, state):
    patch = BackupPatchDataInterface(backend)
    try:
        firmware = FirmwareVersionProperty(backend).get()
    except Exception:
        firmware = None
    current = snapshot(patch, firmware)
    if request['operation'] == 'read':
        return current
    # Always patch the freshly read backup, preserving unrelated changes. The full
    # payload includes live camera state and is not a stable concurrency token.
    check_target(current, request['expected'])
    if request.get('preset') is not None:
        check_preset(current, request['preset'])
    values = validate_languages(request['languages'])
    requested_tweaks = validate_tweaks(request.get('tweaks', {}))
    expected_tweaks = request['expected'].get('tweaks') or {}
    for key in requested_tweaks:
        if key not in current['tweaks']:
            raise ValueError('This camera does not support the requested tweak: ' + key)
        if current['tweaks'][key] != expected_tweaks.get(key):
            raise ValueError('The camera tweak changed after the last reading. Read the camera again before applying.')
    changes = {key: value for key, value in requested_tweaks.items() if value != current['tweaks'][key]['enabled']}
    if values == current['languages'] and not changes:
        return current
    backup = BackupInterface(patch)
    if values != current['languages']:
        backup.writeProp('language', bytes(values))
    for key, value in changes.items():
        TWEAKS[key](backup).setEnabled(value)
    # Preserve upstream checksum, read-only attribute restoration, and readback.
    patch.setProtection(True)
    state['writeAttempted'] = True
    patch.apply()
    verified = snapshot(BackupPatchDataInterface(backend), firmware)
    if verified['languages'] != values:
        raise RuntimeError('Language readback did not match. Keep the saved backup and read the camera again.')
    for key, value in changes.items():
        if verified['tweaks'].get(key, {}).get('enabled') != value:
            raise RuntimeError('Camera tweak readback did not match: ' + key)
    for key in ('model', 'modelCode', 'serial', 'region'):
        if verified[key] != current[key]:
            raise RuntimeError('Camera identity changed during verification.')
    return verified


def configure_usb():
    import usb.backend.libusb1
    lib = ROOT / 'libusb-1.0.dylib'
    if getattr(sys, 'frozen', False) and not lib.exists():
        raise RuntimeError('The app is missing its bundled USB library.')
    backend = usb.backend.libusb1.get_backend(find_library=lambda _: str(lib)) if lib.exists() else usb.backend.libusb1.get_backend()
    if backend is None:
        raise RuntimeError('The bundled USB library could not be loaded.')
    backend.lib.libusb_set_debug(backend.ctx, 3)
    return backend


def run_camera(request, state):
    from pmca.commands.usb import senserShellCommand, updaterShellCommand
    from pmca.platform.backend.senser import SenserPlatformBackend
    from pmca.platform.backend.usb import UsbPlatformBackend
    result = []

    def complete(device):
        backend = SenserPlatformBackend(device) if request['mode'] == 'service' else UsbPlatformBackend(device)
        backend.start()
        try:
            result.append(transact(backend, request, state))
        finally:
            backend.stop()

    configure_usb()
    if request['mode'] == 'service':
        senserShellCommand(driverName='libusb', complete=complete)
    else:
        updaterShellCommand(driverName='libusb', complete=complete)
    if not result:
        raise RuntimeError('The camera session did not start. Check the activity log, USB mode, and model compatibility. Reconnect the camera before trying again.')
    return result[0]


@contextlib.contextmanager
def exclusive_camera():
    import fcntl
    import stat
    fd = os.open('/private/var/run/pmca-swift-camera.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
            raise RuntimeError('The camera lock file has unexpected ownership.')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another PMCA Swift operation is using the camera.')
        yield
    finally:
        os.close(fd)


def describe_error(exc):
    current = exc
    while current is not None:
        if type(current).__name__ == 'USBError':
            return ('Camera USB access failed: %s (libusb %s). '
                    'Disconnect the session, reconnect the camera in Mass Storage mode, and read again. '
                    'If macOS reports a privacy denial, check PMCA Swift’s access in Privacy & Security. '
                    'Native USB details are in Activity.'
                    % (current, getattr(current, 'backend_error_code', 'unknown')))
        current = current.__cause__ or current.__context__
    return str(exc) or type(exc).__name__


def receive_message(connection):
    def read_exact(size):
        data = bytearray()
        while len(data) < size:
            chunk = connection.recv(size - len(data))
            if not chunk:
                raise EOFError('The app disconnected.')
            data.extend(chunk)
        return data
    size, = struct.unpack('!I', read_exact(4))
    if size > 65536:
        raise ValueError('Invalid request size.')
    return json.loads(read_exact(size))


def send_message(connection, response):
    data = json.dumps(response).encode()
    connection.sendall(struct.pack('!I', len(data)) + data)


def install_apk(path):
    """Install only the APK staged by the GUI beside its private session socket."""
    import stat
    from pmca.apk import ApkParser
    from pmca.commands.usb import installCommand
    if path is None:
        raise ValueError('Choose an APK file before installing.')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 128 * 1024 * 1024:
            raise ValueError('Choose an APK file no larger than 128 MB.')
        # Copy once so validation and installation use the same bytes.
        apk = io.BytesIO(source.read(128 * 1024 * 1024 + 1))
    parser = ApkParser(apk)
    package = parser.getPackageName()
    parser.getVersionCode()
    if not package:
        raise ValueError('The APK has no application package name.')
    apk.seek(0)
    configure_usb()
    result = io.StringIO()
    installCommand(driverName='libusb', apkFile=apk, outFile=result)
    # Upstream returns without raising for unsupported cameras or failed discovery.
    # Only its completed installation path writes a result to outFile.
    if not result.getvalue():
        raise RuntimeError('PMCA did not complete installation. Check Activity for camera compatibility or connection details.')
    json.loads(result.getvalue())
    return package


def serve_camera(connection, log, apk_path=None):
    """Keep upstream's callback alive, exactly as the original tweak dialog does."""
    from pmca.commands.usb import senserShellCommand, updaterShellCommand
    from pmca.platform.backend.senser import SenserPlatformBackend
    from pmca.platform.backend.usb import UsbPlatformBackend
    state = {'writeAttempted': False}
    disconnected = False
    entered = False

    def reply(response):
        response['log'] = log.getvalue()[-100000:]
        log.seek(0)
        log.truncate()
        send_message(connection, response)

    try:
        incoming = receive_message(connection)
        if isinstance(incoming, dict) and incoming.get('operation') == 'install':
            with native_usb_log(log):
                package = install_apk(apk_path)
            reply({'ok': True, 'installedPackage': package})
            return
        request = validate_request(incoming)
        if request['operation'] != 'read':
            raise ValueError('Start a connection by reading the camera.')
        mode = request['mode']

        def complete(device):
            nonlocal request, disconnected, entered
            entered = True
            backend = SenserPlatformBackend(device) if mode == 'service' else UsbPlatformBackend(device)
            backend.start()
            try:
                while True:
                    state['writeAttempted'] = False
                    with native_usb_log(log):
                        result = transact(backend, request, state)
                    print('PMCA session remains connected in %s mode; waiting for Read, Apply, or Disconnect.' % mode)
                    reply({'ok': True, 'snapshot': result})
                    request = receive_message(connection)
                    if request == {'operation': 'disconnect'}:
                        disconnected = True
                        return
                    request = validate_request(request)
                    if request['mode'] != mode:
                        raise ValueError('Disconnect before changing the camera connection mode.')
            finally:
                backend.stop()

        configure_usb()
        command = senserShellCommand if mode == 'service' else updaterShellCommand
        command(driverName='libusb', complete=complete)
        if not entered:
            raise RuntimeError('PMCA could not start a camera session. Reconnect in Mass Storage mode and try again.')
        if disconnected:
            reply({'ok': True})  # Only acknowledge after upstream exits service mode.
    except (EOFError, BrokenPipeError, ConnectionResetError):
        pass  # Returning through the upstream callback still ends the camera session.
    except Exception as exc:
        traceback.print_exc(file=log)
        try:
            reply({'ok': False, 'error': describe_error(exc), 'writeAttempted': state['writeAttempted']})
        except OSError:
            pass


def session_main(path):
    if os.geteuid() != 0:
        raise PermissionError('Administrator authorization is required.')
    log = io.StringIO()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(path)
        with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log), exclusive_camera():
            serve_camera(connection, log, Path(path).parent / 'application.apk')


@contextlib.contextmanager
def native_usb_log(log):
    # libusb writes directly to C stderr, bypassing redirect_stderr(StringIO).
    # Keep those details out of JSON stdout and include them in the activity log.
    import ctypes
    libc = ctypes.CDLL(None)
    previous = os.dup(2)
    with tempfile.TemporaryFile(mode='w+b') as capture:
        os.dup2(capture.fileno(), 2)
        try:
            yield
        finally:
            libc.fflush(None)
            os.dup2(previous, 2)
            os.close(previous)
            capture.seek(0)
            native = capture.read().decode('utf-8', errors='replace')
            if native:
                log.write('\nNative USB diagnostics:\n' + native[-50000:])


def verify_installer_tls(server):
    """Exercise a legacy AES-CBC TLS connection inside the frozen runtime, without USB."""
    import threading
    import tlslite
    from pmca.marketserver.server import TLSConnection
    settings = tlslite.HandshakeSettings()
    settings.minVersion = settings.maxVersion = (3, 1)
    settings.cipherNames = ['aes128']
    settings.keyExchangeNames = ['rsa']
    client_socket, server_socket = socket.socketpair()
    client_socket.settimeout(5)
    server_socket.settimeout(5)
    errors = []

    def respond():
        try:
            connection = TLSConnection(server_socket)
            connection.handshakeServer(certChain=server.certChain, privateKey=server.privateKey, settings=settings)
            if connection.read(4, 4) != b'ping':
                raise RuntimeError('Installer TLS request self-test failed.')
            connection.write(b'pong')
        except Exception as exc:
            errors.append(exc)
        finally:
            server_socket.close()

    worker = threading.Thread(target=respond, daemon=True)
    worker.start()
    try:
        connection = TLSConnection(client_socket)
        connection.handshakeClientCert(settings=settings)
        connection.write(b'ping')
        if connection.read(4, 4) != b'pong':
            raise RuntimeError('Installer TLS response self-test failed.')
    finally:
        client_socket.close()
        worker.join(6)
    if worker.is_alive():
        raise RuntimeError('Installer TLS self-test timed out.')
    if errors:
        raise errors[0]


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--session':
        session_main(sys.argv[2])
        return
    state = {'writeAttempted': False}
    log = io.StringIO()
    try:
        if len(sys.argv) == 2 and sys.argv[1] == '--self-test':
            with contextlib.redirect_stdout(log):
                configure_usb()
                from pmca.commands.usb import importDriver, scriptRoot
                from pmca.marketserver.server import LocalMarketServer
                with LocalMarketServer(str(Path(scriptRoot) / 'certs/localtest.me.pem'), port=0) as server:
                    pass
                from tlslite.utils.cipherfactory import createAES
                key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
                iv = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
                plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
                expected = bytes.fromhex('7649abac8119b246cee98e9b12e9197d')
                encrypted = createAES(key, iv, ['python']).encrypt(plain)
                if encrypted != expected or createAES(key, iv, ['python']).decrypt(encrypted) != plain:
                    raise RuntimeError('Installer AES self-test failed.')
                verify_installer_tls(server)
                print('Application installer AES and TLS handshake verified')
                with importDriver('libusb'):
                    pass
            print(json.dumps({'ok': True, 'log': log.getvalue(), 'engineRevision': ENGINE_REVISION, 'architecture': __import__('platform').machine()}))
            return
        if len(sys.argv) != 2 or len(sys.argv[1]) > 65536:
            raise ValueError('Invalid request size.')
        request = validate_request(json.loads(base64.b64decode(sys.argv[1], validate=True)))
        if os.geteuid() != 0:
            raise PermissionError('Use the app’s camera buttons to authorize USB access with macOS.')
        with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log), native_usb_log(log), exclusive_camera():
            print('USB authorization: effective user ID %d' % os.geteuid())
            result = run_camera(request, state)
        response = {'ok': True, 'snapshot': result}
    except Exception as exc:
        traceback.print_exc(file=log)
        response = {'ok': False, 'error': describe_error(exc), 'writeAttempted': state['writeAttempted']}
    response['log'] = log.getvalue()[-100000:]
    print(json.dumps(response), flush=True)
    if sys.argv[1:] == ['--self-test'] and not response['ok']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
