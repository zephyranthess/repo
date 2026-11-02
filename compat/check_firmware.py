#!/usr/bin/env python3
"""Check the private APIs in api_manifest.txt against an iOS dyld_shared_cache.

Usage: check_firmware.py <dyld_shared_cache_arm64e> <label>

Uses `ipsw class-dump` to read the Objective-C classes of the relevant system
libraries, resolves inheritance and categories, then reports which manifest
entries exist. Results are cached next to the cache file.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "api_manifest.txt")

IMAGES = [
    "/System/Library/PrivateFrameworks/AVFCore.framework/AVFCore",
    "/System/Library/PrivateFrameworks/BaseBoard.framework/BaseBoard",
    "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    "/System/Library/PrivateFrameworks/CarKit.framework/CarKit",
    "/System/Library/PrivateFrameworks/DashBoard.framework/DashBoard",
    "/System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome",
    "/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
    "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
    "/System/Library/Frameworks/CoreServices.framework/CoreServices",
    "/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
    "/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard",
    "/System/Library/PrivateFrameworks/SpringBoardUI.framework/SpringBoardUI",
    "/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation",
]


def run(args):
    return subprocess.run(args, capture_output=True, text=True, errors="replace").stdout


METHOD_RE = re.compile(r"^([-+])\[([A-Za-z0-9_.$]+)(?:\s*\(([^)]*)\))?\s+([^\]]+)\]")
INTERFACE_RE = re.compile(r"^@interface\s+([A-Za-z0-9_.$]+)\s*(?:\(\s*([^)]*)\))?\s*(?::\s*([A-Za-z0-9_.$]+))?")
PROPERTY_RE = re.compile(r"^@property\s*\(([^)]*)\)\s*([A-Za-z_][A-Za-z0-9_]*)\s*;")


def parse_dump(text, classes):
    """Parse `ipsw class-dump` output.

    Methods look like  -[Class selector];  or  +[Class(Category) selector];
    Properties look like  @property (T@"NSString",R,C,N) name;  (runtime encoding:
    R = readonly, G<name> = custom getter, S<name> = custom setter).
    """
    current = None
    in_ivars = False
    for raw in text.splitlines():
        line = raw.strip()
        m = METHOD_RE.match(line)
        if m:
            kind, cls, _cat, sel = m.groups()
            entry = classes.setdefault(cls, {"super": None, "methods": set(), "ivars": set()})
            entry["methods"].add(kind + sel.strip())
            continue
        m = INTERFACE_RE.match(line)
        if m:
            name, category, superclass = m.groups()
            current = classes.setdefault(name, {"super": None, "methods": set(), "ivars": set()})
            if superclass and category is None:
                current["super"] = superclass
            in_ivars = line.endswith("{")
            continue
        if line.startswith("@end") or line.startswith("@protocol"):
            current, in_ivars = None, False
            continue
        if current is None:
            continue
        if in_ivars:
            if line.startswith("}"):
                in_ivars = False
                continue
            m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*;\s*$", line)
            if m:
                current["ivars"].add(m.group(1))
            continue
        m = PROPERTY_RE.match(line)
        if m:
            attrs = [a.strip() for a in m.group(1).split(",")]
            prop = m.group(2)
            getter = next((a[1:] for a in attrs if a.startswith("G")), prop)
            setter = next((a[1:] for a in attrs if a.startswith("S")), "set" + prop[0].upper() + prop[1:] + ":")
            current["methods"].add("-" + getter)
            if "R" not in attrs:
                current["methods"].add("-" + setter)


def has_method(classes, name, method):
    seen = set()
    while name and name not in seen:
        seen.add(name)
        entry = classes.get(name)
        if not entry:
            return None  # class unknown
        if method in entry["methods"]:
            return True
        # NSObject/UIKit roots: stop when we leave the libraries we dumped
        name = entry["super"]
    return False


def has_ivar(classes, name, ivar):
    while name:
        entry = classes.get(name)
        if not entry:
            return False
        if ivar in entry["ivars"]:
            return True
        name = entry["super"]
    return False


def main():
    dsc, label = sys.argv[1], sys.argv[2]
    cache_dir = os.path.join(os.path.dirname(dsc), "classdump")
    os.makedirs(cache_dir, exist_ok=True)
    classes = {}
    for image in IMAGES:
        out = os.path.join(cache_dir, os.path.basename(image) + ".h")
        if not os.path.exists(out):
            text = run(["ipsw", "class-dump", dsc, image])
            with open(out, "w") as f:
                f.write(text)
        with open(out) as f:
            parse_dump(f.read(), classes)

    results = []
    for raw in open(MANIFEST):
        parts = raw.split("#")[0].split()
        if len(parts) < 4:
            continue
        feature, need, kind = parts[0], parts[1], parts[2]
        if kind == "class":
            ok = parts[3] in classes
            what = parts[3]
        elif kind == "method":
            ok = has_method(classes, parts[3], parts[4])
            what = f"{parts[3]} {parts[4]}"
        elif kind == "ivar":
            ok = has_ivar(classes, parts[3], parts[4])
            what = f"{parts[3]} ivar {parts[4]}"
        else:  # symbol
            # C symbols are stored with a leading underscore.
            text = run(["ipsw", "dyld", "symaddr", dsc, "_" + parts[3]])
            ok = ("_" + parts[3]) in text
            what = f"symbol {parts[3]}"
        status = "ok" if ok else ("NO CLASS" if ok is None else "MISSING")
        results.append((feature, need, what, status))

    # Resolve alternative routes: a group passes if all entries of one route exist.
    groups = {}
    for feature, need, what, status in results:
        if need.startswith("any:"):
            group, route = need[4:].split("/")
            groups.setdefault((feature, group), {}).setdefault(route, []).append(status == "ok")
    print(f"# iOS {label}")
    for feature, need, what, status in results:
        if need.startswith("any:"):
            continue
        print(f"{status:9} {need:8} {feature:15} {what}")
    for (feature, group), routes in groups.items():
        working = [r for r, oks in routes.items() if all(oks)]
        status = "ok" if working else "MISSING"
        print(f"{status:9} required {feature:15} {group} via {', '.join(working) if working else 'no route (' + ', '.join(routes) + ')'}")


if __name__ == "__main__":
    main()
