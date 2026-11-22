# Sample shelf

The first launch offers the EPUB and CBZ files in this folder as “Look around first, with a
sample shelf” (`Beispielregal.swift`). They are imported into the “Device” source and can be
removed there like any book of your own. If the folder holds no books, the app does not show
that path.

The files are built by the script `beispielregal.py` from the maintainer's private tooling
(not part of this repository; approved 2026-10-01: Der Schimmelreiter,
Kleider machen Leute, Die Judenbuche, Pepper&Carrot 1–3) — do not drop them in by hand. The
script re-typesets the public-domain texts without any trace of the original, gives each book
an appendix “Personen und Orte” for the glossary feature, and writes `LICENSES.md`, which
the same tooling takes over into the licenses screen.

The books themselves stay German on purpose: they are public-domain classics.
