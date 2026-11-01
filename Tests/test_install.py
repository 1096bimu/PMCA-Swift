import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Engine'))
import bridge


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.apk = Path(self.temp.name) / 'application.apk'
        self.apk.write_bytes(b'APK fixture')
        self.parser = Mock()
        self.parser.getPackageName.return_value = 'com.example.camera'
        self.parser.getVersionCode.return_value = 1

    def run_install(self, command):
        with patch('pmca.apk.ApkParser', return_value=self.parser), patch('pmca.commands.usb.installCommand', command), patch.object(bridge, 'configure_usb'):
            return bridge.install_apk(self.apk)

    def test_passes_validated_bytes_to_upstream_and_requires_completion(self):
        def install(**args):
            self.assertEqual(args['driverName'], 'libusb')
            self.assertEqual(args['apkFile'].read(), b'APK fixture')
            json.dump({'device': 'test'}, args['outFile'])
        self.assertEqual(self.run_install(install), 'com.example.camera')

    def test_upstream_no_device_or_unsupported_is_not_success(self):
        with self.assertRaisesRegex(RuntimeError, 'did not complete'):
            self.run_install(lambda **args: None)

    def test_upstream_failure_is_reported(self):
        with self.assertRaisesRegex(RuntimeError, 'camera rejected'):
            self.run_install(Mock(side_effect=RuntimeError('camera rejected')))

    def test_invalid_apk_does_not_start_usb(self):
        with patch.object(bridge, 'configure_usb') as usb:
            with self.assertRaises(Exception):
                bridge.install_apk(self.apk)
            usb.assert_not_called()

    def test_symlink_is_rejected(self):
        link = self.apk.with_name('linked.apk')
        link.symlink_to(self.apk)
        with self.assertRaises(OSError):
            bridge.install_apk(link)

    def test_empty_file_is_rejected(self):
        self.apk.write_bytes(b'')
        with self.assertRaises(ValueError):
            bridge.install_apk(self.apk)


if __name__ == '__main__': unittest.main()
