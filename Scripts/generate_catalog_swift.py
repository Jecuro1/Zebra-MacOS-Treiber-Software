#!/usr/bin/env python3
"""Bettet Catalog/models.json als Swift-Quelltext in LabelWerkCore ein.

So benötigt der Kern keine SwiftPM-Ressourcen-Bundles (die sich in .app-Bundles schlecht signieren
lassen) und der Katalog ist auf macOS und Linux identisch verfügbar.
Aufruf:  python3 Scripts/generate_catalog_swift.py [--check]
"""
import json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "Catalog", "models.json")
dst = os.path.join(root, "Sources", "LabelWerkCore", "Catalog", "ModelCatalogData.swift")

with open(src, encoding="utf-8") as f:
    data = json.load(f)
compact = json.dumps(data, ensure_ascii=False, indent=1)
assert '"""#' not in compact
swift = (
    "// AUTOMATISCH ERZEUGT von Scripts/generate_catalog_swift.py – nicht von Hand bearbeiten.\n"
    "// Quelle: Catalog/models.json\n\n"
    "enum ModelCatalogData {\n"
    "    static let json = #\"\"\"\n" + compact + "\n\"\"\"#\n"
    "}\n"
)
if "--check" in sys.argv:
    current = open(dst, encoding="utf-8").read() if os.path.exists(dst) else ""
    if current != swift:
        print("ModelCatalogData.swift ist veraltet – bitte Scripts/generate_catalog_swift.py ausführen.")
        sys.exit(1)
    print("ModelCatalogData.swift ist aktuell.")
    sys.exit(0)
os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "w", encoding="utf-8") as f:
    f.write(swift)
print(f"geschrieben: {os.path.relpath(dst, root)}")
