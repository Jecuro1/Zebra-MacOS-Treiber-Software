#!/usr/bin/env python3
"""
fake_zebra.py – Nachgebildeter Zebra-Netzwerkdrucker für die End-to-End-Tests des Backends.

Ein TCP-Server (Rohdatenport) mit dem Verhalten, auf das sich das Backend verlässt:

* ``~HS`` (bzw. mit eigenem Steuerzeichen) beantwortet er sofort mit drei Zeilen STX…ETX CR LF:
  Papier leer, Pause, Formate im Empfangspuffer, Druckkopf offen, Farbband leer, Restetiketten.
* Formate ``^XA … ^XZ`` kommen in den Empfangspuffer; ein Druckwerk druckt sie nacheinander,
  jedes Etikett dauert ``print_time`` Sekunden, ``^PQn`` druckt n Etiketten.
* ``~JA`` löscht Empfangspuffer und laufenden Auftrag.
* ``^JZY``/``^JZN``: Bei einem Fehler mitten im Etikett wird es nach dem Beheben erneut gedruckt
  (Y) bzw. geht verloren (N). Standard ist N (``reprint_default``) – so zeigt der Test, dass das
  Backend ^JZY selbst setzt.
* Fehler (``Fault``): nach N fertigen Etiketten tritt Papier leer / Farbband leer / Druckkopf offen /
  Pause ein, mitten im nächsten Etikett, und wird nach ``clear_after`` Sekunden behoben. Mit
  ``power_cycle`` wird der Drucker dabei aus- und eingeschaltet: Puffer weg, Verbindung getrennt,
  kurz nicht erreichbar.
* ``answer_status=False`` simuliert einen Drucker ohne Rückkanal (~HS bleibt unbeantwortet).
* ``offline_until``: nimmt Verbindungen erst ab diesem Zeitpunkt an (Drucker noch aus).

Aufgezeichnet werden die gedruckten Etiketten (Kennung = Inhalt von ^FD), alle empfangenen Bytes,
gesehene Steuerbefehle und die höchste Zahl gleichzeitig im Drucker liegender druckender Formate.
"""

from __future__ import annotations

import re
import socket
import threading
import time
from dataclasses import dataclass, field
from typing import List, Optional

STX = b"\x02"
ETX = b"\x03"


@dataclass
class Fault:
    after_labels: int            # tritt beim Etikett nach so vielen fertigen Etiketten ein
    kind: str                    # "paper", "ribbon", "head", "pause"
    clear_after: float = 0.5     # Sekunden bis zur Behebung
    power_cycle: bool = False    # beim Beheben aus- und einschalten (Puffer weg)
    triggered: bool = False


@dataclass
class Batch:
    label: str
    remaining: int


