#!/usr/bin/env python3
"""
run_backend_e2e.py – End-to-End-Tests des CUPS-Backends ``labelwerk`` gegen einen nachgebildeten
Zebra-Drucker (fake_zebra.py).

Das echte Backend wird wie von CUPS gestartet (argv[0] bzw. DEVICE_URI = labelwerk://127.0.0.1:port,
argv 1–5, Druckdaten auf stdin bzw. als Datei in argv[6]); kurze Zeiten über LW_BACKEND_*.
Geprüft wird jeweils:

* jedes Etikett genau einmal gedruckt (auch ^PQ > 1), nie mehr als ein druckendes Format im Drucker;
* der Auftrag endet erst, wenn der Drucker fertig ist;
* Papier leer / Farbband leer / Druckkopf offen / Pause: STATE-Meldungen gesetzt und wieder gelöscht,
  deutsche INFO-Meldung, Fortsetzen nach dem Beheben (der Drucker druckt das unterbrochene Etikett
  wegen ^JZY erneut – der Nachbau verliert es ohne ^JZY);
* Drucker beim Einlegen aus- und eingeschaltet: Wiederverbinden, Rest erneut gesendet;
* nur die Netzverbindung bricht ab, während der Drucker wartet, und die Rolle wird in der Zeit
  eingelegt: nichts erneut gesendet (Neustart-Merker R:LWJOB.GRF vorhanden) – auch mit ^PQ;
* Drucker mitten im Druck ohne Fehler aus- und eingeschaltet: Rest erneut gesendet;
* Neustart nach Steuerzeichenwechsel im Auftrag (^CC/~CT): Antwort mit den gespeicherten Zeichen;
* Drucker ohne ^HW-Antwort: nach einem Abbruch nichts automatisch wiederholen, WARNING;
* „Aufträge vor dem Drucken abbrechen“ (~JA im Kopf): ^JZY erst danach, Pause lwCancelDelay;
* am Stück gesendet und Verbindung mitten im Senden weg: Fehler statt alles doppelt;
* Filter liefert langsam: das erste Etikett druckt, bevor der Auftrag vollständig gelesen ist;
* Abbrechen (SIGTERM): ~JA leert den Druckerpuffer;
* Drucker ohne ~HS-Antwort, EPL, lwResumeOnError=False, ?mode=stream: Senden am Stück;
* eigene Steuerzeichen („Intern“), Kopien aus einer Datei, Drucker anfangs nicht erreichbar;
* Downloads (~DY mit Binärdaten): danach keine ~HS-Abfrage mehr mitten in den Daten.

Aufruf:
    run_backend_e2e.py --backend build/labelwerk [--quick] [--only MUSTER] [--wrapper "valgrind -q"]
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from fake_zebra import Fault, FakeZebra  # noqa: E402

FAST_ENV = {
    "LW_BACKEND_POLL_MS": "15",
    "LW_BACKEND_ERROR_POLL_MS": "40",
    "LW_BACKEND_REPLY_TIMEOUT_MS": "400",
    "LW_BACKEND_STALL_MS": "1500",
    "LW_BACKEND_RECONNECT_MS": "50",
    "LW_BACKEND_RECONNECT_MAX_MS": "200",
    "LW_BACKEND_CONNECT_TIMEOUT_MS": "1000",
    "LW_BACKEND_CANCEL_DELAY_MS": "50",
}


class Failure(AssertionError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def make_job(labels: Sequence[Tuple[str, int]], fp: str = "^", cp: str = "~", d: str = ",",
             prologue: bool = True, rtc_between: bool = False) -> bytes:
    """ZPL wie vom Filter: Kopf, je Etikett ein Format mit ^PQ (optional ^ST-Formate dazwischen)."""
    parts: List[str] = []
    if prologue:
        parts.append(f"{cp}SD15\n{cp}TA010\n{cp}JSN\n")
    for index, (name, quantity) in enumerate(labels):
        if rtc_between and index > 0:
            parts.append(f"{fp}XA{fp}ST11{d}13{d}2026{d}10{d}00{d}{index:02d}{d}M{fp}XZ\n")
        parts.append(f"{fp}XA\n{fp}PW832\n{fp}LL609\n{fp}FO0{d}0{fp}GFA{d}2{d}2{d}1{d}0F0F{fp}FS\n"
                     f"{fp}FO10{d}10{fp}FD{name}{fp}FS\n{fp}PQ{quantity}\n{fp}XZ\n")
    return "".join(parts).encode("latin-1")


def labels(count: int, quantity: int = 1, prefix: str = "L") -> List[Tuple[str, int]]:
    return [(f"{prefix}{i + 1:03d}", quantity) for i in range(count)]


class Run:
    def __init__(self, returncode: int, stderr: str, duration: float):
        self.returncode = returncode
        self.stderr = stderr
        self.duration = duration

    def lines(self, prefix: str) -> List[str]:
        return [line[len(prefix) + 2:] for line in self.stderr.splitlines() if line.startswith(prefix + ": ")]


class Context:
    def __init__(self, backend: str, wrapper: List[str], quick: bool):
        self.backend = backend
        self.wrapper = wrapper
        self.quick = quick

    def start(self, printer: FakeZebra, data: bytes, options: str = "", uri_suffix: str = "",
              file_copies: Optional[int] = None, env: Optional[Dict[str, str]] = None,
              port: Optional[int] = None, keep_stdin: bool = False) -> Tuple[subprocess.Popen, Optional[str]]:
        uri = f"labelwerk://127.0.0.1:{port or printer.port}{uri_suffix}"
        environment = dict(os.environ)
        environment.pop("PPD", None)
        environment.update(FAST_ENV)
        environment["DEVICE_URI"] = uri
        if env:
            environment.update(env)
        args = [uri, "42", "tester", "Etiketten", str(file_copies or 1), options]
        path = None
        if file_copies is not None:
            handle, path = tempfile.mkstemp(prefix="lwbackend-", suffix=".zpl")
            with os.fdopen(handle, "wb") as f:
                f.write(data)
            args.append(path)
        process = subprocess.Popen(self.wrapper + [self.backend] + args[1:] if self.wrapper else args,
                                   executable=None if self.wrapper else self.backend,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=environment)
        if file_copies is None:
            process.stdin.write(data)
        if not keep_stdin:
            process.stdin.close()
        return process, path

    def run(self, printer: FakeZebra, data: bytes, timeout: float = 30, **kwargs) -> Run:
        started = time.monotonic()
        process, path = self.start(printer, data, **kwargs)
        try:
            _, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            _, stderr = process.communicate()
            raise Failure("Backend hat nicht rechtzeitig beendet:\n" + stderr.decode(errors="replace")[-3000:])
        finally:
            if path:
                os.unlink(path)
        return Run(process.returncode, stderr.decode("utf-8", errors="replace"), time.monotonic() - started)


def assert_exactly_once(printer: FakeZebra, expected: Sequence[Tuple[str, int]], copies: int = 1) -> None:
    counts = collections.Counter(printer.printed)
    want = collections.Counter()
    for name, quantity in expected:
        want[name] += quantity * copies
    missing = {k: want[k] - counts[k] for k in want if counts[k] < want[k]}
    extra = {k: counts[k] - want[k] for k in counts if counts[k] > want[k]}
    check(not missing and not extra,
          f"Etiketten nicht genau einmal gedruckt – fehlend {missing}, doppelt {extra}, verloren {printer.lost}")


def wait_until_printed(printer: FakeZebra, count: int, timeout: float = 5) -> None:
    """Am Stück gesendet: Das Backend ist fertig, bevor der Drucker gedruckt hat – warten."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with printer.lock:
            done = len(printer.printed) + len(printer.lost) >= count and printer.idle()
        if done:
            return
        time.sleep(0.01)


