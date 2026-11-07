"""Build the iOS XCTest bundle and run it on a vphone machine."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
HOST = "com.leo.SimpleReader.VPhoneTests"
VPHONE = shutil.which("vphone-launchpad-cli") or "/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli"


def vphone(*args):
    return json.loads(subprocess.check_output([VPHONE, *args]))


def run(machine):
    ios = BUILD / "tools/go-ios"
    if not ios.is_file():
        ios.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["go", "install", "github.com/danielpaulus/go-ios@v1.3.2"],
                       env={**os.environ, "GOBIN": str(ios.parent)}, check=True)

    device = next((vm for vm in vphone("vm", "list") if vm["name"] == machine), None)
    if device is None:
        raise SystemExit(f"Unknown vphone machine: {machine}")
    derived = BUILD / "DerivedData"
    subprocess.run(["xcodebuild", "-quiet", "-project", "SimpleReader.xcodeproj", "-scheme",
                    "SimpleReader", "-destination", "generic/platform=iOS", "-derivedDataPath",
                    derived, "CODE_SIGNING_ALLOWED=NO", "build-for-testing"], cwd=ROOT, check=True)

    runs = BUILD / "vphone-results"
    runs.mkdir(exist_ok=True)
    result = Path(tempfile.mkdtemp(prefix="run-", dir=runs))
    log = result / "xctest.log"
    print(f"XCTest log: {log}", flush=True)
    with ExitStack() as cleanup:
        stage = Path(cleanup.enter_context(tempfile.TemporaryDirectory(dir=BUILD)))
        app = stage / "Payload/SimpleReader.app"
        source = derived / "Build/Products/Debug-iphoneos/SimpleReader.app"
        shutil.copytree(source, app, symlinks=True, ignore=shutil.ignore_patterns("*.dSYM"))
        tests = app / "PlugIns/SimpleReaderTests.xctest"
        for bundle, identifier in [(app, HOST), (tests, HOST + ".Tests")]:
            subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string", identifier,
                            bundle / "Info.plist"], check=True)
        ipa = stage / "tests.ipa"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", app.parent, ipa], check=True)

        if device["state"] == "stopped":
            vphone("vm", "start", machine, "--headless")
            cleanup.callback(vphone, "vm", "stop", machine)
        vphone("vm", "wait", machine, "--timeout", "120")
        # vphoned answers before SpringBoard finishes starting on a cold boot.
        for attempt in range(3):
            try:
                vphone("guest", "unlock", machine, "--timeout", "20")
                break
            except subprocess.CalledProcessError:
                if attempt == 2:
                    raise
                time.sleep(2)
        guest_path = f"/private/var/tmp/SimpleReader-{stage.name}.ipa"
        vphone("guest", "push", machine, ipa, guest_path)
        vphone("guest", "rpc", machine, "apps.install", json.dumps({"path": guest_path}))

        udid = device["udid"]
        options = [f"--udid={udid}", "--tunnel-info-port=" + os.getenv("VPHONE_TUNNEL_PORT", "60221")]
        tunnel_log = cleanup.enter_context((result / "tunnel.log").open("w"))
        tunnel = subprocess.Popen([ios, "tunnel", "start", "--userspace",
                                   f"--pair-record-path={stage}", *options],
                                  stdout=tunnel_log, stderr=subprocess.STDOUT)

        def stop_tunnel():
            tunnel.terminate()
            tunnel.wait(timeout=10)

        cleanup.callback(stop_tunnel)
        for _ in range(30):
            if tunnel.poll() is not None:
                raise SystemExit(f"Tunnel exited. See {tunnel_log.name}")
            listing = subprocess.run([ios, "tunnel", "ls", *options], capture_output=True)
            if listing.returncode == 0 and any(t["udid"] == udid for t in json.loads(listing.stdout)):
                break
            time.sleep(1)
        else:
            raise SystemExit(f"Device tunnel unavailable. See {tunnel_log.name}")

        with (result / "runner.log").open("w") as runner_log:
            completed = subprocess.run(
                [ios, "runtest", *options, "--xctest", f"--test-runner-bundle-id={HOST}",
                 "--xctest-config=SimpleReaderTests.xctest",
                 "--env=DYLD_INSERT_LIBRARIES=/System/Developer/usr/lib/libXCTestBundleInject.dylib",
                 f"--log-output={log}"],
                stdout=runner_log, stderr=subprocess.STDOUT, timeout=300)
        output = log.read_text(errors="replace") if log.exists() else ""
        summary = re.search(r"Test Suite 'All tests' (passed|failed) at [^\n]+\n\s*Executed (\d+) tests?,[^\n]+", output)
        if not summary:
            raise SystemExit(f"XCTest did not finish. See {result}/runner.log")
        for line in output.splitlines():
            if ": error: -[" in line:
                print(line)
        print(summary.group(), flush=True)
        return int(completed.returncode != 0 or summary[1] != "passed" or int(summary[2]) == 0)


if __name__ == "__main__":
    sys.exit(run(sys.argv[1] if len(sys.argv) > 1 else "iphone-16"))
