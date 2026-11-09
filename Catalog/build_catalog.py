#!/usr/bin/env python3
"""Erzeugt Catalog/models.json – die einzige Quelle für Modelle & Etikettenformate.

Wird von der App (über das generierte ModelCatalogData.swift) und vom PPD-Generator gelesen.
Werte nach bestem Wissen aus Herstellerdatenblättern; Anpassungen bitte hier vornehmen und
anschließend `python3 Catalog/build_catalog.py && python3 Scripts/generate_catalog_swift.py`.
"""
import json, os, re

ALL_MODES_DESKTOP = ["tearOff", "peelOff", "cutter"]
IND_MODES = ["tearOff", "peelOff", "cutter", "delayedCut", "rewind", "applicator"]
MOB_MODES = ["tearOff", "peelOff"]
DT = ["directThermal"]
DTTT = ["directThermal", "thermalTransfer"]

def m(id, name, family, category, langs, res, width, maxlen, speeds, media, modes, conn, feats, stock, mdl=None, default_lang=None):
    # IEEE-1284-MDL-Strings, so wie Zebra-Drucker sie per USB melden.
    if mdl is None:
        base = re.sub(r"(?<=\d)[dtc](?=$|-)", "", name)  # ZD421t -> ZD421, ZD421d-HC -> ZD421-HC
        mdl = []
        for r in res:
            mdl.append(f"ZTC {base}-{r}dpi ZPL" if "zpl" in langs else f"ZTC {base}-{r}dpi")
        mdl.append(f"ZTC {name}")
        mdl.append(f"ZDesigner {name}")
    return {
        "id": id, "name": name, "family": family, "category": category,
        "languages": langs, "defaultLanguage": default_lang or langs[0],
        "resolutions": res, "printWidthMM": width, "maxLabelLengthMM": maxlen,
        "maxSpeedIPS": {str(k): v for k, v in speeds.items()},
        "mediaTypes": media, "printModes": modes, "connectivity": conn,
        "features": feats, "ieee1284": sorted(set(mdl)), "defaultStock": stock,
    }

LINKOS = ["linkOS", "sgd"]
DESK_CONN = ["usb", "ethernet", "wifi", "bluetooth", "ble"]