def assert_ok(run: Run) -> None:
    check(run.returncode == 0, f"Exitcode {run.returncode}\n{run.stderr[-3000:]}")


def assert_states(run: Run, keyword: str) -> None:
    states = run.lines("STATE")
    check(f"+{keyword}" in states, f"STATE +{keyword} fehlt: {states}")
    check(f"-{keyword}" in states, f"STATE -{keyword} fehlt: {states}")
    check(states.index(f"+{keyword}") < len(states) - 1 - states[::-1].index(f"-{keyword}"),
          f"STATE -{keyword} vor +{keyword}: {states}")


# --- Testfälle ------------------------------------------------------------------------------

def test_normal(ctx: Context) -> None:
    printer = FakeZebra(print_time=0.03)
    try:
        job = labels(8)
        run = ctx.run(printer, make_job(job, rtc_between=True))
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(printer.idle(), "Auftrag endete, bevor der Drucker fertig war")
        check(printer.max_outstanding <= 1, f"{printer.max_outstanding} Formate gleichzeitig im Drucker")
        check(run.duration >= 8 * 0.03, f"Auftrag zu schnell beendet ({run.duration:.2f} s)")
        infos = run.lines("INFO")
        check("Etikett 1 von 8" in infos and "Etikett 8 von 8" in infos, f"Fortschritt fehlt: {infos}")
        check("Alle 8 Etiketten gedruckt." in infos, f"Abschlussmeldung fehlt: {infos}")
        check(printer.formats_received[0].upper().startswith("^XA^JZY^XZ"), "^XA^JZY^XZ nicht zuerst gesendet")
        check(bytes(printer.received).find(b"~SD15") > 0, "Auftragskopf fehlt")
        check(len([f for f in printer.formats_received if "^ST" in f]) == 7, "^ST-Formate fehlen")
        check(not run.lines("STATE") or set(run.lines("STATE")) <= {"-connecting-to-device"},
              f"unerwartete STATE-Meldungen: {run.lines('STATE')}")
    finally:
        printer.close()


