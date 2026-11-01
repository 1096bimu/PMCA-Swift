"""Exercise the real PMCA backup parser/writer against a simulated camera."""
import base64
import copy
import io
import json
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Engine'))
import bridge
from pmca.backup import BackupFile
from pmca.platform.backup import BackupInterface, BackupPatchDataInterface


def fixture():
    properties = {
        0x003e0005: b'ILCE-TEST'.ljust(16, b'\0'),
        0x00e70000: b'ABCDE',
        0x00e70001: b'SAFE',
        0x00e70003: b'1234',
        0x003c0373: b'\x00', 0x003c0374: b'\x1d', 0x003c0375: b'\x32',
        0x003c04b6: b'\x2c\x01', 0x01070148: b'\x00',
    }
    properties.update({0x010d008f + i: bytes([1 if i < 3 else 2]) for i in range(35)})
    counts = {s: max((p & 0xffff) + 1 for p in properties if p >> 16 == s) for s in {p >> 16 for p in properties}}
    subsystems = 0x10e
    total = sum(counts.values())
    offset = 0x100 + 6 * subsystems + 5 * total
    data = bytearray(offset)
    cursor = 0
    for s in range(subsystems):
        count = counts.get(s, 0)
        struct.pack_into('<HI', data, 0x100 + s * 6, count, cursor)
        for i in range(count):
            key = (s << 16) | i
            attr = 1 if key in properties else 0
            ptr = 0xffffffff
            if key in properties:
                value = properties[key]
                ptr = (len(value) << 24) | len(data)
                data.extend(value)
            struct.pack_into('<BI', data, 0x100 + 6 * subsystems + (cursor + i) * 5, attr, ptr)
        cursor += count
    data[12:16] = b'BK2\0'
    struct.pack_into('<IIII', data, 16, subsystems, total, offset, len(data) - offset)
    data[0xc0:0xe0] = b'TEST_J1'.ljust(32, b'\0')
    struct.pack_into('<I', data, 0x20, sum(data[:0x20] + data[0x24:]))
    return bytes(data)