models = [
    # --- Desktop: aktuelle Link-OS-Generation -------------------------------------------
    m("zd421d", "ZD421d", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 6, 300: 4}, DT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS + ["display"], "w4h6in"),
    m("zd421t", "ZD421t", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 6, 300: 4}, DTTT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS + ["display"], "w4h6in"),
    m("zd421c", "ZD421c", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 6, 300: 4}, DTTT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS + ["display"], "w4h6in"),
    m("zd420d", "ZD420d", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 6, 300: 4}, DT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS, "w4h6in"),
    m("zd420t", "ZD420t", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 6, 300: 4}, DTTT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS, "w4h6in"),
    m("zd411d", "ZD411d", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 56, 991, {203: 8, 300: 6}, DT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS, "w2h1in"),
    m("zd411t", "ZD411t", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 56, 991, {203: 6, 300: 4}, DTTT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS, "w2h1in"),
    m("zd410", "ZD410", "ZD400", "desktop", ["zpl", "epl"], [203, 300], 56, 991, {203: 6, 300: 4}, DT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS, "w2h1in"),
    m("zd621d", "ZD621d", "ZD600", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 8, 300: 6}, DT, ALL_MODES_DESKTOP + ["applicator"], DESK_CONN + ["serial"], LINKOS + ["display", "rfid"], "w4h6in"),
    m("zd621t", "ZD621t", "ZD600", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 8, 300: 6}, DTTT, ALL_MODES_DESKTOP + ["applicator"], DESK_CONN + ["serial"], LINKOS + ["display", "rfid"], "w4h6in"),
    m("zd620d", "ZD620d", "ZD600", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 8, 300: 6}, DT, ALL_MODES_DESKTOP, DESK_CONN + ["serial"], LINKOS + ["display"], "w4h6in"),
    m("zd620t", "ZD620t", "ZD600", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 8, 300: 6}, DTTT, ALL_MODES_DESKTOP, DESK_CONN + ["serial"], LINKOS + ["display"], "w4h6in"),
    m("zd611d", "ZD611d", "ZD600", "desktop", ["zpl", "epl"], [203, 300], 56, 991, {203: 8, 300: 6}, DT, ALL_MODES_DESKTOP, DESK_CONN + ["serial"], LINKOS + ["display"], "w2h1in"),
    m("zd611t", "ZD611t", "ZD600", "desktop", ["zpl", "epl"], [203, 300], 56, 991, {203: 8, 300: 6}, DTTT, ALL_MODES_DESKTOP, DESK_CONN + ["serial"], LINKOS + ["display"], "w2h1in"),
    m("zd610d", "ZD610d", "ZD600", "desktop", ["zpl", "epl"], [203, 300], 104, 991, {203: 8, 300: 6}, DT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS, "w4h6in"),
    m("zd230d", "ZD230d", "ZD200", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 6}, DT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "wifi", "bluetooth"], [], "w4h6in"),
    m("zd230t", "ZD230t", "ZD200", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 6}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "wifi", "bluetooth"], [], "w4h6in"),
    m("zd220d", "ZD220d", "ZD200", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 4}, DT, ["tearOff"], ["usb"], [], "w4h6in"),
    m("zd220t", "ZD220t", "ZD200", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 4}, DTTT, ["tearOff"], ["usb"], [], "w4h6in"),
    m("zd888t", "ZD888t", "ZD800", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "bluetooth"], [], "w4h6in"),
    m("zd510hc", "ZD510-HC", "ZD500", "healthcare", ["zpl", "epl"], [300], 51, 559, {300: 4}, DT, ["tearOff"], DESK_CONN, LINKOS, "wb1x11in"),
    m("zd421hc", "ZD421d-HC", "ZD400", "healthcare", ["zpl", "epl"], [203, 300], 104, 991, {203: 6, 300: 4}, DT, ALL_MODES_DESKTOP, DESK_CONN, LINKOS, "w4h6in"),
    # --- Desktop: klassische G-Serie & ältere ---------------------------------------------
    m("gk420d", "GK420d", "GK", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 5}, DT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial", "parallel"], [], "w4h6in"),
    m("gk420t", "GK420t", "GK", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 5}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial", "parallel"], [], "w4h6in"),
    m("gx420d", "GX420d", "GX", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 6}, DT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "wifi", "bluetooth", "serial"], [], "w4h6in"),
    m("gx420t", "GX420t", "GX", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 6}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "wifi", "bluetooth", "serial"], [], "w4h6in"),
    m("gx430t", "GX430t", "GX", "desktop", ["zpl", "epl"], [300], 104, 991, {300: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "wifi", "bluetooth", "serial"], [], "w4h6in"),
    m("gc420d", "GC420d", "GC", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 4}, DT, ["tearOff", "peelOff"], ["usb", "serial", "parallel"], [], "w4h6in"),
    m("gc420t", "GC420t", "GC", "desktop", ["zpl", "epl"], [203], 104, 991, {203: 4}, DTTT, ["tearOff", "peelOff"], ["usb", "serial", "parallel"], [], "w4h6in"),
    m("lp2824plus", "LP 2824 Plus", "LP", "desktop", ["zpl", "epl"], [203], 56, 991, {203: 4}, DT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial"], [], "w2h1in", mdl=["ZTC LP 2824 Plus", "LP 2824 Plus", "LP2824 Plus"]),
    m("tlp2824plus", "TLP 2824 Plus", "LP", "desktop", ["zpl", "epl"], [203], 56, 991, {203: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial"], [], "w2h1in", mdl=["ZTC TLP 2824 Plus", "TLP 2824 Plus", "TLP2824 Plus"]),
    m("lp2844", "LP 2844", "LP", "desktop", ["epl"], [203], 104, 991, {203: 4}, DT, ["tearOff", "peelOff", "cutter"], ["usb", "serial", "parallel"], [], "w4h6in", mdl=["LP 2844", "LP2844", "Zebra LP2844"]),
    m("tlp2844", "TLP 2844", "LP", "desktop", ["epl"], [203], 104, 991, {203: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "serial", "parallel"], [], "w4h6in", mdl=["TLP 2844", "TLP2844", "Zebra TLP2844"]),
    m("lp2844z", "LP 2844-Z", "LP", "desktop", ["zpl"], [203], 104, 991, {203: 4}, DT, ["tearOff", "peelOff", "cutter"], ["usb", "serial", "parallel"], [], "w4h6in", mdl=["LP 2844-Z", "LP2844-Z", "ZTC LP 2844-Z"]),
    m("tlp3842", "TLP 3842", "LP", "desktop", ["epl"], [300], 104, 991, {300: 3}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "serial", "parallel"], [], "w4h6in", mdl=["TLP 3842", "TLP3842"]),
    # --- Industrie -------------------------------------------------------------------------
    m("zt111", "ZT111", "ZT100", "industrial", ["zpl"], [203, 300], 104, 991, {203: 6, 300: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial", "bluetooth"], LINKOS, "w4h6in"),
    m("zt211", "ZT211", "ZT200", "industrial", ["zpl"], [203, 300], 104, 991, {203: 6, 300: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial", "wifi"], LINKOS, "w4h6in"),
    m("zt231", "ZT231", "ZT200", "industrial", ["zpl"], [203, 300], 104, 991, {203: 12, 300: 8}, DTTT, ["tearOff", "peelOff", "cutter", "rewind"], ["usb", "ethernet", "serial", "wifi", "bluetooth"], LINKOS + ["display", "rfid"], "w4h6in"),
    m("zt230", "ZT230", "ZT200", "industrial", ["zpl"], [203, 300], 104, 991, {203: 6, 300: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial", "wifi"], LINKOS, "w4h6in"),
    m("zt410", "ZT410", "ZT400", "industrial", ["zpl"], [203, 300, 600], 104, 3988, {203: 14, 300: 12, 600: 6}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "wifi", "bluetooth"], LINKOS + ["display", "rfid"], "w4h6in"),
    m("zt411", "ZT411", "ZT400", "industrial", ["zpl"], [203, 300, 600], 104, 3988, {203: 14, 300: 12, 600: 6}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "wifi", "bluetooth"], LINKOS + ["display", "rfid"], "w4h6in"),
    m("zt420", "ZT420", "ZT400", "industrial", ["zpl"], [203, 300], 168, 3988, {203: 12, 300: 10}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "wifi", "bluetooth"], LINKOS + ["display", "rfid"], "w6h4in"),
    m("zt421", "ZT421", "ZT400", "industrial", ["zpl"], [203, 300], 168, 3988, {203: 12, 300: 10}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "wifi", "bluetooth"], LINKOS + ["display", "rfid"], "w6h4in"),
    m("zt510", "ZT510", "ZT500", "industrial", ["zpl"], [203, 300], 104, 3988, {203: 12, 300: 12}, DTTT, IND_MODES, ["usb", "ethernet", "serial"], LINKOS, "w4h6in"),
    m("zt610", "ZT610", "ZT600", "industrial", ["zpl"], [203, 300, 600], 104, 3988, {203: 14, 300: 12, 600: 6}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "wifi", "bluetooth"], LINKOS + ["display", "rfid"], "w4h6in"),
    m("zt620", "ZT620", "ZT600", "industrial", ["zpl"], [203, 300], 168, 3988, {203: 12, 300: 10}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "wifi", "bluetooth"], LINKOS + ["display", "rfid"], "w6h4in"),
    m("105slplus", "105SLPlus", "SL", "industrial", ["zpl"], [203, 300], 104, 3988, {203: 12, 300: 8}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "parallel"], [], "w4h6in", mdl=["ZTC 105SLPlus-203dpi ZPL", "ZTC 105SLPlus-300dpi ZPL", "105SLPlus", "105SL Plus"]),
    m("110xi4", "110Xi4", "Xi4", "industrial", ["zpl"], [203, 300, 600], 102, 3988, {203: 14, 300: 12, 600: 6}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "parallel"], [], "w4h6in"),
    m("140xi4", "140Xi4", "Xi4", "industrial", ["zpl"], [203], 128, 3988, {203: 14}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "parallel"], [], "w5h3in"),
    m("170xi4", "170Xi4", "Xi4", "industrial", ["zpl"], [203, 300], 168, 3988, {203: 12, 300: 8}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "parallel"], [], "w6h4in"),
    m("220xi4", "220Xi4", "Xi4", "industrial", ["zpl"], [203, 300], 216, 3988, {203: 10, 300: 6}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "parallel"], [], "w8h6in"),
    m("zm400", "ZM400", "ZM", "industrial", ["zpl"], [203, 300, 600], 104, 3988, {203: 10, 300: 8, 600: 4}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "parallel"], [], "w4h6in"),
    m("zm600", "ZM600", "ZM", "industrial", ["zpl"], [203, 300], 168, 3988, {203: 10, 300: 8}, DTTT, IND_MODES, ["usb", "ethernet", "serial", "parallel"], [], "w6h4in"),
    m("s4m", "S4M", "S4M", "industrial", ["zpl", "epl"], [203, 300], 104, 3988, {203: 6, 300: 4}, DTTT, ["tearOff", "peelOff", "cutter"], ["usb", "ethernet", "serial"], [], "w4h6in"),
    m("ze511", "ZE511", "ZE500", "printEngine", ["zpl"], [203, 300, 600], 104, 3988, {203: 18, 300: 12, 600: 6}, DTTT, ["tearOff", "applicator", "rewind"], ["usb", "ethernet", "serial", "bluetooth"], LINKOS + ["rfid"], "w4h6in"),
    m("ze521", "ZE521", "ZE500", "printEngine", ["zpl"], [203, 300], 168, 3988, {203: 12, 300: 12}, DTTT, ["tearOff", "applicator", "rewind"], ["usb", "ethernet", "serial", "bluetooth"], LINKOS + ["rfid"], "w6h4in"),
    # --- Mobil -----------------------------------------------------------------------------
    m("zq630", "ZQ630", "ZQ600", "mobile", ["zpl", "cpcl"], [203], 104, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "ble", "wifi"], LINKOS + ["battery", "display", "linerless"], "w4h6in"),
    m("zq620", "ZQ620", "ZQ600", "mobile", ["zpl", "cpcl"], [203], 72, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "ble", "wifi"], LINKOS + ["battery", "display", "linerless"], "w3h2in"),
    m("zq610", "ZQ610", "ZQ600", "mobile", ["zpl", "cpcl"], [203], 48, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "ble", "wifi"], LINKOS + ["battery", "display", "linerless"], "w2h1in"),
    m("zq521", "ZQ521", "ZQ500", "mobile", ["zpl", "cpcl"], [203], 104, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "ble", "wifi"], LINKOS + ["battery"], "w4h6in"),
    m("zq511", "ZQ511", "ZQ500", "mobile", ["zpl", "cpcl"], [203], 72, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "ble", "wifi"], LINKOS + ["battery"], "w3h2in"),
    m("zq520", "ZQ520", "ZQ500", "mobile", ["zpl", "cpcl"], [203], 104, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "wifi"], LINKOS + ["battery"], "w4h6in"),
    m("zq510", "ZQ510", "ZQ500", "mobile", ["zpl", "cpcl"], [203], 72, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "wifi"], LINKOS + ["battery"], "w3h2in"),
    m("zq320", "ZQ320", "ZQ300", "mobile", ["zpl", "cpcl"], [203], 72, 1016, {203: 4}, DT, MOB_MODES, ["usb", "bluetooth", "ble", "wifi"], LINKOS + ["battery"], "w3h2in", default_lang="cpcl"),
    m("zq310", "ZQ310", "ZQ300", "mobile", ["zpl", "cpcl"], [203], 48, 1016, {203: 4}, DT, MOB_MODES, ["usb", "bluetooth", "ble", "wifi"], LINKOS + ["battery"], "w2h1in", default_lang="cpcl"),
    m("zq220", "ZQ220", "ZQ200", "mobile", ["cpcl", "zpl"], [203], 72, 1016, {203: 3}, DT, ["tearOff"], ["usb", "bluetooth"], ["battery"], "w3h2in"),
    m("qln420", "QLn420", "QLn", "mobile", ["zpl", "cpcl"], [203], 104, 1016, {203: 5}, DT, MOB_MODES, ["usb", "bluetooth", "wifi", "ethernet"], LINKOS + ["battery", "display"], "w4h6in"),
    m("qln320", "QLn320", "QLn", "mobile", ["zpl", "cpcl"], [203], 72, 1016, {203: 4}, DT, MOB_MODES, ["usb", "bluetooth", "wifi", "ethernet"], LINKOS + ["battery", "display"], "w3h2in"),
    m("imz320", "iMZ320", "iMZ", "mobile", ["cpcl", "zpl"], [203], 72, 1016, {203: 3}, DT, ["tearOff"], ["usb", "bluetooth"], ["battery"], "w3h2in"),
]