@dataclass
class FakeZebra:
    format_prefix: str = "^"
    control_prefix: str = "~"
    delimiter: str = ","
    print_time: float = 0.05
    reprint_default: bool = False
    answer_status: bool = True
    faults: List[Fault] = field(default_factory=list)
    offline_until: float = 0.0
    power_cycle_downtime: float = 0.3

    def __post_init__(self) -> None:
        self.lock = threading.RLock()
        # Steuerzeichen nach dem Einschalten (im Drucker gespeicherte Einstellung).
        self._prefixes0 = (self.format_prefix, self.control_prefix, self.delimiter)
        self.printed: List[str] = []
        self.lost: List[str] = []
        self.received = bytearray()
        self.control_commands: List[str] = []
        self.formats_received: List[str] = []
        self.queue: List[Batch] = []
        self.batch: Optional[Batch] = None
        self.reprint = self.reprint_default
        self.paper_out = False
        self.ribbon_out = False
        self.head_open = False
        self.paused = False
        self.max_outstanding = 0
        self.connections = 0
        self.status_queries = 0
        self.cancels = 0
        self.power_cycles = 0
        self._down_until = 0.0
        self._client: Optional[socket.socket] = None
        self._stop = threading.Event()
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(4)
        self._server.settimeout(0.05)
        self.port = self._server.getsockname()[1]
        self._threads = [threading.Thread(target=self._accept_loop, daemon=True),
                         threading.Thread(target=self._engine_loop, daemon=True)]
        for t in self._threads:
            t.start()

    # --- Lebenszyklus --------------------------------------------------------------------

    def close(self) -> None:
        self._stop.set()
        for t in self._threads:
            t.join(timeout=2)
        try:
            self._server.close()
        except OSError:
            pass
        with self.lock:
            if self._client is not None:
                try:
                    self._client.close()
                except OSError:
                    pass

    def idle(self) -> bool:
        with self.lock:
            return not self.queue and self.batch is None

    # --- Netzwerk --------------------------------------------------------------------------

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            now = time.monotonic()
            if now < self.offline_until or now < self._down_until:
                conn.close()   # Drucker (noch) aus
                continue
            with self.lock:
                self.connections += 1
                old = self._client
                self._client = conn
            if old is not None:
                try:
                    old.close()
                except OSError:
                    pass
            threading.Thread(target=self._client_loop, args=(conn,), daemon=True).start()

    def _client_loop(self, conn: socket.socket) -> None:
        conn.settimeout(0.05)
        buffer = bytearray()
        while not self._stop.is_set():
            try:
                data = conn.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            if not data:
                return
            with self.lock:
                if self._client is not conn:
                    return
                self.received.extend(data)
            buffer.extend(data)
            self._parse(buffer, conn)

    def _send(self, conn: socket.socket, data: bytes) -> None:
        try:
            conn.sendall(data)
        except OSError:
            pass

    # --- Befehle ---------------------------------------------------------------------------

    def _parse(self, buffer: bytearray, conn: socket.socket) -> None:
        """Verarbeitet vollständige Befehle/Formate am Anfang des Puffers."""
        while buffer:
            fp = self.format_prefix.encode()
            cp = self.control_prefix.encode()
            head = bytes(buffer[:1])
            if head == cp:
                if len(buffer) < 3:
                    return
                name = buffer[1:3].decode("latin-1").upper()
                if name in ("CC", "CT", "CD"):
                    if len(buffer) < 4:
                        return
                    self._prefix_change(name, chr(buffer[3]))
                    del buffer[:4]
                    continue
                del buffer[:3]
                self._control(name, conn)
                continue
            if head == fp:
                if len(buffer) < 3:
                    return
                name = buffer[1:3].decode("latin-1").upper()
                if name in ("CC", "CT", "CD"):
                    if len(buffer) < 4:
                        return
                    self._prefix_change(name, chr(buffer[3]))
                    del buffer[:4]
                    continue
                if name == "XA":
                    end = self._find_format_end(buffer)
                    if end < 0:
                        # Steuerbefehle wirken auch mitten in einem unvollständigen Format sofort.
                        ja = buffer.find(cp + b"JA")
                        if ja >= 0:
                            del buffer[:ja + 3]
                            self._control("JA", conn)
                            continue
                        return
                    text = bytes(buffer[:end]).decode("latin-1")
                    del buffer[:end]
                    self._format(text)
                    continue
                del buffer[:3]
                continue
            del buffer[:1]

    def _find_format_end(self, buffer: bytearray) -> int:
        marker = (self.format_prefix + "XZ").encode()
        upper = bytes(buffer).upper()
        index = upper.find(marker.upper(), 3)
        return -1 if index < 0 else index + 3

    def _prefix_change(self, name: str, value: str) -> None:
        with self.lock:
            if name == "CC":
                self.format_prefix = value
            elif name == "CT":
                self.control_prefix = value
            else:
                self.delimiter = value

    def _control(self, name: str, conn: socket.socket) -> None:
        with self.lock:
            self.control_commands.append(name)
            if name == "HS":
                self.status_queries += 1
                if self.answer_status:
                    self._send(conn, self._host_status())
            elif name == "JA":
                self.cancels += 1
                self.queue.clear()
                self.batch = None

    def _host_status(self) -> bytes:
        with self.lock:
            formats = len(self.queue)
            remaining = self.batch.remaining if self.batch else 0
            line1 = "030,%d,%d,0609,%03d,0,0,0,000,0,0,0" % (self.paper_out, self.paused, formats)
            line2 = "000,0,%d,%d,1,2,6,0,%08d,1,000" % (self.head_open, self.ribbon_out, remaining)
            line3 = "1234,0"
        return b"".join(STX + line.encode() + ETX + b"\r\n" for line in (line1, line2, line3))

    def _format(self, text: str) -> None:
        fp = re.escape(self.format_prefix)
        d = re.escape(self.delimiter)
        with self.lock:
            self.formats_received.append(text)
            jz = re.search(fp + r"JZ([YN])", text, re.IGNORECASE)
            if jz:
                self.reprint = jz.group(1).upper() == "Y"
            label = re.search(fp + r"FD(.*?)" + fp + "FS", text, re.DOTALL)
            prints = label is not None or re.search(fp + "GF", text, re.IGNORECASE) is not None
            if not prints:
                return
            quantity = 1
            pq = re.search(fp + r"PQ(\d+)(?:" + d + r"|" + fp + r"|\s|$)", text)
            if pq:
                quantity = max(1, int(pq.group(1)))
            self.queue.append(Batch(label.group(1) if label else "graphic", quantity))
            outstanding = len(self.queue) + (1 if self.batch else 0)
            self.max_outstanding = max(self.max_outstanding, outstanding)

    # --- Druckwerk --------------------------------------------------------------------------

    def _blocked(self) -> bool:
        return self.paper_out or self.ribbon_out or self.head_open or self.paused

    def _engine_loop(self) -> None:
        while not self._stop.is_set():
            with self.lock:
                if self.batch is None and self.queue and not self._blocked():
                    self.batch = self.queue.pop(0)
                batch = self.batch
                blocked = self._blocked()
            if batch is None or blocked:
                time.sleep(0.005)
                continue
            # Ein Etikett drucken (Fehler kann mitten im Etikett eintreten).
            fault = self._due_fault()
            if fault is not None:
                time.sleep(self.print_time / 2)
                self._trigger(fault, batch)
                continue
            time.sleep(self.print_time)
            with self.lock:
                if self.batch is not batch or self._blocked():
                    continue   # abgebrochen (~JA) oder Fehler
                self.printed.append(batch.label)
                batch.remaining -= 1
                if batch.remaining <= 0:
                    self.batch = None

    def _due_fault(self) -> Optional[Fault]:
        with self.lock:
            for fault in self.faults:
                if not fault.triggered and len(self.printed) >= fault.after_labels:
                    fault.triggered = True
                    return fault
        return None

    def _trigger(self, fault: Fault, batch: Batch) -> None:
        with self.lock:
            if fault.kind == "paper":
                self.paper_out = True
            elif fault.kind == "ribbon":
                self.ribbon_out = True
            elif fault.kind == "head":
                self.head_open = True
            elif fault.kind == "pause":
                self.paused = True
            interrupted = fault.kind != "pause"
            if interrupted and not self.reprint:
                # ^JZN: das unterbrochene Etikett ist verloren.
                self.lost.append(batch.label)
                batch.remaining -= 1
                if batch.remaining <= 0 and self.batch is batch:
                    self.batch = None
        threading.Timer(fault.clear_after, self._clear, args=(fault,)).start()

    def _clear(self, fault: Fault) -> None:
        with self.lock:
            if fault.power_cycle:
                self.power_cycles += 1
                self.queue.clear()
                self.batch = None
                self.reprint = self.reprint_default
                self.format_prefix, self.control_prefix, self.delimiter = self._prefixes0
                self._down_until = time.monotonic() + self.power_cycle_downtime
                client, self._client = self._client, None
                if client is not None:
                    try:
                        client.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    client.close()
            self.paper_out = self.ribbon_out = self.head_open = self.paused = False