def fault_case(kind: str, keyword: str, text: str) -> Callable[[Context], None]:
    def test(ctx: Context) -> None:
        printer = FakeZebra(print_time=0.03, faults=[Fault(after_labels=4, kind=kind, clear_after=0.6)])
        try:
            job = labels(10)
            run = ctx.run(printer, make_job(job))
            assert_ok(run)
            assert_exactly_once(printer, job)
            check(not printer.lost, f"verlorene Etiketten: {printer.lost}")
            assert_states(run, keyword)
            check(any(line.startswith(text) for line in run.lines("INFO")), f"INFO „{text} …“ fehlt: {run.lines('INFO')}")
            check(printer.max_outstanding <= 1, f"{printer.max_outstanding} Formate gleichzeitig im Drucker")
            check(printer.idle(), "Auftrag endete, bevor der Drucker fertig war")
        finally:
            printer.close()
    return test


def test_quantity_batches(ctx: Context) -> None:
    printer = FakeZebra(print_time=0.02, faults=[Fault(after_labels=6, kind="paper", clear_after=0.5)])
    try:
        job = labels(3, quantity=4)
        run = ctx.run(printer, make_job(job))
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(len(printer.printed) == 12, f"{len(printer.printed)} statt 12 Etiketten")
        infos = run.lines("INFO")
        check("Etikett 12 von 12" in infos, f"Fortschritt mit ^PQ fehlt: {infos}")
        assert_states(run, "media-empty-error")
    finally:
        printer.close()


def test_power_cycle(ctx: Context) -> None:
    """Papier leer, Drucker zum Einlegen aus- und eingeschaltet: Puffer weg, Verbindung weg."""
    printer = FakeZebra(print_time=0.02, faults=[Fault(after_labels=5, kind="paper", clear_after=0.6,
                                                         power_cycle=True)])
    try:
        job = [("A", 3), ("B", 4), ("C", 2)]
        run = ctx.run(printer, make_job(job))
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(printer.power_cycles == 1, "kein Neustart simuliert")
        check(printer.connections >= 2, "Backend hat nicht neu verbunden")
        check(any("erneut gesendet" in line for line in run.lines("INFO")), f"Wiederholung nicht gemeldet: {run.lines('INFO')}")
        # Kopf nach dem Neustart erneut gesendet.
        check(bytes(printer.received).count(b"~SD15") == 2, "Auftragskopf nach Neustart nicht erneut gesendet")
        assert_states(run, "media-empty-error")
    finally:
        printer.close()


def test_cancel(ctx: Context) -> None:
    printer = FakeZebra(print_time=0.05)
    try:
        job = labels(40)
        process, _ = ctx.start(printer, make_job(job))
        deadline = time.monotonic() + 10
        while len(printer.printed) < 3 and time.monotonic() < deadline:
            time.sleep(0.01)
        process.send_signal(signal.SIGTERM)
        _, stderr = process.communicate(timeout=10)
        check(process.returncode == 0, f"Exitcode {process.returncode} nach Abbruch")
        time.sleep(0.2)
        check("JA" in printer.control_commands, "~JA nach dem Abbruch nicht gesendet")
        check(printer.idle(), "Druckerpuffer nach ~JA nicht leer")
        check(len(printer.printed) < 40, "Abbruch hat nichts bewirkt")
        check("Auftrag abgebrochen" in stderr.decode(errors="replace"), "Abbruch nicht gemeldet")
    finally:
        printer.close()


