"""
Z80yPico Partial Emulator with Graphical Display
Version: 25.1 — Delete/Supr keyboard mapping for FW_SUPR + I/O step-limit fix

Emulates a minimal subset of the Z80 instruction set for the Z80yPico
platform with a graphical display window matching the architecture:

  - 32 columns x 24 rows text grid
  - 64-colour palette (loaded from z80ypico_palette_v1.pal)
  - Per-cell ink/paper colours (NO colour clash)
  - Character rendering from binary character ROM (charset.bin)
  - Glyph range 32–158, each glyph 8 bytes (8×8 pixels)
  - On-screen blinking cursor using ROM-based glyph rendering
  - No TTF font dependency for text rendering
  - "Press any key to continue" pagination when output fills screen
  - CR+LF newline convention
  - CRT-style aesthetic with scanlines

The display is a single continuous area. Commands are typed directly
on-screen at the cursor position. The screen scrolls when full, with
a pagination prompt so no output is lost.

Z80yPico channel conventions:
- OUT (1),A  -> console output (rendered on screen)
- OUT (2),A  -> control channel (0x00 = program finished)
- OUT (3),A  -> debug output
- OUT (4),A  -> syscall command port (see below)
- IN A,(1)   -> console input (waits for keypress)
- IN A,(2)   -> status channel
- IN A,(3)   -> debug input placeholder
- IN A,(4)   -> syscall result (0x00 = OK, 0x01 = error)

Console output control characters (OUT (1),A):
  0x08  BS   — backspace (move cursor left, non-destructive)
  0x0A  LF   — line feed
  0x0D  CR   — carriage return
  0x0E  SO   — cursor on (enable blinking cursor)
  0x0F  SI   — cursor off (hide cursor)
  0x20-0x7E  — printable ASCII

Console input key codes (IN A,(1)):
  0x01  Left
  0x02  Right
  0x03  Up
  0x04  Down
  0x08  Backspace
  0x0A  Enter (line feed)
  0x1B  Escape
  0x20-0x7E  Printable ASCII
  0x7F  Delete / Supr

Syscall commands (OUT (4),A):
  0x01  CLS    — Clear screen
  0x02  LOAD   — Load file named at 0x7F00 into 0x8000
  0x03  RUN    — Execute loaded program at 0x8000
  0x04  DIR    — List working directory to console
  0x05  PWD    — Print working directory to console
  0x06  NEW    — Soft reset (CPU registers only, keep RAM)
  0x07  STATUS — Print loaded program info
  0x08  RESET  — Full factory reset (clear RAM, restore defaults)
  0x10  INK    — Set foreground colour (value at 0x7F00)
  0x11  PAPER  — Set background colour (value at 0x7F00)
  0x12  BORDER — Set border colour (value at 0x7F00)
  0x13  FLASH  — Set flash mode (value at 0x7F00: 0|1)
  0x14  BRIGHT — Set bright mode (value at 0x7F00: 0|1)
  0x20  LOCATE — Set cursor position (row at 0x7F00, col at 0x7F01)

Colour system:
  64-colour palette, no colour clash.
  Each character cell stores its own ink and paper colour index.
  Palette indices 0-7: normal colours
  Palette indices 8-15: bright variants of 0-7
  Palette indices 16-63: extended colours
  Bright mode: indices 0-7 map to 8-15; others unchanged.

Memory map (authoritative — see z80ypico_rom_map.md):
  0x0000-0x0002  BIOS reset vector (JP 0x8000)
  0x0003-0x7C7F  Reserved / future ROM space
  0x7C80-0x7C8F  FW_PUTCHAR   — single character output
  0x7C90-0x7C9F  FW_PRINT     — null-terminated string output
  0x7CA0-0x7CAF  FW_LOCATE    — set cursor position
  0x7CB0-0x7CFF  Reserved for future console firmware
  0x7D00-0x7DFF  CMD execution window (256 bytes)
  0x7E00-0x7E0F  FW_CLS       — clear screen
  0x7E10-0x7E1F  FW_DIR       — list directory
  0x7E20-0x7E2F  FW_PWD       — print working directory
  0x7E30-0x7E3F  FW_STATUS    — show loaded program info
  0x7E40-0x7E4F  FW_INK       — set ink colour
  0x7E50-0x7E5F  FW_PAPER     — set paper colour
  0x7E60-0x7E6F  FW_BORDER    — set border colour
  0x7E70-0x7E7F  FW_FLASH     — set flash mode
  0x7E80-0x7E8F  FW_BRIGHT    — set bright mode
  0x7E90-0x7E9F  FW_GETKEY    — wait for keypress
  0x7EA0-0x7EFF  FW_INPUTLINE — line input with editing (multi-slot)
  0x7F00-0x7FFF  System parameter / syscall buffer
  0x8000-0xFFFF  User program area (reserved for user programs only)

Firmware API (user programs can CALL these addresses):
  FW_PUTCHAR   = 0x7C80     FW_PRINT     = 0x7C90
  FW_LOCATE    = 0x7CA0
  FW_CLS       = 0x7E00     FW_DIR       = 0x7E10
  FW_PWD       = 0x7E20     FW_STATUS    = 0x7E30
  FW_INK       = 0x7E40     FW_PAPER     = 0x7E50
  FW_BORDER    = 0x7E60     FW_FLASH     = 0x7E70
  FW_BRIGHT    = 0x7E80
  FW_GETKEY    = 0x7E90     FW_INPUTLINE = 0x7EA0

Console input firmware (v23.0):
  FW_GETKEY    (0x7E90)
    Waits for a single keypress and returns ASCII in register A.
    On real hardware this reads the PS/2 keyboard via the Pico.
    In the emulator this is backed by pygame keyboard events.
    Z80 implementation: IN A,(1) / RET
    Usage:
        CALL 0x7E90      ; FW_GETKEY
        ; A now contains the ASCII code of the key pressed

  FW_INPUTLINE (0x7EA0)
    Reads a full line of text with editing (backspace, escape).
    Echoes characters to the console. Terminates on Enter.
    Stores the null-terminated result in the syscall buffer at
    0x7F00 (max 255 characters + null).
    Implemented as real Z80 machine code that calls FW_GETKEY.
    On real hardware the Pico firmware provides an equivalent
    native routine using PS/2 keyboard input.
    Usage:
        CALL 0x7EA0      ; FW_INPUTLINE
        ; 0x7F00 now contains the null-terminated input string

  Console input architecture (prepares for Z80yPico hardware):

    PS/2 keyboard
          ↓
    Pico firmware
          ↓
    FW_GETKEY         ← Layer 1: single key input
          ↓
    FW_INPUTLINE      ← Layer 2: line input with editing
          ↓
    Shell / INPUT / programs  ← Layer 3: clients

Console output firmware (v23.0):
  FW_PUTCHAR   (0x7C80)
    Prints a single ASCII character to the console.
    Input: A = character to print.
    Sends the character via OUT (1),A and returns.
    Z80 implementation: OUT (1),A / RET
    Usage:
        LD A, 'A'         ; character to print
        CALL 0x7C80       ; FW_PUTCHAR
        ; character 'A' is now on screen

  FW_PRINT     (0x7C90)
    Prints a null-terminated string to the console.
    Input: HL = address of null-terminated string (DB "text",0).
    Walks the string byte-by-byte, sending each character via
    OUT (1),A until a 0x00 terminator is reached.
    HL points past the string on return.
    Usage:
        LD HL, msg        ; pointer to string
        CALL 0x7C90       ; FW_PRINT
        RET
        msg: DB "Hello, world!", 0

  Console output architecture:

    FW_PUTCHAR        ← Primitive: single character output
          ↓
    FW_PRINT          ← String output (loops over FW_PUTCHAR logic)
          ↓
    FW_LOCATE         ← Absolute cursor positioning
          ↓
    User programs     ← Clients

New Z80 opcodes in v23.0:
  CP n   (0xFE)  — Compare A with immediate value
  CP B   (0xB8)  — Compare A with register B
  DEC DE (0x1B)  — Decrement register pair DE
  LD A,E (0x7B)  — Load A from E
  LD A,D (0x7A)  — Load A from D
  LD C,A (0x4F)  — Load C from A
  LD A,C (0x79)  — Load A from C

Shell commands (help, cls, dir, load, run, etc.) are implemented
as Z80 machine code routines that use the I/O ports above. On the
real Z80yPico hardware, port 4 maps to the Pico host controller,
which services file and system operations over the Z80 bus.

All Z80 instructions from v6.0 are preserved.

Font: place charset.bin in the same directory as this script.
      Binary character ROM: 127 glyphs (codes 32–158), 8 bytes each.
      Generate with build_charset_bin.py if not available.

Palette: place z80ypico_palette_v1.pal in the same directory.
"""

import sys
import os
import re
import csv
import time
import pygame
from pathlib import Path

# Z80yPico BASIC integration
try:
    from z80ypico_basic import BasicInterpreter
    _HAS_BASIC = True
except ImportError:
    _HAS_BASIC = False


# ─────────────────────────────────────────────────────────────────────
#  Palette
# ─────────────────────────────────────────────────────────────────────

def load_palette(filepath: Path | None = None) -> list[tuple[int, int, int]]:
    """Load a JASC-PAL palette file. Returns list of 64 RGB tuples."""
    search_paths = []
    if filepath:
        search_paths.append(filepath)
    script_dir = Path(__file__).resolve().parent
    search_paths += [
        script_dir / "z80ypico_palette_v1.pal",
        Path("z80ypico_palette_v1.pal"),
        Path.home() / "z80ypico_palette_v1.pal",
    ]
    for p in search_paths:
        if p.exists():
            with open(p) as f:
                lines = f.readlines()
            colours = []
            for line in lines[3:]:  # skip JASC-PAL, version, count
                parts = line.strip().split()
                if len(parts) == 3:
                    r, g, b = int(parts[0]), int(parts[1]), int(parts[2])
                    colours.append((r, g, b))
            if len(colours) >= 64:
                print(f"Loaded palette from {p} ({len(colours)} colours)")
                return colours[:64]
    # Fallback: generate a basic 64-colour palette
    print("Palette file not found — using fallback.")
    pal = [(0, 0, 0)] * 64
    # Spectrum-like first 16
    base = [
        (0,0,0), (0,0,192), (192,0,0), (192,0,192),
        (0,192,0), (0,192,192), (192,192,0), (192,192,192),
        (0,0,0), (0,0,255), (255,0,0), (255,0,255),
        (0,255,0), (0,255,255), (255,255,0), (255,255,255),
    ]
    for i, c in enumerate(base):
        pal[i] = c
    for i in range(16, 64):
        v = (i * 4) & 0xFF
        pal[i] = (v, v, v)
    return pal


# ─────────────────────────────────────────────────────────────────────
#  CSV Decode Table
# ─────────────────────────────────────────────────────────────────────