class Camera:
    def __init__(self):
        self.data = fixture()
        self.writes = []
        self.corrupt = False

    def getBackupData(self):
        return self.data

    def setBackupData(self, data):
        self.writes.append(data)
        if not self.corrupt:
            self.data = data

    def readFile(self, path, file):
        assert path == '/setting/updater/dat4'
        file.write(b'\x10\x03')


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.camera = Camera()
        self.state = {'writeAttempted': False}
        self.current = bridge.transact(self.camera, {'operation': 'read'}, self.state)
        self.request = {'operation': 'apply', 'mode': 'service', 'languages': [1, 2, 1, 1] + [2] * 31,
                        'expected': {k: self.current[k] for k in ('model', 'modelCode', 'serial', 'region', 'firmware', 'languages', 'tweaks')}}

    def test_read_captures_original_and_does_not_write(self):
        self.assertEqual(self.camera.writes, [])
        self.assertEqual(base64.b64decode(self.current['backupBase64']), self.camera.data)
        self.assertEqual(self.current['firmware'], '3.10')
        self.assertEqual(self.current['languages'], [1] * 3 + [2] * 32)

    def test_apply_preserves_every_other_property_and_restores_attributes(self):
        original = BackupFile(io.BytesIO(self.camera.data))
        result = bridge.transact(self.camera, self.request, self.state)
        changed = BackupFile(io.BytesIO(self.camera.data))
        self.assertEqual(result['languages'], self.request['languages'])
        self.assertTrue(self.state['writeAttempted'])
        self.assertEqual(len(self.camera.writes), 2)
        for key, prop in original.listProperties():
            updated = changed.getProperty(key)
            self.assertEqual(prop.attr, updated.attr)
            if not 0x010d008f <= key < 0x010d008f + 35:
                self.assertEqual(prop, updated)
        self.assertEqual(changed.getId1(), 1)

    def test_noop_does_not_write(self):
        self.request['languages'] = self.current['languages']
        bridge.transact(self.camera, self.request, self.state)
        self.assertEqual(self.camera.writes, [])

    def test_changed_languages_block_write(self):
        self.request['expected']['languages'] = [1] * 35
        with self.assertRaisesRegex(ValueError, 'changed'):
            bridge.transact(self.camera, self.request, self.state)
        self.assertFalse(self.state['writeAttempted'])
        self.assertEqual(self.camera.writes, [])

    def test_unrelated_camera_changes_are_preserved_without_blocking_apply(self):
        file = io.BytesIO(self.camera.data)
        backup = BackupFile(file)
        backup.setProperty(0x00e70001, b'LIVE')
        backup.updateChecksum()
        self.camera.data = file.getvalue()
        result = bridge.transact(self.camera, self.request, self.state)
        self.assertEqual(result['languages'], self.request['languages'])
        self.assertEqual(BackupFile(io.BytesIO(self.camera.data)).getProperty(0x00e70001).data, b'LIVE')

    def test_missing_original_languages_blocks_request(self):
        del self.request['expected']['languages']
        with self.assertRaises(ValueError):
            bridge.validate_request(self.request)

    def test_tweak_only_apply_and_original_gui_off_values(self):
        self.request['languages'] = self.current['languages']
        self.request['tweaks'] = dict.fromkeys(bridge.TWEAKS, True)
        result = bridge.transact(self.camera, self.request, self.state)
        self.assertEqual(result['languages'], self.current['languages'])
        self.assertEqual(result['tweaks']['recLimit']['raw'], [13, 1, 0])
        self.assertEqual(result['tweaks']['recLimit4k']['raw'], [255, 127])
        self.assertEqual(result['tweaks']['palNtscSelector']['raw'], [1])
        self.request['expected'] = result
        self.request['tweaks'] = dict.fromkeys(bridge.TWEAKS, False)
        restored = bridge.transact(self.camera, self.request, self.state)
        self.assertEqual(restored['tweaks'], self.current['tweaks'])

    def test_unselected_tweaks_remain_unchanged(self):
        self.request['tweaks'] = {'palNtscSelector': True}
        result = bridge.transact(self.camera, self.request, self.state)
        self.assertTrue(result['tweaks']['palNtscSelector']['enabled'])
        for key in ('recLimit', 'recLimit4k'):
            self.assertEqual(result['tweaks'][key], self.current['tweaks'][key])

    def test_stale_tweak_blocks_before_writing(self):
        self.request['tweaks'] = {'recLimit': True}
        self.request['expected']['tweaks'] = {}
        with self.assertRaisesRegex(ValueError, 'changed'):
            bridge.transact(self.camera, self.request, self.state)
        self.assertEqual(self.camera.writes, [])

    def test_unknown_or_non_boolean_tweak_is_rejected(self):
        for tweaks in ({'unknown': True}, {'recLimit': 1}, {'recLimit': 'yes'}, []):
            self.request['tweaks'] = tweaks
            with self.assertRaises(ValueError):
                bridge.validate_request(self.request)

    def test_wrong_camera_blocks_write(self):
        self.request['expected']['serial'] = 'another camera'
        with self.assertRaises(ValueError):
            bridge.transact(self.camera, self.request, self.state)
        self.assertEqual(self.camera.writes, [])

    def test_invalid_bytes_are_rejected(self):
        for data in ([1] * 34, [1] * 36, [2] * 35, [0] + [1] * 34, [True] + [1] * 34, '01' * 35):
            with self.subTest(data=data), self.assertRaises(ValueError):
                bridge.validate_languages(data)

    def test_cross_camera_requires_same_model_and_firmware(self):
        source = copy.deepcopy(self.current)
        source['serial'] = 'second camera'
        bridge.check_preset(self.current, source)
        for key, value in [('model', 'OTHER'), ('firmware', '4.00'), ('firmware', None), ('layout', 'unknown')]:
            bad = dict(source, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                bridge.check_preset(self.current, bad)

    def test_bad_preset_blocks_write(self):
        self.request['preset'] = dict(self.current, model='OTHER')
        with self.assertRaises(ValueError):
            bridge.transact(self.camera, self.request, self.state)
        self.assertEqual(self.camera.writes, [])

    def test_failed_readback_reports_attempted_write(self):
        self.camera.corrupt = True
        with self.assertRaisesRegex(Exception, 'Cannot overwrite backup'):
            bridge.transact(self.camera, self.request, self.state)
        self.assertTrue(self.state['writeAttempted'])

    def test_checksum_corruption_is_rejected_before_writing(self):
        self.camera.data = self.camera.data[:-1] + b'\x07'
        with self.assertRaisesRegex(Exception, 'checksum'):
            bridge.transact(self.camera, self.request, self.state)
        self.assertFalse(self.state['writeAttempted'])

    def test_only_restricted_operations_are_accepted(self):
        for request in ({'operation': 'shell', 'mode': 'service'}, {'operation': 'read', 'mode': 'other'}, {'operation': 'apply', 'mode': 'service', 'languages': [1]*35}):
            with self.subTest(request=request), self.assertRaises(ValueError):
                bridge.validate_request(request)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--export-fixture':
        camera = Camera()
        snapshot = bridge.transact(camera, {'operation': 'read'}, {'writeAttempted': False})
        Path(sys.argv[2]).write_text(json.dumps(snapshot))
    else:
        unittest.main()