def test_cancel_while_paper_out(ctx: Context) -> None:
    printer = FakeZebra(print_time=0.02, faults=[Fault(after_labels=2, kind="paper", clear_after=30)])
    try:
        process, _ = ctx.start(printer, make_job(labels(10)))
        deadline = time.monotonic() + 10
        while not printer.paper_out and time.monotonic() < deadline:
            time.sleep(0.01)
        time.sleep(0.2)
        process.send_signal(signal.SIGTERM)
        _, stderr = process.communicate(timeout=10)
        text = stderr.decode(errors="replace")
        check(process.returncode == 0, f"Exitcode {process.returncode}")
        check("STATE: +media-empty-error" in text and "STATE: -media-empty-error" in text,
              "Fehlerzustand beim Abbruch nicht zurückgesetzt")
        time.sleep(0.1)
        check("JA" in printer.control_commands and printer.idle(), "Druckerpuffer nicht geleert")
    finally:
        printer.close()


def test_no_status_answer(ctx: Context) -> None:
    printer = FakeZebra(print_time=0.01, answer_status=False)
    try:
        job = labels(5)
        run = ctx.run(printer, make_job(job))
        assert_ok(run)
        check(any("beantwortet ~HS nicht" in line for line in run.lines("WARNING")), "Warnung fehlt")
        wait_until_printed(printer, len(job))
        assert_exactly_once(printer, job)
        check(printer.status_queries == 1, f"{printer.status_queries} ~HS-Abfragen statt 1")
    finally:
        printer.close()


def stream_case(options: str = "", uri_suffix: str = "") -> Callable[[Context], None]:
    def test(ctx: Context) -> None:
        printer = FakeZebra(print_time=0.01)
        try:
            job = labels(4)
            run = ctx.run(printer, make_job(job), options=options, uri_suffix=uri_suffix)
            assert_ok(run)
            check(printer.status_queries == 0, "Stream-Modus fragt ~HS ab")
            check(b"^JZY" not in bytes(printer.received), "Stream-Modus sendet ^JZY")
            wait_until_printed(printer, len(job))
            assert_exactly_once(printer, job)
        finally:
            printer.close()
    return test


def test_stream_loses_label(ctx: Context) -> None:
    """Gegenprobe: am Stück gesendet (wie socket://) und ohne ^JZY geht das unterbrochene Etikett verloren."""
    printer = FakeZebra(print_time=0.02, faults=[Fault(after_labels=3, kind="paper", clear_after=0.3)])
    try:
        run = ctx.run(printer, make_job(labels(6)), uri_suffix="?mode=stream")
        assert_ok(run)
        wait_until_printed(printer, 6)
        check(printer.lost == ["L004"], f"Gegenprobe: erwartet verlorenes Etikett L004, war {printer.lost}")
        check(len(printer.printed) == 5, f"Gegenprobe: {len(printer.printed)} gedruckt")
    finally:
        printer.close()


def test_custom_prefixes(ctx: Context) -> None:
    printer = FakeZebra(format_prefix="!", control_prefix="#", delimiter=";", print_time=0.02,
                        faults=[Fault(after_labels=2, kind="ribbon", clear_after=0.4)])
    try:
        job = labels(5, quantity=2)
        options = "lwControlChars=Printer lwFormatPrefix=33 lwControlPrefix=35 lwDelimiter=59"
        run = ctx.run(printer, make_job(job, fp="!", cp="#", d=";"), options=options)
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(b"#HS" in bytes(printer.received), "~HS nicht mit eigenem Steuerzeichen gesendet")
        check(b"!XA!JZY!XZ" in bytes(printer.received), "^JZY nicht mit eigenem Formatzeichen gesendet")
        check(printer.max_outstanding <= 1, f"{printer.max_outstanding} Formate gleichzeitig im Drucker")
        assert_states(run, "marker-supply-empty-error")
    finally:
        printer.close()


