; =============================================================================
; EDITOR_BASIC_WORKFLOW_01.asm — milestone EDITOR_BASIC_WORKFLOW_04
; =============================================================================
; Z80yPico — persistent EDIT/LIST/RUN/RENUM environment.
;
; Property under test (WORKFLOW_04):
;   * The editor recognises a third inline command, "renum", in
;     addition to "list" and "run". Recognition is case-insensitive
;     and space-trimmed; "renum", "RENUM", " renum ", "ReNuM" all
;     trigger the same action.
;   * RENUM walks the BASIC program in stored order and rewrites its
;     line numbers to 10, 20, 30, ... preserving the order of lines.
;     This is implemented entirely in ASM (CMD_RENUM in BASIC,
;     exposed via JP slot 0x0118).
;   * After renumbering, the editor source is rebuilt in place from
;     the renumbered program using the same canonical pipeline as
;     LIST. The user sees the renumbered listing immediately and
;     remains in the editor.
;   * If the program is empty, RENUM shows a clear message, waits for
;     a key, and returns to the editor without crashing.
;
; Renumbering level (LEVEL 1, but semantically complete here):
;   This BASIC dialect does not expose any line-number-targeted
;   control-flow construct: there is no GOTO, no GOSUB, no THEN-
;   line-number, no RETURN. Loops are structured (FOR/NEXT,
;   WHILE/WEND, REPEAT/UNTIL, LOOP/ENDLOOP/BREAK). Therefore Level 1
;   (rewriting only the stored line numbers) is also Level 2 in
;   effect: there are no inter-line references that could become
;   stale. We do NOT scan statements for numeric jump targets,
;   because none exist. This is documented honestly here, not faked.
;
; Inherited contract (WORKFLOW_03B):
;   * STORE_LINE preserves the user's bytes verbatim (no TO_UPPER).
;   * PRINT_NORMALIZED uppercases keywords ONLY; variables and
;     string-literal contents are preserved verbatim. RENUM goes
;     through the same PRINT_NORMALIZED path, so the renumbered
;     listing follows that same case rule.
;
; Inherited contract (WORKFLOW_03):
;   * STORE_LINE atomically deletes-then-inserts when given an
;     already-existing line number, so RENUM cannot create
;     duplicates. After RENUM the program is guaranteed to have
;     exactly one entry per (new) line number, in ascending order.
;   * DELETE_LINE is a clean no-op when the line number does not
;     exist.
;
; Inherited from WORKFLOW_02 (with WF06 polish):
;   * LIST canonicalises into editor LINES[] via CMD_LIST_RAW
;     (BASIC slot 0x0115) plus an OUT_CHAR_TARG redirect.
;   * RUN: clear "run" line, CLS, execute, wait for key, then run
;     the same canonical rebuild pipeline as LIST. The editor view
;     on return is therefore canonical (keywords upper, variables
;     and strings preserved) and always in sync with BASIC program
;     storage. This supersedes the older WORKFLOW_03B contract that
;     said "RUN never canonicalises"; the polish milestone changed
;     this deliberately so the editor never shows a stale source.
;   * ENTER_HOOK at 0xD61D so the editor is content-aware on every
;     ENTER press without redesigning the editor itself.
;
; Memory placement: ORG 0xCC00. Out of all BASIC and editor RAM zones.
; =============================================================================

                ORG     0xCC00

; ── Editor entry table ─────────────────────────────────────────────────────

EDITOR_ENTRY    EQU     0x6000
EDITOR_REDRAW   EQU     0x6003
EDITOR_GOTO     EQU     0x6006
EDITOR_GETLA    EQU     0x6009

; ── Editor RAM ─────────────────────────────────────────────────────────────

LINES           EQU     0xD300
CURLINE         EQU     0xD618
CURCOL          EQU     0xD619
NUMLINES        EQU     0xD61A
ENTER_HOOK      EQU     0xD61D
LINESZ          EQU     33
LINEMAX         EQU     32              ; chars per line (LINESZ-1 for null)
MAXLINES        EQU     24

; ── BASIC entry table ──────────────────────────────────────────────────────

BASIC_NEW       EQU     0x0103
BASIC_STORE     EQU     0x0106
BASIC_RUN       EQU     0x0109
BASIC_DELETE    EQU     0x010C
BASIC_RESET     EQU     0x010F
BASIC_LIST      EQU     0x0112
BASIC_LIST_RAW  EQU     0x0115
BASIC_RENUM     EQU     0x0118
BASIC_LOAD      EQU     0x011B  ; HL=ptr to argument string
BASIC_SAVE      EQU     0x011E  ; HL=ptr to argument string
BASIC_WD        EQU     0x0121  ; HL=ptr to argument string (may be empty)
BASIC_PWD       EQU     0x0124  ; no arguments
BASIC_GET_LOAD_TYPE EQU 0x0127  ; returns A=0 (text), 1 (bin), 0xFF (error)