def stock(id, name, w, h, gap=3.0, tracking="gap", cat="product", media=None):
    s = {"id": id, "name": name, "widthMM": round(w, 2), "heightMM": round(h, 2), "gapMM": gap,
         "tracking": tracking, "category": cat, "isCustom": False}
    if media:
        s["mediaType"] = media
    return s

IN = 25.4
stocks = [
    stock("w4h6in", "4 × 6 Zoll (Versand)", 4 * IN, 6 * IN, cat="shipping"),
    stock("w4h4in", "4 × 4 Zoll", 4 * IN, 4 * IN, cat="shipping"),
    stock("w4h3in", "4 × 3 Zoll", 4 * IN, 3 * IN, cat="shipping"),
    stock("w4h2in", "4 × 2 Zoll", 4 * IN, 2 * IN, cat="product"),
    stock("w4h1in", "4 × 1 Zoll", 4 * IN, 1 * IN, cat="barcode"),
    stock("w4h8in", "4 × 8 Zoll", 4 * IN, 8 * IN, cat="shipping"),
    stock("w3h2in", "3 × 2 Zoll", 3 * IN, 2 * IN, cat="product"),
    stock("w3h1in", "3 × 1 Zoll", 3 * IN, 1 * IN, cat="barcode"),
    stock("w2h1in", "2 × 1 Zoll", 2 * IN, 1 * IN, cat="barcode"),
    stock("w2h0_5in", "2 × 0,5 Zoll", 2 * IN, 0.5 * IN, cat="barcode"),
    stock("w2_25h1_25in", "2,25 × 1,25 Zoll", 2.25 * IN, 1.25 * IN, cat="barcode"),
    stock("w2_25h0_75in", "2,25 × 0,75 Zoll", 2.25 * IN, 0.75 * IN, cat="barcode"),
    stock("w1_5h1in", "1,5 × 1 Zoll", 1.5 * IN, 1 * IN, cat="barcode"),
    stock("w1h1in", "1 × 1 Zoll", 1 * IN, 1 * IN, cat="barcode"),
    stock("w5h3in", "5 × 3 Zoll", 5 * IN, 3 * IN, cat="product"),
    stock("w6h4in", "6 × 4 Zoll", 6 * IN, 4 * IN, cat="shipping"),
    stock("w8h6in", "8 × 6 Zoll", 8 * IN, 6 * IN, cat="shipping"),
    stock("m100x150", "100 × 150 mm (DHL/DPD/GLS)", 100, 150, cat="shipping"),
    stock("m103x199", "103 × 199 mm (DHL Warenpost)", 103, 199, cat="shipping"),
    stock("m100x100", "100 × 100 mm", 100, 100, cat="shipping"),
    stock("m100x50", "100 × 50 mm", 100, 50, cat="product"),
    stock("m100x70", "100 × 70 mm", 100, 70, cat="shipping"),
    stock("m102x76", "102 × 76 mm", 102, 76, cat="shipping"),
    stock("m102x152", "102 × 152 mm", 102, 152, cat="shipping"),
    stock("m57x32", "57 × 32 mm", 57, 32, cat="product"),
    stock("m57x19", "57 × 19 mm", 57, 19, cat="barcode"),
    stock("m60x40", "60 × 40 mm", 60, 40, cat="product"),
    stock("m70x32", "70 × 32 mm", 70, 32, cat="product"),
    stock("m76x51", "76 × 51 mm", 76, 51, cat="product"),
    stock("m50x25", "50 × 25 mm", 50, 25, cat="barcode"),
    stock("m40x30", "40 × 30 mm", 40, 30, cat="barcode"),
    stock("m38x25", "38 × 25 mm", 38, 25, cat="barcode"),
    stock("m32x25", "32 × 25 mm", 32, 25, cat="barcode"),
    stock("m25x25", "25 × 25 mm", 25, 25, cat="barcode"),
    stock("m89x36", "89 × 36 mm (Adresse)", 89, 36, cat="address"),
    stock("m89x28", "89 × 28 mm (Adresse klein)", 89, 28, cat="address"),
    stock("m54x101", "54 × 101 mm (Versand)", 54, 101, cat="shipping"),
    stock("jewelry", "Schmucketikett 56 × 13 mm", 56, 13, cat="jewelry"),
    stock("wb1x11in", "Patientenarmband 1 × 11 Zoll", 1 * IN, 11 * IN, gap=3.0, tracking="blackMark", cat="wristband"),
    stock("c80", "Endlos 80 mm (Beleg)", 72, 200, gap=0, tracking="continuous", cat="receipt"),
    stock("c58", "Endlos 58 mm (Beleg)", 48, 150, gap=0, tracking="continuous", cat="receipt"),
    stock("c4in", "Endlos 4 Zoll", 4 * IN, 6 * IN, gap=0, tracking="continuous", cat="receipt"),
]

out = {"schemaVersion": 1, "models": models, "stocks": stocks}
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "models.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"{len(models)} Modelle, {len(stocks)} Etikettenformate geschrieben.")