def test_file_copies(ctx: Context) -> None:
    printer = FakeZebra(print_time=0.01)
    try:
        job = labels(3)
        run = ctx.run(printer, make_job(job), file_copies=2)
        assert_ok(run)
        assert_exactly_once(printer, job, copies=2)
        check("Etikett 6 von 6" in run.lines("INFO"), f"Fortschritt mit Kopien: {run.lines('INFO')}")
    finally:
        printer.close()


def test_offline_at_start(ctx: Context) -> None:
    printer = FakeZebra(print_time=0.01)
    printer.offline_until = time.monotonic() + 0.6
    try:
        job = labels(3)
        run = ctx.run(printer, make_job(job))
        assert_ok(run)
        assert_exactly_once(printer, job)
        assert_states(run, "connecting-to-device")
        check(any("nicht erreichbar" in line for line in run.lines("INFO")), "Wiederholung nicht gemeldet")
    finally:
        printer.close()


def test_unreachable_gives_up(ctx: Context) -> None:
    # Freier Port ohne Server; mit Versuchsgrenze: CUPS soll den Auftrag später erneut versuchen.
    printer = FakeZebra()
    port = printer.port
    printer.close()
    run = ctx.run(printer, make_job(labels(1)), port=port, env={"LW_BACKEND_RECONNECT_LIMIT": "3"})
    check(run.returncode == 6, f"Exitcode {run.returncode} statt CUPS_BACKEND_RETRY (6)")


def test_bad_uri(ctx: Context) -> None:
    printer = FakeZebra()
    try:
        run = ctx.run(printer, b"", env={"DEVICE_URI": "labelwerk://"})
        check(run.returncode == 1, f"Exitcode {run.returncode} statt 1")
        check(any("Ungültige Geräte-URI" in line for line in run.lines("ERROR")), "Fehlermeldung fehlt")
    finally:
        printer.close()


def test_discovery(ctx: Context) -> None:
    result = subprocess.run(ctx.wrapper + [ctx.backend] if ctx.wrapper else [ctx.backend],
                            capture_output=True, text=True, timeout=10)
    check(result.returncode == 0, f"Exitcode {result.returncode}")
    check(result.stdout.startswith("network labelwerk "), f"Ausgabe: {result.stdout!r}")


def test_commands_only(ctx: Context) -> None:
    """Befehlsfilter (Kalibrieren): nur Steuerbefehle, kein Format."""
    printer = FakeZebra()
    try:
        run = ctx.run(printer, b"~JC\n")
        assert_ok(run)
        check("JC" in printer.control_commands, "~JC nicht gesendet")
        check(not printer.printed, "unerwarteter Druck")
    finally:
        printer.close()


def test_paused_after_reload(ctx: Context) -> None:
    """Nach dem Einlegen bleibt der Drucker angehalten: das Backend setzt mit ~PS fort."""
    printer = FakeZebra(print_time=0.02, pause_after_fault=True,
                        faults=[Fault(after_labels=3, kind="paper", clear_after=0.4)])
    try:
        job = labels(6)
        run = ctx.run(printer, make_job(job))
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(printer.resumes >= 1, "~PS nicht gesendet")
        assert_states(run, "media-empty-error")
    finally:
        printer.close()


def test_user_pause_is_not_overridden(ctx: Context) -> None:
    """Eine Pause ohne vorherigen Fehler beendet nur der Benutzer (kein ~PS)."""
    printer = FakeZebra(print_time=0.02, faults=[Fault(after_labels=2, kind="pause", clear_after=0.5)])
    try:
        job = labels(4)
        run = ctx.run(printer, make_job(job))
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(printer.resumes == 0, "~PS bei einer gewollten Pause gesendet")
    finally:
        printer.close()


def test_direct_thermal_ignores_ribbon_flag(ctx: Context) -> None:
    """Thermo-Direkt: ein gemeldetes „Farbband leer“ hält den Auftrag nicht an."""
    printer = FakeZebra(print_time=0.01, thermal_transfer=False)
    printer.ribbon_out = True
    printer._blocked = lambda: printer.paper_out or printer.head_open or printer.paused  # type: ignore[method-assign]
    try:
        job = labels(3)
        run = ctx.run(printer, make_job(job))
        assert_ok(run)
        assert_exactly_once(printer, job)
        check("+marker-supply-empty-error" not in run.lines("STATE"), f"STATE: {run.lines('STATE')}")
    finally:
        printer.close()


