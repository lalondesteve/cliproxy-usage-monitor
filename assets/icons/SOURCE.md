# Compact menubar icon

`compact.svg` is the compact-mode menubar icon: white on transparent, 24×24 viewBox.
Three filled nodes at the center, each with a curved arm out to an open node. It is based
on an "LLM" node icon the user supplied, without the word, and drawn from scratch (not
traced), so no third-party license applies.

Regenerate it with `python3 scripts/glyphs.py spokes "#ffffff" 3 > assets/icons/compact.svg`.
The script can also draw the rejected variants (`ring`, and 4 arms), which are still
compared in `docs/mockups/gauges-overlap.html`.