; Where .bin payloads land (BIN_LOAD_ADDR in BASIC). When the user
; types `load "x.bin"` from the editor, we jump here to run it.
BIN_LOAD_ADDR   EQU     0xC400

; BASIC's program storage start. Used by WF_DO_RENUM to detect an
; empty program (first two bytes == 0xFF 0xFF).
PROG_BASE       EQU     0x8300

; BASIC's output vector for CMD_LIST_RAW / PRINT_NORMALIZED (3 bytes,
; an executable JP). Default content (set by BASIC_INIT) is "JP
; FW_PUTCHAR"; we overwrite it before calling CMD_LIST_RAW and restore
; it (to JP FW_PUTCHAR) afterwards.
OUT_CHAR_TARG   EQU     0x8200 + 54     ; SCRATCH+54

; ── Firmware ───────────────────────────────────────────────────────────────

FW_PUTCHAR      EQU     0x7C80
FW_PRINT        EQU     0x7C90
FW_CLS          EQU     0x7E00
FW_GETKEY       EQU     0x7E90

CTRL_PORT       EQU     2

; ── Bridge RAM (small scratch area inside bridge image) ────────────────────
; A pointer used by WF_BUF_PUT — the next byte slot in the editor line
; currently being constructed. Lives at end of bridge code; see WF_END.

; ═════════════════════════════════════════════════════════════════════════════
; ENTRY
; ═════════════════════════════════════════════════════════════════════════════

WF_ENTRY:
                LD      SP, 0xFEFF
                CALL    BASIC_RESET

                ; Install ENTER_HOOK before launching the editor.
                LD      A, 0xC3
                LD      (ENTER_HOOK), A
                LD      HL, WF_ON_ENTER
                LD      A, L
                LD      (ENTER_HOOK+1), A
                LD      A, H
                LD      (ENTER_HOOK+2), A

                ; Fall through to the boot/restart entry.

; ═════════════════════════════════════════════════════════════════════════════
; WF_BOOT_RESTART — show boot screen, wait for key, run the editor.
;
; This is the single common entry used by:
;   * initial startup (fall-through from WF_ENTRY)
;   * RESET command (JP here from WF_DO_RESET)
;
; Architectural rule: the boot screen lives in this ASM bridge, not
; in Python. Python only orchestrates which mode boots; the visible
; presentation belongs to the workflow itself.
;
; SP is reset every time we land here, because RESET arrives via JP
; (not RET) from inside the editor's call chain — that chain's return
; addresses must be discarded.
; ═════════════════════════════════════════════════════════════════════════════

WF_BOOT_RESTART:
                LD      SP, 0xFEFF              ; discard editor stack on RESET path

                ; Boot screen.
                CALL    FW_CLS
                LD      HL, MSG_WELCOME
                CALL    FW_PRINT
                CALL    FW_GETKEY

                ; Run the editor. ESC exits the workspace.
                CALL    EDITOR_ENTRY

                ; Editor exited (ESC).
                CALL    FW_CLS
                LD      HL, MSG_GOODBYE
                CALL    FW_PRINT
                CALL    FW_GETKEY

                XOR     A
                OUT     (CTRL_PORT), A
WF_SPIN:
                JR      WF_SPIN

; ═════════════════════════════════════════════════════════════════════════════
; WF_ON_ENTER — content-aware dispatch on every editor ENTER press
;
; In:  LINES[CURLINE] holds the just-edited line text.
; Out: A = 0 (normal split), 1 (clear line), or 2 (keep line).
; ═════════════════════════════════════════════════════════════════════════════

WF_ON_ENTER:
                LD      A, (CURLINE)
                CALL    EDITOR_GETLA            ; HL = LINES[CURLINE]
                CALL    SKIP_SPACES_HL
                LD      A, (HL)
                OR      A
                JR      Z, WF_BLANK_JP          ; blank → normal split

                ; Numbered?
                LD      A, (HL)
                CP      '0'
                JR      C, WF_NOTNUM
                CP      '9'+1
                JR      NC, WF_NOTNUM
                JP      WF_DO_BASIC
WF_BLANK_JP:
                JP      WF_RET0

WF_NOTNUM:
                ; "list"?
                PUSH    HL
                LD      DE, CMD_LIST_KW
                CALL    MATCH_CMD
                JR      NZ, WF_NOTLIST
                POP     HL
                JP      WF_DO_LIST
