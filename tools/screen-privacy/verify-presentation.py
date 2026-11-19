"""Test a real extended display, including Mission Control. Requires a logged-in
Mac with screen capture access. Usage: python3 verify-presentation.py OUTPUT.json
"""
import argparse
import plistlib
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    support = repo / "Wisp/Support"
    with tempfile.TemporaryDirectory(prefix="wisp-display-") as folder:
        stage = Path(folder)
        monitor = stage / "monitor.o"
        receiver = stage / "receiver"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-c", support / "PresentationMonitor.m",
                        "-o", monitor], check=True)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", stage / "cache",
                        "-import-objc-header", support / "PresentationMonitor.h", support / "ScreenPrivacy.swift",
                        support / "PresentationDisplay.swift", Path(__file__).with_name("PresentationDisplayProbe.swift"),
                        monitor, "-o", receiver], check=True)

        def fixture(name):
            # Distinct bundle identities reproduce a meeting client recording
            # another application's output; sharing the receiver identity invalidates this test.
            bundle = stage / (name + ".app")
            binary = bundle / "Contents/MacOS/probe"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(receiver.read_bytes())
            binary.chmod(0o755)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "org.wisp.probe." + name,
                "CFBundleName": name, "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
            }))
            subprocess.run(["codesign", "-s", "-", "--force", bundle], check=True)
            return binary

        result = stage / "result.json"
        subprocess.run([fixture("Presenter"), fixture("Control"), result, receiver], check=True)
        args.output.write_bytes(result.read_bytes())


if __name__ == "__main__":
    main()