def load_decode_table(csv_path: Path | None = None) -> dict:
    """Load the Z80 opcode decode table from CSV.

    Returns a dict keyed by (prefix, opcode_int), e.g. ("NONE", 0x01).
    Each value is a dict with keys:
        prefix, opcode, status, mnemonic, bytes, t_states, flags
    """
    search_paths = []
    if csv_path:
        search_paths.append(csv_path)
    script_dir = Path(__file__).resolve().parent
    search_paths += [
        script_dir / "z80_decode_v3.csv",
        Path("z80_decode_v3.csv"),
    ]
    found = None
    for p in search_paths:
        if p.exists():
            found = p
            break
    if found is None:
        print("WARNING: z80_decode_v3.csv not found — decode table empty.")
        return {}

    table = {}
    with open(found, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            prefix = row["prefix"].strip()
            opcode = int(row["opcode_hex"].strip(), 16)
            entry = {
                "prefix":   prefix,
                "opcode":   opcode,
                "status":   row["status"].strip(),
                "mnemonic": row["mnemonic"].strip().strip('"'),
                "bytes":    int(row["bytes"].strip()),
                "t_states": int(row["t_states"].strip()),
                "flags":    row["flags"].strip(),
            }
            table[(prefix, opcode)] = entry
    print(f"Loaded decode table from {found} ({len(table)} entries)")
    return table


# ─────────────────────────────────────────────────────────────────────
#  Z80yPico Emulator Core
# ─────────────────────────────────────────────────────────────────────

class Z80yPicoEmulator:
    BIOS_RESET_VECTOR = 0x0000
    FIRMWARE_BASE = 0x7E00        # Resident firmware routines (ROM)
    FIRMWARE_SLOT_SIZE = 0x10     # 16 bytes per firmware slot
    WRAPPER_ADDRESS = 0x7D00      # Shell command wrapper execution area
    COMMAND_ADDRESS = 0x7E00      # Legacy alias (firmware base)
    USER_PROGRAM_ADDRESS = 0x8000

    # ── Firmware address table ──
    # Fixed addresses for callable firmware routines.
    # User programs can CALL these directly.
    FW_CLS       = 0x7E00
    FW_DIR       = 0x7E10
    FW_PWD       = 0x7E20
    FW_STATUS    = 0x7E30
    FW_INK       = 0x7E40
    FW_PAPER     = 0x7E50
    FW_BORDER    = 0x7E60
    FW_FLASH     = 0x7E70
    FW_BRIGHT    = 0x7E80
    FW_GETKEY    = 0x7E90   # Layer 1: single key input → ASCII in A
    FW_INPUTLINE = 0x7EA0   # Layer 2: line input → null-terminated at 0x7F00

    # ── Console output firmware ──
    # These routines provide character and string output services.
    # They live in the extended firmware area (0x7C80-0x7CFF) because
    # the primary firmware block (0x7E00-0x7EFF) is fully allocated.
    #
    # FW_PUTCHAR (0x7C80)
    #   Print a single character to the console.
    #   Input:  A = ASCII character to print
    #   Effect: Sends the character via OUT (1),A
    #   Usage:
    #       LD A, 'A'
    #       CALL 0x7C80      ; FW_PUTCHAR
    #
    # FW_PRINT (0x7C90)
    #   Print a null-terminated string to the console.
    #   Input:  HL = address of null-terminated string
    #   Effect: Sends each character via OUT (1),A until a 0x00 byte
    #   Usage:
    #       LD HL, msg
    #       CALL 0x7C90      ; FW_PRINT
    #       RET
    #       msg: DB "Hello, world!",0
    #
    FW_PUTCHAR   = 0x7C80   # Console output: single character (A = char)
    FW_PRINT     = 0x7C90   # Console output: null-terminated string (HL = addr)
    FW_LOCATE    = 0x7CA0   # Console: set cursor position (row@7F00, col@7F01)

    CHANNEL_CONSOLE_OUT = 1
    CHANNEL_CONTROL = 2
    CHANNEL_DEBUG = 3
    CHANNEL_SYSCALL = 4

    CHANNEL_CONSOLE_IN = 1
    CHANNEL_STATUS = 2
    CHANNEL_DEBUG_IN = 3
    CHANNEL_SYSCALL_IN = 4
    CHANNEL_CUR_ROW = 5    # IN A,(5) = cursor row
    CHANNEL_CUR_COL = 6    # IN A,(6) = cursor col

    SYSCALL_BUFFER = 0x7F00
    VRAM_BASE = 0xD000      # 768 bytes memory-mapped display grid

    # Syscall command codes (OUT (4),A)
    SYS_CLS  = 0x01
    SYS_LOAD = 0x02
    SYS_RUN  = 0x03
    SYS_DIR  = 0x04
    SYS_PWD  = 0x05
    SYS_NEW  = 0x06
    SYS_STATUS = 0x07
    SYS_RESET  = 0x08    # Full factory reset (stronger than NEW)
    SYS_INK    = 0x10
    SYS_PAPER  = 0x11
    SYS_BORDER = 0x12
    SYS_FLASH  = 0x13
    SYS_BRIGHT = 0x14
    SYS_LOCATE = 0x20       # Set cursor position (row@7F00, col@7F01)

    # ── BASIC interpreter syscall codes (OUT (2),1) ──
    # The BASIC interpreter uses port 2 with value 1 as its syscall trigger.
    # The command byte is read from SYSCALL_BUFFER[0], arguments from [1]+.
    BSYS_FILE_OPEN   = 0x10   # Open text file for line-by-line reading
    BSYS_FILE_NEXT   = 0x11   # Read next line from open file
    BSYS_FILE_CLOSE  = 0x12   # Close read file
    BSYS_FILE_WOPEN  = 0x13   # Open file for writing
    BSYS_FILE_WLINE  = 0x14   # Write one line to open file
    BSYS_FILE_WCLOSE = 0x15   # Close write file
    BSYS_BIN_LOAD    = 0x16   # Load binary file into RAM at 0xC000
    BSYS_CHDIR       = 0x17   # Change working directory
    BSYS_GETCWD      = 0x18   # Get current working directory
    BSYS_DIR_FIRST   = 0x19   # Begin directory iteration (.bas/.bin)
    BSYS_DIR_NEXT    = 0x1A   # Next filename in directory iteration

    STACK_INIT = 0xFFFF

    TEXT_COLS = 32
    TEXT_ROWS = 24

    def __init__(self, display: "Z80yPicoDisplay") -> None:
        self.display = display
        self.mem = bytearray(65536)
        # If True, install_bios() will install in-Python fabricated
        # firmware bytes when the corresponding FW_*.bin is missing,
        # instead of failing. Off by default per the firmware
        # externalisation policy. Set to True only as an explicit
        # transitional escape hatch. Honours a class-level default
        # (_default_legacy_firmware) so CLI flags can opt in.
        self.firmware_legacy_fallback = getattr(
            type(self), "_default_legacy_firmware", False
        )
        # Track whether install_bios()'s diagnostic output has already
        # been printed once. The bytes are still rewritten on every
        # call (defensive against a caller that mutated ROM space),
        # but the per-slot prints are silenced after the first install
        # to keep the boot log readable.
        self._firmware_diag_printed = False
        self.a = 0
        self.b = 0
        self.c = 0
        self.d = 0
        self.e = 0
        self.h = 0
        self.l = 0
        self.f = 0
        self.sp = self.STACK_INIT
        self.ix = 0
        self.pc = self.BIOS_RESET_VECTOR
        self.zf = False
        self.cf = False
        self.running = False
        self.console_input_buffer: list[int] = []
        self.program_length: int = 0
        self.program_name: str = ""
        self.syscall_result: int = 0x00  # last syscall result for IN A,(4)
        self.current_dir: Path = Path(".")  # set by main()
        self._pending_run: bool = False
        self._pending_factory_reset: bool = False
        self._basic_read_file = None     # open file handle for BASIC LOAD
        self._basic_write_file = None    # open file handle for BASIC SAVE
        self._dir_iter: list[str] | None = None  # directory iteration list
        self._dir_iter_idx: int = 0              # current index in dir list
        self.t_states: int = 0
        self.decode_table: dict = {}       # set by main() via load_decode_table()
        self.dispatch_table: dict = {}     # set by _build_dispatch_table()
        self.shell_mode: bool = True       # True = shell (block UP/DOWN), False = BASIC

        # Connect display to emulator memory for VRAM sync
        self.display.vram_mem = self.mem

    # ── Register pairs ──

    @property
    def af(self) -> int:
        return (self.a << 8) | self.f

    @af.setter
    def af(self, value: int) -> None:
        value &= 0xFFFF
        self.a = (value >> 8) & 0xFF
        self.f = value & 0xFF

    def _flags_to_f(self) -> None:
        self.f = 0
        if self.zf:
            self.f |= 0x40
        if self.cf:
            self.f |= 0x01

    def _f_to_flags(self) -> None:
        self.zf = bool(self.f & 0x40)
        self.cf = bool(self.f & 0x01)

    @property
    def bc(self) -> int:
        return (self.b << 8) | self.c

    @bc.setter
    def bc(self, value: int) -> None:
        value &= 0xFFFF
        self.b = (value >> 8) & 0xFF
        self.c = value & 0xFF

    @property
    def de(self) -> int:
        return (self.d << 8) | self.e

    @de.setter
    def de(self, value: int) -> None:
        value &= 0xFFFF
        self.d = (value >> 8) & 0xFF
        self.e = value & 0xFF

    @property
    def hl(self) -> int:
        return (self.h << 8) | self.l

    @hl.setter
    def hl(self, value: int) -> None:
        value &= 0xFFFF
        self.h = (value >> 8) & 0xFF
        self.l = value & 0xFF

    # ── System ──

    def reset(self) -> None:
        self.mem = bytearray(65536)
        self.a = 0
        self.b = 0
        self.c = 0
        self.d = 0
        self.e = 0
        self.h = 0
        self.l = 0
        self.f = 0
        self.sp = self.STACK_INIT
        self.ix = 0
        self.pc = self.BIOS_RESET_VECTOR
        self.zf = False
        self.cf = False
        self.running = False
        self.console_input_buffer = []
        self.program_length = 0
        self.program_name = ""
        self.t_states = 0
        self.install_bios()

    def soft_reset(self) -> None:
        """Reset CPU registers and flags without clearing RAM."""
        self.a = 0
        self.b = 0
        self.c = 0
        self.d = 0
        self.e = 0
        self.h = 0
        self.l = 0
        self.f = 0
        self.sp = self.STACK_INIT
        self.ix = 0
        self.pc = self.BIOS_RESET_VECTOR
        self.zf = False
        self.cf = False
        self.running = False
        self.console_input_buffer = []
        self.t_states = 0
        self.install_bios()

    def factory_reset(self) -> None:
        """Full factory reset — power-on state for the entire machine.

        This is stronger than both soft_reset() and reset():
          - Clears all RAM (64K zeroed)
          - Resets all CPU registers and flags
          - Clears program metadata (name, length)
          - Reinstalls BIOS / firmware
          - Restores display to factory defaults (ink, paper, border,
            bright, flash, cursor, pagination, grid, flash cells)
          - Clears the screen with factory default attributes
          - Resets the syscall result latch
          - Clears pending-run flag

        After this call, the machine is in the same state as a fresh
        boot.  The caller should then show_boot_screen() to complete
        the power-on experience.
        """
        # ── CPU + memory ──
        self.mem = bytearray(65536)
        self.a = 0
        self.b = 0
        self.c = 0
        self.d = 0
        self.e = 0
        self.h = 0
        self.l = 0
        self.f = 0
        self.sp = self.STACK_INIT
        self.ix = 0
        self.pc = self.BIOS_RESET_VECTOR
        self.zf = False
        self.cf = False
        self.running = False
        self.console_input_buffer = []
        self.t_states = 0

        # ── Program metadata ──
        self.program_length = 0
        self.program_name = ""

        # ── Syscall state ──
        self.syscall_result = 0x00
        self._pending_run = False
        self._pending_factory_reset = False

        # ── Firmware ──
        self.install_bios()

        # ── Display: restore factory defaults and clear screen ──
        self.display.factory_reset()

    def install_bios(self) -> None:
        """Install BIOS reset vector and resident firmware routines.

        Firmware routines live at fixed addresses in 0x7E00-0x7EFF.
        Each routine ends with RET and can be called from user programs.
        """
        # Reset vector: JP 0x8000
        self.mem[0x0000] = 0xC3
        self.mem[0x0001] = self.USER_PROGRAM_ADDRESS & 0xFF
        self.mem[0x0002] = (self.USER_PROGRAM_ADDRESS >> 8) & 0xFF

        # Install firmware routines into ROM space
        self._install_firmware()

    def _install_firmware(self) -> None:
        """Write all firmware routines into their fixed ROM slots.

        Architectural rule (WORKFLOW_06 firmware externalisation):
        Firmware is loaded from external `FW_*.bin` files whenever they
        exist on disk. The Python emulator stops being a firmware
        author. The on-disk binaries are produced from the canonical
        `FW_*.asm` sources and are the single source of truth for
        firmware behaviour.

        Loading is driven by `FIRMWARE_TABLE` below. Each entry maps a
        filename to its authoritative ROM slot address. Filenames are
        searched in (a) the emulator's folder and (b) the current
        working directory.

        Strict mode (default):
            If a required FW_*.bin is missing, raise FileNotFoundError.
            This is the policy required by the externalisation
            milestone — Python must not silently fabricate ROM bytes.

        Legacy fallback mode (opt-in):
            If `self.firmware_legacy_fallback` is True (set by callers
            that need to work in environments where the BINs are not
            yet present), the fabricated Python equivalents are
            installed for any missing BIN, with a clearly labelled
            "[legacy]" diagnostic. This mode is explicit and
            transitional, never the default.

        FW_INPUTLINE has its own loading convention (binary at 0x0003,
        trampoline at 0x7EA0). It is handled separately at the end.

        Reset vector handling and FW_GETKEY remain untouched in the
        sense that they are still 2-3 byte primitives — but they too
        are loaded from BIN when the BIN is present.
        """
        # ── Firmware table: (BIN filename, ROM slot, required, fallback bytes)
        # Authoritative addresses match the ROM map. The "fallback"
        # bytes are the original Python-fabricated routines. They are
        # used only in legacy fallback mode for missing BINs.
        SYS = self
        firmware_table = [
            # FW_PUTCHAR: OUT (1),A / RET
            ("FW_PUTCHAR.bin", SYS.FW_PUTCHAR, True,
             bytes([0xD3, 0x01, 0xC9])),

            # FW_PRINT: print null-terminated string at (HL)
            ("FW_PRINT.bin", SYS.FW_PRINT, True,
             bytes([0x7E, 0xB7, 0x28, 0x05, 0xD3, 0x01, 0x23, 0x18, 0xF7, 0xC9])),

            # FW_LOCATE: LD A,SYS_LOCATE / OUT (4),A / RET
            ("FW_LOCATE.bin", SYS.FW_LOCATE, True,
             bytes([0x3E, 0x20, 0xD3, 0x04, 0xC9])),

            # Parameterless syscall stubs:  LD A,code / OUT (4),A / RET
            ("FW_CLS.bin", SYS.FW_CLS, True,
             bytes([0x3E, SYS.SYS_CLS, 0xD3, 0x04, 0xC9])),
            ("FW_DIR.bin", SYS.FW_DIR, True,
             bytes([0x3E, SYS.SYS_DIR, 0xD3, 0x04, 0xC9])),
            ("FW_PWD.bin", SYS.FW_PWD, True,
             bytes([0x3E, SYS.SYS_PWD, 0xD3, 0x04, 0xC9])),
            ("FW_STATUS.bin", SYS.FW_STATUS, True,
             bytes([0x3E, SYS.SYS_STATUS, 0xD3, 0x04, 0xC9])),

            # Parameterised syscall stubs:
            #   LD A,(0x7F00) / LD (0x7F00),A / LD A,code / OUT (4),A / RET
            ("FW_INK.bin", SYS.FW_INK, True,
             bytes([0x3A, 0x00, 0x7F, 0x32, 0x00, 0x7F,
                    0x3E, SYS.SYS_INK, 0xD3, 0x04, 0xC9])),
            ("FW_PAPER.bin", SYS.FW_PAPER, True,
             bytes([0x3A, 0x00, 0x7F, 0x32, 0x00, 0x7F,
                    0x3E, SYS.SYS_PAPER, 0xD3, 0x04, 0xC9])),
            ("FW_BORDER.bin", SYS.FW_BORDER, True,
             bytes([0x3A, 0x00, 0x7F, 0x32, 0x00, 0x7F,
                    0x3E, SYS.SYS_BORDER, 0xD3, 0x04, 0xC9])),
            ("FW_FLASH.bin", SYS.FW_FLASH, True,
             bytes([0x3A, 0x00, 0x7F, 0x32, 0x00, 0x7F,
                    0x3E, SYS.SYS_FLASH, 0xD3, 0x04, 0xC9])),
            ("FW_BRIGHT.bin", SYS.FW_BRIGHT, True,
             bytes([0x3A, 0x00, 0x7F, 0x32, 0x00, 0x7F,
                    0x3E, SYS.SYS_BRIGHT, 0xD3, 0x04, 0xC9])),

            # FW_GETKEY: IN A,(1) / RET
            ("FW_GETKEY.bin", SYS.FW_GETKEY, True,
             bytes([0xDB, 0x01, 0xC9])),
        ]

        legacy_mode = getattr(self, "firmware_legacy_fallback", False)
        script_dir = Path(__file__).resolve().parent
        loaded_count = 0
        fallback_count = 0
        missing_required = []

        # Print per-slot diagnostics only the first time install_bios()
        # is called on this emulator instance. The bytes themselves are
        # always (re-)written, but downstream calls (run_from() does a
        # defensive install_bios()) won't re-spam the boot log.
        verbose = not self._firmware_diag_printed

        for filename, address, required, fallback_bytes in firmware_table:
            data = None
            for try_path in (script_dir / filename, Path(filename)):
                if try_path.exists() and try_path.is_file():
                    data = try_path.read_bytes()
                    break

            if data is not None:
                self.mem[address:address + len(data)] = data
                if verbose:
                    print(f"  {filename}: {len(data)} bytes -> 0x{address:04X}")
                loaded_count += 1
            else:
                if required and not legacy_mode:
                    missing_required.append(filename)
                    continue
                # Legacy fallback path — clearly labelled.
                self.mem[address:address + len(fallback_bytes)] = fallback_bytes
                if verbose:
                    print(f"  [legacy] {filename}: NOT FOUND, "
                          f"using fabricated {len(fallback_bytes)} bytes "
                          f"-> 0x{address:04X}")
                fallback_count += 1

        # If anything required was missing in strict mode, fail loudly.
        if missing_required:
            raise FileNotFoundError(
                "Required firmware BIN(s) not found:\n  "
                + "\n  ".join(missing_required)
                + "\n\nThe emulator no longer fabricates these in Python."
                + " Place the .bin files next to Z80yPicoPartialEmulator60.py"
                + " or in the current working directory."
                + "\nTo run with the legacy in-Python fallback, set"
                + " emulator.firmware_legacy_fallback = True before"
                + " calling install_bios()."
            )

        # ── FW_INPUTLINE — special: payload at 0x0003, trampoline at 0x7EA0
        # The line editor is a standalone Z80 binary loaded at 0x0003,
        # and FW_INPUTLINE at 0x7EA0 is a JP trampoline to it. This
        # convention is preserved unchanged from before externalisation.
        FW_IL_ADDR = 0x0003
        fw_il_bin = b""
        for try_path in [script_dir / "FW_INPUTLINE.bin",
                          Path("FW_INPUTLINE.bin")]:
            if try_path.exists():
                fw_il_bin = try_path.read_bytes()
                if verbose:
                    print(f"  FW_INPUTLINE.bin: {len(fw_il_bin)} bytes -> 0x{FW_IL_ADDR:04X}")
                break

        if fw_il_bin:
            self.mem[FW_IL_ADDR:FW_IL_ADDR + len(fw_il_bin)] = fw_il_bin
            # Trampoline: JP 0x0003
            self.mem[self.FW_INPUTLINE] = 0xC3
            self.mem[self.FW_INPUTLINE + 1] = FW_IL_ADDR & 0xFF
            self.mem[self.FW_INPUTLINE + 2] = (FW_IL_ADDR >> 8) & 0xFF
        elif legacy_mode:
            if verbose:
                print("  [legacy] FW_INPUTLINE.bin: NOT FOUND, using fabricated 91 bytes")
            fw_inputline_legacy = bytes([
                0x3E, 0x0E, 0xD3, 0x01,
                0x11, 0x00, 0x7F, 0x06, 0x00,
                0xCD, 0x90, 0x7E,
                0xFE, 0x0A, 0x28, 0x3C,
                0xFE, 0x08, 0x28, 0x12,
                0xFE, 0x1B, 0x28, 0x21,
                0xFE, 0x20, 0x38, 0xED,
                0xFE, 0x9F, 0x30, 0xE9,
                0x12, 0xD3, 0x01, 0x13, 0x18, 0xE3,
                0x7B, 0xB8, 0x28, 0xDF,
                0x1B,
                0x3E, 0x08, 0xD3, 0x01,
                0x3E, 0x20, 0xD3, 0x01,
                0x3E, 0x08, 0xD3, 0x01,
                0x18, 0xD0,
                0x7B, 0xB8, 0x28, 0xCC,
                0x1B,
                0x3E, 0x08, 0xD3, 0x01,
                0x3E, 0x20, 0xD3, 0x01,
                0x3E, 0x08, 0xD3, 0x01,
                0x18, 0xED,
                0xAF, 0x12,
                0x3E, 0x0D, 0xD3, 0x01,
                0x3E, 0x0A, 0xD3, 0x01,
                0x3E, 0x0F, 0xD3, 0x01,
                0xC9,
            ])
            self.mem[self.FW_INPUTLINE:
                     self.FW_INPUTLINE + len(fw_inputline_legacy)] = fw_inputline_legacy
            fallback_count += 1
        else:
            # In strict mode FW_INPUTLINE is also required.
            raise FileNotFoundError(
                "Required firmware BIN not found: FW_INPUTLINE.bin\n"
                "Place it next to Z80yPicoPartialEmulator60.py."
            )

        # Diagnostic summary.
        if verbose:
            if legacy_mode and fallback_count:
                print(f"  Firmware: {loaded_count} from disk, "
                      f"{fallback_count} legacy-fabricated.")
            else:
                print(f"  Firmware: {loaded_count + 1} routines installed from disk "
                      f"(13 FW slots + FW_INPUTLINE).")

        # Mark diagnostics as printed so subsequent install_bios()
        # calls (e.g. the defensive one in run_from()) stay silent.
        self._firmware_diag_printed = True

    def load_program(self, filename: str, address: int | None = None) -> None:
        if address is None:
            address = self.USER_PROGRAM_ADDRESS
        data = Path(filename).read_bytes()
        end_address = address + len(data)
        if end_address > len(self.mem):
            raise ValueError("The binary file is too large to fit in memory.")
        self.reset()
        self.mem[address:end_address] = data
        self.pc = self.BIOS_RESET_VECTOR
        self.running = True

    def load_binary(self, filename: str,
                    address: int | None = None) -> int:
        """Load a binary file into RAM without resetting or executing.

        Returns the number of bytes loaded.
        """
        if address is None:
            address = self.USER_PROGRAM_ADDRESS
        data = Path(filename).read_bytes()
        end_address = address + len(data)
        if end_address > len(self.mem):
            raise ValueError("The binary file is too large to fit in memory.")
        self.mem[address:end_address] = data
        self.program_length = len(data)
        self.program_name = Path(filename).name
        return len(data)

    def run_from(self, address: int | None = None,
                 max_steps: int = 10_000_000) -> None:
        """Set PC to address and execute using the existing run loop."""
        if address is None:
            address = self.USER_PROGRAM_ADDRESS
        self.pc = address
        self.sp = self.STACK_INIT
        self.running = True
        self.install_bios()
        self.run(max_steps)

    def fetch_byte(self) -> int:
        value = self.mem[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        return value

    def fetch_word(self) -> int:
        lo = self.fetch_byte()
        hi = self.fetch_byte()
        return lo | (hi << 8)

    def push_word(self, value: int) -> None:
        value &= 0xFFFF
        self.sp = (self.sp - 1) & 0xFFFF
        self.mem[self.sp] = (value >> 8) & 0xFF
        self.sp = (self.sp - 1) & 0xFFFF
        self.mem[self.sp] = value & 0xFF

    def pop_word(self) -> int:
        lo = self.mem[self.sp]
        self.sp = (self.sp + 1) & 0xFFFF
        hi = self.mem[self.sp]
        self.sp = (self.sp + 1) & 0xFFFF
        return lo | (hi << 8)

    # ── I/O ──

    def out_port(self, port: int, value: int) -> None:
        if port == self.CHANNEL_CONSOLE_OUT:
            # In shell mode, block UP/DOWN cursor codes (3, 4)
            if self.shell_mode and value in (3, 4):
                return
            if (32 <= value <= 126 or value in (3, 4, 8, 9, 10, 13, 0x0E, 0x0F)
                    or 128 <= value <= 158):
                self.display.put_char(value)
        elif port == self.CHANNEL_CONTROL:
            if value == 0x00:
                self.running = False
            elif value == 0x01:
                self._handle_basic_syscall()
        elif port == self.CHANNEL_DEBUG:
            pass
        elif port == self.CHANNEL_SYSCALL:
            self._handle_syscall(value)
        else:
            pass

    def in_port(self, port: int) -> int:
        if port == self.CHANNEL_CONSOLE_IN:
            if self.console_input_buffer:
                return self.console_input_buffer.pop(0)
            return self.display.wait_for_key()
        if port == self.CHANNEL_STATUS:
            return 0x01 if self.running else 0x00
        if port == self.CHANNEL_DEBUG_IN:
            return 0x00
        if port == self.CHANNEL_SYSCALL_IN:
            return self.syscall_result
        if port == self.CHANNEL_CUR_ROW:
            return self.display.cur_row & 0xFF
        if port == self.CHANNEL_CUR_COL:
            return self.display.cur_col & 0xFF
        return 0x00

    def _read_buffer_string(self) -> str:
        """Read a null-terminated string from the syscall buffer."""
        chars = []
        addr = self.SYSCALL_BUFFER
        while addr < self.SYSCALL_BUFFER + 256:
            b = self.mem[addr]
            if b == 0:
                break
            chars.append(chr(b))
            addr += 1
        return "".join(chars)

    def _write_buffer_string(self, text: str) -> None:
        """Write a null-terminated string into the syscall buffer."""
        addr = self.SYSCALL_BUFFER
        for ch in text[:255]:
            self.mem[addr] = ord(ch) & 0xFF
            addr += 1
        self.mem[addr] = 0x00

    def _handle_syscall(self, command: int) -> None:
        """Process a syscall command written to port 4."""
        if command == self.SYS_CLS:
            self.display.clear_screen()
            self.display.render()
            self.syscall_result = 0x00

        elif command == self.SYS_LOAD:
            filename = self._read_buffer_string()
            if not filename:
                self.syscall_result = 0x01
                return
            bin_path = normalize_path(filename, self.current_dir)
            if not bin_path.exists() or not bin_path.is_file():
                self.display.print_str("File not found.\n")
                self.display.render()
                self.syscall_result = 0x01
                return
            try:
                nbytes = self.load_binary(str(bin_path))
                self.display.print_str(
                    f"Loaded {bin_path.name}\n"
                    f" at 0x8000 ({nbytes} bytes)\n"
                )
                self.display.render()
                self.syscall_result = 0x00
            except Exception as exc:
                self.display.print_str(f"Error: {exc}\n")
                self.display.render()
                self.syscall_result = 0x01

        elif command == self.SYS_RUN:
            if self.program_length == 0:
                self.display.print_str("No program loaded.\n")
                self.display.render()
                self.syscall_result = 0x01
                return
            # Stop the current Z80 routine so control returns to main loop,
            # which will then execute the loaded program
            self.syscall_result = 0x00
            self._pending_run = True
            self.running = False

        elif command == self.SYS_DIR:
            lines = list_directory(self.current_dir)
            for line in lines:
                self.display.print_str(line[:32] + "\n")
            self.display.render()
            self.syscall_result = 0x00

        elif command == self.SYS_PWD:
            self.display.print_str(f"{self.current_dir}\n")
            self.display.render()
            self.syscall_result = 0x00

        elif command == self.SYS_NEW:
            self.soft_reset()
            self.syscall_result = 0x00

        elif command == self.SYS_STATUS:
            if self.program_length > 0 and self.program_name:
                self.display.print_str(
                    f"Program: {self.program_name}\n"
                    f" {self.program_length} bytes"
                    f" at 0x8000\n"
                )
            else:
                self.display.print_str(
                    "No program loaded.\n"
                )
            d = self.display
            self.display.print_str(
                f"Ink:{d.current_ink}"
                f" Paper:{d.current_paper}"
                f" Border:{d.current_border}\n"
                f"Bright:{d.current_bright}"
                f" Flash:{d.current_flash}\n"
            )
            self.display.render()
            self.syscall_result = 0x00

        elif command == self.SYS_INK:
            val = self.mem[self.SYSCALL_BUFFER]
            if 0 <= val <= 63:
                self.display.set_ink(val)
                self.syscall_result = 0x00
            else:
                self.display.print_str("Ink: 0-63\n")
                self.display.render()
                self.syscall_result = 0x01

        elif command == self.SYS_PAPER:
            val = self.mem[self.SYSCALL_BUFFER]
            if 0 <= val <= 63:
                self.display.set_paper(val)
                self.syscall_result = 0x00
            else:
                self.display.print_str("Paper: 0-63\n")
                self.display.render()
                self.syscall_result = 0x01

        elif command == self.SYS_BORDER:
            val = self.mem[self.SYSCALL_BUFFER]
            if 0 <= val <= 63:
                self.display.set_border(val)
                self.syscall_result = 0x00
            else:
                self.display.print_str("Border: 0-63\n")
                self.display.render()
                self.syscall_result = 0x01

        elif command == self.SYS_FLASH:
            val = self.mem[self.SYSCALL_BUFFER]
            self.display.current_flash = 1 if val else 0
            self.syscall_result = 0x00

        elif command == self.SYS_BRIGHT:
            val = self.mem[self.SYSCALL_BUFFER]
            self.display.current_bright = 1 if val else 0
            self.syscall_result = 0x00

        elif command == self.SYS_LOCATE:
            row = self.mem[self.SYSCALL_BUFFER]
            col = self.mem[self.SYSCALL_BUFFER + 1]
            row = max(0, min(self.TEXT_ROWS - 1, row))
            col = max(0, min(self.TEXT_COLS - 1, col))
            self.display.cur_row = row
            self.display.cur_col = col
            self.syscall_result = 0x00

        elif command == self.SYS_RESET:
            # Full factory reset — handled by stopping the Z80 run loop.
            # The actual reset is performed by the main loop after the
            # command binary exits, because factory_reset() wipes the
            # memory that the currently-executing command lives in.
            # We set a flag and stop execution cleanly.
            self.syscall_result = 0x00
            self._pending_factory_reset = True
            self.running = False

        else:
            self.syscall_result = 0x01  # unknown syscall

    # ── BASIC interpreter syscall handler (port 2, value 1) ──

    def _read_basic_buffer_string(self) -> str:
        """Read null-terminated string from SYSCALL_BUFFER+1."""
        chars = []
        addr = self.SYSCALL_BUFFER + 1
        while addr < self.SYSCALL_BUFFER + 256:
            b = self.mem[addr]
            if b == 0:
                break
            chars.append(chr(b))
            addr += 1
        return "".join(chars)

    def _write_basic_buffer_string(self, text: str) -> None:
        """Write null-terminated string to SYSCALL_BUFFER+1 (max 254 chars)."""
        addr = self.SYSCALL_BUFFER + 1
        for ch in text[:254]:
            self.mem[addr] = ord(ch) & 0xFF
            addr += 1
        self.mem[addr] = 0x00

    def _handle_basic_syscall(self) -> None:
        """Process a BASIC syscall.  Command byte at SYSCALL_BUFFER[0],
        arguments (filename/path) at SYSCALL_BUFFER+1."""
        cmd = self.mem[self.SYSCALL_BUFFER]
        arg = self._read_basic_buffer_string()

        if cmd == self.BSYS_FILE_OPEN:
            try:
                if self._basic_read_file:
                    self._basic_read_file.close()
                fpath = normalize_path(arg, self.current_dir)
                self._basic_read_file = open(
                    str(fpath), 'r', encoding='utf-8', errors='replace')
                self.mem[self.SYSCALL_BUFFER] = 0x00
            except (FileNotFoundError, OSError):
                self.mem[self.SYSCALL_BUFFER] = 0xFF

        elif cmd == self.BSYS_FILE_NEXT:
            if self._basic_read_file is None:
                self.mem[self.SYSCALL_BUFFER] = 0xFF
                return
            line = self._basic_read_file.readline()
            if line == '':
                self.mem[self.SYSCALL_BUFFER] = 0xFF   # EOF
            else:
                line = line.rstrip('\r\n')
                self._write_basic_buffer_string(line)
                self.mem[self.SYSCALL_BUFFER] = 0x00

        elif cmd == self.BSYS_FILE_CLOSE:
            if self._basic_read_file:
                self._basic_read_file.close()
                self._basic_read_file = None
            self.mem[self.SYSCALL_BUFFER] = 0x00

        elif cmd == self.BSYS_FILE_WOPEN:
            try:
                if self._basic_write_file:
                    self._basic_write_file.close()
                fpath = normalize_path(arg, self.current_dir)
                self._basic_write_file = open(
                    str(fpath), 'w', encoding='utf-8')
                self.mem[self.SYSCALL_BUFFER] = 0x00
            except (IOError, OSError):
                self.mem[self.SYSCALL_BUFFER] = 0xFF

        elif cmd == self.BSYS_FILE_WLINE:
            if self._basic_write_file is None:
                self.mem[self.SYSCALL_BUFFER] = 0xFF
                return
            line = self._read_basic_buffer_string()
            self._basic_write_file.write(line + '\n')
            self.mem[self.SYSCALL_BUFFER] = 0x00

        elif cmd == self.BSYS_FILE_WCLOSE:
            if self._basic_write_file:
                self._basic_write_file.close()
                self._basic_write_file = None
            self.mem[self.SYSCALL_BUFFER] = 0x00

        elif cmd == self.BSYS_BIN_LOAD:
            try:
                fpath = normalize_path(arg, self.current_dir)
                with open(str(fpath), 'rb') as f:
                    data = f.read()
                addr = 0xC400
                for b in data:
                    if addr > 0xFFFF:
                        break
                    self.mem[addr] = b
                    addr += 1
                self.mem[self.SYSCALL_BUFFER] = 0x00
            except (FileNotFoundError, OSError):
                self.mem[self.SYSCALL_BUFFER] = 0xFF

        elif cmd == self.BSYS_CHDIR:
            if not arg:
                # No path given — open a directory picker dialog
                try:
                    import tkinter as tk
                    from tkinter import filedialog
                    root = tk.Tk()
                    root.withdraw()
                    root.update()
                    selected = filedialog.askdirectory(
                        title="Select working directory",
                        initialdir=str(self.current_dir)
                    )
                    root.destroy()
                    if selected:
                        self.current_dir = Path(selected)
                        self._write_basic_buffer_string(str(self.current_dir))
                        self.mem[self.SYSCALL_BUFFER] = 0x00
                    else:
                        self.mem[self.SYSCALL_BUFFER] = 0xFF  # cancelled
                except Exception:
                    self.mem[self.SYSCALL_BUFFER] = 0xFF
            else:
                target = normalize_path(arg, self.current_dir)
                if target.exists() and target.is_dir():
                    self.current_dir = target
                    self._write_basic_buffer_string(str(self.current_dir))
                    self.mem[self.SYSCALL_BUFFER] = 0x00
                else:
                    self.mem[self.SYSCALL_BUFFER] = 0xFF

        elif cmd == self.BSYS_GETCWD:
            self._write_basic_buffer_string(str(self.current_dir))
            self.mem[self.SYSCALL_BUFFER] = 0x00

        elif cmd == self.BSYS_DIR_FIRST:
            # Begin directory iteration: build sorted list of .bas/.bin files
            try:
                self._dir_iter = sorted(
                    f for f in os.listdir(str(self.current_dir))
                    if f.lower().endswith(('.bas', '.bin'))
                )
                self._dir_iter_idx = 0
                if self._dir_iter:
                    # Return first filename
                    self._write_basic_buffer_string(self._dir_iter[0])
                    self._dir_iter_idx = 1
                    self.mem[self.SYSCALL_BUFFER] = 0x00  # SYS_OK
                else:
                    # Empty directory
                    self.mem[self.SYSCALL_BUFFER] = 0xFF  # SYS_ERR (no files)
            except OSError:
                self._dir_iter = None
                self._dir_iter_idx = 0
                self.mem[self.SYSCALL_BUFFER] = 0xFF

        elif cmd == self.BSYS_DIR_NEXT:
            # Return next filename in iteration
            if (self._dir_iter is not None
                    and self._dir_iter_idx < len(self._dir_iter)):
                self._write_basic_buffer_string(
                    self._dir_iter[self._dir_iter_idx])
                self._dir_iter_idx += 1
                self.mem[self.SYSCALL_BUFFER] = 0x00  # SYS_OK
            else:
                # End of listing — clean up
                self._dir_iter = None
                self._dir_iter_idx = 0
                self.mem[self.SYSCALL_BUFFER] = 0xFF  # SYS_ERR (no more files)

        else:
            self.mem[self.SYSCALL_BUFFER] = 0xFF  # unknown BASIC syscall

    # ── Dispatch table construction ──

    def _build_dispatch_table(self) -> None:
        """Build the mnemonic -> handler dispatch table.

        Call once after __init__.  Maps mnemonic strings from the CSV
        decode table to handler methods on this class.

        To add a new instruction:
          1. Implement op_<name>(self, entry, opcode_address) on this class
          2. Add its mnemonic string to this dict
        """
        self.dispatch_table = {
            # ── Loads: 8-bit immediate ──
            "LD A,n":       self._op_ld_a_n,
            "LD B,n":       self._op_ld_b_n,
            "LD C,n":       self._op_ld_c_n,
            "LD D,n":       self._op_ld_d_n,
            "LD E,n":       self._op_ld_e_n,
            "LD H,n":       self._op_ld_h_n,
            "LD L,n":       self._op_ld_l_n,
            # ── Loads: 16-bit immediate ──
            "LD HL,nn":     self._op_ld_hl_nn,
            "LD DE,nn":     self._op_ld_de_nn,
            "LD BC,nn":     self._op_ld_bc_nn,
            "LD SP,nn":     self._op_ld_sp_nn,
            # ── Loads: memory (non-register-block) ──
            "LD (HL),n":    self._op_ld_hl_ind_n,
            "LD (BC),A":    self._op_ld_bc_ind_a,
            "LD (DE),A":    self._op_ld_de_ind_a,
            "LD A,(BC)":    self._op_ld_a_bc_ind,
            "LD A,(DE)":    self._op_ld_a_de_ind,
            "LD (nn),A":    self._op_ld_nn_ind_a,
            "LD A,(nn)":    self._op_ld_a_nn_ind,
            "LD (nn),HL":   self._op_ld_nn_ind_hl,
            "LD HL,(nn)":   self._op_ld_hl_nn_ind,
            # ── Stack ──
            "PUSH AF":      self._op_push_af,
            "PUSH BC":      self._op_push_bc,
            "PUSH DE":      self._op_push_de,
            "PUSH HL":      self._op_push_hl,
            "POP AF":       self._op_pop_af,
            "POP BC":       self._op_pop_bc,
            "POP DE":       self._op_pop_de,
            "POP HL":       self._op_pop_hl,
            # ── 16-bit arithmetic (full families) ──
            "INC BC":       self._op_inc_bc,
            "INC DE":       self._op_inc_de,
            "INC HL":       self._op_inc_hl,
            "DEC BC":       self._op_dec_bc,
            "DEC DE":       self._op_dec_de,
            "DEC HL":       self._op_dec_hl,
            "ADD HL,BC":    self._op_add_hl_bc,
            "ADD HL,DE":    self._op_add_hl_de,
            "ADD HL,HL":    self._op_add_hl_hl,
            "ADD HL,SP":    self._op_add_hl_sp,
            # ── 8-bit INC/DEC (full register family) ──
            "INC B":        self._op_inc_r,
            "INC C":        self._op_inc_r,
            "INC D":        self._op_inc_r,
            "INC E":        self._op_inc_r,
            "INC H":        self._op_inc_r,
            "INC L":        self._op_inc_r,
            "INC (HL)":     self._op_inc_r,
            "INC A":        self._op_inc_r,
            "DEC B":        self._op_dec_r,
            "DEC C":        self._op_dec_r,
            "DEC D":        self._op_dec_r,
            "DEC E":        self._op_dec_r,
            "DEC H":        self._op_dec_r,
            "DEC L":        self._op_dec_r,
            "DEC (HL)":     self._op_dec_r,
            "DEC A":        self._op_dec_r,
            # ── 8-bit ALU register families ──
            "ADD A,B":      self._op_add_a_r,
            "ADD A,C":      self._op_add_a_r,
            "ADD A,D":      self._op_add_a_r,
            "ADD A,E":      self._op_add_a_r,
            "ADD A,H":      self._op_add_a_r,
            "ADD A,L":      self._op_add_a_r,
            "ADD A,(HL)":   self._op_add_a_r,
            "ADD A,A":      self._op_add_a_r,
            "ADC A,B":      self._op_adc_a_r,
            "ADC A,C":      self._op_adc_a_r,
            "ADC A,D":      self._op_adc_a_r,
            "ADC A,E":      self._op_adc_a_r,
            "ADC A,H":      self._op_adc_a_r,
            "ADC A,L":      self._op_adc_a_r,
            "ADC A,(HL)":   self._op_adc_a_r,
            "ADC A,A":      self._op_adc_a_r,
            "SUB B":        self._op_sub_r,
            "SUB C":        self._op_sub_r,
            "SUB D":        self._op_sub_r,
            "SUB E":        self._op_sub_r,
            "SUB H":        self._op_sub_r,
            "SUB L":        self._op_sub_r,
            "SUB (HL)":     self._op_sub_r,
            "SUB A":        self._op_sub_r,
            "SBC A,B":      self._op_sbc_a_r,
            "SBC A,C":      self._op_sbc_a_r,
            "SBC A,D":      self._op_sbc_a_r,
            "SBC A,E":      self._op_sbc_a_r,
            "SBC A,H":      self._op_sbc_a_r,
            "SBC A,L":      self._op_sbc_a_r,
            "SBC A,(HL)":   self._op_sbc_a_r,
            "SBC A,A":      self._op_sbc_a_r,
            "AND B":        self._op_and_r,
            "AND C":        self._op_and_r,
            "AND D":        self._op_and_r,
            "AND E":        self._op_and_r,
            "AND H":        self._op_and_r,
            "AND L":        self._op_and_r,
            "AND (HL)":     self._op_and_r,
            "AND A":        self._op_and_r,
            "XOR B":        self._op_xor_r,
            "XOR C":        self._op_xor_r,
            "XOR D":        self._op_xor_r,
            "XOR E":        self._op_xor_r,
            "XOR H":        self._op_xor_r,
            "XOR L":        self._op_xor_r,
            "XOR (HL)":     self._op_xor_r,
            "XOR A":        self._op_xor_r,
            "OR B":         self._op_or_r,
            "OR C":         self._op_or_r,
            "OR D":         self._op_or_r,
            "OR E":         self._op_or_r,
            "OR H":         self._op_or_r,
            "OR L":         self._op_or_r,
            "OR (HL)":      self._op_or_r,
            "OR A":         self._op_or_r,
            "CP B":         self._op_cp_r,
            "CP C":         self._op_cp_r,
            "CP D":         self._op_cp_r,
            "CP E":         self._op_cp_r,
            "CP H":         self._op_cp_r,
            "CP L":         self._op_cp_r,
            "CP (HL)":      self._op_cp_r,
            "CP A":         self._op_cp_r,
            # ── 8-bit ALU immediate ──
            "ADD A,n":      self._op_add_a_n,
            "ADC A,n":      self._op_adc_a_n,
            "SUB n":        self._op_sub_n,
            "SBC A,n":      self._op_sbc_a_n,
            "AND n":        self._op_and_n,
            "XOR n":        self._op_xor_n,
            "OR n":         self._op_or_n,
            "CP n":         self._op_cp_n,
            # ── Misc arithmetic / flags ──
            "SCF":          self._op_scf,
            "CCF":          self._op_ccf,
            # ── Jumps ──
            "JP nn":        self._op_jp_nn,
            "JP NZ,nn":     self._op_jp_nz_nn,
            "JP Z,nn":      self._op_jp_z_nn,
            "JP NC,nn":     self._op_jp_nc_nn,
            "JP C,nn":      self._op_jp_c_nn,
            "JP (HL)":      self._op_jp_hl,
            "JR e":         self._op_jr_e,
            "JR Z,e":       self._op_jr_z_e,
            "JR NZ,e":      self._op_jr_nz_e,
            "JR C,e":       self._op_jr_c_e,
            "JR NC,e":      self._op_jr_nc_e,
            # ── Call / Return ──
            "CALL nn":      self._op_call_nn,
            "RET":          self._op_ret,
            "RET NZ":       self._op_ret_nz,
            "RET Z":        self._op_ret_z,
            "RET NC":       self._op_ret_nc,
            "RET C":        self._op_ret_c,
            "DJNZ e":       self._op_djnz_e,
            # ── I/O ──
            "OUT (n),A":    self._op_out_n_a,
            "IN A,(n)":     self._op_in_a_n,
            # ── Misc ──
            "NOP":          self._op_nop,
            "HALT":         self._op_halt,
            "EX DE,HL":     self._op_ex_de_hl,
            "EX (SP),HL":   self._op_ex_sp_hl,
            "EXX":          self._op_exx,
            "RLCA":         self._op_rlca,
            "RRCA":         self._op_rrca,
            "RLA":          self._op_rla,
            "RRA":          self._op_rra,
            "CPL":          self._op_cpl,
            "DI":           self._op_nop,   # no interrupts in emulator
            "EI":           self._op_nop,   # no interrupts in emulator
            "LD SP,HL":     self._op_ld_sp_hl,
            "INC SP":       self._op_inc_sp,
            "DEC SP":       self._op_dec_sp,
            # ── Conditional calls ──
            "CALL NZ,nn":   self._op_call_nz_nn,
            "CALL Z,nn":    self._op_call_z_nn,
            "CALL NC,nn":   self._op_call_nc_nn,
            "CALL C,nn":    self._op_call_c_nn,
            # ── ED prefix ──
            "SBC HL,BC":    self._op_sbc_hl_bc,
            "SBC HL,DE":    self._op_sbc_hl_de,
            "LD (nn),DE":   self._op_ld_nn_ind_de,
            "LD DE,(nn)":   self._op_ld_de_nn_ind,
            "LD (nn),BC":   self._op_ld_nn_ind_bc,
            "LD BC,(nn)":   self._op_ld_bc_nn_ind,
            "LDIR":         self._op_ldir,
            "LDDR":         self._op_lddr,
            # ── DD prefix ──
            "LD IX,nn":     self._op_ld_ix_nn,
            "PUSH IX":      self._op_push_ix,
            "POP IX":       self._op_pop_ix,
            "INC IX":       self._op_inc_ix,
            "DEC IX":       self._op_dec_ix,
            # ── DD prefix: IX+d indexed loads ──
            "LD (IX+d),n":  self._op_ld_ixd_n,
            "LD (IX+d),A":  self._op_ld_ixd_r,
            "LD (IX+d),B":  self._op_ld_ixd_r,
            "LD (IX+d),C":  self._op_ld_ixd_r,
            "LD (IX+d),D":  self._op_ld_ixd_r,
            "LD (IX+d),E":  self._op_ld_ixd_r,
            "LD (IX+d),H":  self._op_ld_ixd_r,
            "LD (IX+d),L":  self._op_ld_ixd_r,
            "LD A,(IX+d)":  self._op_ld_r_ixd,
            "LD B,(IX+d)":  self._op_ld_r_ixd,
            "LD C,(IX+d)":  self._op_ld_r_ixd,
            "LD D,(IX+d)":  self._op_ld_r_ixd,
            "LD E,(IX+d)":  self._op_ld_r_ixd,
            "LD H,(IX+d)":  self._op_ld_r_ixd,
            "LD L,(IX+d)":  self._op_ld_r_ixd,
            # ── DD CB prefix: IX+d bit operations ──
            "BIT 0,(IX+d)": self._op_bit_ixd, "BIT 1,(IX+d)": self._op_bit_ixd,
            "BIT 2,(IX+d)": self._op_bit_ixd, "BIT 3,(IX+d)": self._op_bit_ixd,
            "BIT 4,(IX+d)": self._op_bit_ixd, "BIT 5,(IX+d)": self._op_bit_ixd,
            "BIT 6,(IX+d)": self._op_bit_ixd, "BIT 7,(IX+d)": self._op_bit_ixd,
            # ── CB prefix: rotate/shift (parameterised handlers) ──
            "RLC B":  self._op_cb_rlc, "RLC C":  self._op_cb_rlc,
            "RLC D":  self._op_cb_rlc, "RLC E":  self._op_cb_rlc,
            "RLC H":  self._op_cb_rlc, "RLC L":  self._op_cb_rlc,
            "RLC (HL)": self._op_cb_rlc, "RLC A": self._op_cb_rlc,
            "RRC B":  self._op_cb_rrc, "RRC C":  self._op_cb_rrc,
            "RRC D":  self._op_cb_rrc, "RRC E":  self._op_cb_rrc,
            "RRC H":  self._op_cb_rrc, "RRC L":  self._op_cb_rrc,
            "RRC (HL)": self._op_cb_rrc, "RRC A": self._op_cb_rrc,
            "RL B":   self._op_cb_rl,  "RL C":   self._op_cb_rl,
            "RL D":   self._op_cb_rl,  "RL E":   self._op_cb_rl,
            "RL H":   self._op_cb_rl,  "RL L":   self._op_cb_rl,
            "RL (HL)": self._op_cb_rl, "RL A":   self._op_cb_rl,
            "RR B":   self._op_cb_rr,  "RR C":   self._op_cb_rr,
            "RR D":   self._op_cb_rr,  "RR E":   self._op_cb_rr,
            "RR H":   self._op_cb_rr,  "RR L":   self._op_cb_rr,
            "RR (HL)": self._op_cb_rr, "RR A":   self._op_cb_rr,
            "SLA B":  self._op_cb_sla, "SLA C":  self._op_cb_sla,
            "SLA D":  self._op_cb_sla, "SLA E":  self._op_cb_sla,
            "SLA H":  self._op_cb_sla, "SLA L":  self._op_cb_sla,
            "SLA (HL)": self._op_cb_sla, "SLA A": self._op_cb_sla,
            "SRA B":  self._op_cb_sra, "SRA C":  self._op_cb_sra,
            "SRA D":  self._op_cb_sra, "SRA E":  self._op_cb_sra,
            "SRA H":  self._op_cb_sra, "SRA L":  self._op_cb_sra,
            "SRA (HL)": self._op_cb_sra, "SRA A": self._op_cb_sra,
            "SRL B":  self._op_cb_srl, "SRL C":  self._op_cb_srl,
            "SRL D":  self._op_cb_srl, "SRL E":  self._op_cb_srl,
            "SRL H":  self._op_cb_srl, "SRL L":  self._op_cb_srl,
            "SRL (HL)": self._op_cb_srl, "SRL A": self._op_cb_srl,
        }

        # ── Bulk-register all LD r,r' / LD r,(HL) / LD (HL),r ──
        # These are opcodes 0x40-0x7F (excluding 0x76 = HALT).
        # The Z80 encodes dst in bits 5-3, src in bits 2-0.
        # Register index: B=0 C=1 D=2 E=3 H=4 L=5 (HL)=6 A=7
        _reg_names = ["B", "C", "D", "E", "H", "L", "(HL)", "A"]
        for dst_idx in range(8):
            for src_idx in range(8):
                opcode = 0x40 | (dst_idx << 3) | src_idx
                if opcode == 0x76:
                    continue  # HALT, not LD
                dst = _reg_names[dst_idx]
                src = _reg_names[src_idx]
                mnemonic = f"LD {dst},{src}"
                self.dispatch_table[mnemonic] = self._op_ld_r_r

        # ── Bulk-register CB BIT/RES/SET families ──
        for bit in range(8):
            for reg in _reg_names:
                self.dispatch_table[f"BIT {bit},{reg}"] = self._op_cb_bit
                self.dispatch_table[f"RES {bit},{reg}"] = self._op_cb_res
                self.dispatch_table[f"SET {bit},{reg}"] = self._op_cb_set

    # ── CPU decode + dispatch (CSV-driven) ──

    def _decode_prefix(self, first_byte: int, opcode_address: int):
        """Determine prefix and effective opcode from the byte stream.

        Returns (prefix_str, opcode_int, opcode_address).
        PC is advanced past prefix bytes but NOT past the opcode's
        own operands — that is the handler's job.
        """
        if first_byte == 0xCB:
            op2 = self.fetch_byte()
            return ("CB", op2, opcode_address)
        elif first_byte == 0xED:
            op2 = self.fetch_byte()
            return ("ED", op2, opcode_address)
        elif first_byte == 0xDD:
            op2 = self.fetch_byte()
            if op2 == 0xCB:
                # DD CB d opcode — displacement is BEFORE the opcode
                _disp = self.fetch_byte()   # displacement (consumed here)
                op3 = self.fetch_byte()     # actual opcode
                # Store displacement for the handler
                self._ddcb_displacement = _disp
                return ("DDCB", op3, opcode_address)
            return ("DD", op2, opcode_address)
        elif first_byte == 0xFD:
            op2 = self.fetch_byte()
            if op2 == 0xCB:
                _disp = self.fetch_byte()
                op3 = self.fetch_byte()
                self._fdcb_displacement = _disp
                return ("FDCB", op3, opcode_address)
            return ("FD", op2, opcode_address)
        else:
            return ("NONE", first_byte, opcode_address)

    def step(self) -> None:
        """Fetch-decode-dispatch cycle driven by the CSV decode table."""
        opcode_address = self.pc
        first_byte = self.fetch_byte()

        # ── Decode: determine prefix and opcode ──
        prefix, opcode, opcode_address = self._decode_prefix(
            first_byte, opcode_address
        )

        # ── Look up in CSV decode table ──
        entry = self.decode_table.get((prefix, opcode))

        if entry is None:
            # Fallback: not in CSV table at all
            if prefix == "NONE":
                raise NotImplementedError(
                    f"Opcode 0x{opcode:02X} not in decode table "
                    f"at PC=0x{opcode_address:04X}")
            else:
                raise NotImplementedError(
                    f"Opcode {prefix} 0x{opcode:02X} not in decode table "
                    f"at PC=0x{opcode_address:04X}")

        status = entry["status"]
        mnemonic = entry["mnemonic"]

        # ── Handle INVALID opcodes ──
        if status == "INVALID":
            if prefix == "NONE":
                raise NotImplementedError(
                    f"Invalid opcode 0x{opcode:02X} "
                    f"at PC=0x{opcode_address:04X}")
            else:
                raise NotImplementedError(
                    f"Invalid opcode {prefix} 0x{opcode:02X} "
                    f"at PC=0x{opcode_address:04X}")

        # ── Handle ALIAS opcodes (DD/FD prefixed duplicates) ──
        # These behave like the unprefixed version; re-dispatch
        if status == "ALIAS":
            # The opcode after DD/FD acts as the NONE-prefix opcode.
            # Re-look up in NONE prefix.
            alias_entry = self.decode_table.get(("NONE", opcode))
            if alias_entry is None:
                raise NotImplementedError(
                    f"Alias opcode {prefix} 0x{opcode:02X} — "
                    f"base 0x{opcode:02X} not found "
                    f"at PC=0x{opcode_address:04X}")
            entry = alias_entry
            mnemonic = entry["mnemonic"]

        # ── Dispatch to handler ──
        handler = self.dispatch_table.get(mnemonic)
        if handler is None:
            if prefix == "NONE":
                raise NotImplementedError(
                    f"No handler for '{mnemonic}' (0x{opcode:02X}) "
                    f"at PC=0x{opcode_address:04X}")
            else:
                raise NotImplementedError(
                    f"No handler for '{mnemonic}' ({prefix} 0x{opcode:02X}) "
                    f"at PC=0x{opcode_address:04X}")

        handler(entry, opcode_address)

        # ── Accumulate timing ──
        self.t_states += entry["t_states"]

    # ── Instruction handlers ──
    #
    # Each handler receives:
    #   entry          — the CSV decode table row dict
    #   opcode_address — PC value where the instruction started
    #
    # Handlers consume their own operands via fetch_byte / fetch_word.
    # The decode table already consumed prefix bytes.

    # ── NOP ──
    def _op_nop(self, entry, addr):
        pass

    # ── Loads: 8-bit immediate ──
    def _op_ld_a_n(self, entry, addr):
        self.a = self.fetch_byte()

    def _op_ld_b_n(self, entry, addr):
        self.b = self.fetch_byte()

    def _op_ld_c_n(self, entry, addr):
        self.c = self.fetch_byte()

    def _op_ld_d_n(self, entry, addr):
        self.d = self.fetch_byte()

    def _op_ld_e_n(self, entry, addr):
        self.e = self.fetch_byte()

    def _op_ld_h_n(self, entry, addr):
        self.h = self.fetch_byte()

    def _op_ld_l_n(self, entry, addr):
        self.l = self.fetch_byte()

    # ── Loads: 16-bit immediate ──
    def _op_ld_hl_nn(self, entry, addr):
        self.hl = self.fetch_word()

    def _op_ld_de_nn(self, entry, addr):
        self.de = self.fetch_word()

    def _op_ld_bc_nn(self, entry, addr):
        self.bc = self.fetch_word()

    def _op_ld_sp_nn(self, entry, addr):
        self.sp = self.fetch_word()

    # ── Loads: register block (0x40-0x7F) ──
    # Single parameterised handler for all LD r,r' / LD r,(HL) / LD (HL),r.
    # The opcode byte encodes dst (bits 5-3) and src (bits 2-0).
    # Register index: B=0 C=1 D=2 E=3 H=4 L=5 (HL)=6 A=7

    def _reg_read(self, idx: int) -> int:
        """Read register by Z80 register index (0-7)."""
        if   idx == 0: return self.b
        elif idx == 1: return self.c
        elif idx == 2: return self.d
        elif idx == 3: return self.e
        elif idx == 4: return self.h
        elif idx == 5: return self.l
        elif idx == 6: return self.mem[self.hl]
        elif idx == 7: return self.a
        return 0

    def _reg_write(self, idx: int, value: int) -> None:
        """Write register by Z80 register index (0-7)."""
        value &= 0xFF
        if   idx == 0: self.b = value
        elif idx == 1: self.c = value
        elif idx == 2: self.d = value
        elif idx == 3: self.e = value
        elif idx == 4: self.h = value
        elif idx == 5: self.l = value
        elif idx == 6: self.mem[self.hl] = value
        elif idx == 7: self.a = value

    def _op_ld_r_r(self, entry, addr):
        """Parameterised handler for all LD r,r' opcodes (0x40-0x7F)."""
        opcode = entry["opcode"]
        dst = (opcode >> 3) & 0x07
        src = opcode & 0x07
        self._reg_write(dst, self._reg_read(src))

    def _op_ld_hl_ind_n(self, entry, addr):
        self.mem[self.hl] = self.fetch_byte()

    def _op_ld_bc_ind_a(self, entry, addr):
        self.mem[self.bc] = self.a & 0xFF

    def _op_ld_de_ind_a(self, entry, addr):
        self.mem[self.de] = self.a & 0xFF

    def _op_ld_a_bc_ind(self, entry, addr):
        self.a = self.mem[self.bc]

    def _op_ld_a_de_ind(self, entry, addr):
        self.a = self.mem[self.de]

    def _op_ld_nn_ind_a(self, entry, addr):
        a = self.fetch_word()
        self.mem[a] = self.a & 0xFF

    def _op_ld_a_nn_ind(self, entry, addr):
        a = self.fetch_word()
        self.a = self.mem[a]

    def _op_ld_nn_ind_hl(self, entry, addr):
        a = self.fetch_word()
        self.mem[a] = self.l
        self.mem[(a + 1) & 0xFFFF] = self.h

    def _op_ld_hl_nn_ind(self, entry, addr):
        a = self.fetch_word()
        self.l = self.mem[a]
        self.h = self.mem[(a + 1) & 0xFFFF]

    # ── Stack ──
    def _op_push_af(self, entry, addr):
        self._flags_to_f()
        self.push_word(self.af)

    def _op_push_bc(self, entry, addr):
        self.push_word(self.bc)

    def _op_push_de(self, entry, addr):
        self.push_word(self.de)

    def _op_push_hl(self, entry, addr):
        self.push_word(self.hl)

    def _op_pop_af(self, entry, addr):
        self.af = self.pop_word()
        self._f_to_flags()

    def _op_pop_bc(self, entry, addr):
        self.bc = self.pop_word()

    def _op_pop_de(self, entry, addr):
        self.de = self.pop_word()

    def _op_pop_hl(self, entry, addr):
        self.hl = self.pop_word()

    # ── 16-bit arithmetic (full families) ──

    def _op_inc_bc(self, entry, addr):
        self.bc = (self.bc + 1) & 0xFFFF

    def _op_inc_de(self, entry, addr):
        self.de = (self.de + 1) & 0xFFFF

    def _op_inc_hl(self, entry, addr):
        self.hl = (self.hl + 1) & 0xFFFF

    def _op_dec_bc(self, entry, addr):
        self.bc = (self.bc - 1) & 0xFFFF

    def _op_dec_de(self, entry, addr):
        self.de = (self.de - 1) & 0xFFFF

    def _op_dec_hl(self, entry, addr):
        self.hl = (self.hl - 1) & 0xFFFF

    def _op_add_hl_bc(self, entry, addr):
        r = self.hl + self.bc
        self.cf = r > 0xFFFF
        self.hl = r & 0xFFFF

    def _op_add_hl_de(self, entry, addr):
        r = self.hl + self.de
        self.cf = r > 0xFFFF
        self.hl = r & 0xFFFF

    def _op_add_hl_hl(self, entry, addr):
        r = self.hl + self.hl
        self.cf = r > 0xFFFF
        self.hl = r & 0xFFFF

    def _op_add_hl_sp(self, entry, addr):
        r = self.hl + self.sp
        self.cf = r > 0xFFFF
        self.hl = r & 0xFFFF

    # ── 8-bit INC/DEC (parameterised by opcode bits) ──
    # INC r: opcode = 0x04 | (reg_idx << 3), reg_idx in bits 5-3
    # DEC r: opcode = 0x05 | (reg_idx << 3), reg_idx in bits 5-3

    def _op_inc_r(self, entry, addr):
        """INC r — parameterised for all 8-bit registers + (HL)."""
        idx = (entry["opcode"] >> 3) & 0x07
        v = (self._reg_read(idx) + 1) & 0xFF
        self._reg_write(idx, v)
        self.zf = v == 0

    def _op_dec_r(self, entry, addr):
        """DEC r — parameterised for all 8-bit registers + (HL)."""
        idx = (entry["opcode"] >> 3) & 0x07
        v = (self._reg_read(idx) - 1) & 0xFF
        self._reg_write(idx, v)
        self.zf = v == 0

    # ── 8-bit ALU register families (parameterised by opcode bits 2-0) ──
    # The src register is encoded in bits 2-0 of the opcode.

    def _op_add_a_r(self, entry, addr):
        """ADD A,r — full register family."""
        src = entry["opcode"] & 0x07
        v = self._reg_read(src)
        r = self.a + v
        self.cf = r > 0xFF
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_adc_a_r(self, entry, addr):
        """ADC A,r — add with carry, full register family."""
        src = entry["opcode"] & 0x07
        v = self._reg_read(src)
        r = self.a + v + (1 if self.cf else 0)
        self.cf = r > 0xFF
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_sub_r(self, entry, addr):
        """SUB r — full register family."""
        src = entry["opcode"] & 0x07
        v = self._reg_read(src)
        r = self.a - v
        self.cf = r < 0
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_sbc_a_r(self, entry, addr):
        """SBC A,r — subtract with carry, full register family."""
        src = entry["opcode"] & 0x07
        v = self._reg_read(src)
        r = self.a - v - (1 if self.cf else 0)
        self.cf = r < 0
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_and_r(self, entry, addr):
        """AND r — full register family."""
        src = entry["opcode"] & 0x07
        self.a = self.a & self._reg_read(src)
        self.zf = self.a == 0
        self.cf = False

    def _op_xor_r(self, entry, addr):
        """XOR r — full register family."""
        src = entry["opcode"] & 0x07
        self.a = self.a ^ self._reg_read(src)
        self.zf = self.a == 0
        self.cf = False

    def _op_or_r(self, entry, addr):
        """OR r — full register family."""
        src = entry["opcode"] & 0x07
        self.a = self.a | self._reg_read(src)
        self.zf = self.a == 0
        self.cf = False

    def _op_cp_r(self, entry, addr):
        """CP r — full register family (compare without storing)."""
        src = entry["opcode"] & 0x07
        v = self._reg_read(src)
        r = self.a - v
        self.cf = r < 0
        self.zf = (r & 0xFF) == 0

    # ── 8-bit ALU immediate ──

    def _op_add_a_n(self, entry, addr):
        v = self.fetch_byte()
        r = self.a + v
        self.cf = r > 0xFF
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_adc_a_n(self, entry, addr):
        """ADC A,n — add immediate with carry."""
        v = self.fetch_byte()
        r = self.a + v + (1 if self.cf else 0)
        self.cf = r > 0xFF
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_sub_n(self, entry, addr):
        v = self.fetch_byte()
        r = self.a - v
        self.cf = r < 0
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_sbc_a_n(self, entry, addr):
        """SBC A,n — subtract immediate with carry."""
        v = self.fetch_byte()
        r = self.a - v - (1 if self.cf else 0)
        self.cf = r < 0
        self.a = r & 0xFF
        self.zf = self.a == 0

    def _op_and_n(self, entry, addr):
        """AND n — AND immediate."""
        v = self.fetch_byte()
        self.a = self.a & v
        self.zf = self.a == 0
        self.cf = False

    def _op_xor_n(self, entry, addr):
        """XOR n — XOR immediate."""
        v = self.fetch_byte()
        self.a = self.a ^ v
        self.zf = self.a == 0
        self.cf = False

    def _op_or_n(self, entry, addr):
        """OR n — OR immediate."""
        v = self.fetch_byte()
        self.a = self.a | v
        self.zf = self.a == 0
        self.cf = False

    def _op_cp_n(self, entry, addr):
        v = self.fetch_byte()
        r = self.a - v
        self.cf = r < 0
        self.zf = (r & 0xFF) == 0

    # ── Misc arithmetic / flags ──

    def _op_scf(self, entry, addr):
        """SCF — Set Carry Flag."""
        self.cf = True

    def _op_ccf(self, entry, addr):
        """CCF — Complement Carry Flag."""
        self.cf = not self.cf

    # ── Jumps ──
    def _op_jp_nn(self, entry, addr):
        self.pc = self.fetch_word()

    def _op_jp_nz_nn(self, entry, addr):
        target = self.fetch_word()
        if not self.zf:
            self.pc = target

    def _op_jp_z_nn(self, entry, addr):
        target = self.fetch_word()
        if self.zf:
            self.pc = target

    def _op_jp_nc_nn(self, entry, addr):
        target = self.fetch_word()
        if not self.cf:
            self.pc = target

    def _op_jp_c_nn(self, entry, addr):
        target = self.fetch_word()
        if self.cf:
            self.pc = target

    def _op_jp_hl(self, entry, addr):
        self.pc = self.hl

    def _op_jr_e(self, entry, addr):
        o = self.fetch_byte()
        if o >= 128:
            o -= 256
        self.pc = (self.pc + o) & 0xFFFF

    def _op_jr_z_e(self, entry, addr):
        o = self.fetch_byte()
        if o >= 128:
            o -= 256
        if self.zf:
            self.pc = (self.pc + o) & 0xFFFF

    def _op_jr_nz_e(self, entry, addr):
        o = self.fetch_byte()
        if o >= 128:
            o -= 256
        if not self.zf:
            self.pc = (self.pc + o) & 0xFFFF

    def _op_jr_c_e(self, entry, addr):
        o = self.fetch_byte()
        if o >= 128:
            o -= 256
        if self.cf:
            self.pc = (self.pc + o) & 0xFFFF

    def _op_jr_nc_e(self, entry, addr):
        o = self.fetch_byte()
        if o >= 128:
            o -= 256
        if not self.cf:
            self.pc = (self.pc + o) & 0xFFFF

    # ── Call / Return ──
    def _op_call_nn(self, entry, addr):
        target = self.fetch_word()
        self.push_word(self.pc)
        self.pc = target

    def _op_ret(self, entry, addr):
        self.pc = self.pop_word()

    def _op_ret_nz(self, entry, addr):
        """RET NZ — return if zero flag is not set."""
        if not self.zf:
            self.pc = self.pop_word()

    def _op_ret_z(self, entry, addr):
        """RET Z — return if zero flag is set."""
        if self.zf:
            self.pc = self.pop_word()

    def _op_ret_nc(self, entry, addr):
        """RET NC — return if carry flag is not set."""
        if not self.cf:
            self.pc = self.pop_word()

    def _op_ret_c(self, entry, addr):
        """RET C — return if carry flag is set."""
        if self.cf:
            self.pc = self.pop_word()

    def _op_djnz_e(self, entry, addr):
        o = self.fetch_byte()
        if o >= 128:
            o -= 256
        self.b = (self.b - 1) & 0xFF
        if self.b != 0:
            self.pc = (self.pc + o) & 0xFFFF

    # ── I/O ──
    def _op_out_n_a(self, entry, addr):
        port = self.fetch_byte()
        self.out_port(port, self.a)

    def _op_in_a_n(self, entry, addr):
        port = self.fetch_byte()
        self.a = self.in_port(port)
        self.zf = self.a == 0

    # ── Misc ──
    def _op_ex_de_hl(self, entry, addr):
        """EX DE,HL — exchange DE and HL."""
        self.de, self.hl = self.hl, self.de

    def _op_ex_sp_hl(self, entry, addr):
        """EX (SP),HL — exchange (SP) with HL."""
        lo = self.mem[self.sp]
        hi = self.mem[(self.sp + 1) & 0xFFFF]
        self.mem[self.sp] = self.l
        self.mem[(self.sp + 1) & 0xFFFF] = self.h
        self.l = lo
        self.h = hi

    def _op_halt(self, entry, addr):
        """HALT — stop execution (equivalent to OUT (2),0 for this emulator)."""
        self.running = False

    def _op_exx(self, entry, addr):
        """EXX — exchange BC,DE,HL with shadow registers.
        Simplified: swap BC↔DE, HL preserved (no shadow set in this emulator).
        For now, treat as NOP to avoid crashes — programs rarely depend on EXX
        behaviour, but they must not crash on it.
        """
        pass  # no shadow registers in this emulator

    def _op_rlca(self, entry, addr):
        """RLCA — Rotate A left circular. Bit 7 → carry and bit 0."""
        bit7 = (self.a >> 7) & 1
        self.a = ((self.a << 1) | bit7) & 0xFF
        self.cf = bool(bit7)

    def _op_rrca(self, entry, addr):
        """RRCA — Rotate A right circular. Bit 0 → carry and bit 7."""
        bit0 = self.a & 1
        self.a = ((self.a >> 1) | (bit0 << 7)) & 0xFF
        self.cf = bool(bit0)

    def _op_rla(self, entry, addr):
        """RLA — Rotate A left through carry."""
        old_carry = 1 if self.cf else 0
        self.cf = bool(self.a & 0x80)
        self.a = ((self.a << 1) | old_carry) & 0xFF

    def _op_rra(self, entry, addr):
        """RRA — Rotate A right through carry."""
        old_carry = 1 if self.cf else 0
        self.cf = bool(self.a & 0x01)
        self.a = ((self.a >> 1) | (old_carry << 7)) & 0xFF

    def _op_cpl(self, entry, addr):
        """CPL — Complement A (flip all bits)."""
        self.a = (~self.a) & 0xFF

    def _op_ld_sp_hl(self, entry, addr):
        """LD SP,HL — load stack pointer from HL."""
        self.sp = self.hl

    def _op_inc_sp(self, entry, addr):
        """INC SP."""
        self.sp = (self.sp + 1) & 0xFFFF

    def _op_dec_sp(self, entry, addr):
        """DEC SP."""
        self.sp = (self.sp - 1) & 0xFFFF

    def _op_call_nz_nn(self, entry, addr):
        """CALL NZ,nn — call if zero flag is not set."""
        target = self.fetch_word()
        if not self.zf:
            self.push_word(self.pc)
            self.pc = target

    def _op_call_z_nn(self, entry, addr):
        """CALL Z,nn — call if zero flag is set."""
        target = self.fetch_word()
        if self.zf:
            self.push_word(self.pc)
            self.pc = target

    def _op_call_nc_nn(self, entry, addr):
        """CALL NC,nn — call if carry flag is not set."""
        target = self.fetch_word()
        if not self.cf:
            self.push_word(self.pc)
            self.pc = target

    def _op_call_c_nn(self, entry, addr):
        """CALL C,nn — call if carry flag is set."""
        target = self.fetch_word()
        if self.cf:
            self.push_word(self.pc)
            self.pc = target

    # ── ED prefix instructions ──
    def _op_sbc_hl_bc(self, entry, addr):
        r = self.hl - self.bc - (1 if self.cf else 0)
        self.cf = r < 0
        self.hl = r & 0xFFFF
        self.zf = self.hl == 0

    # ── DD prefix instructions ──
    def _op_ld_ix_nn(self, entry, addr):
        self.ix = self.fetch_word()

    def _op_push_ix(self, entry, addr):
        self.push_word(self.ix)

    def _op_pop_ix(self, entry, addr):
        self.ix = self.pop_word()

    def _op_inc_ix(self, entry, addr):
        self.ix = (self.ix + 1) & 0xFFFF

    def _op_dec_ix(self, entry, addr):
        self.ix = (self.ix - 1) & 0xFFFF

    # ── DD prefix: IX+d indexed loads (parameterised) ──
    #
    # LD (IX+d),r  — DD 70+r d   (store register to IX+d)
    # LD r,(IX+d)  — DD 46+r*8 d (load register from IX+d)
    # LD (IX+d),n  — DD 36 d n   (store immediate to IX+d)
    #
    # The displacement byte d is fetched by the handler.  For DD-prefix
    # opcodes the decode already consumed the DD byte and the opcode
    # byte; d follows immediately.

    def _op_ld_ixd_r(self, entry, addr):
        """LD (IX+d),r — store register to memory at IX+d."""
        d = self.fetch_byte()
        if d >= 128:
            d -= 256
        # Source register encoded in bits 2-0 of the opcode
        src_idx = entry["opcode"] & 0x07
        val = self._reg_read(src_idx)
        ea = (self.ix + d) & 0xFFFF
        self.mem[ea] = val & 0xFF

    def _op_ld_r_ixd(self, entry, addr):
        """LD r,(IX+d) — load register from memory at IX+d."""
        d = self.fetch_byte()
        if d >= 128:
            d -= 256
        # Destination register encoded in bits 5-3 of the opcode
        dst_idx = (entry["opcode"] >> 3) & 0x07
        ea = (self.ix + d) & 0xFFFF
        val = self.mem[ea]
        self._reg_write(dst_idx, val)

    def _op_ld_ixd_n(self, entry, addr):
        """LD (IX+d),n — store immediate byte to memory at IX+d."""
        d = self.fetch_byte()
        if d >= 128:
            d -= 256
        n = self.fetch_byte()
        ea = (self.ix + d) & 0xFFFF
        self.mem[ea] = n & 0xFF

    # ── DD CB prefix: BIT b,(IX+d) ──
    #
    # DD CB d opcode — the displacement is consumed by _decode_prefix
    # and stored in self._ddcb_displacement.

    def _op_bit_ixd(self, entry, addr):
        """BIT b,(IX+d) — test bit b of memory at IX+d."""
        d = getattr(self, '_ddcb_displacement', 0)
        if d >= 128:
            d -= 256
        bit = (entry["opcode"] >> 3) & 0x07
        ea = (self.ix + d) & 0xFFFF
        val = self.mem[ea]
        self.zf = not bool(val & (1 << bit))

    # ── ED prefix: additional 16-bit loads and SBC ──

    def _op_sbc_hl_de(self, entry, addr):
        """SBC HL,DE — subtract DE and carry from HL."""
        r = self.hl - self.de - (1 if self.cf else 0)
        self.cf = r < 0
        self.hl = r & 0xFFFF
        self.zf = self.hl == 0

    def _op_ld_nn_ind_de(self, entry, addr):
        """LD (nn),DE — store DE to memory address nn."""
        a = self.fetch_word()
        self.mem[a] = self.e
        self.mem[(a + 1) & 0xFFFF] = self.d

    def _op_ld_de_nn_ind(self, entry, addr):
        """LD DE,(nn) — load DE from memory address nn."""
        a = self.fetch_word()
        self.e = self.mem[a]
        self.d = self.mem[(a + 1) & 0xFFFF]

    def _op_ld_nn_ind_bc(self, entry, addr):
        """LD (nn),BC — store BC to memory address nn."""
        a = self.fetch_word()
        self.mem[a] = self.c
        self.mem[(a + 1) & 0xFFFF] = self.b

    def _op_ld_bc_nn_ind(self, entry, addr):
        """LD BC,(nn) — load BC from memory address nn."""
        a = self.fetch_word()
        self.c = self.mem[a]
        self.b = self.mem[(a + 1) & 0xFFFF]

    def _op_ldir(self, entry, addr):
        """LDIR — Block copy forward: (DE)←(HL), HL++, DE++, BC-- until BC=0."""
        while True:
            self.mem[self.de] = self.mem[self.hl]
            self.hl = (self.hl + 1) & 0xFFFF
            self.de = (self.de + 1) & 0xFFFF
            self.bc = (self.bc - 1) & 0xFFFF
            if self.bc == 0:
                break
        self.f &= ~0x04  # reset P/V flag

    def _op_lddr(self, entry, addr):
        """LDDR — Block copy backward: (DE)←(HL), HL--, DE--, BC-- until BC=0."""
        while True:
            self.mem[self.de] = self.mem[self.hl]
            self.hl = (self.hl - 1) & 0xFFFF
            self.de = (self.de - 1) & 0xFFFF
            self.bc = (self.bc - 1) & 0xFFFF
            if self.bc == 0:
                break
        self.f &= ~0x04  # reset P/V flag

    # ── CB prefix: rotate / shift (parameterised) ──
    #
    # CB opcodes encode the register in bits 2-0.
    # Register index: B=0 C=1 D=2 E=3 H=4 L=5 (HL)=6 A=7

    def _op_cb_rlc(self, entry, addr):
        """RLC r — Rotate Left Circular (bit 7 → carry and bit 0)."""
        idx = entry["opcode"] & 0x07
        v = self._reg_read(idx)
        bit7 = (v >> 7) & 1
        v = ((v << 1) | bit7) & 0xFF
        self.cf = bool(bit7)
        self.zf = v == 0
        self._reg_write(idx, v)

    def _op_cb_rrc(self, entry, addr):
        """RRC r — Rotate Right Circular (bit 0 → carry and bit 7)."""
        idx = entry["opcode"] & 0x07
        v = self._reg_read(idx)
        bit0 = v & 1
        v = ((v >> 1) | (bit0 << 7)) & 0xFF
        self.cf = bool(bit0)
        self.zf = v == 0
        self._reg_write(idx, v)

    def _op_cb_rl(self, entry, addr):
        """RL r — Rotate Left through carry."""
        idx = entry["opcode"] & 0x07
        v = self._reg_read(idx)
        old_carry = 1 if self.cf else 0
        self.cf = bool(v & 0x80)
        v = ((v << 1) | old_carry) & 0xFF
        self.zf = v == 0
        self._reg_write(idx, v)

    def _op_cb_rr(self, entry, addr):
        """RR r — Rotate Right through carry."""
        idx = entry["opcode"] & 0x07
        v = self._reg_read(idx)
        old_carry = 1 if self.cf else 0
        self.cf = bool(v & 0x01)
        v = ((v >> 1) | (old_carry << 7)) & 0xFF
        self.zf = v == 0
        self._reg_write(idx, v)

    def _op_cb_sla(self, entry, addr):
        """SLA r — Shift Left Arithmetic (bit 7 → carry, bit 0 = 0)."""
        idx = entry["opcode"] & 0x07
        v = self._reg_read(idx)
        self.cf = bool(v & 0x80)
        v = (v << 1) & 0xFF
        self.zf = v == 0
        self._reg_write(idx, v)

    def _op_cb_sra(self, entry, addr):
        """SRA r — Shift Right Arithmetic (bit 0 → carry, bit 7 preserved)."""
        idx = entry["opcode"] & 0x07
        v = self._reg_read(idx)
        self.cf = bool(v & 0x01)
        v = ((v >> 1) | (v & 0x80)) & 0xFF
        self.zf = v == 0
        self._reg_write(idx, v)

    def _op_cb_srl(self, entry, addr):
        """SRL r — Shift Right Logical (bit 0 → carry, bit 7 = 0)."""
        idx = entry["opcode"] & 0x07
        v = self._reg_read(idx)
        self.cf = bool(v & 0x01)
        v = (v >> 1) & 0xFF
        self.zf = v == 0
        self._reg_write(idx, v)

    def _op_cb_bit(self, entry, addr):
        """BIT b,r — Test bit b of register r. Set ZF if bit is 0."""
        opcode = entry["opcode"]
        bit = (opcode >> 3) & 0x07
        idx = opcode & 0x07
        v = self._reg_read(idx)
        self.zf = not bool(v & (1 << bit))

    def _op_cb_res(self, entry, addr):
        """RES b,r — Reset (clear) bit b of register r."""
        opcode = entry["opcode"]
        bit = (opcode >> 3) & 0x07
        idx = opcode & 0x07
        v = self._reg_read(idx)
        v &= ~(1 << bit)
        self._reg_write(idx, v & 0xFF)

    def _op_cb_set(self, entry, addr):
        """SET b,r — Set bit b of register r."""
        opcode = entry["opcode"]
        bit = (opcode >> 3) & 0x07
        idx = opcode & 0x07
        v = self._reg_read(idx)
        v |= (1 << bit)
        self._reg_write(idx, v & 0xFF)

    # ── Run loop with I/O-aware step limiting ──

    def run(self, max_steps: int = 10_000_000) -> None:
        """Execute instructions until HALT/stop or step limit.

        The step counter only counts instructions executed in *user*
        address space.  Instructions running inside the firmware ROM
        area (0x7C80-0x7EFF) are excluded because they are system
        overhead — input polling loops, character echo, string
        printing — not user-program computation.  This lets
        interactive programs call FW_INPUTLINE or FW_GETKEY without
        burning through the step budget, while still protecting
        against runaway user code.

        A separate tick counter (always incremented) drives the
        periodic event pump and render so that pygame stays
        responsive during firmware I/O waits.

        max_steps defaults to 10 million so that compute-heavy
        programs like factorial have headroom.
        """
        FIRMWARE_LO = 0x7C80
        FIRMWARE_HI = 0x7EFF

        steps = 0
        ticks = 0
        while self.running and steps < max_steps:
            pc_now = self.pc

            self.step()

            # Only count steps when executing user code
            if not (FIRMWARE_LO <= pc_now <= FIRMWARE_HI):
                steps += 1

            ticks += 1
            if ticks % 256 == 0:
                self.display.pump_events()
                self.display.render()

        if self.running and steps >= max_steps:
            self.display.print_str("\nMax steps reached.\n")
        self.display.render()


# ─────────────────────────────────────────────────────────────────────
#  Unified Graphical Display
# ─────────────────────────────────────────────────────────────────────

class Z80yPicoDisplay:
    """
    Single unified screen — 32 columns x 24 rows.

    64-colour palette, NO colour clash: each character cell stores
    its own ink and paper colour index independently.

    Matches the ZX Spectrum display geometry: 256×192 logical pixels.
    Text is rendered from the loaded binary character ROM (charset.bin).
    Glyphs are rendered as 8×8 bitmaps, scaled to the display framebuffer.

    Cursor is drawn on-screen using the same ROM glyph system (block character).
    When output reaches the last row, a "Press any key..." prompt
    appears, then the screen scrolls to make room.
    """

    COLS = 32
    ROWS = 24
    BORDER = 96  # border in final window pixels (large, ZX Spectrum style)

    # ZX Spectrum logical resolution, scaled ×3
    DISPLAY_W = 256 * 3   # 768
    DISPLAY_H = 192 * 3   # 576

    # ── Factory default display attributes ──
    # These constants define the power-on state for all display
    # attributes.  Used by __init__, factory_reset, and boot.
    DEFAULT_INK = 0       # black
    DEFAULT_PAPER = 7     # white
    DEFAULT_BORDER = 7    # white
    DEFAULT_BRIGHT = 0    # bright off
    DEFAULT_FLASH = 0     # flash off

    COL_SCANLINE  = (0, 0, 0, 30)

    # --- Charset BIN system ---
    CHARSET_GLYPH_COUNT = 127       # codes 32–158
    CHARSET_BYTES_PER_GLYPH = 8
    CHARSET_EXPECTED_SIZE = CHARSET_GLYPH_COUNT * CHARSET_BYTES_PER_GLYPH  # 1016
    CHARSET_FIRST_CODE = 32
    CHARSET_LAST_CODE = 158

    # ── Glyph Mode key mapping (key char → extended code) ──
    GLYPH_KEY_MAP = {
        'q': 128, 'w': 129, 'e': 130, 'r': 131, 't': 132,
        'y': 133, 'u': 134, 'i': 135,
        'a': 136, 's': 137, 'd': 138, 'f': 139, 'g': 140,
        'h': 141, 'j': 142, 'k': 143,
        'z': 144, 'x': 145, 'c': 146, 'v': 147, 'b': 148,
        'n': 149, 'm': 150, ',': 151,
        '.': 152, '/': 153,
        'o': 154, 'p': 155, 'l': 156, ';': 157,
        "'": 158,
    }

    def __init__(self, palette: list[tuple[int, int, int]] | None = None):
        pygame.init()
        pygame.key.set_repeat(400, 50)

        # ── Palette ──
        self.palette = palette if palette else [(0, 0, 0)] * 64

        # ── Colour state ──
        self.current_ink = self.DEFAULT_INK
        self.current_paper = self.DEFAULT_PAPER
        self.current_border = self.DEFAULT_BORDER
        self.current_bright = self.DEFAULT_BRIGHT
        self.current_flash = self.DEFAULT_FLASH
        self._flash_state = False  # toggled by timer
        self._flash_time = pygame.time.get_ticks()
        self.flash_cells = set()   # coordinates of cells with FLASH attribute

        # ── Target cell size: 24×24 pixels (768/32 × 576/24) ──
        self.char_w = self.DISPLAY_W // self.COLS   # 24
        self.char_h = self.DISPLAY_H // self.ROWS   # 24

        # --- Charset BIN system ---
        # Load binary character ROM: 127 glyphs (codes 32–158), 8 bytes each
        script_dir = Path(__file__).resolve().parent
        charset_path = None
        for try_path in [
            script_dir / "charset.bin",
            Path("charset.bin"),
            Path.home() / "charset.bin",
        ]:
            if try_path.exists():
                charset_path = try_path
                break
        if charset_path is None:
            raise RuntimeError("charset.bin missing or invalid")
        with open(charset_path, "rb") as f:
            self._charset = f.read()
        if len(self._charset) != self.CHARSET_EXPECTED_SIZE:
            raise RuntimeError("charset.bin missing or invalid")
        print(f"Loaded charset from {charset_path} ({len(self._charset)} bytes)")

        # Framebuffer at final display resolution
        self.fb_w = self.DISPLAY_W   # 768
        self.fb_h = self.DISPLAY_H   # 576
        self.framebuffer = pygame.Surface((self.fb_w, self.fb_h))
        self.framebuffer.fill(self._get_rgb(self.current_paper))

        # Window size
        self.win_w = self.DISPLAY_W + self.BORDER * 2
        self.win_h = self.DISPLAY_H + self.BORDER * 2
        self.screen = pygame.display.set_mode((self.win_w, self.win_h))
        pygame.display.set_caption("Z80yPico")

        # Text grid: character codes (0 = empty/space)
        self.grid = [[0] * self.COLS for _ in range(self.ROWS)]
        # Per-cell colour: (ink_index, paper_index, bright, flash)
        self.cell_ink   = [[self.DEFAULT_INK]   * self.COLS
                           for _ in range(self.ROWS)]
        self.cell_paper = [[self.DEFAULT_PAPER]  * self.COLS
                           for _ in range(self.ROWS)]
        self.cell_bright = [[self.DEFAULT_BRIGHT] * self.COLS for _ in range(self.ROWS)]
        self.cell_flash  = [[self.DEFAULT_FLASH]  * self.COLS for _ in range(self.ROWS)]

        # Cursor position
        self.cur_col = 0
        self.cur_row = 0

        # VRAM memory reference — set by emulator to self.mem
        # When set, grid writes are mirrored to mem[0xD000..0xD2FF]
        self.vram_mem = None
        self.VRAM_BASE = 0xD000

        # Cursor blink state (derived from _flash_state, no independent timer)
        self._prev_cursor_col = 0
        self._prev_cursor_row = 0
        self.cursor_visible = False   # Z80 programs control via 0x0E/0x0F

        # Pagination
        self._lines_since_pause = 0

        # Scanline overlay (built once) — every 3rd pixel row
        self._scanlines = pygame.Surface(
            (self.DISPLAY_W, self.DISPLAY_H), pygame.SRCALPHA
        )
        for y in range(2, self.DISPLAY_H, 3):
            pygame.draw.line(
                self._scanlines, self.COL_SCANLINE,
                (0, y), (self.DISPLAY_W, y)
            )

        # ── Glyph cache keyed by (char_code, rgb_colour) ──
        self._glyph_cache: dict[tuple[int, tuple], pygame.Surface] = {}

        # ── Glyph Mode state ──
        self.glyph_mode = False

        # ── Internal keyboard queue ──
        # pump_events() translates KEYDOWN into key codes and appends here.
        # wait_for_key() drains this queue before polling pygame again.
        self.key_queue: list[int] = []

        # ── Pre-render [GLYPH] overlay indicator ──
        indicator_font = pygame.font.SysFont("monospace", 18, bold=True)
        self._glyph_indicator = indicator_font.render(
            "[GLYPH]", True, (255, 255, 255), (180, 0, 0)
        )

        self.clock = pygame.time.Clock()

    # ── Palette helpers ──

    def _get_rgb(self, index: int, bright: int = 0) -> tuple[int, int, int]:
        """Get RGB tuple for palette index, applying bright if needed."""
        index = max(0, min(63, index))
        if bright and 0 <= index <= 7:
            index += 8  # map to bright variant
        return self.palette[index]

    # --- Charset BIN system ---
    def _get_glyph(self, code: int, colour: tuple) -> pygame.Surface:
        """Get a glyph surface for (code, colour), cached.

        All glyphs are rendered from the binary charset ROM.
        Codes outside 32–158 are replaced with '?' (code 63).
        """
        # Clamp out-of-range codes to '?'
        if code < self.CHARSET_FIRST_CODE or code > self.CHARSET_LAST_CODE:
            code = 63
        key = (code, colour)
        if key not in self._glyph_cache:
            offset = (code - self.CHARSET_FIRST_CODE) * self.CHARSET_BYTES_PER_GLYPH
            glyph_data = self._charset[offset:offset + self.CHARSET_BYTES_PER_GLYPH]
            # Build 8×8 bitmap surface, then scale to cell size
            raw = pygame.Surface((8, 8), pygame.SRCALPHA)
            for y in range(8):
                row_byte = glyph_data[y]
                for x in range(8):
                    if row_byte & (0x80 >> x):
                        raw.set_at((x, y), colour)
            scaled = pygame.transform.scale(
                raw, (self.char_w, self.char_h)
            )
            self._glyph_cache[key] = scaled
        return self._glyph_cache[key]

    # ── Colour setters ──

    def set_ink(self, index: int) -> None:
        self.current_ink = max(0, min(63, index))

    def set_paper(self, index: int) -> None:
        self.current_paper = max(0, min(63, index))
        # Redraw background
        self._redraw_all()

    def set_border(self, index: int) -> None:
        self.current_border = max(0, min(63, index))

    # ── Text grid operations ──

    def _draw_cell(self, col: int, row: int):
        """Redraw a single cell on the framebuffer."""
        px = col * self.char_w
        py = row * self.char_h
        ink_idx = self.cell_ink[row][col]
        paper_idx = self.cell_paper[row][col]
        bright = self.cell_bright[row][col]
        flash = self.cell_flash[row][col]

        # Flash: swap ink and paper if flash active and state is on
        if flash and self._flash_state:
            ink_idx, paper_idx = paper_idx, ink_idx

        ink_rgb = self._get_rgb(ink_idx, bright)
        paper_rgb = self._get_rgb(paper_idx, bright)

        # Draw paper background
        pygame.draw.rect(self.framebuffer, paper_rgb,
                         (px, py, self.char_w, self.char_h))
        # Draw glyph
        ch = self.grid[row][col]
        if ch and (32 <= ch <= 158):
            glyph = self._get_glyph(ch, ink_rgb)
            self.framebuffer.blit(glyph, (px, py))

    def _redraw_all(self):
        """Redraw entire framebuffer from grid."""
        paper_rgb = self._get_rgb(self.current_paper, self.current_bright)
        self.framebuffer.fill(paper_rgb)
        for r in range(self.ROWS):
            for c in range(self.COLS):
                self._draw_cell(c, r)

    def _scroll_up(self):
        """Scroll the grid up by one row, clearing the bottom row."""
        for r in range(self.ROWS - 1):
            self.grid[r] = self.grid[r + 1][:]
            self.cell_ink[r] = self.cell_ink[r + 1][:]
            self.cell_paper[r] = self.cell_paper[r + 1][:]
            self.cell_bright[r] = self.cell_bright[r + 1][:]
            self.cell_flash[r] = self.cell_flash[r + 1][:]
        self.grid[self.ROWS - 1] = [0] * self.COLS
        self.cell_ink[self.ROWS - 1] = [self.current_ink] * self.COLS
        self.cell_paper[self.ROWS - 1] = [self.current_paper] * self.COLS
        self.cell_bright[self.ROWS - 1] = [self.current_bright] * self.COLS
        self.cell_flash[self.ROWS - 1] = [self.current_flash] * self.COLS
        # Rebuild flash_cells set after scroll
        self.flash_cells = {
            (r, c)
            for r in range(self.ROWS)
            for c in range(self.COLS)
            if self.cell_flash[r][c]
        }
        self._redraw_all()
        self._sync_vram_full()

    def _sync_vram_full(self):
        """Mirror the entire display grid into Z80 memory at VRAM_BASE."""
        if self.vram_mem is None:
            return
        for r in range(self.ROWS):
            base = self.VRAM_BASE + r * self.COLS
            for c in range(self.COLS):
                self.vram_mem[base + c] = self.grid[r][c] & 0xFF

    def _do_newline(self):
        """Move cursor to start of next line, with pagination."""
        self.cur_col = 0
        self.cur_row += 1
        self._lines_since_pause += 1

        if self.cur_row >= self.ROWS:
            self._show_press_any_key()
            self._scroll_up()
            self.cur_row = self.ROWS - 1

    def _show_press_any_key(self):
        """Show pagination prompt on last row and wait for keypress."""
        saved_row = self.grid[self.ROWS - 1][:]
        saved_ink = self.cell_ink[self.ROWS - 1][:]
        saved_paper = self.cell_paper[self.ROWS - 1][:]
        saved_bright = self.cell_bright[self.ROWS - 1][:]
        saved_flash = self.cell_flash[self.ROWS - 1][:]

        prompt = "-- Press any key --"
        self.grid[self.ROWS - 1] = [0] * self.COLS
        self.cell_ink[self.ROWS - 1] = [self.current_ink] * self.COLS
        self.cell_paper[self.ROWS - 1] = [self.current_paper] * self.COLS
        self.cell_bright[self.ROWS - 1] = [self.current_bright] * self.COLS
        self.cell_flash[self.ROWS - 1] = [0] * self.COLS
        offset = (self.COLS - len(prompt)) // 2
        if offset < 0:
            offset = 0
        for i, ch in enumerate(prompt):
            pos = offset + i
            if pos < self.COLS:
                self.grid[self.ROWS - 1][pos] = ord(ch)
        self._redraw_all()
        self.render()

        waiting = True
        while waiting:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit()
                    sys.exit(0)
                if event.type == pygame.KEYDOWN:
                    waiting = False
                    break
            self.render()

        self.grid[self.ROWS - 1] = saved_row
        self.cell_ink[self.ROWS - 1] = saved_ink
        self.cell_paper[self.ROWS - 1] = saved_paper
        self.cell_bright[self.ROWS - 1] = saved_bright
        self.cell_flash[self.ROWS - 1] = saved_flash
        self._redraw_all()
        self._lines_since_pause = 0

    def put_char(self, ch: int):
        """Handle a character for console output.

        Control characters:
          0x08 (BS)  — move cursor one position left (non-destructive)
          0x0D (CR)  — carriage return
          0x0A (LF)  — line feed
          0x0E (SO)  — cursor on (enable blinking cursor)
          0x0F (SI)  — cursor off (hide cursor)
        Printable: 0x20–0x7E
        """
        if ch == 0x0E:  # SO — cursor on
            self.cursor_visible = True
            return
        if ch == 0x0F:  # SI — cursor off
            self.cursor_visible = False
            return
        if ch == 3:   # ETX — move cursor up (non-destructive)
            if self.cur_row > 0:
                self.cur_row -= 1
            return
        if ch == 4:   # EOT — move cursor down (non-destructive)
            if self.cur_row < self.ROWS - 1:
                self.cur_row += 1
            return
        if ch == 8:   # BS — move cursor left (non-destructive)
            if self.cur_col > 0:
                self.cur_col -= 1
            elif self.cur_row > 0:
                self.cur_row -= 1
                self.cur_col = self.COLS - 1
            return
        if ch == 9:   # HT — move cursor right (non-destructive)
            if self.cur_col < self.COLS - 1:
                self.cur_col += 1
            elif self.cur_row < self.ROWS - 1:
                self.cur_row += 1
                self.cur_col = 0
            return
        if ch == 13:  # CR
            self.cur_col = 0
            return
        if ch == 10:  # LF
            self._do_newline()
            return
        if (32 <= ch <= 158):
            if self.cur_col >= self.COLS:
                self._do_newline()
            r, c = self.cur_row, self.cur_col
            self.grid[r][c] = ch
            if self.vram_mem is not None:
                self.vram_mem[self.VRAM_BASE + r * self.COLS + c] = ch & 0xFF
            self.cell_ink[r][c] = self.current_ink
            self.cell_paper[r][c] = self.current_paper
            self.cell_bright[r][c] = self.current_bright
            self.cell_flash[r][c] = self.current_flash
            if self.current_flash:
                self.flash_cells.add((r, c))
            else:
                self.flash_cells.discard((r, c))
            self._draw_cell(c, r)
            self.cur_col += 1

    def clear_screen(self):
        """Clear entire screen and reset cursor."""
        self.grid = [[0] * self.COLS for _ in range(self.ROWS)]
        self.cell_ink = [[self.current_ink] * self.COLS
                         for _ in range(self.ROWS)]
        self.cell_paper = [[self.current_paper] * self.COLS
                           for _ in range(self.ROWS)]
        self.cell_bright = [[self.current_bright] * self.COLS
                            for _ in range(self.ROWS)]
        self.cell_flash = [[self.current_flash] * self.COLS
                           for _ in range(self.ROWS)]
        self.flash_cells.clear()
        self.cur_col = 0
        self.cur_row = 0
        self._lines_since_pause = 0
        paper_rgb = self._get_rgb(self.current_paper, self.current_bright)
        self.framebuffer.fill(paper_rgb)
        self._sync_vram_full()

    def print_str(self, text: str):
        """Print a Python string on screen via put_char."""
        for ch in text:
            if ch == '\n':
                self.put_char(13)
                self.put_char(10)
            elif ch == '\r':
                self.put_char(13)
            elif 32 <= ord(ch) <= 126:
                self.put_char(ord(ch))

    def reset_pagination(self):
        """Reset the line counter (call after user interaction)."""
        self._lines_since_pause = 0

    def factory_reset(self):
        """Restore all display state to factory power-on defaults.

        Resets:
          - current ink/paper/border/bright/flash to DEFAULT_* constants
          - per-cell ink/paper/bright/flash arrays
          - character grid (all cells cleared)
          - flash_cells tracking set
          - cursor position and visibility
          - previous cursor position bookkeeping
          - pagination counter
          - glyph mode flag
          - framebuffer fill to factory paper colour
        """
        # Restore attribute state to factory defaults
        self.current_ink    = self.DEFAULT_INK
        self.current_paper  = self.DEFAULT_PAPER
        self.current_border = self.DEFAULT_BORDER
        self.current_bright = self.DEFAULT_BRIGHT
        self.current_flash  = self.DEFAULT_FLASH

        # Reset flash timer state
        self._flash_state = False
        self._flash_time  = pygame.time.get_ticks()
        self.flash_cells  = set()

        # Clear character grid and per-cell attributes
        self.grid       = [[0] * self.COLS for _ in range(self.ROWS)]
        self.cell_ink   = [[self.DEFAULT_INK]    * self.COLS
                           for _ in range(self.ROWS)]
        self.cell_paper = [[self.DEFAULT_PAPER]   * self.COLS
                           for _ in range(self.ROWS)]
        self.cell_bright = [[self.DEFAULT_BRIGHT] * self.COLS
                            for _ in range(self.ROWS)]
        self.cell_flash  = [[self.DEFAULT_FLASH]  * self.COLS
                            for _ in range(self.ROWS)]

        # Reset cursor
        self.cur_col = 0
        self.cur_row = 0
        self._prev_cursor_col = 0
        self._prev_cursor_row = 0
        self.cursor_visible = False

        # Reset pagination
        self._lines_since_pause = 0

        # Reset glyph mode
        self.glyph_mode = False

        # Repaint framebuffer with factory paper colour
        paper_rgb = self._get_rgb(self.DEFAULT_PAPER, self.DEFAULT_BRIGHT)
        self.framebuffer.fill(paper_rgb)

    # ── Cursor ──

    def _update_flash(self):
        now = pygame.time.get_ticks()
        if now - self._flash_time > 640:  # ~1.5 Hz like Spectrum
            self._flash_state = not self._flash_state
            self._flash_time = now
            # Redraw only flashing cells
            for row, col in self.flash_cells:
                self._draw_cell(col, row)

    def _draw_cursor_on_framebuffer(self):
        """Draw the blinking block cursor directly on the framebuffer."""
        if not self.cursor_visible:
            return
        # Cursor is visible when _flash_state is False (inverse of flash phase)
        if self._flash_state:
            return
        col = self.cur_col
        row = self.cur_row
        if col >= self.COLS or row >= self.ROWS:
            return

        px = col * self.char_w
        py = row * self.char_h

        ink_rgb = self._get_rgb(self.current_ink, self.current_bright)
        paper_rgb = self._get_rgb(self.current_paper, self.current_bright)

        # Draw a filled block in ink colour
        pygame.draw.rect(self.framebuffer, ink_rgb,
                         (px, py, self.char_w, self.char_h))

        # If there's a character under the cursor, draw it in paper colour
        ch = self.grid[row][col]
        if ch and (32 <= ch <= 158):
            glyph = self._get_glyph(ch, paper_rgb)
            self.framebuffer.blit(glyph, (px, py))

    def _erase_cursor_on_framebuffer(self):
        """Erase the cursor by restoring the cell at the *previous* cursor position."""
        col = self._prev_cursor_col
        row = self._prev_cursor_row
        if col < self.COLS and row < self.ROWS:
            self._draw_cell(col, row)

    # ── Rendering ──

    def render(self):
        """Full render cycle."""
        self._update_flash()

        # Always restore the previous cursor cell first (removes ghost)
        self._erase_cursor_on_framebuffer()

        # Draw cursor at current position onto the framebuffer
        self._draw_cursor_on_framebuffer()

        # Remember where the cursor was drawn so we can erase it next frame
        self._prev_cursor_col = self.cur_col
        self._prev_cursor_row = self.cur_row

        # Fill window with border colour
        border_rgb = self._get_rgb(self.current_border, self.current_bright)
        self.screen.fill(border_rgb)

        # CRT bezel lines
        bezel_rgb = tuple(max(0, c - 40) for c in border_rgb)
        bezel2_rgb = tuple(max(0, c - 20) for c in border_rgb)
        bx = self.BORDER - 4
        by = self.BORDER - 4
        bw = self.DISPLAY_W + 8
        bh = self.DISPLAY_H + 8
        pygame.draw.rect(self.screen, bezel_rgb,
                         (bx, by, bw, bh), 2, border_radius=6)
        pygame.draw.rect(self.screen, bezel2_rgb,
                         (bx + 2, by + 2, bw - 4, bh - 4), 1,
                         border_radius=4)

        # Blit framebuffer directly
        self.screen.blit(self.framebuffer, (self.BORDER, self.BORDER))

        # Scanline overlay
        self.screen.blit(self._scanlines, (self.BORDER, self.BORDER))

        # Glyph Mode indicator overlay (does not alter framebuffer)
        if self.glyph_mode:
            ind_x = self.BORDER + self.DISPLAY_W - self._glyph_indicator.get_width() - 4
            ind_y = self.BORDER + 4
            self.screen.blit(self._glyph_indicator, (ind_x, ind_y))

        pygame.display.flip()

        self.clock.tick(60)

    # ── Input ──

    def _translate_event(self, event) -> int | None:
        """Translate a pygame KEYDOWN event into an internal key code, or None."""
        if event.key == pygame.K_RETURN:
            return 10
        if event.key == pygame.K_BACKSPACE:
            return 8
        if event.key == pygame.K_ESCAPE:
            return 27
        if event.key == pygame.K_LEFT:
            return 1
        if event.key == pygame.K_RIGHT:
            return 2
        if event.key == pygame.K_UP:
            return 3
        if event.key == pygame.K_DOWN:
            return 4
        if event.key == pygame.K_DELETE:
            return 0x7F
        # Ctrl+G toggles Glyph Mode (no key code returned)
        if event.key == pygame.K_g and (event.mod & pygame.KMOD_CTRL):
            self.glyph_mode = not self.glyph_mode
            return None
        # Glyph Mode mapping
        if self.glyph_mode and event.unicode and event.unicode.lower() in self.GLYPH_KEY_MAP:
            return self.GLYPH_KEY_MAP[event.unicode.lower()]
        # Printable ASCII
        if event.unicode and 32 <= ord(event.unicode) <= 126:
            return ord(event.unicode)
        return None

    def pump_events(self):
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                pygame.quit()
                sys.exit(0)
            if event.type == pygame.KEYDOWN:
                code = self._translate_event(event)
                if code is not None:
                    self.key_queue.append(code)

    def wait_for_key(self) -> int:
        """Block until a key is pressed. Return ASCII code.

        Key codes returned:
          1   — Left
          2   — Right
          3   — Up
          4   — Down
          8   — Backspace
          10  — Enter (line feed)
          27  — Escape
          32-126 — printable ASCII
          127 — Delete / Supr
          128-153 — extended glyphs (via Glyph Mode)

        Drains self.key_queue first (filled by pump_events during
        compute bursts), then polls pygame for new events.
        """
        while True:
            # Drain any keys buffered by pump_events()
            if self.key_queue:
                code = self.key_queue.pop(0)
                return code
            # Poll pygame for new events
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit()
                    sys.exit(0)
                if event.type == pygame.KEYDOWN:
                    code = self._translate_event(event)
                    if code is not None:
                        return code
            self.render()

    def get_command(self, prompt: str = "> ") -> str:
        """
        Read a command line typed on-screen.
        Characters appear at the cursor using the character ROM glyphs.
        Returns the entered string when Enter is pressed.
        """
        self.reset_pagination()
        self.print_str(prompt)
        self.render()

        cmd_chars: list[str] = []

        while True:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit()
                    sys.exit(0)

                if event.type == pygame.KEYDOWN:
                    if event.key == pygame.K_RETURN:
                        self.put_char(13)
                        self.put_char(10)
                        self.render()
                        return "".join(cmd_chars)

                    elif event.key == pygame.K_BACKSPACE:
                        if cmd_chars:
                            cmd_chars.pop()
                            if self.cur_col > 0:
                                self.cur_col -= 1
                            elif self.cur_row > 0:
                                self.cur_row -= 1
                                self.cur_col = self.COLS - 1
                            self.grid[self.cur_row][self.cur_col] = 0
                            self._draw_cell(self.cur_col, self.cur_row)

                    elif event.key == pygame.K_ESCAPE:
                        while cmd_chars:
                            cmd_chars.pop()
                            if self.cur_col > 0:
                                self.cur_col -= 1
                            elif self.cur_row > 0:
                                self.cur_row -= 1
                                self.cur_col = self.COLS - 1
                            self.grid[self.cur_row][self.cur_col] = 0
                            self._draw_cell(self.cur_col, self.cur_row)

                    elif event.key == pygame.K_g and (event.mod & pygame.KMOD_CTRL):
                        self.glyph_mode = not self.glyph_mode

                    elif self.glyph_mode and event.unicode and event.unicode.lower() in self.GLYPH_KEY_MAP:
                        glyph_code = self.GLYPH_KEY_MAP[event.unicode.lower()]
                        cmd_chars.append(chr(glyph_code))
                        self.put_char(glyph_code)

                    elif event.unicode:
                        ch = event.unicode
                        if 32 <= ord(ch) <= 126:
                            cmd_chars.append(ch)
                            self.put_char(ord(ch))

            self.render()


# ─────────────────────────────────────────────────────────────────────
#  File system helpers
# ─────────────────────────────────────────────────────────────────────

def get_initial_working_directory() -> Path:
    preferred = Path("C:/")
    if preferred.exists():
        return preferred
    return Path.cwd()


def normalize_path(path_str: str, current_dir: Path) -> Path:
    # Replace forward slashes with OS separator for Windows compatibility
    path_str = path_str.replace("/", os.sep)
    raw_path = Path(path_str)
    if raw_path.is_absolute():
        return raw_path
    return current_dir / raw_path


def list_directory(target: Path) -> list[str]:
    lines = []
    if not target.exists():
        lines.append(f"Not found: {target}")
        return lines
    if target.is_file():
        lines.append(f"File: {target.name}")
        lines.append(f"Size: {target.stat().st_size} bytes")
        return lines
    lines.append(f"Dir: {target.name}/")
    entries = sorted(target.iterdir(),
                     key=lambda p: (p.is_file(), p.name.lower()))
    # Filter: visible directories + .bin files only
    filtered = []
    for entry in entries:
        if entry.name.startswith("."):
            continue
        if entry.is_dir():
            filtered.append(entry)
        elif entry.is_file() and entry.suffix.lower() == ".bin":
            filtered.append(entry)
    if not filtered:
        lines.append("  (empty)")
        return lines
    for entry in filtered:
        if entry.is_dir():
            lines.append(f" <DIR> {entry.name}"[:32])
        else:
            sz = entry.stat().st_size
            lines.append(f" {sz:>5} {entry.name}"[:32])
    return lines


def parse_command(command_line: str) -> list[str]:
    import shlex
    try:
        return shlex.split(command_line, posix=False)
    except ValueError:
        return []


# ─────────────────────────────────────────────────────────────────────
#  Z80 Command Assembler — Firmware + Shell Wrapper Architecture
# ─────────────────────────────────────────────────────────────────────
#
#  Layer 1 — Firmware routines (resident in ROM at 0x7E00–0x7EFF)
#
#    Callable subroutines that end with RET.  Installed by
#    install_bios() and never overwritten.  User programs can
#    call them directly:
#
#        LD A, 12
#        LD (0x7F00), A
#        CALL 0x7E40          ; FW_INK
#
#    Console input firmware (v23.0):
#
#        CALL 0x7E90          ; FW_GETKEY — single key → A
#        CALL 0x7EA0          ; FW_INPUTLINE — line → 0x7F00
#
#    Console output firmware (v23.0):
#
#        CALL 0x7C80          ; FW_PUTCHAR — print char in A
#        CALL 0x7C90          ; FW_PRINT   — print string at (HL)
#
#    Firmware address table:
#        FW_CLS       = 0x7E00     FW_DIR       = 0x7E10
#        FW_PWD       = 0x7E20     FW_STATUS    = 0x7E30
#        FW_INK       = 0x7E40     FW_PAPER     = 0x7E50
#        FW_BORDER    = 0x7E60     FW_FLASH     = 0x7E70
#        FW_BRIGHT    = 0x7E80
#        FW_GETKEY    = 0x7E90     FW_INPUTLINE = 0x7EA0
#        FW_PUTCHAR   = 0x7C80     FW_PRINT     = 0x7C90
#
#  Layer 2 — Shell command wrappers (loaded at 0x7D00 by exec_z80)
#
#    Small binaries that CALL a firmware routine, then halt via
#    OUT (2),A.  These are what the shell executes.  They do NOT
#    live in ROM — they are written into 0x7D00 on each command.
#
#    Pure-output wrappers (help, bios) still print via OUT (1),A
#    and halt, since they have no firmware routine counterpart.
#
#  Layer 3 — Shell prompt
#
#    The shell prompt is itself a Z80 wrapper (CMD_SHELL_PROMPT)
#    that prints "> " via OUT(1) and then CALLs FW_INPUTLINE.
#    The result is read from 0x7F00 by the Python main loop.
#    FW_INPUTLINE is a reusable service: the shell is one client,
#    future Z80 programs and an INPUT command can also use it.
#
#  On real Z80yPico hardware the firmware routines live in ROM and
#  the Pico services port 4 over the Z80 bus.  The wrapper area
#  would be in RAM below the ROM region.  FW_GETKEY reads the PS/2
#  keyboard and FW_INPUTLINE is Z80 machine code in ROM.
# ─────────────────────────────────────────────────────────────────────

WRAPPER_ORG = Z80yPicoEmulator.WRAPPER_ADDRESS  # 0x7D00


def _asm_print_halt(text: str) -> bytes:
    """Assemble: print null-terminated string via OUT(1), then halt.

    Used for help and bios — these have no firmware counterpart.
    """
    code_len = 16
    str_addr = WRAPPER_ORG + code_len
    code = bytearray([
        0x21, str_addr & 0xFF, (str_addr >> 8) & 0xFF,  # LD HL,str
        0x7E,                   # loop: LD A,(HL)
        0xB7,                   # OR A
        0x28, 0x05,             # JR Z,done (+5)
        0xD3, 0x01,             # OUT (1),A
        0x23,                   # INC HL
        0x18, 0xF7,             # JR loop (-9)
        0x3E, 0x00,             # done: LD A,0
        0xD3, 0x02,             # OUT (2),A
    ])
    for ch in text:
        if ch == '\n':
            code += b'\r\n'
        else:
            code.append(ord(ch) & 0x7F)
    code.append(0x00)
    return bytes(code)


def _asm_fw_wrapper(fw_addr: int) -> bytes:
    """Assemble a shell command wrapper that CALLs a firmware routine.

    Z80 machine code:
        CALL fw_addr     ; CD lo hi — call resident firmware
        LD A, 0          ; 3E 00    — completion signal
        OUT (2), A       ; D3 02    — halt Z80 routine
    """
    return bytes([
        0xCD, fw_addr & 0xFF, (fw_addr >> 8) & 0xFF,  # CALL fw_addr
        0x3E, 0x00,             # LD A, 0
        0xD3, 0x02,             # OUT (2), A  — halt
    ])


def _asm_load_file(filename: str) -> bytes:
    """Assemble: copy filename to 0x7F00, syscall LOAD, halt."""
    code = bytearray()
    code += b'\x21\x00\x00'          # LD HL, str_addr (patched)
    code += b'\x11\x00\x7F'          # LD DE, 0x7F00
    code += bytes([
        0x7E,               # LD A,(HL)
        0x12,               # LD (DE),A
        0xB7,               # OR A
        0x28, 0x04,         # JR Z, do_load
        0x23,               # INC HL
        0x13,               # INC DE
        0x18, 0xF7,         # JR copy  (-9 back to LD A,(HL))
    ])
    # do_load:
    code += bytes([
        0x3E, 0x02,         # LD A, SYS_LOAD
        0xD3, 0x04,         # OUT (4), A
        0xDB, 0x04,         # IN A,(4)  — result
        0x3E, 0x00,         # LD A, 0
        0xD3, 0x02,         # OUT (2), A
    ])
    str_offset = len(code)
    for ch in filename:
        code.append(ord(ch) & 0x7F)
    code.append(0x00)
    str_addr = WRAPPER_ORG + str_offset
    code[1] = str_addr & 0xFF
    code[2] = (str_addr >> 8) & 0xFF
    return bytes(code)


def _asm_run_file(filename: str) -> bytes:
    """Assemble: copy filename to buffer, LOAD, check, RUN, halt."""
    code = bytearray()
    code += b'\x21\x00\x00'          # LD HL, str (patched)
    code += b'\x11\x00\x7F'          # LD DE, 0x7F00
    code += bytes([
        0x7E, 0x12, 0xB7,            # LD A,(HL) / LD (DE),A / OR A
        0x28, 0x04,                   # JR Z, do_load
        0x23, 0x13,                   # INC HL / INC DE
        0x18, 0xF7,                   # JR copy  (-9 back to LD A,(HL))
    ])
    # do_load:
    code += bytes([
        0x3E, 0x02,                   # LD A, SYS_LOAD
        0xD3, 0x04,                   # OUT (4), A
        0xDB, 0x04,                   # IN A,(4)
        0xB7,                         # OR A
        0x20, 0x04,                   # JR NZ, halt (skip run)
        0x3E, 0x03,                   # LD A, SYS_RUN
        0xD3, 0x04,                   # OUT (4), A
    ])
    # halt:
    code += bytes([
        0x3E, 0x00,                   # LD A, 0
        0xD3, 0x02,                   # OUT (2), A
    ])
    str_offset = len(code)
    for ch in filename:
        code.append(ord(ch) & 0x7F)
    code.append(0x00)
    str_addr = WRAPPER_ORG + str_offset
    code[1] = str_addr & 0xFF
    code[2] = (str_addr >> 8) & 0xFF
    return bytes(code)


# ─────────────────────────────────────────────────────────────────────
#  External command binary loader
# ─────────────────────────────────────────────────────────────────────
#  All shell commands are loaded from external .BIN files at startup.
#  This mirrors the real Z80yPico hardware where command programs
#  exist as standalone Z80 binaries on storage.

def _load_cmd_bin(filename: str) -> bytes:
    """Load a command binary from disk.

    Search order:
      1. Directory of this script
      2. Current working directory

    Returns the binary data, or empty bytes if not found.
    """
    script_dir = Path(__file__).resolve().parent
    for try_path in [
        script_dir / filename,
        Path(filename),
    ]:
        if try_path.exists():
            with open(try_path, "rb") as f:
                data = f.read()
            print(f"  {filename}: {len(data)} bytes")
            return data
    print(f"  {filename}: NOT FOUND")
    return b""


print("Loading command binaries:")
CMD_HELP    = _load_cmd_bin("CMD_HELP.BIN")
CMD_BIOS    = _load_cmd_bin("CMD_BIOS.BIN")
CMD_CLS     = _load_cmd_bin("CMD_CLS.BIN")
CMD_DIR     = _load_cmd_bin("CMD_DIR.BIN")
CMD_PWD     = _load_cmd_bin("CMD_PWD.BIN")
CMD_STATUS  = _load_cmd_bin("CMD_STATUS.BIN")
CMD_INK     = _load_cmd_bin("CMD_INK.BIN")
CMD_PAPER   = _load_cmd_bin("CMD_PAPER.BIN")
CMD_BORDER  = _load_cmd_bin("CMD_BORDER.BIN")
CMD_FLASH   = _load_cmd_bin("CMD_FLASH.BIN")
CMD_BRIGHT  = _load_cmd_bin("CMD_BRIGHT.BIN")
CMD_NEW     = _load_cmd_bin("CMD_NEW.BIN")
CMD_RESET   = _load_cmd_bin("CMD_RESET.BIN")
CMD_RUN     = _load_cmd_bin("CMD_RUN.BIN")
CMD_PALETTE = _load_cmd_bin("CMD_PALETTE.BIN")


# ─────────────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────────────

def _main_shell():
    """Legacy interactive shell entry point.

    This is the original `main()` from the emulator before the
    workflow integration. It boots the Z80yPico shell prompt and
    dispatches CMD_*.BIN commands. Preserved for backward
    compatibility behind the `--shell` CLI flag.
    """
    palette = load_palette()
    display = Z80yPicoDisplay(palette)
    emulator = Z80yPicoEmulator(display)

    # ── Load CSV decode table and build dispatch ──
    emulator.decode_table = load_decode_table()
    emulator._build_dispatch_table()

    current_dir = get_initial_working_directory()
    emulator.current_dir = current_dir

    # ── BASIC interpreter ──
    basic = BasicInterpreter(display, emulator) if _HAS_BASIC else None

    def show_boot_screen():
        display.clear_screen()
        display.print_str("Z80yPico Emulator v24.0\n")
        display.print_str("524288 bytes free\n")
        display.print_str("64 colour palette\n")
        display.print_str("\n")
        display.print_str("Type 'help' for commands.\n")
        display.print_str("\n")
        display.render()

    def exec_z80(binary: bytes):
        """Load a Z80 command wrapper into the wrapper area and execute.

        Wrappers are loaded at WRAPPER_ADDRESS (0x7D00), which is
        below the firmware area (0x7E00).  This preserves resident
        firmware routines so that wrappers can CALL them.
        """
        addr = Z80yPicoEmulator.WRAPPER_ADDRESS
        emulator.mem[addr:addr + len(binary)] = binary
        emulator._pending_run = False
        emulator.pc = addr
        emulator.sp = Z80yPicoEmulator.STACK_INIT
        emulator.running = True
        emulator.install_bios()
        try:
            emulator.run()
        except NotImplementedError as exc:
            display.print_str(f"\nStopped: {exc}\n")
        except Exception as exc:
            display.print_str(f"\nError: {exc}\n")

        # If the Z80 program requested RUN via syscall,
        # execute the loaded user program now
        if emulator._pending_run:
            emulator._pending_run = False
            try:
                display.clear_screen()
                display.render()
                emulator.run_from()
            except NotImplementedError as exc:
                display.print_str(f"\nStopped: {exc}\n")
            except Exception as exc:
                display.print_str(f"\nError: {exc}\n")

        # If the Z80 program requested a factory reset via syscall,
        # perform it now that the command binary has exited cleanly.
        if emulator._pending_factory_reset:
            emulator._pending_factory_reset = False
            emulator.factory_reset()
            emulator.current_dir = current_dir
            show_boot_screen()

    # ── Shell prompt wrapper (Layer 3) ──
    # The shell is a client of FW_INPUTLINE.  This Z80 wrapper
    # prints the "> " prompt via OUT(1), then CALLs FW_INPUTLINE
    # to read a line into 0x7F00, then halts.
    #
    # Z80 machine code:
    #   LD A, '>'          ; 3E 3E
    #   OUT (1), A         ; D3 01
    #   LD A, ' '          ; 3E 20
    #   OUT (1), A         ; D3 01
    #   CALL FW_INPUTLINE  ; CD A0 7E
    #   LD A, 0            ; 3E 00
    #   OUT (2), A         ; D3 02  — halt
    CMD_SHELL_PROMPT = bytes([
        0x3E, 0x3E,         # LD A, '>'
        0xD3, 0x01,         # OUT (1), A
        0x3E, 0x20,         # LD A, ' '
        0xD3, 0x01,         # OUT (1), A
        0xCD, 0xA0, 0x7E,   # CALL FW_INPUTLINE
        0x3E, 0x00,         # LD A, 0
        0xD3, 0x02,         # OUT (2), A  — halt
    ])

    # Boot message on screen
    show_boot_screen()

    while True:
        # Layer 3: Shell calls FW_INPUTLINE via Z80 wrapper.
        # The prompt is printed and input is read entirely by Z80
        # machine code calling the firmware line input service.
        display.reset_pagination()
        emulator.shell_mode = True
        exec_z80(CMD_SHELL_PROMPT)

        # Read the null-terminated command from the syscall buffer
        command_line = emulator._read_buffer_string()

        if not command_line:
            continue

        parts = parse_command(command_line)
        if not parts:
            continue

        cmd = parts[0].lower().strip('"').strip("'")

        # ── Commands that must stay in Python ──

        if cmd in ("exit", "quit"):
            display.print_str("Goodbye.\n")
            display.render()
            pygame.time.wait(600)
            pygame.quit()
            sys.exit(0)

        elif cmd == "reset":
            if not CMD_RESET:
                display.print_str("CMD_RESET.BIN not found.\n")
            else:
                exec_z80(CMD_RESET)

        elif cmd == "wd":
            if len(parts) < 2:
                try:
                    import tkinter as tk
                    from tkinter import filedialog
                    root = tk.Tk()
                    root.withdraw()
                    root.update()
                    selected = filedialog.askdirectory(
                        title="Select working directory",
                        initialdir=str(current_dir)
                    )
                    root.destroy()
                    if not selected:
                        display.print_str("Cancelled.\n")
                        continue
                    current_dir = Path(selected)
                    emulator.current_dir = current_dir
                    display.print_str("OK\n")
                except Exception as exc:
                    display.print_str(f"Error: {exc}\n")
            else:
                raw = " ".join(parts[1:]).strip('"').strip("'")
                target = normalize_path(raw, current_dir)
                if not target.exists():
                    display.print_str("Not found:\n")
                    display.print_str(f"{target}\n")
                elif not target.is_dir():
                    display.print_str("Not a directory.\n")
                else:
                    current_dir = target
                    emulator.current_dir = current_dir
                    display.print_str("OK\n")

        # ── Commands executed as Z80 machine code ──

        elif cmd == "help":
            if not CMD_HELP:
                display.print_str("CMD_HELP.BIN not found.\n")
            else:
                exec_z80(CMD_HELP)

        elif cmd == "bios":
            if not CMD_BIOS:
                display.print_str("CMD_BIOS.BIN not found.\n")
            else:
                exec_z80(CMD_BIOS)

        elif cmd == "cls":
            if not CMD_CLS:
                display.print_str("CMD_CLS.BIN not found.\n")
            else:
                exec_z80(CMD_CLS)

        elif cmd == "new":
            if not CMD_NEW:
                display.print_str("CMD_NEW.BIN not found.\n")
            else:
                exec_z80(CMD_NEW)
                show_boot_screen()

        elif cmd in ("dir", "cat", "ls"):
            if not CMD_DIR:
                display.print_str("CMD_DIR.BIN not found.\n")
            else:
                exec_z80(CMD_DIR)

        elif cmd == "pwd":
            if not CMD_PWD:
                display.print_str("CMD_PWD.BIN not found.\n")
            else:
                exec_z80(CMD_PWD)

        elif cmd == "status":
            if not CMD_STATUS:
                display.print_str("CMD_STATUS.BIN not found.\n")
            else:
                exec_z80(CMD_STATUS)

        elif cmd == "load":
            if len(parts) == 1:
                try:
                    import tkinter as tk
                    from tkinter import filedialog
                    root = tk.Tk()
                    root.withdraw()
                    root.update()
                    file_path = filedialog.askopenfilename(
                        title="Select a BIN file",
                        initialdir=str(current_dir),
                        filetypes=[
                            ("BIN files", "*.bin"),
                            ("All files", "*.*")
                        ]
                    )
                    root.destroy()
                    if not file_path:
                        display.print_str("No file selected.\n")
                        continue
                    filename = Path(file_path).name
                except Exception:
                    display.print_str("Usage: load <file>\n")
                    continue
            else:
                filename = " ".join(parts[1:]).strip('"').strip("'")
            exec_z80(_asm_load_file(filename))

        elif cmd == "run":
            if len(parts) > 1:
                filename = " ".join(parts[1:]).strip('"').strip("'")
                exec_z80(_asm_run_file(filename))
            else:
                if not CMD_RUN:
                    display.print_str("CMD_RUN.BIN not found.\n")
                else:
                    exec_z80(CMD_RUN)

        elif cmd in ("ink", "paper", "border", "flash", "bright"):
            cmd_map = {
                "ink":    ("CMD_INK.BIN",    CMD_INK),
                "paper":  ("CMD_PAPER.BIN",  CMD_PAPER),
                "border": ("CMD_BORDER.BIN", CMD_BORDER),
                "flash":  ("CMD_FLASH.BIN",  CMD_FLASH),
                "bright": ("CMD_BRIGHT.BIN", CMD_BRIGHT),
            }
            bin_name, bin_data = cmd_map[cmd]
            if not bin_data:
                display.print_str(f"{bin_name} not found.\n")
            elif len(parts) < 2:
                if cmd in ("flash", "bright"):
                    display.print_str(f"Usage: {cmd} <0|1>\n")
                else:
                    display.print_str(f"Usage: {cmd} <0-63>\n")
            else:
                try:
                    val = int(parts[1])
                except ValueError:
                    display.print_str("Invalid number.\n")
                    display.render()
                    continue
                if cmd in ("flash", "bright"):
                    if val not in (0, 1):
                        display.print_str(f"{cmd}: 0 or 1\n")
                        display.render()
                        continue
                else:
                    if not (0 <= val <= 63):
                        display.print_str(f"{cmd}: 0-63\n")
                        display.render()
                        continue
                # Write parameter into syscall buffer, then
                # execute the command binary
                emulator.mem[Z80yPicoEmulator.SYSCALL_BUFFER] = val & 0xFF
                exec_z80(bin_data)

        elif cmd == "palette":
            if not CMD_PALETTE:
                display.print_str("CMD_PALETTE.BIN not found.\n")
            else:
                exec_z80(CMD_PALETTE)

        elif cmd == "basic":
            # Try native Z80 BIN first, then fall back to Python
            # The BASIC interpreter is ROM-resident at 0x0100,
            # leaving 0x8000+ free for BASIC program storage.
            BASIC_ROM_ADDR = 0x0100
            bin_path = None
            for try_path in [
                Path(__file__).resolve().parent / "z80ypico_basic.bin",
                current_dir / "z80ypico_basic.bin",
                Path("z80ypico_basic.bin"),
            ]:
                if try_path.exists():
                    bin_path = try_path
                    break
            if bin_path:
                try:
                    nbytes = emulator.load_binary(
                        str(bin_path), address=BASIC_ROM_ADDR)
                    emulator.shell_mode = False
                    display.clear_screen()
                    display.render()
                    # BASIC is an interactive loop — needs very high step limit
                    emulator.run_from(
                        address=BASIC_ROM_ADDR,
                        max_steps=1_000_000_000)
                except NotImplementedError as exc:
                    display.print_str(f"\nStopped: {exc}\n")
                except Exception as exc:
                    display.print_str(f"\nError: {exc}\n")
            elif basic is not None:
                basic.enter()
            else:
                display.print_str("BASIC not available.\n")
                display.print_str("Place z80ypico_basic.bin\n")
                display.print_str("or z80ypico_basic.py\n")
                display.print_str("in script directory.\n")

        else:
            display.print_str(f"Unknown: {parts[0]}\n")
            display.print_str("Type 'help'.\n")

        display.render()


# ╔════════════════════════════════════════════════════════════════════════╗
# ║ WORKFLOW STARTUP — integrated entry points                              ║
# ║                                                                          ║
# ║ The emulator can act as a self-sufficient launcher for the integrated   ║
# ║ EDITOR+BASIC workflow without needing Run_BRIDGE_01.py beside it.       ║
# ║                                                                          ║
# ║ These helpers are pure orchestration:                                   ║
# ║   * find_bin    — locate a .bin in standard places                      ║
# ║   * load_into   — copy a .bin into emulator memory at a given address   ║
# ║   * boot_workflow    — auto-load the three workflow BINs and run from   ║
# ║                        0xCC00                                            ║
# ║   * boot_single_bin  — load one .bin at the address parsed from its     ║
# ║                        sibling .asm `org` directive (test mode)         ║
# ║                                                                          ║
# ║ NONE of these helpers inspect editor source, parse BASIC, or decide     ║
# ║ LIST/RUN/RENUM behaviour. All such semantics remain owned by ASM        ║
# ║ (z80ypico_basic.asm and EDITOR_BASIC_WORKFLOW_01.asm).                  ║
# ╚════════════════════════════════════════════════════════════════════════╝


# Authoritative workflow BIN names and load addresses.
WORKFLOW_BASIC_BIN = "z80ypico_basic.bin"
WORKFLOW_EDITOR_BIN = "FW_TEXTEDITOR_NOWRAP_24_SUPR.bin"
WORKFLOW_BRIDGE_BIN = "EDITOR_BASIC_WORKFLOW_01.bin"

WORKFLOW_BASIC_ADDR = 0x0100
WORKFLOW_EDITOR_ADDR = 0x6000
WORKFLOW_BRIDGE_ADDR = 0xCC00

# Authoritative ranges from z80ypico_rom_map.md (used by single-bin mode
# to print a friendly classification of the load address).
_USER_START = 0x8000
_USER_END = 0xFFFF
_FW_PUTCHAR = 0x7C80
_FW_PRINT = 0x7C90
_FW_CLS = 0x7E00
_FW_GETKEY = 0x7E90
_FW_INPUTLINE = 0x7EA0
_CMD_WINDOW_START = 0x7D00
_CMD_WINDOW_END = 0x7DFF

_ORG_RE = re.compile(r"^\s*org\s+(?:0x|\$)?([0-9A-Fa-f]+)h?\b", re.IGNORECASE)


def find_bin(name: str, here: Path | None = None) -> Path:
    """Locate a .bin file in the emulator folder, the cwd, or by direct path.

    Raises FileNotFoundError with all attempted paths if not found.
    """
    if here is None:
        here = Path(__file__).resolve().parent
    candidates = (here / name, Path.cwd() / name, Path(name))
    for c in candidates:
        if c.exists() and c.is_file():
            return c
    raise FileNotFoundError(
        f"Required binary '{name}' not found.\n"
        f"Looked in:\n"
        f"  {here / name}\n"
        f"  {Path.cwd() / name}\n"
        f"  {Path(name).resolve()}"
    )


def load_into(emulator: "Z80yPicoEmulator", path: Path, address: int) -> int:
    """Copy a binary file into emulator memory at the given address.

    Returns the number of bytes loaded. Raises ValueError if the load
    would overflow the 64 KiB address space.
    """
    data = path.read_bytes()
    end = address + len(data)
    if end > 0x10000:
        raise ValueError(
            f"{path.name}: {len(data)} bytes at 0x{address:04X} would "
            f"overflow at 0x{end - 1:04X}"
        )
    emulator.mem[address:end] = data
    return len(data)


def _build_emulator(legacy_firmware_fallback: bool = False
                    ) -> "tuple[Z80yPicoEmulator, Z80yPicoDisplay]":
    """Common setup: palette + display + emulator + decode table + BIOS.

    If legacy_firmware_fallback is True, missing FW_*.bin files will
    be substituted with in-Python fabricated bytes (each clearly
    labelled "[legacy]" in the boot diagnostics). Default is the
    strict policy: missing FW_*.bin causes install_bios() to fail.
    """
    palette = load_palette()
    display = Z80yPicoDisplay(palette)
    emulator = Z80yPicoEmulator(display)
    emulator.firmware_legacy_fallback = legacy_firmware_fallback
    emulator.decode_table = load_decode_table()
    emulator._build_dispatch_table()
    # reset() internally calls install_bios(), so we don't call it
    # again here. (run_from() will defensively call install_bios()
    # one more time at execution start, but that's outside this
    # function's scope.)
    emulator.reset()
    return emulator, display


def boot_workflow(legacy_firmware_fallback: bool = False) -> None:
    """Auto-load the three workflow BINs and start at 0xCC00.

    This is the integrated entry point that replaces Run_BRIDGE_01.py.
    All BASIC / editor / LIST / RUN / RENUM semantics live in the ASM
    binaries; this routine only performs file loading and execution.
    """
    print("=== Z80yPico Editor+BASIC Workflow ===")

    here = Path(__file__).resolve().parent
    basic_path = find_bin(WORKFLOW_BASIC_BIN, here)
    editor_path = find_bin(WORKFLOW_EDITOR_BIN, here)
    bridge_path = find_bin(WORKFLOW_BRIDGE_BIN, here)

    print(f"BASIC    bin  : {basic_path}")
    print(f"Editor   bin  : {editor_path}")
    print(f"Workflow bin  : {bridge_path}")

    emulator, _display = _build_emulator(legacy_firmware_fallback=legacy_firmware_fallback)

    n_basic = load_into(emulator, basic_path, WORKFLOW_BASIC_ADDR)
    n_editor = load_into(emulator, editor_path, WORKFLOW_EDITOR_ADDR)
    n_bridge = load_into(emulator, bridge_path, WORKFLOW_BRIDGE_ADDR)

    print(f"Loaded BASIC    : {n_basic} bytes at 0x{WORKFLOW_BASIC_ADDR:04X}")
    print(f"Loaded Editor   : {n_editor} bytes at 0x{WORKFLOW_EDITOR_ADDR:04X}")
    print(f"Loaded Workflow : {n_bridge} bytes at 0x{WORKFLOW_BRIDGE_ADDR:04X}")
    print(f"Running from 0x{WORKFLOW_BRIDGE_ADDR:04X}")

    emulator.run_from(address=WORKFLOW_BRIDGE_ADDR, max_steps=1_000_000_000)


def _classify_address(addr: int) -> str:
    if _USER_START <= addr <= _USER_END:
        return "user program area"
    if _CMD_WINDOW_START <= addr <= _CMD_WINDOW_END:
        return "CMD execution window"
    if addr == _FW_PUTCHAR:
        return "firmware slot: FW_PUTCHAR"
    if addr == _FW_PRINT:
        return "firmware slot: FW_PRINT"
    if addr == _FW_CLS:
        return "firmware slot: FW_CLS"
    if addr == _FW_GETKEY:
        return "firmware slot: FW_GETKEY"
    if addr == _FW_INPUTLINE:
        return "firmware slot: FW_INPUTLINE trampoline"
    if 0x0000 <= addr <= 0x7FFF:
        return "ROM / reserved / firmware-adjacent region"
    return "unknown region"


def _parse_org_from_asm(asm_path: Path) -> int:
    if not asm_path.exists() or not asm_path.is_file():
        raise FileNotFoundError(
            f"Sibling ASM not found for BIN: {asm_path}\n"
            "The runner refuses to guess the load address."
        )
    for line in asm_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = _ORG_RE.match(line)
        if m:
            return int(m.group(1), 16)
    raise ValueError(
        f"No `org` directive found in {asm_path}.\n"
        "The runner refuses to guess the load address."
    )


def boot_single_bin(bin_path: Path | None = None,
                    legacy_firmware_fallback: bool = False) -> None:
    """Load a single .bin and run it at the address from its sibling .asm.

    If `bin_path` is None, prompt the user interactively.
    """
    print("=== Z80yPico Single-BIN Test Runner ===")

    if bin_path is None:
        while True:
            raw = input("Full path to test BIN: ").strip().strip('"').strip("'")
            if not raw:
                print("Please enter a full path to a .bin file.")
                continue
            p = Path(raw).expanduser()
            if not p.exists():
                print(f"File not found: {p}")
                continue
            if not p.is_file():
                print(f"Not a file: {p}")
                continue
            bin_path = p
            break

    asm_path = bin_path.with_suffix(".asm")
    addr = _parse_org_from_asm(asm_path)
    region = _classify_address(addr)

    print(f"BIN file      : {bin_path}")
    print(f"ASM sibling   : {asm_path}")
    print(f"Load address  : 0x{addr:04X}")
    print(f"ROM map class : {region}")

    emulator, _display = _build_emulator(
        legacy_firmware_fallback=legacy_firmware_fallback
    )
    n = load_into(emulator, bin_path, addr)
    print(f"Loaded {n} bytes at 0x{addr:04X}")
    print(f"Running from 0x{addr:04X}")
    emulator.run_from(address=addr)


def main():
    """Mode selector.

    Default (no arguments) → workflow mode (auto-load the three BINs
    and run from 0xCC00).

    Flags:
      --shell             Launch the legacy Z80yPico interactive shell.
      --test [PATH]       Single-BIN test runner. Optional PATH; if
                          omitted, prompt for one.
      --legacy-firmware   Use Python-fabricated firmware bytes when a
                          FW_*.bin is missing, instead of failing.
                          Combinable with the other modes; clearly
                          marked as legacy/transitional.
      --help / -h         Print usage and exit.
    """
    args = sys.argv[1:]

    if args and args[0] in ("-h", "--help"):
        print("Usage:")
        print("  python Z80yPicoPartialEmulator60.py")
        print("      Boot the integrated EDITOR+BASIC workflow (default).")
        print("  python Z80yPicoPartialEmulator60.py --shell")
        print("      Boot the legacy interactive shell.")
        print("  python Z80yPicoPartialEmulator60.py --test [PATH]")
        print("      Run a single BIN at the address from its sibling ASM.")
        print("  Add --legacy-firmware to any mode above to allow")
        print("      Python-fabricated firmware as a fallback for missing")
        print("      FW_*.bin files (transitional, clearly diagnosed).")
        print("  python Z80yPicoPartialEmulator60.py --help")
        print("      Show this help.")
        return

    # Pull --legacy-firmware out of argv; it's a global flag combinable
    # with any of the mode flags below.
    legacy_firmware = "--legacy-firmware" in args
    args = [a for a in args if a != "--legacy-firmware"]

    try:
        if not args:
            boot_workflow(legacy_firmware_fallback=legacy_firmware)
            return

        if args[0] == "--shell":
            if legacy_firmware:
                # --shell uses _main_shell which builds its own emulator
                # before exposing a setting hook. We respect the flag by
                # patching the class-level default so any emulator built
                # later reads it.
                Z80yPicoEmulator._default_legacy_firmware = True
            _main_shell()
            return

        if args[0] == "--test":
            path = Path(args[1]).expanduser() if len(args) > 1 else None
            boot_single_bin(path, legacy_firmware_fallback=legacy_firmware)
            return

        # Unknown argument → fall through with a friendly message.
        print(f"Unknown argument: {args[0]!r}")
        print("Run with --help for usage.")
        sys.exit(2)

    except KeyboardInterrupt:
        print("\nCancelled by user.")
    except Exception as exc:
        print(f"\nERROR: {exc}")
        try:
            input("Press Enter to exit...")
        except EOFError:
            pass
        raise


if __name__ == "__main__":
    main()
