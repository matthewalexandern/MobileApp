#!/usr/bin/env python3
"""Generate the checked-in Xcode project with Python's standard library only."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "KernalMobile.xcodeproj"


def identifier(kind: str, path: str = "") -> str:
    return hashlib.sha256(f"kernal-mobile:{kind}:{path}".encode()).hexdigest()[:24].upper()


def quote(value: str) -> str:
    return json.dumps(value)


def generate() -> dict[Path, str]:
    app = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "KernalMobile").rglob("*") if p.suffix in {".swift", ".cpp"})
    headers = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "KernalMobile").rglob("*.h"))
    tests = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "KernalMobileTests").rglob("*.swift"))
    if not app or not tests:
        raise SystemExit("App and XCTest source files are required before generation.")
    resources = [p for p in ("KernalMobile/Assets.xcassets", "KernalMobile/PrivacyInfo.xcprivacy") if (ROOT / p).exists()]
    fixtures = ["ContractFixtures"] if (ROOT / "ContractFixtures").is_dir() else []
    objects: dict[str, str] = {}

    def obj(kind: str, path: str, body: str) -> str:
        key = identifier(kind, path)
        if key in objects:
            raise ValueError("Duplicate project object")
        objects[key] = "{ " + body + " };"
        return key

    def refs(values: list[str]) -> str:
        return "(" + ", ".join(values) + ("," if values else "") + ")"

    file_refs: dict[str, str] = {}
    for path in app + headers + tests + resources + fixtures + ["KernalMobile/Info.plist", "Vendor/llama.xcframework"]:
        if path.endswith(".swift"):
            file_type = "sourcecode.swift"
        elif path.endswith(".cpp"):
            file_type = "sourcecode.cpp.cpp"
        elif path.endswith(".h"):
            file_type = "sourcecode.c.h"
        elif path.endswith(".xcframework"):
            file_type = "wrapper.xcframework"
        elif path.endswith(".xcassets"):
            file_type = "folder.assetcatalog"
        elif path == "ContractFixtures":
            file_type = "folder"
        else:
            file_type = "text.xml"
        file_refs[path] = obj("file", path, f"isa = PBXFileReference; lastKnownFileType = {file_type}; path = {quote(path)}; sourceTree = SOURCE_ROOT;")

    def phase(name: str, kind: str, paths: list[str]) -> str:
        builds = [obj("build-file", name + ":" + p, f"isa = PBXBuildFile; fileRef = {file_refs[p]};") for p in paths]
        return obj("phase", name, f"isa = {kind}; buildActionMask = 2147483647; files = {refs(builds)}; runOnlyForDeploymentPostprocessing = 0;")

    app_sources = phase("app-sources", "PBXSourcesBuildPhase", app)
    app_resources = phase("app-resources", "PBXResourcesBuildPhase", resources)
    app_frameworks = phase("app-frameworks", "PBXFrameworksBuildPhase", ["Vendor/llama.xcframework"])
    framework_ref = file_refs["Vendor/llama.xcframework"]
    embedded = obj("build-file", "embed-llama", f"isa = PBXBuildFile; fileRef = {framework_ref}; settings = {{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy); }};")
    embed_phase = obj("phase", "embed-frameworks", f"isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 10; files = {refs([embedded])}; name = \"Embed Frameworks\"; runOnlyForDeploymentPostprocessing = 0;")
    sqlite = obj("system-framework", "sqlite", 'isa = PBXFileReference; lastKnownFileType = sourcecode.text-based-dylib-definition; name = libsqlite3.tbd; path = usr/lib/libsqlite3.tbd; sourceTree = SDKROOT;')
    sqlite_build = obj("build-file", "sqlite", f"isa = PBXBuildFile; fileRef = {sqlite};")
    objects[app_frameworks] = "{ isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = " + refs([identifier("build-file", "app-frameworks:Vendor/llama.xcframework"), sqlite_build]) + "; runOnlyForDeploymentPostprocessing = 0; };"
    test_sources = phase("test-sources", "PBXSourcesBuildPhase", tests)
    test_resources = phase("test-resources", "PBXResourcesBuildPhase", fixtures)
    test_frameworks = phase("test-frameworks", "PBXFrameworksBuildPhase", [])
    app_product = obj("product", "app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = KernalMobile.app; sourceTree = BUILT_PRODUCTS_DIR;')
    test_product = obj("product", "tests", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = KernalMobileTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    app_group = obj("group", "app", f"isa = PBXGroup; children = {refs([file_refs[p] for p in app + headers + resources + ['KernalMobile/Info.plist', 'Vendor/llama.xcframework']] + [sqlite])}; name = KernalMobile; sourceTree = \"<group>\";")
    test_group = obj("group", "tests", f"isa = PBXGroup; children = {refs([file_refs[p] for p in tests + fixtures])}; name = Tests; sourceTree = \"<group>\";")
    products = obj("group", "products", f"isa = PBXGroup; children = {refs([app_product, test_product])}; name = Products; sourceTree = \"<group>\";")
    main_group = obj("group", "root", f"isa = PBXGroup; children = {refs([app_group, test_group, products])}; sourceTree = \"<group>\";")

    def configurations(name: str, common: dict[str, str]) -> str:
        ids = []
        for mode in ("Debug", "Release"):
            settings = dict(common)
            settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if mode == "Debug" else "-O"
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf" if mode == "Debug" else "dwarf-with-dsym"
            if mode == "Debug":
                settings["ENABLE_TESTABILITY"] = "YES"
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            raw = " ".join(f"{key} = {quote(value)};" for key, value in sorted(settings.items()))
            ids.append(obj("config", name + mode, f"isa = XCBuildConfiguration; buildSettings = {{ {raw} }}; name = {mode};"))
        return obj("config-list", name, f"isa = XCConfigurationList; buildConfigurations = {refs(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

    project_config = configurations("project", {
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    })
    common = {"CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1", "DEVELOPMENT_TEAM": "", "MARKETING_VERSION": "0.1.0", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "TARGETED_DEVICE_FAMILY": "1"}
    app_config = configurations("app", common | {
        "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "KernalMobile/Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.example.KernalMobile", "PRODUCT_NAME": "KernalMobile",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "SWIFT_OBJC_BRIDGING_HEADER": "KernalMobile/Native/KernalMobile-Bridging-Header.h",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "OTHER_LDFLAGS": "$(inherited) -lc++",
        "FRAMEWORK_SEARCH_PATHS": "$(inherited) $(PROJECT_DIR)/Vendor",
    })
    test_config = configurations("tests", common | {
        "GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.KernalMobileTests",
        "PRODUCT_NAME": "KernalMobileTests", "BUNDLE_LOADER": "$(TEST_HOST)",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/KernalMobile.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/KernalMobile",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
    })
    app_id = identifier("target", "app")
    project_id = identifier("project", "root")
    proxy = obj("proxy", "app", f"isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {app_id}; remoteInfo = KernalMobile;")
    dependency = obj("dependency", "app", f"isa = PBXTargetDependency; target = {app_id}; targetProxy = {proxy};")
    obj("target", "app", f"isa = PBXNativeTarget; buildConfigurationList = {app_config}; buildPhases = {refs([app_sources, app_frameworks, app_resources, embed_phase])}; buildRules = (); dependencies = (); name = KernalMobile; productName = KernalMobile; productReference = {app_product}; productType = \"com.apple.product-type.application\";")
    test_id = obj("target", "tests", f"isa = PBXNativeTarget; buildConfigurationList = {test_config}; buildPhases = {refs([test_sources, test_frameworks, test_resources])}; buildRules = (); dependencies = {refs([dependency])}; name = KernalMobileTests; productName = KernalMobileTests; productReference = {test_product}; productType = \"com.apple.product-type.bundle.unit-test\";")
    obj("project", "root", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1500; TargetAttributes = {{ {app_id} = {{ CreatedOnToolsVersion = 15.0; }}; {test_id} = {{ CreatedOnToolsVersion = 15.0; TestTargetID = {app_id}; }}; }}; }}; buildConfigurationList = {project_config}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = \"\"; projectRoot = \"\"; targets = {refs([app_id, test_id])};")
    pbx = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
    pbx += "\n".join(f"\t\t{key} = {objects[key]}" for key in sorted(objects))
    pbx += f"\n\t}};\n\trootObject = {project_id};\n}}\n"

    def buildable(parent: ET.Element, target: str, name: str, product: str) -> None:
        ET.SubElement(parent, "BuildableReference", {"BuildableIdentifier": "primary", "BlueprintIdentifier": target, "BuildableName": product, "BlueprintName": name, "ReferencedContainer": "container:KernalMobile.xcodeproj"})

    scheme = ET.Element("Scheme", {"LastUpgradeVersion": "1500", "version": "1.3"})
    build = ET.SubElement(scheme, "BuildAction", {"parallelizeBuildables": "YES", "buildImplicitDependencies": "YES"})
    entries = ET.SubElement(build, "BuildActionEntries")
    for target, name, product, running in [(app_id, "KernalMobile", "KernalMobile.app", "YES"), (test_id, "KernalMobileTests", "KernalMobileTests.xctest", "NO")]:
        entry = ET.SubElement(entries, "BuildActionEntry", {"buildForTesting": "YES", "buildForRunning": running, "buildForProfiling": running, "buildForArchiving": running, "buildForAnalyzing": "YES"})
        buildable(entry, target, name, product)
    test_action = ET.SubElement(scheme, "TestAction", {"buildConfiguration": "Debug", "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB", "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "shouldUseLaunchSchemeArgsEnv": "YES"})
    testables = ET.SubElement(test_action, "Testables")
    buildable(ET.SubElement(testables, "TestableReference", {"skipped": "NO"}), test_id, "KernalMobileTests", "KernalMobileTests.xctest")
    for tag, mode in [("LaunchAction", "Debug"), ("ProfileAction", "Release")]:
        action = ET.SubElement(scheme, tag, {"buildConfiguration": mode, "useCustomWorkingDirectory": "NO"})
        buildable(ET.SubElement(action, "BuildableProductRunnable", {"runnableDebuggingMode": "0"}), app_id, "KernalMobile", "KernalMobile.app")
    ET.SubElement(scheme, "AnalyzeAction", {"buildConfiguration": "Debug"})
    ET.SubElement(scheme, "ArchiveAction", {"buildConfiguration": "Release", "revealArchiveInOrganizer": "YES"})
    ET.indent(scheme)
    xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(scheme, encoding="unicode") + "\n"
    return {PROJECT / "project.pbxproj": pbx, PROJECT / "xcshareddata/xcschemes/KernalMobile.xcscheme": xml}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the checked-in project is stale")
    args = parser.parse_args()
    for path, text in generate().items():
        if args.check:
            if not path.exists() or path.read_text() != text:
                raise SystemExit(f"Stale project: {path.relative_to(ROOT)}; run scripts/generate_project.py")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    print("Xcode project is current." if args.check else "Generated KernalMobile.xcodeproj.")


if __name__ == "__main__":
    main()
