#!/usr/bin/env python3
"""Package this plugin-only project into a .pbw the Pebble app can sideload, without the Pebble SDK.

    python3 tools/pack-pbw.py [project-dir]       # default: the directory above tools/

A plugin-only pbw has no watch binary: it is a zip of appinfo.json (built from package.json's
`pebble` block, marked as using permissions with manifestVersion 2) and the files the manifest
names, the plugin script and the bundled settings page, at the paths the manifest gives them.
The result is written to build/<package name>.pbw.

Before writing, it checks what the Pebble app would otherwise reject or silently drop: a missing
uuid, script, or settings page, and sources without declared properties and shapes.
"""

import json
import os
import sys
import zipfile

MANIFEST_VERSION = 2
SHAPES = {"shortText", "longText", "numericValue", "timestamp", "boolean", "icon", "image"}


def fail(message):
    sys.exit(f"pack-pbw: {message}")


def appinfo_for(package):
    pebble = dict(package.get("pebble") or {})
    name = pebble.get("displayName") or package.get("name") or ""
    pebble["manifestVersion"] = MANIFEST_VERSION
    pebble.setdefault("shortName", name)
    pebble.setdefault("longName", name)
    pebble.setdefault("companyName", package.get("author", ""))
    pebble.setdefault("versionLabel", package.get("version", "1.0.0"))
    pebble.setdefault("sdkVersion", "3")
    pebble.setdefault("resources", {"media": []})
    pebble.setdefault("watchapp", {"watchface": False})
    return pebble


def check(appinfo):
    if not appinfo.get("uuid"):
        fail("package.json's pebble block needs a uuid")
    plugin = appinfo.get("plugin")
    if not isinstance(plugin, dict) or not plugin.get("script"):
        fail("package.json's pebble block needs a plugin with a script")
    for source in plugin.get("sources", []):
        where = f"{source.get('category')}/{','.join(source.get('items', []))}"
        properties = source.get("properties") or {}
        if not properties:
            fail(f"source {where} declares no properties")
        for prop, shapes in properties.items():
            unknown = [s for s in shapes if s.split(".", 1)[-1] not in SHAPES]
            if not shapes or unknown:
                fail(f"source {where} property {prop} has no shapes or unknown ones: {unknown}")


def bundled_files(appinfo):
    files = [appinfo["plugin"]["script"]]
    page = appinfo.get("configPage")
    if isinstance(page, str) and not page.startswith(("http://", "https://")):
        files.append(page)
    return files


def main(argv):
    project = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
    with open(os.path.join(project, "package.json"), encoding="utf-8") as f:
        package = json.load(f)
    appinfo = appinfo_for(package)
    check(appinfo)

    out = os.path.join(project, "build", f"{package['name']}.pbw")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as pbw:
        pbw.writestr("appinfo.json", json.dumps(appinfo, indent=2))
        for name in bundled_files(appinfo):
            path = os.path.join(project, name)
            if not os.path.isfile(path):
                fail(f"the manifest names {name}, which is not in the project")
            pbw.write(path, name)
    print(f"packaged {out}")


if __name__ == "__main__":
    main(sys.argv)