WF_NOTLIST:
                POP     HL
                ; "run"?
                PUSH    HL
                LD      DE, CMD_RUN_KW
                CALL    MATCH_CMD
                JR      NZ, WF_NOTRUN
                POP     HL
                JP      WF_DO_RUN
WF_NOTRUN:
                POP     HL
                ; "renum"?
                PUSH    HL
                LD      DE, CMD_RENUM_KW
                CALL    MATCH_CMD
                JR      NZ, WF_NOTRENUM
                POP     HL
                JP      WF_DO_RENUM
WF_NOTRENUM:
                POP     HL
                ; "cls"?
                PUSH    HL
                LD      DE, CMD_CLS_KW
                CALL    MATCH_CMD
                JR      NZ, WF_NOTCLS
                POP     HL
                JP      WF_DO_CLS
WF_NOTCLS:
                POP     HL
                ; "new"?
                PUSH    HL
                LD      DE, CMD_NEW_KW
                CALL    MATCH_CMD
                JR      NZ, WF_NOTNEW
                POP     HL
                JP      WF_DO_NEW
WF_NOTNEW:
                POP     HL
                ; "reset"?
                PUSH    HL
                LD      DE, CMD_RESET_KW
                CALL    MATCH_CMD
                JR      NZ, WF_NOTRESET
                POP     HL
                JP      WF_DO_RESET
WF_NOTRESET:
                POP     HL
                ; "load ..."?
                PUSH    HL
                LD      DE, CMD_LOAD_KW
                CALL    MATCH_CMD_PREFIX
                JR      NZ, WF_NOTLOAD
                ; HL is now past "load", at the argument tail.
                ; Discard the saved start (we want HL at the tail).
                INC     SP
                INC     SP
                JP      WF_DO_LOAD
WF_NOTLOAD:
                POP     HL
                ; "save ..."?
                PUSH    HL
                LD      DE, CMD_SAVE_KW
                CALL    MATCH_CMD_PREFIX
                JR      NZ, WF_NOTSAVE
                INC     SP
                INC     SP
                JP      WF_DO_SAVE
WF_NOTSAVE:
                POP     HL
                ; "wd" or "wd \"path\""?
                PUSH    HL
                LD      DE, CMD_WD_KW
                CALL    MATCH_CMD_PREFIX
                JR      NZ, WF_NOTWD
                INC     SP
                INC     SP
                JP      WF_DO_WD
WF_NOTWD:
                POP     HL
                ; "pwd"?
                PUSH    HL
                LD      DE, CMD_PWD_KW
                CALL    MATCH_CMD
                JR      NZ, WF_NOTPWD
                POP     HL
                JP      WF_DO_PWD
WF_NOTPWD:
                POP     HL
                JP      WF_DO_BAD

WF_RET0:
                XOR     A
                RET
WF_RET1:
                LD      A, 1
                RET
WF_RET2:
                LD      A, 2
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_BASIC — numbered BASIC source line dispatch
;
;   Called when the editor's ENTER_HOOK has identified that the line
;   the user just committed begins with a decimal digit.  This routine
;   chooses between two well-defined ASM-resident BASIC operations and
;   delegates the actual storage mutation to BASIC:
;
;     * "20"            (digits only, no statement)
;            → CALL BASIC_DELETE  (deletes line 20 if present; clean
;                                  no-op otherwise)
;            → return A=1 so the editor wipes the literal "20" the
;              user typed (it would otherwise appear as a ghost line
;              in the document)
;
;     * "20 PRINT \"X\""    (digits + statement)
;            → CALL BASIC_STORE   (insert ordered, OR replace if line
;                                  20 already existed — STORE_LINE
;                                  itself does the delete-then-insert)
;            → return A=0 so the editor performs its normal split
;              (cursor advances to next physical row)
;
;   The decision is taken purely in Z80 code (this routine). No host
;   layer is involved. The actual program-memory mutation is performed
;   in BASIC's STORE_LINE / DELETE_LINE — the canonical owners of
;   numbered-line semantics.
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_BASIC:
                CALL    PARSE_DECIMAL           ; DE = line#, HL past digits
                PUSH    DE
                CALL    SKIP_SPACES_HL
                LD      A, (HL)
                OR      A
                JR      Z, WF_BASIC_DEL
                POP     DE
                CALL    BASIC_STORE
                XOR     A
                RET
