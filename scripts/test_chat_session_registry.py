#!/usr/bin/env python3
"""Run production conversation-ownership tests on macOS without a simulator."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="leaf-chat-registry-") as folder:
    package = pathlib.Path(folder)
    (package / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LeafChatLifecycle", platforms: [.macOS(.v13)],
    targets: [.target(name: "LeafReader"), .testTarget(name: "LeafReaderTests", dependencies: ["LeafReader"])])
''')
    for target, source in [
        ("Sources/LeafReader", "LeafReader/Services/Chat/ChatSessionRegistry.swift"),
        ("Tests/LeafReaderTests", "LeafReaderTests/ChatSessionRegistryTests.swift"),
    ]:
        directory = package / target
        directory.mkdir(parents=True)
        (directory / pathlib.Path(source).name).symlink_to(root / source)
    result = subprocess.run(["swift", "test", "--package-path", str(package), "-j", "1"])
    sys.exit(result.returncode)
