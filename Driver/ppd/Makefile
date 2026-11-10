# LabelWerk – PPD-Generator (siehe README.md)
#
#   make            PPDs nach $(OUT) erzeugen
#   make gzip       PPDs als .ppd.gz erzeugen
#   make check      erzeugen und mit cupstestppd prüfen
#   make test       Tests (unittest)
#   make list       Ziele auflisten
#   make clean      Ausgabe und Python-Zwischendateien entfernen

PYTHON  ?= python3
OUT     ?= out
VERSION ?= 1.0.0

.PHONY: all ppds gzip check test list clean

all: ppds

ppds:
	$(PYTHON) generate_ppds.py --output "$(OUT)" --file-version "$(VERSION)"

gzip:
	$(PYTHON) generate_ppds.py --output "$(OUT)" --file-version "$(VERSION)" --gzip

check:
	$(PYTHON) generate_ppds.py --output "$(OUT)" --file-version "$(VERSION)" --gzip --check

test:
	$(PYTHON) -m unittest discover -s tests -v

list:
	$(PYTHON) generate_ppds.py --list

clean:
	rm -rf "$(OUT)" __pycache__ tests/__pycache__
