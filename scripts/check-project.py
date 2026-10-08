#!/usr/bin/env python3
"""Check the checked-in Xcode project graph without requiring Apple tools.

This checks OpenStep plist syntax, references, source membership, local package
products and the shared scheme. It does not replace xcodebuild or device tests.
"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "NativeRuntime.xcodeproj"
UUID = re.compile(r"[A-F0-9]{24}\Z")
TOKEN = re.compile(
    r'(?P<skip>\s+|/\*.*?\*/|//[^\n]*)'
    r'|(?P<string>"(?:\\.|[^"\\])*")'
    r'|(?P<symbol>[{}()=;,])'
    r'|(?P<bare>[^\s{}()=;,"/]+(?:/[^\s{}()=;,"/]*)*|/[^\s{}()=;,"/]*)',
    re.DOTALL,
)


class ProjectError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProjectError(message)


class OpenStepParser:
    """Parse the dictionaries, arrays and strings used by an Xcode project."""

    def __init__(self, text: str):
        self.tokens: list[str] = []
        cursor = 0
        while cursor < len(text):
            match = TOKEN.match(text, cursor)
            require(match is not None, f"Invalid project syntax at character {cursor}")
            if match.lastgroup != "skip":
                self.tokens.append(match.group())
            cursor = match.end()
        self.cursor = 0

    def pop(self) -> str:
        require(self.cursor < len(self.tokens), "Unexpected end of project")
        token = self.tokens[self.cursor]
        self.cursor += 1
        return token

    def expect(self, expected: str) -> None:
        actual = self.pop()
        require(actual == expected, f"Expected {expected!r}, found {actual!r}")

    def peek(self) -> str:
        require(self.cursor < len(self.tokens), "Unexpected end of project")
        return self.tokens[self.cursor]

    def scalar(self, token: str) -> str:
        require(token not in "{}()=;,", f"Expected a string, found {token!r}")
        return json.loads(token) if token.startswith('"') else token

    def value(self):
        token = self.pop()
        if token == "{":
            result = {}
            while self.peek() != "}":
                key = self.scalar(self.pop())
                require(key not in result, f"Duplicate project key: {key}")
                self.expect("=")
                result[key] = self.value()
                self.expect(";")
            self.expect("}")
            return result
        if token == "(":
            result = []
            while self.peek() != ")":
                result.append(self.value())
                if self.peek() != ")":
                    self.expect(",")
            self.expect(")")
            return result
        return self.scalar(token)

    def parse(self):
        result = self.value()
        require(self.cursor == len(self.tokens), "Unexpected text after project plist")
        return result


def check() -> tuple[int, int]:
    plist = OpenStepParser((PROJECT / "project.pbxproj").read_text()).parse()
    objects = plist["objects"]

    def references(value):
        if isinstance(value, dict):
            for key, child in value.items():
                references(key)
                references(child)
        elif isinstance(value, list):
            for child in value:
                references(child)
        elif isinstance(value, str) and UUID.fullmatch(value):
            require(value in objects, f"Dangling Xcode object reference: {value}")

    references(plist)
    project = objects[plist["rootObject"]]
    require(project["isa"] == "PBXProject", "Root object must be PBXProject")
    require(len(project["targets"]) == 1, "Expected one application target")
    target_id = project["targets"][0]
    target = objects[target_id]
    require(target["isa"] == "PBXNativeTarget", "Expected a native application target")
    require(target["productType"] == "com.apple.product-type.application", "Expected an iOS app")

    files = {}

    def group(object_id: str, parent: Path):
        obj = objects[object_id]
        source_tree = obj.get("sourceTree", "<group>")
        if source_tree == "BUILT_PRODUCTS_DIR":
            return
        require(source_tree in {"<group>", "SOURCE_ROOT"}, f"Unsupported source tree: {source_tree}")
        base = ROOT if source_tree == "SOURCE_ROOT" else parent
        path = base / obj.get("path", "")
        if obj["isa"] == "PBXGroup":
            for child in obj["children"]:
                group(child, path)
        elif obj["isa"] == "PBXFileReference":
            require(path.exists(), f"Referenced file does not exist: {path.relative_to(ROOT)}")
            files[object_id] = path
        else:
            raise ProjectError(f"Unexpected object in source group: {obj['isa']}")

    group(project["mainGroup"], ROOT)
    phases = [objects[ref] for ref in target["buildPhases"]]
    sources = set()
    frameworks = set()
    resources = set()
    for phase in phases:
        for ref in phase["files"]:
            build_file = objects[ref]
            require(build_file["isa"] == "PBXBuildFile", "Build phases must reference PBXBuildFile")
            if phase["isa"] == "PBXSourcesBuildPhase":
                sources.add(files[build_file["fileRef"]])
            elif phase["isa"] == "PBXFrameworksBuildPhase":
                frameworks.add(build_file["productRef"])
            elif phase["isa"] == "PBXResourcesBuildPhase":
                resources.add(files[build_file["fileRef"]])
            else:
                raise ProjectError(f"Unexpected build phase: {phase['isa']}")
    app_sources = set((ROOT / "Apps/NativeRuntimeApp").rglob("*.swift"))
    require(bool(app_sources), "Application has no Swift sources")
    require(sources == app_sources, f"Source membership differs: {sorted(str(p.relative_to(ROOT)) for p in sources ^ app_sources)}")
    require(ROOT / "Apps/NativeRuntimeApp/Assets.xcassets" in resources, "Missing app asset catalog resource")

    packages = project["packageReferences"]
    require(len(packages) == 1, "Expected one local Swift package")
    package = objects[packages[0]]
    require(package["isa"] == "XCLocalSwiftPackageReference", "Package must be local")
    manifest = ROOT / package["relativePath"] / "Package.swift"
    require(manifest.is_file(), "Missing local Swift package manifest")
    available = set(re.findall(r'\.library\(name:\s*"([^"]+)"', manifest.read_text()))
    dependencies = target["packageProductDependencies"]
    require(set(dependencies) == frameworks, "Package products must be linked in Frameworks")
    products = set()
    for ref in dependencies:
        product = objects[ref]
        require(product["isa"] == "XCSwiftPackageProductDependency", "Invalid package product dependency")
        require(product["package"] == packages[0], "Product must reference the local package")
        products.add(product["productName"])
    require(products == available, f"Linked package products differ: {products ^ available}")

    def configurations(obj):
        refs = objects[obj["buildConfigurationList"]]["buildConfigurations"]
        return {objects[ref]["name"]: objects[ref]["buildSettings"] for ref in refs}

    project_settings = configurations(project)
    target_settings = configurations(target)
    require(set(project_settings) == {"Debug", "Release"}, "Missing project build configurations")
    require(set(target_settings) == {"Debug", "Release"}, "Missing target build configurations")
    for name, settings in target_settings.items():
        combined = project_settings[name] | settings
        require(combined["SWIFT_VERSION"] == "6.0", f"{name} must use Swift 6")
        require(combined["IPHONEOS_DEPLOYMENT_TARGET"] == "17.0", f"{name} must support iOS 17")
        require(combined["CODE_SIGN_STYLE"] == "Automatic", "Device signing must be configurable")
        require(combined["GENERATE_INFOPLIST_FILE"] == "YES", "Expected a generated Info.plist")

    scheme = ET.parse(PROJECT / "xcshareddata/xcschemes/NativeRuntimeApp.xcscheme")
    buildables = scheme.findall(".//BuildableReference")
    require(bool(buildables), "Shared scheme has no buildable references")
    product_file = objects[target["productReference"]]["path"]
    for buildable in buildables:
        require(buildable.attrib["BlueprintIdentifier"] == target_id, "Scheme target reference differs")
        require(buildable.attrib["BlueprintName"] == target["name"], "Scheme target name differs")
        require(buildable.attrib["BuildableName"] == product_file, "Scheme product differs")
        require(buildable.attrib["ReferencedContainer"] == "container:NativeRuntime.xcodeproj", "Scheme project differs")
    require(scheme.find(".//BuildActionEntry") is not None, "Shared scheme has no build action")
    return len(sources), len(products)


if __name__ == "__main__":
    try:
        source_count, product_count = check()
    except (ProjectError, KeyError, ValueError, OSError, ET.ParseError) as error:
        print(f"Project verification failed: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"Project references verified: {source_count} Swift sources, {product_count} local package products, shared scheme.")
    print("Run xcodebuild on macOS to verify compilation; this check does not compile the app.")