def test_download_is_streamed(ctx: Context) -> None:
    """~DY mit Binärdaten (darin „^XA…^XZ“): ab dem Download keine ~HS-Abfrage mehr mitten in den Daten."""
    printer = FakeZebra(print_time=0.01)
    try:
        job = labels(2)
        payload = b"\x00\x01^XA^FDfake^FS^XZ\x02\x03" * 8
        data = make_job(job) + b"~DYE:LOGO.PNG,B,P,%d,0," % len(payload) + payload + make_job([("Z", 1)], prologue=False)
        run = ctx.run(printer, data)
        assert_ok(run)
        received = bytes(printer.received)
        start = received.find(b"~DYE:LOGO.PNG")
        check(start > 0, "Download nicht gesendet")
        check(b"~HS" not in received[start:], "~HS mitten in den Download-Daten gesendet")
        check(received[start:].startswith(b"~DYE:LOGO.PNG,B,P,%d,0," % len(payload) + payload),
              "Download-Daten verändert")
        check(collections.Counter(printer.printed)["L001"] == 1 and collections.Counter(printer.printed)["L002"] == 1,
              f"Etiketten vor dem Download: {printer.printed}")
    finally:
        printer.close()


def wait_for(condition: Callable[[], bool], timeout: float = 10) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.005)
    return condition()


def net_drop_case(quantity: int) -> Callable[[Context], None]:
    """Papier leer, dann bricht nur die Netzverbindung ab; die Rolle wird eingelegt, während das
    Backend neu verbindet, und der Drucker druckt allein weiter. Nichts darf doppelt kommen."""
    def test(ctx: Context) -> None:
        printer = FakeZebra(print_time=0.03, faults=[Fault(after_labels=2, kind="paper", clear_after=0.6)])
        try:
            job = [("A", quantity), ("B", 1)] if quantity > 1 else labels(5)
            process, _ = ctx.start(printer, make_job(job))
            check(wait_for(lambda: printer.paper_out), "Papier leer nicht eingetreten")
            time.sleep(0.15)   # das Backend hat den Fehler gesehen
            printer.drop_connection(down=1.5)   # länger als bis zum Einlegen
            _, stderr = process.communicate(timeout=30)
            text = stderr.decode("utf-8", errors="replace")
            check(process.returncode == 0, f"Exitcode {process.returncode}\n{text[-2000:]}")
            assert_exactly_once(printer, job)
            check("neu gestartet" not in text, "Neustart vermutet, obwohl nur die Verbindung weg war")
            check(printer.connections >= 2, "Backend hat nicht neu verbunden")
            check(printer.directory_queries >= 2, "Neustart-Merker nach dem Wiederverbinden nicht geprüft")
        finally:
            printer.close()
    return test


def test_power_cycle_while_printing(ctx: Context) -> None:
    """Drucker mitten in einer ^PQ-Menge ohne Fehler aus- und eingeschaltet: Rest erneut gesendet."""
    printer = FakeZebra(print_time=0.1)
    try:
        job = [("A", 6), ("B", 1)]
        process, _ = ctx.start(printer, make_job(job))
        check(wait_for(lambda: len(printer.printed) >= 2), "Druck nicht begonnen")
        time.sleep(0.04)   # das Backend hat „4 Restetiketten“ gesehen, Etikett 3 läuft
        printer.power_cycle()
        _, stderr = process.communicate(timeout=30)
        text = stderr.decode("utf-8", errors="replace")
        check(process.returncode == 0, f"Exitcode {process.returncode}\n{text[-2000:]}")
        assert_exactly_once(printer, job)
        check("erneut gesendet" in text, "Wiederholung nicht gemeldet")
        check(bytes(printer.received).count(b"~SD15") == 2, "Auftragskopf nach Neustart nicht erneut gesendet")
        check(printer.reprint, "^JZY nach dem Neustart nicht erneut gesetzt")
    finally:
        printer.close()


def test_power_cycle_after_prefix_change(ctx: Context) -> None:
    """Der Auftrag stellt per ^CC/~CT auf ! und # um; nach dem Neustart antwortet der Drucker nur auf ~HS."""
    printer = FakeZebra(print_time=0.02, faults=[Fault(after_labels=1, kind="paper", clear_after=0.4,
                                                         power_cycle=True)])
    try:
        job = labels(3)
        data = b"~SD15\n^CC!\n!CT#\n" + make_job(job, fp="!", cp="#", prologue=False)
        run = ctx.run(printer, data, timeout=20)
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(printer.power_cycles == 1, "kein Neustart simuliert")
        check(printer.max_outstanding <= 1, f"{printer.max_outstanding} Formate gleichzeitig im Drucker")
    finally:
        printer.close()


