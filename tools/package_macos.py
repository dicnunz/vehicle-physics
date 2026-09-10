#!/usr/bin/env python3
"""Package the Vehicle Physics Godot project as a self-contained local Apple Silicon app.

This adapts the proven direct-engine bundle layout. The actual Godot process is
CFBundleExecutable, and discovers its sibling Resources/VehiclePhysics.pck.
No launcher shell, external engine install, source directory or network is needed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".build"
APP_NAME = "Vehicle Physics"
EXECUTABLE = "VehiclePhysics"
BUNDLE_ID = "local.provingground.simulator"
DEFAULT_DEST = WORK / "dist" / f"{APP_NAME}.app"
EXTRA_ASSETS = {}

# Generated inside the isolated build directory. Notices come from the exact
# bundled engine, including every third-party component reported by that engine.
LICENSE_EXTRACTOR = r'''extends SceneTree
func _initialize() -> void:
    var args: PackedStringArray = OS.get_cmdline_user_args()
    if args.size() != 1:
        push_error("Expected one license output directory")
        quit(2)
        return
    var output: String = args[0]
    DirAccess.make_dir_recursive_absolute(output)
    var mit: FileAccess = FileAccess.open(output.path_join("Godot-MIT.txt"), FileAccess.WRITE)
    mit.store_string(Engine.get_license_text() + "\n")
    mit.close()
    var licenses: Dictionary = Engine.get_license_info()
    var components: Array = Engine.get_copyright_info()
    var names: Array = licenses.keys()
    names.sort()
    var notices: FileAccess = FileAccess.open(output.path_join("Godot-Third-Party-Notices.txt"), FileAccess.WRITE)
    notices.store_string("Godot " + Engine.get_version_info().string + "\n\n")
    for component: Dictionary in components:
        notices.store_string(str(component.get("name", "Unnamed component")) + "\n")
        for part: Dictionary in component.get("parts", []):
            for copyright: String in part.get("copyright", []):
                notices.store_string(copyright + "\n")
            for filename: String in part.get("files", []):
                notices.store_string("File: " + filename + "\n")
            notices.store_string("License: " + str(part.get("license", "")) + "\n")
        notices.store_string("\n")
    for name: String in names:
        notices.store_string("\n===== " + name + " =====\n\n" + str(licenses[name]) + "\n")
    notices.close()
    var data: FileAccess = FileAccess.open(output.path_join("Godot-License-Data.json"), FileAccess.WRITE)
    data.store_string(JSON.stringify({"engine": Engine.get_version_info(), "licenses": licenses, "components": components}, "\t"))
    data.close()
    print("LICENSES_EXTRACTED ", licenses.size(), " licenses; ", components.size(), " components")
    quit(0)
'''


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def inventory(project: Path) -> dict[str, str]:
    return {
        str(path.relative_to(project)): digest(path)
        for path in sorted(project.rglob("*"))
        if path.is_file()
        and not any(part in {".godot", ".git", ".build", ".DS_Store", "__pycache__"}
                    for part in path.relative_to(project).parts)
    }


def run(command: list[str | Path], log: Path, *, cwd: Path | None = None,
        timeout: int = 300) -> str:
    result = subprocess.run([str(part) for part in command], cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(result.stdout)
    # Godot may return zero after reporting a script parse error.
    if result.returncode or re.search(r"(?m)^(?:SCRIPT )?ERROR:", result.stdout):
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{result.stdout[-4000:]}")
    return result.stdout


def credits_from_manifest(path: Path) -> tuple[str, dict[str, str]]:
    records = json.loads(path.read_text())
    if not isinstance(records, list):
        raise ValueError("The download manifest must contain an asset record array")
    assets: dict[str, str] = {}
    for record in records:
        name, source = record.get("asset"), record.get("source")
        if name and source:
            if record.get("license") not in {"CC0", "CC0-1.0", "CC0 1.0"}:
                raise ValueError(f"Review the changed license for asset {name}")
            assets[str(name)] = str(source)
    assets.update(EXTRA_ASSETS)
    lines = ["# Vehicle Physics", "", "Original code and authored assets: Nicholas Dunzelman, MIT.", "", "Built with Godot Engine. Engine and asset license notices are included in Contents/Resources/Licenses.", "", "Poly Haven assets retain CC0 terms.", ""]
    lines.extend(f"- [{name.replace('_', ' ')}]({source})" for name, source in sorted(assets.items()))
    lines.extend(["", "[CC0 1.0 license](https://creativecommons.org/publicdomain/zero/1.0/)", ""])
    return "\n".join(lines), assets


def copy_ignore(directory: str, names: list[str]) -> list[str]:
    excluded = {".git", ".build", ".DS_Store", "__pycache__"}
    if Path(directory).name == ".godot":
        excluded.update({"shader_cache", "editor"})
    return list(excluded.intersection(names))


def system_dependencies(binary: Path, log: Path) -> list[str]:
    output = run(["/usr/bin/otool", "-L", binary], log)
    dependencies = [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:] if line.strip()]
    external = [path for path in dependencies if not path.startswith(("/System/Library/", "/usr/lib/"))]
    if external:
        raise RuntimeError(f"Unbundled non-system runtime dependencies: {external}")
    return dependencies


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--dest", type=Path, default=DEFAULT_DEST)
    parser.add_argument("--godot", type=Path, default=Path(os.environ.get("GODOT") or shutil.which("godot") or "/Applications/Godot.app/Contents/MacOS/Godot"))
    parser.add_argument("--preset", default="Mac")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--asset-manifest", type=Path, default=ROOT / "tools" / "material-sources.json")
    parser.add_argument("--qa-dir", type=Path, default=WORK / "qa" / "package_vehicle")
    parser.add_argument("--icon", type=Path, default=None, help="Optional .icns file for the native app bundle")
    parser.add_argument("--credits-only", action="store_true", help="Write the credit deliverable without exporting or changing an app")
    parser.add_argument("--smoke-test", action="store_true", help="Launch the bundled PCK headlessly from an empty independent directory")
    parser.add_argument("--keep-snapshot", action="store_true")
    args = parser.parse_args()
    project, destination, godot, qa, asset_manifest = (
        path.expanduser().resolve() for path in (args.project, args.dest, args.godot, args.qa_dir, args.asset_manifest)
    )
    credits, asset_sources = credits_from_manifest(asset_manifest)
    if args.credits_only:
        destination.parent.mkdir(parents=True, exist_ok=True)
        credit_path = destination.parent / "CREDITS.md"
        credit_path.write_text(credits)
        print(credit_path)
        return
    if destination.suffix != ".app" or destination == project or (project in destination.parents and WORK not in destination.parents):
        raise ValueError("Destination must be an .app outside the source project")
    for required in [project / "project.godot", project / "export_presets.cfg", godot]:
        if not required.is_file():
            raise ValueError(f"Missing required build input: {required}")
    if destination.exists():
        info_path = destination / "Contents" / "Info.plist"
        if not info_path.is_file() or plistlib.loads(info_path.read_bytes()).get("CFBundleIdentifier") != BUNDLE_ID:
            raise ValueError("Refusing to replace an unrelated app bundle")
    if args.icon and (not args.icon.is_file() or args.icon.suffix.lower() != ".icns"):
        raise ValueError("--icon must point to an existing .icns file")
    qa.mkdir(parents=True, exist_ok=True)
    build_parent = WORK / "package_vehicle"
    build_parent.mkdir(parents=True, exist_ok=True)
    build = Path(tempfile.mkdtemp(prefix=".build-", dir=build_parent))
    success = False
    try:
        print("Copying an isolated project snapshot...", flush=True)
        before = inventory(project)
        snapshot = build / "project"
        shutil.copytree(project, snapshot, ignore=copy_ignore)
        copied = inventory(snapshot)
        if before != inventory(project) or copied != before:
            raise RuntimeError("The source project changed during snapshot creation; retry when edits finish")
        # A source-independent license probe uses the exact runtime being bundled.
        tooling = build / "license_tooling"
        tooling.mkdir()
        (tooling / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Engine License Extraction"\n')
        (tooling / "extract_licenses.gd").write_text(LICENSE_EXTRACTOR)
        app = build / f"{APP_NAME}.app"
        executable_dir = app / "Contents" / "MacOS"
        resources = app / "Contents" / "Resources"
        licenses = resources / "Licenses"
        for directory in [executable_dir, resources, licenses]:
            directory.mkdir(parents=True, exist_ok=True)
        runtime = executable_dir / EXECUTABLE
        pack = resources / f"{EXECUTABLE}.pck"
        print("Preparing the arm64 runtime...", flush=True)
        architectures = run(["/usr/bin/lipo", "-archs", godot], qa / "source-architectures.log").split()
        if "arm64" not in architectures:
            raise RuntimeError(f"The selected Godot engine has no arm64 slice: {architectures}")
        if architectures == ["arm64"]:
            shutil.copy2(godot, runtime)
        else:
            run(["/usr/bin/lipo", godot, "-thin", "arm64", "-output", runtime], qa / "lipo.log")
        runtime.chmod(0o755)
        actual_arch = run(["/usr/bin/lipo", "-archs", runtime], qa / "runtime-architecture.log").strip()
        if actual_arch != "arm64":
            raise RuntimeError(f"Unexpected packaged runtime architecture: {actual_arch}")
        dependencies = system_dependencies(runtime, qa / "runtime-dependencies.log")
        print("Importing and exporting the isolated Mac preset...", flush=True)
        run([godot, "--headless", "--path", snapshot, "--editor", "--import", "--quit"], qa / "import.log", timeout=900)
        run([godot, "--headless", "--path", snapshot, "--export-pack", args.preset, pack], qa / "export.log", timeout=900)
        if not pack.is_file() or pack.stat().st_size < 1024:
            raise RuntimeError("Export did not produce a valid-size project pack")
        with pack.open("rb") as handle:
            if handle.read(4) != b"GDPC":
                raise RuntimeError("Exported pack is missing the Godot PCK header")
        print("Collecting engine and asset credits...", flush=True)
        run([godot, "--headless", "--path", tooling, "--script", "res://extract_licenses.gd", "--", licenses], qa / "licenses.log")
        license_data = json.loads((licenses / "Godot-License-Data.json").read_text())
        if not license_data.get("licenses") or not license_data.get("components"):
            raise RuntimeError("Engine license extraction returned no third-party notices")
        (resources / "CREDITS.md").write_text(credits)
        (licenses / "Poly-Haven-Assets.json").write_text(json.dumps({"license": "CC0-1.0", "assets": asset_sources}, indent=2) + "\n")
        (licenses / "CC0-source.txt").write_text("CC0 1.0 Universal\nhttps://creativecommons.org/publicdomain/zero/1.0/legalcode.txt\n")
        # Preserve any asset author notices supplied with the actual source project.
        project_notices = []
        for relative in copied:
            path = Path(relative)
            if any(token in path.name.lower() for token in ("license", "licence", "credits", "attribution", "notice")):
                target = licenses / "Assets" / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(snapshot / path, target)
                project_notices.append(relative)
        info = {
            "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": EXECUTABLE,
            "CFBundleIdentifier": BUNDLE_ID, "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": APP_NAME, "CFBundleDisplayName": APP_NAME,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": args.version,
            "CFBundleVersion": args.version, "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSApplicationCategoryType": "public.app-category.simulation-games",
            "LSMinimumSystemVersion": "13.0", "LSArchitecturePriority": ["arm64"],
            "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
            "NSRequiresAquaSystemAppearance": False,
        }
        if args.icon:
            shutil.copy2(args.icon, resources / "AppIcon.icns")
            info["CFBundleIconFile"] = "AppIcon.icns"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
        (app / "Contents" / "PkgInfo").write_bytes(b"APPL????")
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", runtime], qa / "runtime-sign.log")
        manifest = {
            "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "bundle_identifier": BUNDLE_ID, "version": args.version, "architecture": "arm64",
            "engine": license_data["engine"], "source_project": ".",
            "source_files_sha256": copied, "pck_bytes": pack.stat().st_size,
            "pck_sha256": digest(pack), "runtime_bytes": runtime.stat().st_size,
            "runtime_dependencies": dependencies, "license_count": len(license_data["licenses"]),
            "third_party_component_count": len(license_data["components"]),
            "project_notices": project_notices, "asset_sources": asset_sources,
            "signing": "ad hoc, local use", "notarized": False,
            "executable": f"Contents/MacOS/{EXECUTABLE}",
            "pack_discovery": f"Contents/Resources/{EXECUTABLE}.pck",
            "distribution": "Apple Silicon macOS 13+; bundled engine and project; no external Godot installation required",
        }
        if args.smoke_test:
            print("Launching the packaged project from an independent empty directory...", flush=True)
            with tempfile.TemporaryDirectory(prefix="vehicle-physics-smoke-") as empty:
                run([runtime, "--headless", "--quit-after", "30"], qa / "headless-smoke.log", cwd=Path(empty), timeout=180)
            manifest["headless_smoke"] = {"passed": True, "independent_cwd": True, "quit_after_iterations": 30}
        if inventory(project) != copied:
            raise RuntimeError("Source changed after snapshot; the app was not published. Re-run after edits finish")
        manifest["source_changed_after_snapshot"] = False
        (resources / "BuildManifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print("Signing and validating the native bundle...", flush=True)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app], qa / "app-sign.log")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app], qa / "codesign-verify.log")
        run(["/usr/bin/plutil", "-lint", app / "Contents" / "Info.plist"], qa / "plist-verify.log")
        destination.parent.mkdir(parents=True, exist_ok=True)
        previous = build / "previous.app"
        if destination.exists():
            shutil.move(str(destination), str(previous))
        try:
            shutil.move(str(app), str(destination))
        except BaseException:
            if previous.exists():
                shutil.move(str(previous), str(destination))
            raise
        (destination.parent / "CREDITS.md").write_text(credits)
        manifest["app_path"] = str(destination)
        manifest["app_bytes"] = sum(path.stat().st_size for path in destination.rglob("*") if path.is_file())
        manifest["runtime_sha256_signed"] = digest(destination / "Contents" / "MacOS" / EXECUTABLE)
        (qa / "package-result.json").write_text(json.dumps(manifest, indent=2) + "\n")
        success = True
        print(json.dumps({key: manifest[key] for key in ["app_path", "app_bytes", "pck_bytes", "pck_sha256"]}, indent=2), flush=True)
    finally:
        if success and not args.keep_snapshot:
            shutil.rmtree(build)
        else:
            print(f"Build workspace retained: {build}", flush=True)


if __name__ == "__main__":
    main()