WF_BASIC_DEL:
                POP     DE
                CALL    BASIC_DELETE
                LD      A, 1
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_LIST — canonicalise the editor source IN PLACE
;
;   1. Save current OUT_CHAR_TARG (although it's always JP FW_PUTCHAR
;      at this point because BASIC_INIT set it that way and nothing
;      between resets it; we restore the default explicitly anyway).
;   2. Install OUT_CHAR_TARG = JP WF_BUF_PUT.
;   3. Initialise BUF_LINE_IDX = 0, BUF_COL_IDX = 0.
;      Pre-clear LINES[0..MAXLINES-1] to empty (single 0x00 each).
;   4. CALL CMD_LIST_RAW.
;   5. Restore OUT_CHAR_TARG to JP FW_PUTCHAR.
;   6. Compute new NUMLINES = max(BUF_LINE_IDX, 1).
;   7. Place cursor on the line BELOW the last listed line (or stay on
;      line 0 if program is empty), col 0.
;   8. Redraw editor.
;   9. Return A=1 so the editor wipes the literal "list" line.
;
; Special case: if the program is empty, CMD_LIST_RAW emits only the
; 0x00 sentinel and BUF_LINE_IDX stays at 0. We then leave the editor
; with one empty physical line (NUMLINES = 1, CURLINE = 0).
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_LIST:
                ; LIST is a thin wrapper around the canonical
                ; "rebuild editor LINES[] from current BASIC program"
                ; pipeline. CMD_LIST_RAW is what feeds character
                ; output into our buffer-put routine, with
                ; PRINT_NORMALIZED applying keyword-only
                ; canonicalisation.
                CALL    WF_REBUILD_FROM_BASIC
                LD      A, 1                    ; clear "list" line
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_RENUM — handle the "renum" command (WORKFLOW_04)
;
;   1. If the program is empty (PROG_BASE starts with 0xFF 0xFF) print
;      a clear message, wait a key, redraw editor, return A=2 (keep
;      the line so the user can correct or delete it).
;   2. Otherwise: CALL BASIC_RENUM. The BASIC routine walks PROG_BASE
;      forward and rewrites each stored line number to 10, 20, 30 ...
;      preserving order. It does NOT touch references inside
;      statements — but this BASIC dialect has no GOTO, GOSUB, or
;      THEN-line-number, so there are no references to rewrite, which
;      means LEVEL 1 is semantically complete here.
;   3. After renumbering, run the same canonical rebuild pipeline as
;      LIST so the editor view becomes the renumbered listing in
;      place. Return A=1 (clear the literal "renum" the user typed).
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_RENUM:
                ; Check for empty program: PROG_BASE = [0xFF, 0xFF]?
                LD      A, (PROG_BASE)
                CP      0xFF
                JR      NZ, WFR_NONEMPTY
                LD      A, (PROG_BASE+1)
                CP      0xFF
                JR      NZ, WFR_NONEMPTY
                ; Empty program — show message, wait, return.
                CALL    FW_CLS
                LD      HL, MSG_RENUM_EMPTY
                CALL    FW_PRINT
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    FW_CLS
                CALL    EDITOR_REDRAW
                CALL    EDITOR_GOTO
                LD      A, 2                    ; keep "renum" line
                RET
WFR_NONEMPTY:
                ; Renumber in place inside BASIC's program storage.
                CALL    BASIC_RENUM
                ; Reuse the LIST canonicalisation pipeline.
                CALL    WF_REBUILD_FROM_BASIC
                LD      A, 1                    ; clear "renum" line
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_CLS — handle "cls" typed as a command in the editor
;
;   Per user spec: simply clear the screen, wait for a key, then
;   return to the editor. The editor will redraw itself, so the
;   user sees a momentary blank screen. The "cls" line itself is
;   cleared from LINES[] (return A=1).
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_CLS:
                CALL    FW_CLS
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    FW_CLS
                CALL    EDITOR_REDRAW
                CALL    EDITOR_GOTO
                LD      A, 1                    ; clear "cls" line
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_NEW — handle "new" typed as a command in the editor
;
;   Per user spec: NEW wipes the program from BASIC's program storage
;   and leaves the editor window blank.
;
;   Implementation: call BASIC_NEW (which writes 0xFF 0xFF at
;   PROG_BASE = empty-program marker) and then call the standard
;   rebuild-from-BASIC pipeline. With an empty program, that pipeline
;   leaves LINES[] cleared, NUMLINES=1, CURLINE=0, CURCOL=0, and
;   redraws the screen. Net effect: blank editor.
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_NEW:
                CALL    BASIC_NEW               ; PROG_BASE = 0xFF 0xFF
                CALL    WF_REBUILD_FROM_BASIC   ; LINES[]=empty, redraw
                LD      A, 1                    ; clear "new" line
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_RESET — handle "reset" typed as a command in the editor
;
;   Per user spec: RESET returns the system to its initial state and
;   shows the boot screen again, waiting for a key before re-entering
;   the workspace.
;
;   Implementation strategy:
;     1. BASIC_RESET re-initialises the BASIC interpreter state
;        (variables, loops, RUN flag, etc.).
;     2. BASIC_NEW wipes the program from PROG_BASE.
;     3. WF_REBUILD_FROM_BASIC clears LINES[] and editor counters.
;     4. JP WF_BOOT_RESTART — we cannot RET because RESET is invoked
;        from deep inside the editor's call chain (FW_INPUTLINE →
;        editor → ENTER_HOOK → WF_ON_ENTER → here). The boot-restart
;        path resets SP to 0xFEFF, so all those return addresses are
;        cleanly discarded.
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_RESET:
                CALL    BASIC_RESET             ; reset BASIC interpreter state
                CALL    BASIC_NEW               ; wipe program
                CALL    WF_REBUILD_FROM_BASIC   ; clear editor LINES[]
                JP      WF_BOOT_RESTART         ; → boot screen, wait, editor

