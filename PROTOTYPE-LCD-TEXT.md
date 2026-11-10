# PROTOTYPE — mt32-pi text LCD (option C), X68000 only

Branch: `prototype/mt32pi-lcd-text-x68000` (local only, not pushed).
Status: **prototype, NOT verified.** No Quartus, verilator, iverilog or yosys
exists on this VM, so the RTL has never been compiled or simulated.
Do not ship as-is. The old bitmap path is untouched and still the default
until a text packet arrives.

## FIX1 (2026-11-09) — pipelined text expansion, timing fix

The first CI build failed setup on the 80 MHz video clock (-6.933 ns;
baseline unmodified master is clean at +2.009 ns), so the violation was
introduced by this prototype. The cause was the combinational text
expansion in one CE_PIXEL cycle: `/6` and `%6` dividers, an asynchronous
DDRAM read, and the font-ROM lookup chained into `mt32_lcd_pix`.

FIX1 replaces it with a 3-stage pipeline in `sys/mt32pi.sv`, all feeding
registers, no division/modulo/multiplier in the video path:

- `txt_px==3`: register the DDRAM address of the next char (index via
  shifts: MU50 row*20 = row*16+row*4; SC-55 HD44780 2-line addressing).
- `txt_px==4`: register the DDRAM byte (synchronous read: registered
  address -> register). This also fixes the Quartus warning that
  `lcd_text_ddram` was "uninferred due to asynchronous read logic".
- `txt_px==5`: register the glyph row (font ROM or CGRAM, from the
  registered char). Pixel output then only does a 5:1 mux from the
  registered glyph + a 0..5 pixel counter.
- Char 0 of each line is fetched the same way during horizontal blanking
  (guarded to in-range rows only: MU50 rows 4..7 would address DDRAM
  past entry 79).

CGRAM and flags are now wired in (they were write-only before):
- Codes < 0x10 render from CGRAM (8 chars x 8 rows, 5 bits/row) instead
  of as solid blocks — MU50 bar-graph / SC-55 level-meter glyphs.
- `flags` bit 0 gates the text pixels (LCD enable).
- `flags` bits 4:0 render as 5 MU50 LED squares (5 px wide + 1 px gap,
  page 4, y 32..37, x 0..29; bit i = LED i), shown whenever a text
  packet is active in MU50 mode, independent of the LCD-enable flag.
  Only visible in 128x64 mode (page 4 is outside the 128x32 window).

Rendered output is otherwise unchanged (6 px/char, 8 px/row, same
addressing). Verified by a Python cycle-model of the pipeline against
the original combinational logic (`/tmp/fix1_model.py`, kept on the VM):
0 pixel mismatches across MU50/SC-55 x flags on/off, including a full
horizontal-blanking sweep, and LED geometry matches spec. Timing is
still to be confirmed by the CI rebuild (this fix + rebuild is the one
authorised iteration).

## What it does

The Pi can send the emulated LCD as *text* instead of pixels, and the FPGA
expands it to pixels at video rate. This is design option C from the
SC-55/MU50 LCD assessment: ~150 bytes per update instead of a 1024-byte
bitmap frame, and legible text at 1:1 instead of a downscaled bitmap.

## Wire format (Pi -> FPGA, I2C address 0x3C, existing bus)

```
byte  0: control 0x00            (0x40 = existing SSD1306 bitmap path)
byte  1: magic 0x54 ('T')
byte  2: mode: 0 = SC-55, 1 = MU50
bytes 3..82:   DDRAM, 80 bytes (HD44780 addressing)
bytes 83..146: CGRAM, 64 bytes (captured, not rendered yet)
byte  147: flags: bit0 LCD enable, bits 4:0 MU50 LEDs (captured, not rendered)
total: 148 bytes after the I2C address. Send on change only, from Core 1.
```

A bitmap packet (control 0x40) clears text mode and restores the old
behaviour. A malformed text packet (wrong magic) is ignored.

## Render

- 6 px/char (5 px glyph + 1 px gap), 8 px/row, inside the existing
  128x64 overlay window; no change to the video-side enable window.
- MU50 (mode 1): DDRAM rows are 20 chars: index = row*20 + col (4 rows).
- SC-55 (mode 0): HD44780 2-line addressing: row 0 = DDRAM[0:19],
  row 1 = DDRAM[40:59].
- Font: 5x7, transcribed mechanically from Nuked-SC55 `lcd_font.h`
  (`gen_proto.py` in `~/workspace/mister-lcd-reference/`; the packed
  3325-bit ROM was verified round-trip against the source table).
  Covers ASCII 0x20..0x7E only; other codes render blank.
