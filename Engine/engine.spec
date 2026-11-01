from pathlib import Path
import os
root = Path(SPECPATH)
a = Analysis(
    [str(root / 'bridge.py')],
    pathex=[str(root / 'vendor/Sony-PMCA-RE')],
    binaries=[(os.environ.get('PMCA_LIBUSB', '/opt/homebrew/lib/libusb-1.0.dylib'), '.')],
    datas=[(str(root / 'vendor/Sony-PMCA-RE/certs'), 'certs'),
           (str(root / 'vendor/Sony-PMCA-RE/updatershell/fdat'), 'updatershell/fdat'),
           (str(root / 'licenses'), 'licenses')],
    excludes=['tkinter', 'PyInstaller'],
    # tlslite's deprecated-class wrappers inspect caller source during AES setup.
    module_collection_mode={'tlslite': 'pyz+py'},
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='pmca-engine',
          console=True, target_arch='arm64', upx=False)
coll = COLLECT(exe, a.binaries, a.datas, name='pmca-engine', upx=False)
app = BUNDLE(coll, name='PMCAEngine.app', bundle_identifier='local.pmca-swift.engine',
             info_plist={'LSUIElement': True, 'LSMinimumSystemVersion': '27.0', 'NSRemovableVolumesUsageDescription': 'PMCA Swift needs access to the camera USB storage interface to read and update language settings.'})