def test_no_marker_support(ctx: Context) -> None:
    """Drucker ohne ^HW-Antwort: nach einem Abbruch nichts automatisch wiederholen, sondern warnen."""
    printer = FakeZebra(print_time=0.03, answer_directory=False,
                        faults=[Fault(after_labels=2, kind="paper", clear_after=0.6)])
    try:
        job = labels(5)
        process, _ = ctx.start(printer, make_job(job))
        check(wait_for(lambda: printer.paper_out), "Papier leer nicht eingetreten")
        time.sleep(0.15)
        printer.drop_connection(down=1.5)
        _, stderr = process.communicate(timeout=30)
        text = stderr.decode("utf-8", errors="replace")
        check(process.returncode == 0, f"Exitcode {process.returncode}\n{text[-2000:]}")
        assert_exactly_once(printer, job)
        warnings = [line for line in text.splitlines() if line.startswith("WARNING: ")]
        check(any("nachzählen" in line for line in warnings), f"Warnung fehlt: {warnings}")
        check("Alle 5 Etiketten gedruckt." not in text, "Erfolg gemeldet, obwohl nicht prüfbar")
    finally:
        printer.close()


def test_cancel_before_prologue(ctx: Context) -> None:
    """~JA im Kopf („Aufträge vor dem Drucken abbrechen“): Pause danach, ^JZY erst danach – sonst
    verwirft ~JA das ^JZY und das unterbrochene Etikett ginge verloren."""
    printer = FakeZebra(print_time=0.03, faults=[Fault(after_labels=2, kind="paper", clear_after=0.4)])
    try:
        job = labels(5)
        run = ctx.run(printer, b"~JA\n~SD15\n" + make_job(job, prologue=False), options="lwCancelDelay=150")
        assert_ok(run)
        assert_exactly_once(printer, job)
        check(not printer.lost, f"verlorene Etiketten: {printer.lost}")
        check(printer.reprint, "^JZY wurde von ~JA verworfen")
        received = bytes(printer.received)
        check(0 <= received.find(b"~JA") < received.find(b"^JZY"), "^JZY vor ~JA gesendet")
        times = {name: when for when, name in reversed(printer.events)}
        check(times["SD"] - times["JA"] >= 0.12, f"keine Pause nach ~JA ({times['SD'] - times['JA']:.3f} s)")
    finally:
        printer.close()


def test_stream_drop_fails(ctx: Context) -> None:
    """Am Stück gesendet (Drucker ohne ~HS) und Verbindung mitten im Senden weg: Fehler, nichts doppelt."""
    printer = FakeZebra(print_time=0.0, answer_status=False, read_throttle=2048)
    try:
        job = labels(1500)
        process, _ = ctx.start(printer, make_job(job), env={"LW_BACKEND_SNDBUF": "4096"})
        check(wait_for(lambda: len(printer.received) > 20000), "Senden nicht begonnen")
        printer.drop_connection(down=2.0)
        _, stderr = process.communicate(timeout=30)
        text = stderr.decode("utf-8", errors="replace")
        check(process.returncode == 1, f"Exitcode {process.returncode} statt 1\n{text[-2000:]}")
        check("nicht erneut gesendet" in text, f"Fehlermeldung fehlt:\n{text[-1500:]}")
        check(printer.connections == 1, f"{printer.connections} Verbindungen – Auftrag erneut gesendet")
        counts = collections.Counter(printer.printed)
        check(not any(n > 1 for n in counts.values()), "Etiketten doppelt gedruckt")
    finally:
        printer.close()


