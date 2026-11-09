#!/bin/bash
# Build the X68000 MiSTer core .rbf with Quartus Prime Lite 17.0.
# Prototype helper for branch prototype/mt32pi-lcd-text-x68000.
# Expects Quartus installed at ~/workspace/tools/quartus-17.0
# (or QUARTUS_DIR set). Fails fast with instructions if it is absent.
# Output: output_files/X68000.rbf  (GENERATE_RBF_FILE is ON in X68000.qsf)
set -e
cd "$(dirname "$0")"

QUARTUS_DIR="${QUARTUS_DIR:-$HOME/workspace/tools/quartus-17.0}"
QUARTUS_SH="$QUARTUS_DIR/quartus/bin/quartus_sh"

if [ ! -x "$QUARTUS_SH" ]; then
    echo "Quartus Prime Lite 17.0 not found at: $QUARTUS_SH" >&2
    echo "See PROTOTYPE-LCD-TEXT.md ('Quartus status') for the blocker:" >&2
    echo "  download QuartusLiteSetup-17.0.0.590-linux.run + Cyclone V" >&2
    echo "  device support with an Intel/Altera account, install under" >&2
    echo "  ~/workspace/tools/quartus-17.0/ (or set QUARTUS_DIR)." >&2
    exit 1
fi

export PATH="$QUARTUS_DIR/quartus/bin:$PATH"
echo "Using Quartus: $QUARTUS_SH"
"$QUARTUS_SH" --flow compile X68000

echo "Build finished."
ls -l output_files/X68000.rbf
