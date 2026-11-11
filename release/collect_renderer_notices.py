#!/usr/bin/env python3
"""Extract license notices for the exact npm builds shipped in Glancemark."""

import argparse
import base64
import concurrent.futures
import hashlib
import io
import json
import re
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path

# The MathJax 3.2.2 lockfile and component bundle identify these modules.
# Include the speech engine's browser/CLI dependencies conservatively.
MATHJAX = {
    ("mathjax-full", "3.2.2"),
    ("mhchemparser", "4.1.1"),
    ("mj-context-menu", "0.6.1"),
    ("speech-rule-engine", "4.0.6"),
    ("commander", "9.2.0"),
    ("xmldom-sre", "0.1.31"),
    ("wicked-good-xpath", "1.3.0"),
}
REGISTRY = "https://registry.npmjs.org"
CONTEXT_SOURCE = "https://raw.githubusercontent.com/zorkow/context-menu/8ddd26a41f834cd23b9bb20737dfae5fa9b05eb4/ts/context_menu.ts"
NOTICE = re.compile(r"^package/(?:licen[cs]e|copying|copyright|notice)(?:[-_.].*)?$", re.I)


def registry_fetch(url):
    if not url.startswith(REGISTRY + "/"):
        raise ValueError(f"Unexpected registry origin: {url}")
    with urllib.request.urlopen(url, timeout=20) as response:
        if urllib.parse.urlsplit(response.url).hostname != "registry.npmjs.org":
            raise ValueError(f"Unexpected registry redirect: {response.url}")
        payload = response.read(64 * 1024 * 1024 + 1)
    if len(payload) > 64 * 1024 * 1024:
        raise ValueError("Registry package exceeds the audit size limit")
    return payload


def package_receipt(name, version):
    identifier = urllib.parse.quote(name, safe="")
    metadata = json.loads(registry_fetch(f"{REGISTRY}/{identifier}/{version}"))
    dist = metadata["dist"]
    archive = registry_fetch(dist["tarball"])
    algorithm, _, expected = dist["integrity"].partition("-")
    if algorithm != "sha512":
        raise ValueError(f"Unexpected integrity algorithm for {name}@{version}: {algorithm}")
    actual = base64.b64encode(hashlib.sha512(archive).digest()).decode()
    if actual != expected:
        raise ValueError(f"Registry integrity mismatch: {name}@{version}")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        notices = {
            member.name: tar.extractfile(member).read().decode("utf-8-sig")
            for member in tar
            if member.isfile() and NOTICE.fullmatch(member.name)
        }
        if (name, version) == ("fastdom", "1.0.12") and not notices:
            readme = tar.extractfile("package/README.md").read().decode()
            _, separator, notice = readme.partition("## License\n")
            if not separator or "Copyright (c) 2016 Wilson Page" not in notice:
                raise ValueError("Missing fastdom license section in the package README")
            notices["package/README.md, License section"] = notice
    if (name, version) == ("mj-context-menu", "0.6.1") and not notices:
        with urllib.request.urlopen(CONTEXT_SOURCE, timeout=20) as response:
            header = response.read(2048).decode().split("*/", 1)[0] + "*/"
        if "Copyright (c) 2015-2016 The MathJax Consortium" not in header or "Apache License, Version 2.0" not in header:
            raise ValueError("Unexpected source notice for mj-context-menu")
        notices[f"source notice from {CONTEXT_SOURCE}"] = header
    return {
        "name": name, "version": version, "license": metadata.get("license"),
        "url": dist["tarball"], "integrity": dist["integrity"], "notices": notices,
    }


def mermaid_packages(path):
    with tarfile.open(path, mode="r:gz") as tar:
        source_map = json.load(tar.extractfile("package/dist/mermaid.min.js.map"))
        package = json.load(tar.extractfile("package/package.json"))
    if package["name"] != "mermaid":
        raise ValueError("Expected an exact Mermaid npm package")
    release = (package["name"], package["version"])
    packages = {release}
    for source in source_map["sources"]:
        match = re.search(r"\.pnpm/([^/]+)/node_modules/", source)
        if match:
            entry = re.fullmatch(r"((?:@[^+]+\+)?[^@]+)@([^_(@]+).*", match[1])
            if not entry:
                raise ValueError(f"Unrecognized pnpm source map path: {source}")
            name, version = entry.groups()
            packages.add((name.replace("+", "/"), version))
    return release, packages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mermaid_tgz", type=Path, help="Pinned Mermaid npm package containing its source map")
    parser.add_argument("output", type=Path, help="New notice output file")
    args = parser.parse_args()

    release, embedded = mermaid_packages(args.mermaid_tgz)
    packages = sorted(embedded | MATHJAX)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
        receipts = list(workers.map(lambda pair: package_receipt(*pair), packages))
    mermaid_receipt = next(item for item in receipts if (item["name"], item["version"]) == release)
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(args.mermaid_tgz.read_bytes()).digest()).decode()
    if integrity != mermaid_receipt["integrity"]:
        raise ValueError("The local Mermaid package differs from the registry")

    missing = []
    with args.output.open("x", encoding="utf-8") as output:
        output.write("Glancemark renderer dependency notices\n\n")
        output.write(f"Mermaid inventory: Mermaid {release[1]} minified distribution source map.\n")
        output.write("MathJax inventory: MathJax 3.2.2 lockfile and compiled browser component.\n")
        output.write("Registry package licenses and notices follow below. Where no root license was\n")
        output.write("packaged for mj-context-menu, the exact upstream source header is reproduced.\n")
        output.write("The fastdom license is reproduced from its published package README.\n")
        output.write("See the MathJax Apache-2.0 entry for the full terms of that license.\n")
        for receipt in receipts:
            package = f'{receipt["name"]}@{receipt["version"]}'
            license_name = receipt["license"]
            if package == "khroma@2.1.0" and license_name is None:
                license_name = "MIT (archive license)"
            output.write(f'\n===== {package} | {license_name} =====\n')
            output.write(f'{receipt["url"]}\n{receipt["integrity"]}\n')
            if package == "elkjs@0.12.0":
                output.write("ELK source is available under EPL-2.0 from the exact upstream versions:\n")
                output.write("https://github.com/kieler/elkjs/tree/ff5771d7165445c42c408bb8a090c8035272218c\n")
                output.write("https://github.com/eclipse-elk/elk/tree/323312916048544e4e594eab3303cdb0d01e2929\n")
            if not receipt["notices"]:
                missing.append(package)
                output.write("[No root license or notice in the published npm archive. See the release audit.]\n")
            for filename, text in sorted(receipt["notices"].items()):
                output.write(f"\n----- {filename} -----\n{text.rstrip()}\n")
    if missing:
        raise SystemExit(f"Missing notices for: {', '.join(missing)}")
    print(f"Collected notices for {len(receipts)} exact npm versions.")


if __name__ == "__main__":
    main()