; ═════════════════════════════════════════════════════════════════════════════
; WF_REBUILD_FROM_BASIC — common pipeline used by LIST and RENUM
;
;   Pre-clears all 24 editor lines, installs WF_BUF_PUT as
;   OUT_CHAR_TARG, calls CMD_LIST_RAW, restores OUT_CHAR_TARG, sets
;   NUMLINES / CURLINE / CURCOL, and repaints the editor screen.
;
;   This is the single owner of the editor-source-from-BASIC
;   rebuild path. WF_DO_LIST and WF_DO_RENUM both end here.
; ═════════════════════════════════════════════════════════════════════════════

WF_REBUILD_FROM_BASIC:
                ; Pre-clear all 24 editor lines.
                LD      B, MAXLINES
                LD      C, 0
WFR_CLR:
                PUSH    BC
                LD      A, C
                CALL    EDITOR_GETLA
                LD      (HL), 0
                POP     BC
                INC     C
                DJNZ    WFR_CLR

                ; Initialise capture state.
                XOR     A
                LD      (BUF_LINE_IDX), A
                LD      (BUF_COL_IDX), A

                ; Install OUT_CHAR_TARG = JP WF_BUF_PUT.
                LD      A, 0xC3
                LD      (OUT_CHAR_TARG), A
                LD      HL, WF_BUF_PUT
                LD      A, L
                LD      (OUT_CHAR_TARG+1), A
                LD      A, H
                LD      (OUT_CHAR_TARG+2), A

                ; Capture the listing.
                CALL    BASIC_LIST_RAW

                ; Restore OUT_CHAR_TARG = JP FW_PUTCHAR.
                LD      A, 0xC3
                LD      (OUT_CHAR_TARG), A
                LD      HL, FW_PUTCHAR
                LD      A, L
                LD      (OUT_CHAR_TARG+1), A
                LD      A, H
                LD      (OUT_CHAR_TARG+2), A

                ; Update NUMLINES / CURLINE / CURCOL.
                LD      A, (BUF_LINE_IDX)
                OR      A
                JR      NZ, WFR_NONEMPTY2
                LD      A, 1
                LD      (NUMLINES), A
                XOR     A
                LD      (CURLINE), A
                LD      (CURCOL), A
                JR      WFR_REDRAW
WFR_NONEMPTY2:
                LD      B, A                    ; B = listed-lines count
                INC     A
                CP      MAXLINES+1
                JR      C, WFR_NL_OK
                LD      A, MAXLINES
WFR_NL_OK:
                LD      (NUMLINES), A
                LD      A, B
                CP      MAXLINES
                JR      C, WFR_CUR_OK
                LD      A, MAXLINES-1
WFR_CUR_OK:
                LD      (CURLINE), A
                XOR     A
                LD      (CURCOL), A