def test_slow_filter(ctx: Context) -> None:
    """Der Filter liefert langsam: das erste Etikett druckt, bevor der Auftrag vollständig gelesen ist."""
    printer = FakeZebra(print_time=0.02)
    try:
        job = labels(4)
        data = make_job(job)
        first_end = data.find(b"^XZ\n") + 4
        process, _ = ctx.start(printer, b"", keep_stdin=True)
        process.stdin.write(data[:first_end])
        process.stdin.flush()
        printed_early = wait_for(lambda: printer.printed[:1] == ["L001"], timeout=10)
        process.stdin.write(data[first_end:])
        process.stdin.close()
        _, stderr = process.communicate(timeout=30)
        text = stderr.decode("utf-8", errors="replace")
        check(printed_early, "erstes Etikett erst nach dem Auftragsende gedruckt")
        check(process.returncode == 0, f"Exitcode {process.returncode}\n{text[-2000:]}")
        assert_exactly_once(printer, job)
        infos = [line[6:] for line in text.splitlines() if line.startswith("INFO: ")]
        check("Etikett 1" in infos, f"Fortschritt ohne Gesamtzahl fehlt: {infos}")
        check("Etikett 4 von 4" in infos, f"Gesamtzahl nach dem Auftragsende fehlt: {infos}")
    finally:
        printer.close()


TESTS: List[Tuple[str, Callable[[Context], None], bool]] = [
    ("normal", test_normal, True),
    ("paper_out", fault_case("paper", "media-empty-error", "Kein Papier"), True),
    ("ribbon_out", fault_case("ribbon", "marker-supply-empty-error", "Farbband leer"), False),
    ("head_open", fault_case("head", "cover-open-error", "Druckkopf offen"), False),
    ("pause", fault_case("pause", "other-warning", "Drucker angehalten"), False),
    ("quantity_batches", test_quantity_batches, False),
    ("power_cycle", test_power_cycle, True),
    ("cancel", test_cancel, True),
    ("cancel_while_paper_out", test_cancel_while_paper_out, False),
    ("no_status_answer", test_no_status_answer, False),
    ("stream_epl", stream_case(options="lwLanguage=EPL"), False),
    ("stream_option", stream_case(options="lwResumeOnError=False"), False),
    ("stream_uri", stream_case(uri_suffix="?mode=stream"), False),
    ("stream_loses_label", test_stream_loses_label, False),
    ("custom_prefixes", test_custom_prefixes, True),
    ("file_copies", test_file_copies, False),
    ("offline_at_start", test_offline_at_start, False),
    ("unreachable_gives_up", test_unreachable_gives_up, False),
    ("bad_uri", test_bad_uri, False),
    ("discovery", test_discovery, True),
    ("commands_only", test_commands_only, False),
    ("download_is_streamed", test_download_is_streamed, False),
    ("paused_after_reload", test_paused_after_reload, False),
    ("user_pause_is_not_overridden", test_user_pause_is_not_overridden, False),
    ("direct_thermal_ignores_ribbon_flag", test_direct_thermal_ignores_ribbon_flag, False),
    ("net_drop_during_fault", net_drop_case(1), True),
    ("net_drop_during_fault_quantity", net_drop_case(6), False),
    ("power_cycle_while_printing", test_power_cycle_while_printing, True),
    ("power_cycle_after_prefix_change", test_power_cycle_after_prefix_change, False),
    ("no_marker_support", test_no_marker_support, False),
    ("cancel_before_prologue", test_cancel_before_prologue, True),
    ("stream_drop_fails", test_stream_drop_fails, False),
    ("slow_filter", test_slow_filter, False),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--backend", required=True, help="Pfad zum gebauten Backend")
    parser.add_argument("--quick", action="store_true", help="nur die Kernfälle")
    parser.add_argument("--only", action="append", default=[], help="nur Fälle, deren Name das Muster enthält")
    parser.add_argument("--wrapper", default="", help="Befehl vor dem Backend (z. B. valgrind)")
    args = parser.parse_args()
    ctx = Context(os.path.abspath(args.backend), shlex.split(args.wrapper), args.quick)
    if ctx.wrapper:
        # Valgrind ist langsam: Zeiten großzügiger.
        FAST_ENV.update({"LW_BACKEND_REPLY_TIMEOUT_MS": "3000", "LW_BACKEND_STALL_MS": "8000"})
    failures = 0
    count = 0
    for name, test, core in TESTS:
        if args.quick and not core:
            continue
        if args.only and not any(re.search(pattern, name) for pattern in args.only):
            continue
        count += 1
        started = time.monotonic()
        try:
            test(ctx)
            print(f"ok    {name} ({time.monotonic() - started:.2f} s)")
        except Failure as error:
            failures += 1
            print(f"FAIL  {name}: {error}")
    print(f"{count} Backend-Fälle, {failures} Fehler")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