- CGRAM characters (codes < 0x10, i.e. MU50's bar-graph glyphs and the
  SC-55 level-meter glyphs) render from CGRAM (FIX1); before FIX1 they
  rendered as solid blocks.
- MU50 LEDs render as 5 squares in the row below the text (FIX1).

## Files changed

| File | Change |
|---|---|
| `sys/mt32pi.sv` | Text RAM (DDRAM/CGRAM/mode/flags), text-packet capture in the I2C slave, font ROM + `lcd_text_font_row()`, character expansion in the CLK_VIDEO block, render mux (`lcd_text_valid ? txt_pix : bitmap`). +69/-2 lines. |
| `X68000.sv` | Info popup: `mt32_mode` 0xA3/0xA4/0xA5 map to new codes 13/14/15; `CONF_STR` `I,` list gains "EmuSC", "Nuked SC-55", "MU50" (list terminator `;` moved to the last entry). Previously all three showed "Unknown mode". +10/-2 lines. |
| `build-rbf.sh` (new) | Build wrapper; fails fast with instructions if Quartus is absent. |
| `PROTOTYPE-LCD-TEXT.md` (this file) | This document. |

## What is NOT done

- **Pi side**: nothing sends the text packet yet. The mt32-pi fork needs:
  SC-55 DDRAM snapshot from Nuked (`LCD_Data[80]` + `LCD_CG[64]`) and the
  MU50 HD44780 port, then a Core-1 sender over I2C 0x3C. Until then the
  prototype can only be exercised with a test I2C master.
- **CGRAM / LEDs / contrast**: captured, not rendered. MU50 bar-graph
  characters will show as solid blocks until CGRAM expansion lands.
- **Font**: Nuked's font is used for both modes. MU50's real glyphs come
  from `mu100-font.bin`; ASCII is near-identical, custom glyphs differ.
- **Main**: the `Show Info` popup names are fixed here, but Main's
  `Current Config` decode and the Default Config synth list still only
  know Munt/SoundFont. Selecting EmuSC/Nuked/MU50 from the core is still
  impossible — the FPGA can only *request* Munt/SoundFont (0xA1/0xA2).
- **Clock-domain crossing**: text RAM is written on CLK_AUDIO and read on
  CLK_VIDEO with no synchroniser — the same wart the existing `lcd_data`
  bitmap already has. A torn text frame is possible; the update toggle
  (`mt32_lcd_update`) is the only ordering signal.

## Known prototype warts (fix before shipping)

1. A spurious STOP with `textdata` still set re-toggles `mt32_lcd_update`
   (extra LCD-Auto wake). Harmless, but `textdata` should be cleared on STOP.
2. ~~`/ 6` and `% 6` in the render path~~ — FIXED by FIX1 (pixel counter).
3. ~~`lcd_text_cgram` / `lcd_text_flags` write-only~~ — FIXED by FIX1
   (CGRAM glyphs, LCD-enable gating, MU50 LEDs).

## How to produce the .rbf (once Quartus exists)

```sh
./build-rbf.sh        # quartus_sh --flow compile X68000
ls -l output_files/X68000.rbf
```

`X68000.qsf` already sets `GENERATE_RBF_FILE ON` and
`PROJECT_OUTPUT_DIRECTORY output_files`, so a successful compile emits
the .rbf directly. Then: check the Quartus fit report (timing + M10K
usage), and test on hardware against both a bitmap sender (old path)
and a text-packet sender.

## Quartus status (2026-11-09, blocker)

Quartus Prime Lite 17.0 is **not installed and could not be downloaded
without an Intel/Altera account** from this VM:

- Download page:
  https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-17-0-linux
  — page text is reachable, but it exposes no direct `.run` link
  (JS-gated download centre); `curl` to it returns Akamai **403
  Access Denied**.
- `https://dl.altera.com/17.0/?edition=lite` — empty reply / connection
  failure from this VM.
- `https://fpgasoftware.intel.com/?edition=lite` — redirects to an
  Intel 404 page.
- Contemporary docs (Univ. of Florida, 17.1): "If you are not already
  signed in, you will eventually be asked to log in or to make an
  account."
- Size: installer set ~4 GB download; Lite Edition needs **14 GB** disk
  installed. Disk here is fine (114 GB free); RAM is 7.7 GB total,
  ~1.5 GB available at check time — the single-core Lite fitter will be
  slow (expect 35–60 min for X68000).

**Unblocker**: an Intel/Altera account (Joe's, or a shared one) used in
a real browser to download `QuartusLiteSetup-17.0.0.590-linux.run` +
Cyclone V device support (`.qdz`), then install under
`~/workspace/tools/quartus-17.0/` (persistent across VM restarts).
No account was created and no credentials were entered for this check.