WFR_REDRAW:
                CALL    FW_CLS
                CALL    EDITOR_REDRAW
                CALL    EDITOR_GOTO
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_BUF_PUT — character writer used while CMD_LIST_RAW is running
;
;   In:  A = character to deliver
;   Side effects on bridge state: BUF_LINE_IDX, BUF_COL_IDX, LINES[].
;
;   * 0x0D (CR)   → null-terminate current line, advance line index.
;   * 0x00 (NUL)  → end-of-listing sentinel; ignore (we already
;                   stopped writing if we're past MAXLINES).
;   * 0x0A (LF)   → ignored (CMD_LIST_RAW does not emit LF; defensive).
;   * Any other   → append at LINES[BUF_LINE_IDX][BUF_COL_IDX] if there
;                   is room (BUF_COL_IDX < LINEMAX) and we have not yet
;                   exceeded MAXLINES. Cap silently otherwise.
; ═════════════════════════════════════════════════════════════════════════════

WF_BUF_PUT:
                PUSH    AF
                PUSH    BC
                PUSH    DE
                PUSH    HL

                ; Stop accepting if we've already filled the document.
                LD      B, A                    ; save char in B
                LD      A, (BUF_LINE_IDX)
                CP      MAXLINES
                JR      NC, WBP_DONE            ; line index >= MAXLINES → drop

                LD      A, B                    ; recover char
                CP      0x0A
                JR      Z, WBP_DONE             ; ignore LF
                CP      0x00
                JR      Z, WBP_DONE             ; ignore NUL sentinel
                CP      0x0D
                JR      Z, WBP_EOL              ; CR ends current line

                ; Printable: store at LINES[BUF_LINE_IDX][BUF_COL_IDX]
                ; if BUF_COL_IDX < LINEMAX.
                LD      A, (BUF_COL_IDX)
                CP      LINEMAX
                JR      NC, WBP_DONE            ; col already at cap → drop

                ; Compute target address in LINES[].
                LD      C, A                    ; C = column
                LD      A, (BUF_LINE_IDX)
                CALL    EDITOR_GETLA            ; HL = LINES[BUF_LINE_IDX]
                LD      D, 0
                LD      E, C
                ADD     HL, DE                  ; HL = LINES[N] + col
                LD      A, B                    ; recover char
                LD      (HL), A
                INC     HL
                LD      (HL), 0                 ; ensure null after current
                ; Advance column.
                LD      A, (BUF_COL_IDX)
                INC     A
                LD      (BUF_COL_IDX), A
                JR      WBP_DONE

WBP_EOL:
                ; CR: null-terminate current line and advance to next.
                LD      A, (BUF_LINE_IDX)
                CALL    EDITOR_GETLA
                LD      A, (BUF_COL_IDX)
                LD      C, A
                LD      D, 0
                LD      E, C
                ADD     HL, DE
                LD      (HL), 0                 ; defensive null
                ; Move to next line.
                LD      A, (BUF_LINE_IDX)
                INC     A
                LD      (BUF_LINE_IDX), A
                XOR     A
                LD      (BUF_COL_IDX), A

WBP_DONE:
                POP     HL
                POP     DE
                POP     BC
                POP     AF
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_RUN — unchanged from WORKFLOW_01
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_RUN:
                ; Clear the "run" text from LINES[CURLINE] BEFORE we
                ; leave the editor for execution. This way the user
                ; sees the line go blank as RUN starts, and on return
                ; the editor never has to repaint "run" at all.
                LD      A, (CURLINE)
                CALL    EDITOR_GETLA            ; HL = LINES[CURLINE]
                LD      (HL), 0                 ; null-terminate at col 0
                CALL    BASIC_RUN
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                ; On return from execution, run the same canonical
                ; pipeline as LIST so the editor view is rebuilt from
                ; the actual BASIC program storage. This guarantees
                ; the editor is always in sync with what the
                ; interpreter would execute next, and it covers any
                ; program-storage changes that ran inside the program
                ; (e.g. self-modifying code, future LOAD/SAVE inside
                ; the program). The pre-clear above is still useful
                ; for the empty-program case, where WF_REBUILD_FROM_BASIC
                ; leaves a single empty line and we want CURLINE clean.
                CALL    WF_REBUILD_FROM_BASIC
                LD      A, 1
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_BAD — unrecognised non-blank line
; ═════════════════════════════════════════════════════════════════════════════

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_LOAD — handle "load <arg>" command (WORKFLOW_06 polish)
;
;   In:  HL = pointer into the editor line, just past the keyword
;             "load" (so HL points at the leading space or quote of
;             the filename).
;   The argument string is fed to BASIC's CMD_LOAD via the
;   CMD_LOAD_HL JP-table wrapper. CMD_LOAD parses the filename,
;   detects the extension (.bas / .txt / .bin), and either reads a
;   numbered-line text into PROG_BASE or loads a raw .bin at 0xC400.
;   On return we read GET_LOAD_TYPE:
;     A=0    → text source loaded; rebuild the editor view from the
;              now-populated PROG_BASE (same path as LIST).
;     A=1    → raw .bin loaded at 0xC400; CALL it directly so the
;              user gets execution semantics (as if they had typed
;              `run` after a binary load). On return, leave the
;              editor LINES[] untouched: the .bin is foreign code,
;              not BASIC source.
;     A=0xFF → CMD_LOAD already printed an error message; we simply
;              wait for a key and rebuild the editor from PROG_BASE
;              (which still holds whatever it held before the LOAD,
;              so nothing is lost).
;   In every case we clear the "load ..." line in the editor before
;   leaving for the action so the user does not see it lingering.
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_LOAD:
                ; Pre-clear the "load ..." line so the user never sees
                ; it on screen while CMD_LOAD prints its messages.
                PUSH    HL
                LD      A, (CURLINE)
                CALL    EDITOR_GETLA            ; HL = LINES[CURLINE]
                LD      (HL), 0
                POP     HL
                ; Hand off to BASIC. HL still points at the argument.
                CALL    FW_CLS
                CALL    BASIC_LOAD              ; CMD_LOAD_HL wrapper
                ; Inspect outcome.
                CALL    BASIC_GET_LOAD_TYPE     ; A = LOAD_TYPE
                CP      0x01
                JR      Z, WFL_BIN
                ; A = 0 (text) or 0xFF (error). Either way: pause,
                ; then rebuild editor view.
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    WF_REBUILD_FROM_BASIC
                LD      A, 1
                RET
WFL_BIN:
                ; Raw .bin loaded at 0xC400. Run it directly.
                CALL    BIN_LOAD_ADDR
                ; Wait for key, then return to editor without touching
                ; LINES[] — the editor must keep whatever the user had
                ; (which is empty after the pre-clear in this case).
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    FW_CLS
                CALL    EDITOR_REDRAW
                CALL    EDITOR_GOTO
                LD      A, 1
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_SAVE — handle "save <arg>" command
;
;   In:  HL = pointer into the editor line, just past "save".
;   Calls BASIC's CMD_SAVE via the CMD_SAVE_HL wrapper. CMD_SAVE
;   writes the current program as a .bas text file. We do not touch
;   PROG_BASE so the editor view stays the same; we just clear the
;   "save ..." line for tidiness and rebuild. (Rebuild here is
;   conservative: it canonicalises the editor into the same form
;   that LIST would produce — keeping the editor in sync with what
;   was just saved.)
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_SAVE:
                ; Pre-clear the "save ..." line.
                PUSH    HL
                LD      A, (CURLINE)
                CALL    EDITOR_GETLA
                LD      (HL), 0
                POP     HL
                CALL    FW_CLS
                CALL    BASIC_SAVE              ; CMD_SAVE_HL wrapper
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    WF_REBUILD_FROM_BASIC
                LD      A, 1
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_WD — handle "wd" / "wd \"path\"" command
;
;   In:  HL = pointer just past "wd" (may be empty, may have quoted
;             path). Forwarded to BASIC's CMD_WD via CMD_WD_HL.
;   CMD_WD with empty arg opens a Tk directory picker via the host
;   (SYS_CHDIR with empty string). With a quoted path it tries to
;   chdir directly. Either way, the new CWD is printed on success.
;   We pause for a key, then return to the editor preserving the
;   user's source (no rebuild — chdir does not affect the program).
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_WD:
                ; Pre-clear the "wd ..." line.
                PUSH    HL
                LD      A, (CURLINE)
                CALL    EDITOR_GETLA
                LD      (HL), 0
                POP     HL
                CALL    FW_CLS
                CALL    BASIC_WD                ; CMD_WD_HL wrapper
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    FW_CLS
                CALL    EDITOR_REDRAW
                CALL    EDITOR_GOTO
                LD      A, 1
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_PWD — handle "pwd" command
;
;   No arguments. CMD_PWD prints the current working directory.
;   Long paths wrap automatically because the display puts each char
;   through put_char(), which advances the next row when col reaches
;   the screen width. We simply clear the "pwd" line and pause.
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_PWD:
                LD      A, (CURLINE)
                CALL    EDITOR_GETLA
                LD      (HL), 0
                CALL    FW_CLS
                CALL    BASIC_PWD               ; CMD_PWD_ENTRY wrapper
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    FW_CLS
                CALL    EDITOR_REDRAW
                CALL    EDITOR_GOTO
                LD      A, 1
                RET

; ═════════════════════════════════════════════════════════════════════════════
; WF_DO_BAD — unrecognised non-blank line
; ═════════════════════════════════════════════════════════════════════════════

WF_DO_BAD:
                CALL    FW_CLS
                LD      HL, MSG_BAD_LINE
                CALL    FW_PRINT
                LD      HL, MSG_PRESS_RETURN
                CALL    FW_PRINT
                CALL    FW_GETKEY
                CALL    FW_CLS
                CALL    EDITOR_REDRAW
                CALL    EDITOR_GOTO
                LD      A, 2
                RET

; ═════════════════════════════════════════════════════════════════════════════
; SKIP_SPACES_HL / PARSE_DECIMAL / MATCH_CMD / UPCASE — unchanged utilities
; ═════════════════════════════════════════════════════════════════════════════

SKIP_SPACES_HL:
                LD      A, (HL)
                CP      ' '
                RET     NZ
                INC     HL
                JR      SKIP_SPACES_HL

PARSE_DECIMAL:
                LD      DE, 0
PD_LOOP:
                LD      A, (HL)
                CP      '0'
                RET     C
                CP      '9'+1
                RET     NC
                PUSH    HL
                LD      H, D
                LD      L, E
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, DE
                ADD     HL, HL
                SUB     '0'
                LD      E, A
                LD      D, 0
                ADD     HL, DE
                EX      DE, HL
                POP     HL
                INC     HL
                JR      PD_LOOP

MATCH_CMD:
                PUSH    HL
                PUSH    DE
MC_LOOP:
                LD      A, (DE)
                OR      A
                JR      Z, MC_KW_END
                LD      B, A
                LD      A, (HL)
                CALL    UPCASE
                CP      B
                JR      NZ, MC_FAIL
                INC     HL
                INC     DE
                JR      MC_LOOP
MC_KW_END:
                LD      A, (HL)
                OR      A
                JR      Z, MC_OK
                CP      ' '
                JR      NZ, MC_FAIL
                INC     HL
                JR      MC_KW_END
MC_OK:
                POP     DE
                POP     HL
                XOR     A
                RET
MC_FAIL:
                POP     DE
                POP     HL
                OR      0xFF
                RET

; ── MATCH_CMD_PREFIX ────────────────────────────────────────────────────────
; Like MATCH_CMD but allows trailing content after the keyword. Returns:
;   Z=1 (A=0)  → keyword matched. HL has been advanced PAST the
;                keyword (so the caller can read the argument tail
;                directly from HL).
;   Z=0 (A=FF) → no match; HL and DE restored to their entry values.
; The keyword must be terminated by a space, a quote, or NUL — same
; word-boundary discipline as MATCH_CMD, so "loaded" cannot match
; "load".
MATCH_CMD_PREFIX:
                PUSH    DE              ; preserve DE for both paths
                PUSH    HL              ; saved start (in case of fail)
MCP_LOOP:
                LD      A, (DE)
                OR      A
                JR      Z, MCP_KWEND
                LD      B, A
                LD      A, (HL)
                CALL    UPCASE
                CP      B
                JR      NZ, MCP_FAIL
                INC     HL
                INC     DE
                JR      MCP_LOOP
MCP_KWEND:
                ; HL is on the byte AFTER the keyword.
                LD      A, (HL)
                OR      A
                JR      Z, MCP_OK
                CP      ' '
                JR      Z, MCP_OK
                CP      '"'
                JR      Z, MCP_OK
                JR      MCP_FAIL
MCP_OK:
                ; Discard the saved start: we want the advanced HL.
                INC     SP
                INC     SP
                POP     DE
                XOR     A
                RET
MCP_FAIL:
                POP     HL              ; restore start
                POP     DE
                OR      0xFF
                RET

UPCASE:
                CP      'a'
                RET     C
                CP      'z'+1
                RET     NC
                SUB     'a'-'A'
                RET

; ═════════════════════════════════════════════════════════════════════════════
; STRINGS
; ═════════════════════════════════════════════════════════════════════════════

CMD_LIST_KW:    DB      "LIST", 0
CMD_RUN_KW:     DB      "RUN", 0
CMD_RENUM_KW:   DB      "RENUM", 0
CMD_CLS_KW:     DB      "CLS", 0
CMD_NEW_KW:     DB      "NEW", 0
CMD_RESET_KW:   DB      "RESET", 0
CMD_LOAD_KW:    DB      "LOAD", 0
CMD_SAVE_KW:    DB      "SAVE", 0
CMD_WD_KW:      DB      "WD", 0
CMD_PWD_KW:     DB      "PWD", 0

MSG_WELCOME:
                DB      "Z80yPico Emulator Demo", 13, 10
                DB      13, 10
                DB      "By Raul Santos Quiros 2026", 13, 10
                DB      13, 10
                DB      "Press any key to start.", 0

MSG_GOODBYE:
                DB      "Workspace closed.", 13, 10, 13, 10
                DB      "Press any key to exit.", 0

MSG_PRESS_RETURN:
                DB      13, 10
                DB      "Press any key to return to editor.", 0

MSG_BAD_LINE:
                DB      "Error: not a numbered BASIC line", 13, 10
                DB      "and not a known command.", 13, 10
                DB      0

MSG_RENUM_EMPTY:
                DB      "RENUM: program is empty.", 13, 10
                DB      "Nothing to renumber.", 13, 10
                DB      0

; ═════════════════════════════════════════════════════════════════════════════
; Bridge RAM (in-image scratch — these labels point at bytes inside the
; assembled binary that we treat as mutable state at runtime).
; ═════════════════════════════════════════════════════════════════════════════

BUF_LINE_IDX:   DB      0
BUF_COL_IDX:    DB      0

WF_END:
