#!/usr/bin/env python3
"""Fetch the pinned sherpa-onnx + onnxruntime iOS XCFrameworks into ThirdParty/sherpa-onnx.

Run once before building (needs network):  python3 scripts/fetch_sherpa_onnx.py
The archives are verified against the SHA-256 values in ThirdParty/dependencies.json.
The frameworks are not committed; the Xcode project links them from ThirdParty/sherpa-onnx.
"""
import hashlib, io, json, os, shutil, sys, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, "ThirdParty", "sherpa-onnx")
with open(os.path.join(ROOT, "ThirdParty", "dependencies.json")) as f:
    pin = json.load(f)["sherpa-onnx"]
ORT = json.load(open(os.path.join(ROOT, "ThirdParty", "dependencies.json")))["onnxruntime"]
# name -> (url, sha256). sherpa-onnx comes from the Swift package's release (built from
# the upstream v1.13.8 tag against onnxruntime 1.28.2 headers); onnxruntime comes from
# the same k2-fsa build that sherpa-onnx's own build-ios.sh downloads. The package's
# bundled onnxruntime is 1.24.4 and fails sherpa-onnx's API-version check at engine
# creation, so it is not used.
ARCHIVES = {
    "sherpa-onnx.xcframework.zip": (f"{pin['swift-package']}/releases/download/{pin['version']}/sherpa-onnx.xcframework.zip",
                                    pin["sherpa-onnx.xcframework.zip.sha256"]),
    "onnxruntime.xcframework.zip": (ORT["source"], ORT["sha256"]),
}
STAMP = os.path.join(DEST, ".fetched")


def fetch(name, sha256):
    url = ARCHIVES[name][0]
    print(f"downloading {url}", flush=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256:
        sys.exit(f"checksum mismatch for {name}: {digest} != {sha256}")
    return data


def main():
    expected = json.dumps({name: sha for name, (_, sha) in ARCHIVES.items()}, sort_keys=True)
    if os.path.isfile(STAMP) and open(STAMP).read() == expected and all(
        os.path.isdir(os.path.join(DEST, n.replace(".zip", ""))) for n in ARCHIVES
    ):
        print(f"sherpa-onnx {pin['version']} already present in {DEST}")
        return
    shutil.rmtree(DEST, ignore_errors=True)
    os.makedirs(DEST)
    for name, (_, sha256) in ARCHIVES.items():
        data = fetch(name, sha256)
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.infolist():
                target = os.path.realpath(os.path.join(DEST, member.filename))
                if not target.startswith(os.path.realpath(DEST) + os.sep):
                    sys.exit(f"unsafe path in {name}: {member.filename}")
            archive.extractall(DEST)
        # One archive nests its framework in a folder; normalize to DEST/<name>.xcframework.
        framework = name.replace(".zip", "")
        if not os.path.isdir(os.path.join(DEST, framework)):
            for current, dirs, _ in os.walk(DEST):
                if framework in dirs:
                    shutil.move(os.path.join(current, framework), os.path.join(DEST, framework))
                    break
        for entry in os.listdir(DEST):
            full = os.path.join(DEST, entry)
            if os.path.isdir(full) and not entry.endswith(".xcframework"):
                shutil.rmtree(full)
    # Both frameworks ship a root module.modulemap; Xcode copies every
    # xcframework's headers into one include/ directory, so the duplicate file
    # fails the build. Leaf only imports the sherpa-onnx module, so the
    # onnxruntime map (which nothing imports) is removed.
    ort = os.path.join(DEST, "onnxruntime.xcframework")
    for slice_dir in os.listdir(ort):
        modulemap = os.path.join(ort, slice_dir, "Headers", "module.modulemap")
        if os.path.isfile(modulemap):
            os.remove(modulemap)
    with open(STAMP, "w") as f:
        f.write(expected)
    print(f"sherpa-onnx {pin['version']} ready in {DEST}")


if __name__ == "__main__":
    main()
