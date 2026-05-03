; =====================================================================
; Z80yPico BASIC Interpreter — Z80 Assembly Source
; Version 1.2 — ROM-resident, z80asm compatible
;
; Assemble:  z80asm -b z80ypico_basic.asm
; Output:    z80ypico_basic.bin  (load at 0x0100 in ROM space)
;
; Target: Z80yPico — 32 KB ROM (expandable to 256 KB)
;
; The interpreter lives in ROM space (0x0100-0x2FFF) alongside the
; existing firmware.  The user program area (0x8000+) is used for
; BASIC program storage, variables, loop stack, and scratch — giving
; BASIC programs the full upper 32 KB of RAM.
;
; Firmware API used:
;   FW_PUTCHAR   = 0x7C80  (A = character)
;   FW_PRINT     = 0x7C90  (HL = null-terminated string)
;   FW_CLS       = 0x7E00
;   FW_GETKEY    = 0x7E90
;   FW_INPUTLINE = 0x7EA0  (result at 0x7F00)
;
; Memory Map:
;   0x0000-0x0002  BIOS reset vector
;   0x0100-0x2FFF  BASIC interpreter code (ROM, ~12 KB max)
;   0x7C80-0x7EFF  Firmware routines (ROM)
;   0x7F00-0x7FFF  Syscall buffer / input line buffer
;   0x8000-0x80FF  Variable storage (26 vars A-Z, 16-bit signed)
;   0x8100-0x81FF  Loop stack (8 entries x 32 bytes)
;   0x8200-0x82FF  Scratch/temp workspace
;   0x8300-0xBFFF  Program storage (~15 KB)
;   0xC000-0xFFFF  Free / stack descends from 0xFFFF
;
; =====================================================================

; Constants

FW_PUTCHAR      EQU     0x7C80
FW_PRINT        EQU     0x7C90
FW_CLS          EQU     0x7E00
FW_GETKEY       EQU     0x7E90
FW_INPUTLINE    EQU     0x7EA0

SYSCALL_BUFFER  EQU     0x7F00
CTRL_PORT       EQU     2

; Syscall command codes (written to SYSCALL_BUFFER[0], triggered via OUT)
SYS_FILE_OPEN   EQU     0x10    ; open file for line-by-line read
SYS_FILE_NEXT   EQU     0x11    ; read next line from open file
SYS_FILE_CLOSE  EQU     0x12    ; close open file
SYS_FILE_WOPEN  EQU     0x13    ; open file for writing
SYS_FILE_WLINE  EQU     0x14    ; write a line to open file
SYS_FILE_WCLOSE EQU     0x15    ; close write file
SYS_BIN_LOAD    EQU     0x16    ; load binary file into RAM
SYS_CHDIR       EQU     0x17    ; change working directory
SYS_GETCWD      EQU     0x18    ; get current working directory
SYS_DIR_FIRST   EQU     0x19    ; begin directory iteration (first .bas/.bin)
SYS_DIR_NEXT    EQU     0x1A    ; next filename in directory iteration

; Syscall result codes (returned in SYSCALL_BUFFER[0] after OUT)
SYS_OK          EQU     0x00
SYS_ERR         EQU     0xFF

; Binary load destination
BIN_LOAD_ADDR   EQU     0xC400  ; .bin files load here (after string vars)

; RENUM old→new mapping table. Built by CMD_RENUM in pass A,
; consumed during pass B (remap of GOTO targets), then discarded.
; This area is free at RENUM time because nothing else uses it
; outside of LOAD .bin, and you can't RENUM while LOAD .bin is
; running. Each entry is 4 bytes: old_hi, old_lo, new_hi, new_lo.
; Terminator: a single 0xFF in the high byte of an entry's old.
RENUM_MAP       EQU     0xC400
RENUM_MAP_SIZE  EQU     1024            ; up to 256 lines mapped

VAR_BASE        EQU     0x8000
SVAR_BASE       EQU     0xC000  ; String variable storage (26 x 32 bytes)
SVAR_ENTRY_SIZE EQU     32      ; Max 31 chars + null per string var
LOOP_STACK      EQU     0x8100
LOOP_ENTRY_SIZE EQU     32
MAX_LOOPS       EQU     8
SCRATCH         EQU     0x8200
PROG_BASE       EQU     0x8300
PROG_END        EQU     0xBFFF
INPUT_BUF       EQU     0x7F00

; VRAM memory-mapped display grid (read-only from Z80)
VRAM_BASE       EQU     0xD000  ; 768 bytes: 24 rows x 32 cols
VRAM_COLS       EQU     32
VRAM_ROWS       EQU     24

; I/O ports for cursor position readback
PORT_CUR_ROW    EQU     5       ; IN A,(5) = current cursor row (0..23)
PORT_CUR_COL    EQU     6       ; IN A,(6) = current cursor col (0..31)

; LIST-region state (in SCRATCH area)
; Set by CMD_LIST, cleared by any other command/action.
; FW_SCREEN_EDIT only allows navigation within this region.
LIST_ACTIVE     EQU     SCRATCH+50      ; 0 = no valid list region, 1 = valid
LIST_TOP_ROW    EQU     SCRATCH+51      ; first row of LIST output (after CLS)
LIST_BOT_ROW    EQU     SCRATCH+52      ; last row of LIST output
NAV_ROW         EQU     SCRATCH+53      ; current navigation row
OUT_CHAR_TARG   EQU     SCRATCH+54      ; 3 bytes: JP <addr>
SAVE_BUF_PTR    EQU     SCRATCH+57      ; 2 bytes: write pointer used
                                        ; by SAVE_WRITER to feed each
                                        ; canonicalised byte from
                                        ; PRINT_NORMALIZED into the
                                        ; line-output buffer.

; Output redirection vector for LIST. Three bytes (an executable JP).
; Used by PRINT_NORMALIZED and by CMD_LIST_RAW so an external workflow
; can capture LIST output into a buffer instead of the console.
; Default: JP FW_PUTCHAR  (transparent, identical to legacy behaviour).
; OUT_CHAR_TARG and SAVE_BUF_PTR are declared in the SCRATCH map above.

LOOP_FOR        EQU     1
LOOP_WHILE      EQU     2
LOOP_REPEAT     EQU     3
LOOP_LOOP       EQU     4

                ORG     0x0100

; ─────────────────────────────────────────────────────────────────
; BRIDGE CALL TABLE — fixed entry points for external integration.
;
; Fourteen 3-byte JP slots (42 bytes total) starting at 0x0100.
; Used by EDITOR_BASIC_BRIDGE_01.asm and the workflow milestone files
; to drive the BASIC interpreter from outside without depending on
; internal label addresses.
;
; Slot 0 (0x0100) preserves original boot semantics: jumping to
; 0x0100 still enters the interactive REPL exactly as before.
;
;   0x0100  JP BASIC_ENTRY_REAL  — legacy boot / interactive REPL
;   0x0103  JP NEW_PROGRAM       — clear program storage
;   0x0106  JP STORE_LINE        — DE=line#, HL=text → store/replace
;   0x0109  JP CMD_RUN           — execute current program
;   0x010C  JP DELETE_LINE       — DE=line# → delete that line
;   0x010F  JP BASIC_INIT        — full BASIC state reset
;   0x0112  JP CMD_LIST          — list current program (uppercase
;                                  keywords via PRINT_NORMALIZED)
;   0x0115  JP CMD_LIST_RAW      — list without CLS / cursor tracking
;   0x0118  JP CMD_RENUM         — renumber program: line numbers
;                                  become 10, 20, 30, ...
;   0x011B  JP CMD_LOAD_HL       — HL = pointer to string after the
;                                  LOAD keyword (e.g. ' "x.bas"').
;                                  Issues the load via SYS_FILE_*.
;                                  See LOAD_TYPE for outcome.
;   0x011E  JP CMD_SAVE_HL       — HL = pointer to string after SAVE
;                                  (e.g. ' "x.bas"'). Writes the
;                                  current program to disk.
;   0x0121  JP CMD_WD_HL         — HL = pointer to string after WD
;                                  (may be empty → directory picker).
;                                  Calls SYS_CHDIR via Python host.
;   0x0124  JP CMD_PWD_ENTRY     — print current working directory.
;   0x0127  JP GET_LOAD_TYPE     — A = LOAD_TYPE byte (0=text, 1=bin,
;                                  0xFF=error). Used by the bridge to
;                                  decide what to do after CMD_LOAD.
; ─────────────────────────────────────────────────────────────────

BASIC_ENTRY:
                JP      BASIC_ENTRY_REAL
                JP      NEW_PROGRAM
                JP      STORE_LINE
                JP      CMD_RUN
                JP      DELETE_LINE
                JP      BASIC_INIT
                JP      CMD_LIST
                JP      CMD_LIST_RAW
                JP      CMD_RENUM
                JP      CMD_LOAD_HL
                JP      CMD_SAVE_HL
                JP      CMD_WD_HL
                JP      CMD_PWD_ENTRY
                JP      GET_LOAD_TYPE

; Wrappers: each accepts HL = pointer to the argument string and
; calls the original CMD_* via STMT_PTR. The bridge can therefore
; pass a pointer into editor LINES[] (or into IOBUF) directly.

CMD_LOAD_HL:
                LD      (STMT_PTR), HL
                CALL    CMD_LOAD
                RET

CMD_SAVE_HL:
                LD      (STMT_PTR), HL
                CALL    CMD_SAVE
                RET

CMD_WD_HL:
                LD      (STMT_PTR), HL
                CALL    CMD_WD
                RET

CMD_PWD_ENTRY:
                CALL    CMD_PWD
                RET

GET_LOAD_TYPE:
                LD      A, (LOAD_TYPE)
                RET

BASIC_ENTRY_REAL:
                CALL    BASIC_INIT
                LD      HL, MSG_READY
                CALL    FW_PRINT

BASIC_MAIN:
                CALL    FW_SCREEN_EDIT
                LD      HL, INPUT_BUF
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                JR      Z, BASIC_MAIN
                CALL    IS_DIGIT
                JR      C, BM_STORE
                CALL    EXEC_IMMEDIATE
                JR      BASIC_MAIN

BM_STORE:
                CALL    PARSE_NUMBER
                PUSH    DE
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                JR      Z, BM_DELETE
                POP     DE
                XOR     A
                LD      (LIST_ACTIVE), A        ; line edit invalidates LIST region
                CALL    STORE_LINE
                JR      BASIC_MAIN

BM_DELETE:
                POP     DE
                XOR     A
                LD      (LIST_ACTIVE), A        ; line deletion invalidates LIST region
                CALL    DELETE_LINE
                JR      BASIC_MAIN

BASIC_INIT:
                LD      HL, VAR_BASE
                LD      B, 52
BI_CLR:
                LD      (HL), 0
                INC     HL
                DJNZ    BI_CLR
                CALL    CLEAR_SVAR_ALL
                CALL    CLEAR_LOOP_STACK
                CALL    NEW_PROGRAM
                XOR     A
                LD      (LIST_ACTIVE), A        ; no valid LIST region at start
                ; Initialise OUT_CHAR_TARG to "JP FW_PUTCHAR" so any
                ; PRINT_NORMALIZED / CMD_LIST_RAW call defaults to the
                ; legacy console output path.
                LD      A, 0xC3                 ; opcode JP
                LD      (OUT_CHAR_TARG), A
                LD      HL, FW_PUTCHAR
                LD      A, L
                LD      (OUT_CHAR_TARG+1), A
                LD      A, H
                LD      (OUT_CHAR_TARG+2), A
                RET

NEW_PROGRAM:
                LD      HL, PROG_BASE
                LD      (HL), 0xFF
                INC     HL
                LD      (HL), 0xFF
                RET

CLEAR_LOOP_STACK:
                LD      HL, LOOP_STACK
                LD      B, 0
CLS_CLR:
                LD      (HL), 0
                INC     HL
                DJNZ    CLS_CLR
                XOR     A
                LD      (LOOP_SP), A
                RET

EXEC_IMMEDIATE:
                ; Invalidate LIST region — CMD_LIST will re-set it if needed
                XOR     A
                LD      (LIST_ACTIVE), A
                PUSH    HL
                LD      HL, KW_EXIT
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_EXIT
                POP     HL
                LD      A, 0
                OUT     (CTRL_PORT), A
                RET
EI_NOT_EXIT:
                LD      HL, KW_RUN
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_RUN
                POP     HL
                CALL    CMD_RUN
                RET
EI_NOT_RUN:
                LD      HL, KW_LIST
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_LIST
                POP     HL
                CALL    CMD_LIST
                RET
EI_NOT_LIST:
                LD      HL, KW_NEW
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_NEW
                POP     HL
                CALL    NEW_PROGRAM
                CALL    BASIC_INIT
                LD      HL, MSG_READY
                CALL    FW_PRINT
                RET
EI_NOT_NEW:
                LD      HL, KW_CLS
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_CLS
                POP     HL
                CALL    FW_CLS
                RET
EI_NOT_CLS:
                LD      HL, KW_RENUM
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_RENUM
                POP     HL
                CALL    CMD_RENUM
                RET
EI_NOT_RENUM:
                LD      HL, KW_LOAD
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH_PREFIX
                JR      NZ, EI_NOT_LOAD
                POP     HL
                CALL    SKIP_KW_LOAD
                CALL    CMD_LOAD
                RET
EI_NOT_LOAD:
                LD      HL, KW_SAVE
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH_PREFIX
                JR      NZ, EI_NOT_SAVE
                POP     HL
                CALL    SKIP_KW_SAVE
                CALL    CMD_SAVE
                RET
EI_NOT_SAVE:
                LD      HL, KW_WD
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH_PREFIX
                JR      NZ, EI_NOT_WD
                POP     HL
                CALL    SKIP_KW_WD
                CALL    CMD_WD
                RET
EI_NOT_WD:
                LD      HL, KW_PWD
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_PWD
                POP     HL
                CALL    CMD_PWD
                RET
EI_NOT_PWD:
                LD      HL, KW_DIR
                POP     DE
                PUSH    DE
                CALL    KEYWORD_MATCH
                JR      NZ, EI_NOT_DIR
                POP     HL
                CALL    CMD_DIR
                RET
EI_NOT_DIR:
                POP     HL
                XOR     A
                LD      (EXEC_MODE), A
                CALL    EXEC_STATEMENT
                RET

CMD_RUN:
                CALL    FW_CLS
                CALL    CLEAR_LOOP_STACK
                CALL    CLEAR_SVAR_ALL
                LD      HL, VAR_BASE
                LD      B, 52
CR_CLR:
                LD      (HL), 0
                INC     HL
                DJNZ    CR_CLR
                LD      HL, PROG_BASE
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (EXEC_MODE), A
CR_LOOP:
                LD      HL, (EXEC_PTR)
                LD      A, (HL)
                CP      0xFF
                JR      NZ, CR_NOT_END
                LD      E, A
                INC     HL
                LD      A, (HL)
                CP      0xFF
                JR      Z, CR_DONE
                DEC     HL
                LD      A, E
CR_NOT_END:
                LD      D, (HL)
                INC     HL
                LD      E, (HL)
                INC     HL
                LD      (CURRENT_LINE), DE
                LD      A, (HL)
                INC     HL
                LD      B, A
                LD      (STMT_PTR), HL
                CALL    EXEC_LINE_STMTS
                LD      A, (RUN_FLAG)
                OR      A
                JR      Z, CR_DONE
                LD      A, (PC_CHANGED)
                OR      A
                JR      NZ, CR_PC_CHG
                LD      HL, (EXEC_PTR)
                LD      D, (HL)
                INC     HL
                LD      E, (HL)
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      E, A
                LD      D, 0
                ADD     HL, DE
                INC     HL
                LD      (EXEC_PTR), HL
                JR      CR_LOOP
CR_PC_CHG:
                XOR     A
                LD      (PC_CHANGED), A
                JR      CR_LOOP
CR_DONE:
                XOR     A
                LD      (EXEC_MODE), A
                LD      (RUN_FLAG), A
                LD      HL, MSG_READY
                CALL    FW_PRINT
                RET

EXEC_LINE_STMTS:
                LD      A, 1
                LD      (RUN_FLAG), A
                XOR     A
                LD      (PC_CHANGED), A
ELS_NEXT:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                RET     Z
                CALL    EXEC_STATEMENT
                LD      A, (RUN_FLAG)
                OR      A
                RET     Z
                LD      A, (PC_CHANGED)
                OR      A
                RET     NZ
                LD      HL, (STMT_PTR)
ELS_COLON:
                LD      A, (HL)
                OR      A
                RET     Z
                CP      ':'
                JR      Z, ELS_FOUND
                CP      '"'
                JR      NZ, ELS_NOTSTR
                INC     HL
ELS_SKIPSTR:
                LD      A, (HL)
                OR      A
                RET     Z
                CP      '"'
                JR      Z, ELS_ENDSTR
                INC     HL
                JR      ELS_SKIPSTR
ELS_ENDSTR:
                INC     HL
                JR      ELS_COLON
ELS_NOTSTR:
                INC     HL
                JR      ELS_COLON
ELS_FOUND:
                INC     HL
                LD      (STMT_PTR), HL
                JR      ELS_NEXT

EXEC_STATEMENT:
                CALL    SKIP_SPACES
                LD      (STMT_PTR), HL
                LD      A, (HL)
                OR      A
                RET     Z
                LD      DE, KW_PRINT
                CALL    TRY_KEYWORD
                JR      NZ, ES_NP
                CALL    STMT_PRINT
                RET
ES_NP:
                LD      DE, KW_INPUT
                CALL    TRY_KEYWORD
                JR      NZ, ES_NI
                CALL    STMT_INPUT
                RET
ES_NI:
                LD      DE, KW_IF
                CALL    TRY_KEYWORD
                JR      NZ, ES_NIF
                CALL    STMT_IF
                RET
ES_NIF:
                LD      DE, KW_LET
                CALL    TRY_KEYWORD
                JR      NZ, ES_NL
                CALL    STMT_LET
                RET
ES_NL:
                LD      DE, KW_FOR
                CALL    TRY_KEYWORD
                JR      NZ, ES_NFR
                CALL    STMT_FOR
                RET
ES_NFR:
                LD      DE, KW_NEXT
                CALL    TRY_KEYWORD
                JR      NZ, ES_NNX
                CALL    STMT_NEXT
                RET
ES_NNX:
                LD      DE, KW_WHILE
                CALL    TRY_KEYWORD
                JR      NZ, ES_NWH
                CALL    STMT_WHILE
                RET
ES_NWH:
                LD      DE, KW_WEND
                CALL    TRY_KEYWORD
                JR      NZ, ES_NWD
                CALL    STMT_WEND
                RET
ES_NWD:
                LD      DE, KW_REPEAT
                CALL    TRY_KEYWORD
                JR      NZ, ES_NRP
                CALL    STMT_REPEAT
                RET
ES_NRP:
                LD      DE, KW_UNTIL
                CALL    TRY_KEYWORD
                JR      NZ, ES_NUT
                CALL    STMT_UNTIL
                RET
ES_NUT:
                LD      DE, KW_LOOP_KW
                CALL    TRY_KEYWORD
                JR      NZ, ES_NLP
                CALL    STMT_LOOP
                RET
ES_NLP:
                LD      DE, KW_ENDLOOP
                CALL    TRY_KEYWORD
                JR      NZ, ES_NEL
                CALL    STMT_ENDLOOP
                RET
ES_NEL:
                LD      DE, KW_BREAK
                CALL    TRY_KEYWORD
                JR      NZ, ES_NBK
                CALL    STMT_BREAK
                RET
ES_NBK:
                LD      DE, KW_GOTO
                CALL    TRY_KEYWORD
                JR      NZ, ES_NGO
                CALL    STMT_GOTO
                RET
ES_NGO:
                LD      DE, KW_STOP
                CALL    TRY_KEYWORD
                JR      NZ, ES_NST
                ; STOP statement reached. Print:
                ;   <CR><LF>Program stopped at line N
                ; where N is the BASIC line number currently
                ; executing (CURRENT_LINE). Then halt the interpreter
                ; by clearing RUN_FLAG. The message goes through
                ; FW_PUTCHAR / FW_PRINT, so it appears on the RUN
                ; screen alongside any program output.
                PUSH    HL                  ; preserve STMT_PTR's HL
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                LD      HL, MSG_STOPPED
                CALL    FW_PRINT
                LD      DE, (CURRENT_LINE)
                CALL    PRINT_UINT16
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                POP     HL
                XOR     A
                LD      (RUN_FLAG), A
                RET
ES_NST:
                LD      DE, KW_REM
                CALL    TRY_KEYWORD
                JR      NZ, ES_NRM
                LD      HL, (STMT_PTR)
ES_SKIPRM:
                LD      A, (HL)
                OR      A
                JR      Z, ES_RMDONE
                INC     HL
                JR      ES_SKIPRM
ES_RMDONE:
                LD      (STMT_PTR), HL
                RET
ES_NRM:
                LD      DE, KW_CLS
                CALL    TRY_KEYWORD
                JR      NZ, ES_NCLS
                CALL    FW_CLS
                RET
ES_NCLS:
                LD      HL, (STMT_PTR)
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'A'
                JR      C, ES_SYNERR
                CP      'Z'+1
                JR      NC, ES_SYNERR
                PUSH    HL
                INC     HL
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '='
                POP     HL
                JR      NZ, ES_SYNERR
                CALL    STMT_LET
                RET
ES_SYNERR:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

STMT_PRINT:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                JR      Z, SP_BARE
                CP      ':'
                JR      Z, SP_BARE
SP_ITEMS:
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                JR      Z, SP_ENDNL
                CP      ':'
                JR      Z, SP_ENDNL
                CP      '"'
                JR      Z, SP_STR
                CP      ';'
                JR      Z, SP_SEMI
                CP      ','
                JR      Z, SP_COMMA
                CALL    EVAL_EXPR
                CALL    PRINT_INT16
                LD      (STMT_PTR), HL
                JR      SP_ITEMS
SP_STR:
                INC     HL
SP_SLOOP:
                LD      A, (HL)
                OR      A
                JR      Z, SP_SEND
                CP      '"'
                JR      Z, SP_SCLOSE
                CALL    FW_PUTCHAR
                INC     HL
                JR      SP_SLOOP
SP_SCLOSE:
                INC     HL
SP_SEND:
                LD      (STMT_PTR), HL
                JR      SP_ITEMS
SP_SEMI:
                INC     HL
                LD      (STMT_PTR), HL
                ; Check if semicolon is at end (suppress newline)
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                JR      Z, SP_DONE
                CP      ':'
                JR      Z, SP_DONE
                JR      SP_ITEMS
SP_COMMA:
                INC     HL
                LD      (STMT_PTR), HL
                LD      A, ' '
                CALL    FW_PUTCHAR
                JR      SP_ITEMS
SP_BARE:
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                LD      (STMT_PTR), HL
                RET
SP_ENDNL:
                ; Print trailing CR+LF after content
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
SP_DONE:
                LD      (STMT_PTR), HL
                RET

STMT_INPUT:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                XOR     A
                LD      (SCRATCH+16), A     ; 0 = no custom prompt
                LD      A, (HL)
                CP      '"'
                JR      NZ, SI_NOPR
                LD      A, 1
                LD      (SCRATCH+16), A     ; 1 = custom prompt given
                INC     HL
SI_PLOOP:
                LD      A, (HL)
                OR      A
                JR      Z, SI_PDONE
                CP      '"'
                JR      Z, SI_PCLS
                CALL    FW_PUTCHAR
                INC     HL
                JR      SI_PLOOP
SI_PCLS:
                INC     HL
SI_PDONE:
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      ';'
                JR      NZ, SI_NOPR
                INC     HL
                CALL    SKIP_SPACES
SI_NOPR:
                ; Read variable letter
                LD      A, (HL)
                CALL    TO_UPPER
                SUB     'A'
                LD      (SCRATCH), A
                INC     HL
                ; Check for '$' — string variable
                LD      A, (HL)
                CP      '$'
                JR      NZ, SI_NUMERIC
                ; ── String variable input ──
                INC     HL              ; skip '$'
                LD      (STMT_PTR), HL
                ; Print '? ' only if no custom prompt
                LD      A, (SCRATCH+16)
                OR      A
                JR      NZ, SI_SNOQ
                LD      A, '?'
                CALL    FW_PUTCHAR
SI_SNOQ:
                LD      A, ' '
                CALL    FW_PUTCHAR
                CALL    FW_INPUTLINE
                ; Copy input to string variable buffer
                LD      A, (SCRATCH)
                CALL    GET_SVAR_ADDR   ; DE = address of string buffer
                LD      HL, INPUT_BUF
                LD      B, 31           ; max 31 chars
SI_SCOPY:
                LD      A, (HL)
                LD      (DE), A
                OR      A
                JR      Z, SI_SDONE
                INC     HL
                INC     DE
                DJNZ    SI_SCOPY
                XOR     A
                LD      (DE), A         ; null terminate if max reached
SI_SDONE:
                RET

SI_NUMERIC:
                ; ── Numeric variable input ──
                LD      (STMT_PTR), HL
                ; Print '? ' only if no custom prompt
                LD      A, (SCRATCH+16)
                OR      A
                JR      NZ, SI_NNOQ
                LD      A, '?'
                CALL    FW_PUTCHAR
SI_NNOQ:
                LD      A, ' '
                CALL    FW_PUTCHAR
                CALL    FW_INPUTLINE
                LD      HL, INPUT_BUF
                CALL    SKIP_SPACES
                CALL    PARSE_SIGNED_NUM
                LD      A, (SCRATCH)
                CALL    SET_VAR
                RET

STMT_LET:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                CALL    TO_UPPER
                SUB     'A'
                LD      (SCRATCH), A
                INC     HL
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '='
                JR      NZ, SL_ERR
                INC     HL
                CALL    EVAL_EXPR
                LD      A, (SCRATCH)
                CALL    SET_VAR
                LD      (STMT_PTR), HL
                RET
SL_ERR:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                RET

STMT_IF:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                ; Evaluate condition
                CALL    EVAL_EXPR           ; DE = condition result, HL past expr
                ; Save condition result
                LD      (SCRATCH+28), DE
                ; Now scan HL forward for "THEN" (case-insensitive)
                ; Simple byte-by-byte scan with inline matching
                CALL    SKIP_SPACES
SIF_SCAN:
                LD      A, (HL)
                OR      A
                JR      Z, SIF_NOTHEN       ; end of line — no THEN found
                ; Check for T-H-E-N followed by non-alpha
                CALL    TO_UPPER
                CP      'T'
                JR      NZ, SIF_ADV
                ; Check H
                INC     HL
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'H'
                JR      NZ, SIF_CONT
                ; Check E
                INC     HL
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'E'
                JR      NZ, SIF_CONT
                ; Check N
                INC     HL
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'N'
                JR      NZ, SIF_CONT
                ; Check word boundary after N
                INC     HL
                LD      A, (HL)
                OR      A
                JR      Z, SIF_GOTHEN       ; THEN at end of line
                CP      ' '
                JR      Z, SIF_GOTHEN       ; THEN followed by space
                CALL    TO_UPPER
                CP      'A'
                JR      C, SIF_GOTHEN       ; non-alpha
                CP      'Z'+1
                JR      NC, SIF_GOTHEN      ; non-alpha
                ; Part of a longer word — not THEN
SIF_CONT:
                ; HL was advanced into the middle of a failed match
                ; Keep scanning from current position
                JR      SIF_SCAN
SIF_ADV:
                INC     HL
                JR      SIF_SCAN

SIF_GOTHEN:
                ; HL is past "THEN", possibly on space or null
                CALL    SKIP_SPACES
                LD      (STMT_PTR), HL
                ; Check condition
                LD      DE, (SCRATCH+28)
                LD      A, D
                OR      E
                JR      NZ, SIF_TRUE
                ; Condition false — skip entire rest of line
                ; so EXEC_LINE_STMTS won't find a ':' and run BREAK etc.
SIF_SKIPREST:
                LD      A, (HL)
                OR      A
                JR      Z, SIF_SKDONE
                INC     HL
                JR      SIF_SKIPREST
SIF_SKDONE:
                LD      (STMT_PTR), HL
                RET
SIF_TRUE:
                ; Condition true — execute the rest
                CALL    EXEC_STATEMENT
                RET

SIF_NOTHEN:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

STMT_FOR:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                CALL    TO_UPPER
                SUB     'A'
                LD      (SCRATCH), A
                INC     HL
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '='
                JP      NZ, SF_SYNERR
                INC     HL
                CALL    EVAL_EXPR
                PUSH    DE
                CALL    SKIP_SPACES
                LD      DE, KW_TO
                CALL    TRY_KW_AT_HL
                JP      NZ, SF_SYNERR2
                CALL    EVAL_EXPR
                PUSH    DE
                CALL    SKIP_SPACES
                LD      DE, KW_STEP
                PUSH    HL
                CALL    TRY_KW_AT_HL
                JR      NZ, SF_NOSTEP
                CALL    EVAL_EXPR
                LD      A, D
                OR      E
                JR      NZ, SF_HAVESTEP
                POP     DE
                POP     DE
                LD      HL, ERR_STEP_ZERO
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET
SF_NOSTEP:
                POP     HL
                POP     DE
                POP     BC
                PUSH    BC
                PUSH    DE
                CALL    SIGNED_CMP_BC_DE
                JR      C, SF_SPOS
                JR      Z, SF_SPOS
                LD      DE, 0xFFFF
                JR      SF_HAVESTEP
SF_SPOS:
                LD      DE, 0x0001
SF_HAVESTEP:
                LD      (SCRATCH+2), DE
                POP     BC
                POP     DE
                LD      A, (SCRATCH)
                CALL    SET_VAR
                CALL    PUSH_LOOP_FOR
                LD      A, (SCRATCH)
                CALL    GET_VAR
                LD      BC, (SCRATCH+4)
                LD      HL, (SCRATCH+2)
                BIT     7, H
                JR      NZ, SF_CNEG
                CALL    SIGNED_CMP_DE_BC
                JR      Z, SF_CONT
                JR      C, SF_CONT
                JR      SF_SKIP
SF_CNEG:
                CALL    SIGNED_CMP_DE_BC
                JR      Z, SF_CONT
                JR      NC, SF_CONT
SF_SKIP:
                CALL    FIND_MATCH_NEXT
                CALL    POP_LOOP
                RET
SF_CONT:
                LD      HL, (STMT_PTR)
                LD      (STMT_PTR), HL
                RET
SF_SYNERR:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                RET
SF_SYNERR2:
                POP     DE
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                RET

STMT_NEXT:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                CALL    TO_UPPER
                SUB     'A'
                LD      B, A
                INC     HL
                LD      (STMT_PTR), HL
                LD      A, (LOOP_SP)
                OR      A
                JP      Z, SN_NOFOR
                CALL    PEEK_LOOP
                LD      A, (IX+0)
                CP      LOOP_FOR
                JP      NZ, SN_NOFOR
                LD      A, (IX+1)
                CP      B
                JP      NZ, SN_MISM
                LD      A, B
                CALL    GET_VAR
                LD      C, (IX+4)
                LD      B, (IX+5)
                EX      DE, HL
                ADD     HL, BC
                EX      DE, HL
                LD      A, (IX+1)
                CALL    SET_VAR
                LD      C, (IX+2)
                LD      B, (IX+3)
                BIT     7, (IX+5)
                JR      NZ, SN_NEGS
                CALL    SIGNED_CMP_DE_BC
                JR      Z, SN_CONT
                JR      C, SN_CONT
                JR      SN_DONE
SN_NEGS:
                CALL    SIGNED_CMP_DE_BC
                JR      Z, SN_CONT
                JR      NC, SN_CONT
SN_DONE:
                CALL    POP_LOOP
                RET
SN_CONT:
                ; ── Check enclosing WHILE before continuing FOR ──
                ; If there is a WHILE frame directly below this FOR on the
                ; loop stack, re-evaluate its condition.  If it has become
                ; false, break out of both FOR and WHILE immediately.
                LD      A, (LOOP_SP)
                CP      2
                JP      C, SN_CONT_GO       ; stack too shallow for outer
                ; Peek at LOOP_SP-2 (frame below the FOR)
                DEC     A
                DEC     A
                LD      L, A
                LD      H, 0
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL              ; index * 32
                LD      DE, LOOP_STACK
                ADD     HL, DE              ; HL = base of outer frame
                LD      A, (HL)
                CP      LOOP_WHILE
                JP      NZ, SN_CONT_GO     ; not a WHILE — skip
                ; Save outer frame base for later
                LD      (SCRATCH+14), HL
                ; Read condition text pointer at offset +8/+9
                LD      DE, 8
                ADD     HL, DE
                LD      E, (HL)
                INC     HL
                LD      D, (HL)             ; DE = condition text address
                EX      DE, HL              ; HL = condition text
                ; Preserve STMT_PTR across eval
                LD      DE, (STMT_PTR)
                PUSH    DE
                CALL    EVAL_EXPR           ; DE = condition result
                POP     BC
                LD      (STMT_PTR), BC
                LD      A, D
                OR      E
                JP      NZ, SN_CONT_GO     ; WHILE still true — continue FOR
                ; ── WHILE condition is false — exit both loops ──
                ; Read the WHILE frame's EXEC_PTR (offset +6/+7)
                LD      HL, (SCRATCH+14)    ; outer frame base
                LD      DE, 6
                ADD     HL, DE
                LD      E, (HL)
                INC     HL
                LD      D, (HL)
                LD      (EXEC_PTR), DE      ; point to WHILE line
                ; Pop FOR (top)
                CALL    POP_LOOP
                ; Pop WHILE (now top)
                CALL    POP_LOOP
                ; Skip execution past the matching WEND
                CALL    FIND_MATCH_WEND
                RET

SN_CONT_GO:
                ; Normal FOR continuation — loop back
                CALL    PEEK_LOOP
                LD      L, (IX+6)
                LD      H, (IX+7)
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
SN_NOFOR:
                LD      HL, ERR_NEXT_NO_FOR
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET
SN_MISM:
                LD      HL, ERR_NEXT_MISMATCH
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

STMT_WHILE:
                LD      HL, (STMT_PTR)
                LD      (SCRATCH+12), HL    ; save condition text pointer
                LD      DE, (EXEC_PTR)
                LD      (SCRATCH+10), DE
                CALL    EVAL_EXPR
                LD      (STMT_PTR), HL
                LD      A, D
                OR      E
                JR      NZ, SW_ENTER
                CALL    FIND_MATCH_WEND
                RET
SW_ENTER:
                CALL    PUSH_LOOP_WHILE
                RET

STMT_WEND:
                LD      A, (LOOP_SP)
                OR      A
                JR      Z, SWEND_ERR
                CALL    PEEK_LOOP
                LD      A, (IX+0)
                CP      LOOP_WHILE
                JR      NZ, SWEND_ERR
                LD      L, (IX+6)
                LD      H, (IX+7)
                LD      (EXEC_PTR), HL
                CALL    POP_LOOP
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
SWEND_ERR:
                LD      HL, ERR_WEND_NO_WHILE
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

STMT_REPEAT:
                CALL    PUSH_LOOP_REPEAT
                RET

STMT_UNTIL:
                LD      A, (LOOP_SP)
                OR      A
                JR      Z, SU_ERR
                CALL    PEEK_LOOP
                LD      A, (IX+0)
                CP      LOOP_REPEAT
                JR      NZ, SU_ERR
                LD      HL, (STMT_PTR)
                CALL    EVAL_EXPR
                LD      (STMT_PTR), HL
                LD      A, D
                OR      E
                JR      NZ, SU_EXIT
                LD      L, (IX+6)
                LD      H, (IX+7)
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
SU_EXIT:
                CALL    POP_LOOP
                RET
SU_ERR:
                LD      HL, ERR_UNTIL_NO_REPEAT
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

STMT_LOOP:
                CALL    PUSH_LOOP_LOOP
                RET

STMT_ENDLOOP:
                LD      A, (LOOP_SP)
                OR      A
                JR      Z, SEL_ERR
                CALL    PEEK_LOOP
                LD      A, (IX+0)
                CP      LOOP_LOOP
                JR      NZ, SEL_ERR
                LD      L, (IX+6)
                LD      H, (IX+7)
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
SEL_ERR:
                LD      HL, ERR_ENDLOOP_NO_LOOP
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

STMT_BREAK:
                LD      A, (LOOP_SP)
                OR      A
                JR      Z, SB_ERR
                CALL    PEEK_LOOP
                LD      A, (IX+0)
                OR      A
                JR      Z, SB_ERR
                LD      L, (IX+10)
                LD      H, (IX+11)
                LD      A, H
                OR      L
                JR      NZ, SB_TOEXIT
                LD      A, (IX+0)
                CP      LOOP_FOR
                JR      Z, SB_FOR
                CP      LOOP_WHILE
                JR      Z, SB_WHILE
                CP      LOOP_REPEAT
                JR      Z, SB_REPEAT
                CP      LOOP_LOOP
                JR      Z, SB_LOOPKW
                JR      SB_ERR
SB_FOR:
                CALL    FIND_MATCH_NEXT
                JR      SB_POP
SB_WHILE:
                CALL    FIND_MATCH_WEND
                JR      SB_POP
SB_REPEAT:
                CALL    FIND_MATCH_UNTIL
                JR      SB_POP
SB_LOOPKW:
                CALL    FIND_MATCH_ENDLP
SB_POP:
                CALL    POP_LOOP
                RET
SB_TOEXIT:
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                CALL    POP_LOOP
                RET
SB_ERR:
                LD      HL, ERR_BREAK_NO_LOOP
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

; ─────────────────────────────────────────────────────────────────
; STMT_GOTO — execute "GOTO <line-number>"
;
;   Entry:  STMT_PTR points at the argument (just past "GOTO ").
;   Effect: Parses the target line number, looks it up in PROG_BASE
;           via FIND_LINE_NO, sets EXEC_PTR to the found record's
;           start, and sets PC_CHANGED so CR_LOOP jumps there next
;           iteration. Updates STMT_PTR to skip past the parsed
;           digits so EXEC_LINE_STMTS sees we consumed them.
;           If the target line does not exist, prints
;           "GOTO target line not found" and halts the run.
;   Allowed: anywhere a statement is allowed — at line start, after
;           THEN, after a colon. The interpreter calls EXEC_STATEMENT
;           uniformly in those positions, so just being a recognised
;           keyword in EXEC_STATEMENT is sufficient.
; ─────────────────────────────────────────────────────────────────
STMT_GOTO:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                ; Must be a digit. Reject anything else as syntax error.
                CP      '0'
                JR      C, SG_SYN
                CP      '9'+1
                JR      NC, SG_SYN
                CALL    PARSE_NUMBER        ; HL advanced past digits, DE=number
                LD      (STMT_PTR), HL      ; consume the digits
                ; DE = target line number. Find it in PROG_BASE.
                CALL    FIND_LINE_NO
                JR      Z, SG_FOUND
                ; Not found — runtime error.
                LD      HL, ERR_GOTO_NOLINE
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET
SG_FOUND:
                ; HL points at the start of the target line (line# high
                ; byte). Set EXEC_PTR there and flag PC change.
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
SG_SYN:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

; ─────────────────────────────────────────────────────────────────
; FIND_LINE_NO — locate a line by number in PROG_BASE
;
;   In:     DE = target line number (16-bit, big-endian when stored).
;   Out:    Z=1 (A=0) and HL = pointer to the start of the matching
;           record (the line# high byte) on success.
;           Z=0 (A!=0) on failure; HL undefined.
;   Trashes: AF, BC, HL.
; ─────────────────────────────────────────────────────────────────
FIND_LINE_NO:
                LD      HL, PROG_BASE
FLN_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, FLN_CHECK       ; not 0xFF — compare line#
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      0xFF
                JR      Z, FLN_NOTFOUND     ; 0xFF 0xFF = end-of-program
                ; otherwise line# starts with 0xFF (high byte = 255).
                ; Continue to the comparison below; reload A from (HL).
FLN_CHECK:
                ; Compare line# at (HL,HL+1) against DE
                LD      A, (HL)
                CP      D
                JR      NZ, FLN_NEXT
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      E
                JR      NZ, FLN_NEXT
                ; Match!
                XOR     A
                RET
FLN_NEXT:
                ; Skip this record: 2 bytes line# + 1 byte len + len bytes + 1 NUL
                INC     HL              ; past line# high
                INC     HL              ; past line# low
                LD      A, (HL)
                INC     HL              ; past length byte
                LD      C, A
                LD      B, 0
                ADD     HL, BC          ; past text body
                INC     HL              ; past NUL terminator
                JR      FLN_LOOP
FLN_NOTFOUND:
                OR      0xFF
                RET

; Expression evaluator
EVAL_EXPR:
                ; Check for string variable comparison: letter$ op "string"
                PUSH    HL
                CALL    SKIP_SPACES
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'A'
                JP      C, EE_NOT_SVAR
                CP      'Z'+1
                JP      NC, EE_NOT_SVAR
                SUB     'A'
                LD      B, A            ; B = var index
                INC     HL
                LD      A, (HL)
                CP      '$'
                JP      NZ, EE_NOT_SVAR
                INC     HL              ; skip '$'
                CALL    SKIP_SPACES
                ; Check for comparison operator
                LD      A, (HL)
                CP      '='
                JR      Z, EE_SVAR_CMP
                CP      '<'
                JR      Z, EE_SVAR_CMP
                CP      '>'
                JR      Z, EE_SVAR_CMP
                JP      EE_NOT_SVAR
EE_SVAR_CMP:
                ; It's a string comparison — discard saved HL
                POP     DE              ; discard old HL
                ; B = var index, HL = at operator
                ; Save operator
                LD      A, (HL)
                CP      '<'
                JR      Z, EE_SC_LT
                CP      '>'
                JR      Z, EE_SC_GT
                ; Must be '='
                INC     HL
                LD      A, 1            ; op code 1 = equal
                JR      EE_SC_DORHS
EE_SC_LT:
                INC     HL
                LD      A, (HL)
                CP      '>'
                JR      Z, EE_SC_NE
                ; plain '<' not supported for strings, treat as NE
                LD      A, 2
                JR      EE_SC_DORHS
EE_SC_NE:
                INC     HL              ; skip '>'
                LD      A, 2            ; op code 2 = not-equal
                JR      EE_SC_DORHS
EE_SC_GT:
                INC     HL
                LD      A, 2            ; '>' treat as not-equal
                JR      EE_SC_DORHS
EE_SC_DORHS:
                LD      (SCRATCH+17), A ; save op code (1=eq, 2=ne)
                CALL    SKIP_SPACES
                ; RHS must be a quoted string
                LD      A, (HL)
                CP      '"'
                JP      NZ, EE_SCMP_FALSE
                INC     HL              ; skip opening quote
                ; HL points to RHS string literal
                ; Get address of LHS string variable
                LD      A, B
                CALL    GET_SVAR_ADDR   ; DE = address of svar buffer
                ; Compare strings: DE=svar, HL=literal (quote-terminated)
EE_SCMP_LOOP:
                LD      A, (DE)
                LD      C, (HL)
                ; Check if literal ended (closing quote or null)
                LD      A, C
                CP      '"'
                JR      Z, EE_SCMP_LEND
                OR      A
                JR      Z, EE_SCMP_LEND
                ; Literal char in C, compare with svar char
                LD      A, (DE)
                OR      A
                JR      Z, EE_SCMP_DIFF ; svar ended early, literal hasn't
                CP      C
                JR      NZ, EE_SCMP_DIFF
                INC     DE
                INC     HL
                JR      EE_SCMP_LOOP
EE_SCMP_LEND:
                ; Literal ended. Svar must also be at null for equal.
                LD      A, (DE)
                OR      A
                JR      Z, EE_SCMP_EQ
                ; Svar has more chars — not equal
                JR      EE_SCMP_DIFF
EE_SCMP_EQ:
                ; Strings are equal
                ; Skip past closing quote in source
                LD      A, (HL)
                CP      '"'
                JR      NZ, EE_SCMP_EQ2
                INC     HL
EE_SCMP_EQ2:
                LD      A, (SCRATCH+17)
                CP      1               ; eq?
                JR      Z, EE_SCMP_TRUE
                JR      EE_SCMP_FALSE2
EE_SCMP_DIFF:
                ; Strings differ — skip past closing quote in source
                ; Need to find closing quote
EE_SCMP_SKIPQ:
                LD      A, (HL)
                OR      A
                JR      Z, EE_SCMP_SKDONE
                CP      '"'
                JR      Z, EE_SCMP_SKCLOSE
                INC     HL
                JR      EE_SCMP_SKIPQ
EE_SCMP_SKCLOSE:
                INC     HL
EE_SCMP_SKDONE:
                LD      A, (SCRATCH+17)
                CP      2               ; ne?
                JR      Z, EE_SCMP_TRUE
EE_SCMP_FALSE:
EE_SCMP_FALSE2:
                LD      DE, 0
                RET
EE_SCMP_TRUE:
                LD      DE, 1
                RET

EE_NOT_SVAR:
                POP     HL              ; restore original HL
                CALL    EVAL_ADD
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '='
                JR      Z, EE_EQ
                CP      '<'
                JR      Z, EE_LT
                CP      '>'
                JR      Z, EE_GT
                RET
EE_EQ:
                INC     HL
                PUSH    DE
                CALL    EVAL_ADD
                POP     BC
                LD      A, B
                CP      D
                JR      NZ, EE_FALSE
                LD      A, C
                CP      E
                JR      NZ, EE_FALSE
                JR      EE_TRUE
EE_LT:
                INC     HL
                LD      A, (HL)
                CP      '>'
                JR      Z, EE_NE
                CP      '='
                JR      Z, EE_LE
                PUSH    DE
                CALL    EVAL_ADD
                POP     BC
                CALL    SIGNED_CMP_BC_DE
                JR      C, EE_TRUE
                JR      EE_FALSE
EE_NE:
                INC     HL
                PUSH    DE
                CALL    EVAL_ADD
                POP     BC
                LD      A, B
                CP      D
                JR      NZ, EE_TRUE
                LD      A, C
                CP      E
                JR      NZ, EE_TRUE
                JR      EE_FALSE
EE_LE:
                INC     HL
                PUSH    DE
                CALL    EVAL_ADD
                POP     BC
                CALL    SIGNED_CMP_BC_DE
                JR      C, EE_TRUE
                JR      Z, EE_TRUE
                JR      EE_FALSE
EE_GT:
                INC     HL
                LD      A, (HL)
                CP      '='
                JR      Z, EE_GE
                PUSH    DE
                CALL    EVAL_ADD
                POP     BC
                CALL    SIGNED_CMP_DE_BC
                JR      C, EE_TRUE
                JR      EE_FALSE
EE_GE:
                INC     HL
                PUSH    DE
                CALL    EVAL_ADD
                POP     BC
                CALL    SIGNED_CMP_BC_DE
                JR      NC, EE_TRUE
                JR      EE_FALSE
EE_TRUE:
                LD      DE, 1
                RET
EE_FALSE:
                LD      DE, 0
                RET

EVAL_ADD:
                CALL    EVAL_MUL
                CALL    SKIP_SPACES
EA_LOOP:
                LD      A, (HL)
                CP      '+'
                JR      Z, EA_ADD
                CP      '-'
                JR      Z, EA_SUB
                RET
EA_ADD:
                INC     HL
                PUSH    DE
                CALL    EVAL_MUL
                POP     BC
                EX      DE, HL
                ADD     HL, BC
                EX      DE, HL
                CALL    SKIP_SPACES
                JR      EA_LOOP
EA_SUB:
                INC     HL
                PUSH    DE
                CALL    EVAL_MUL
                POP     BC
                PUSH    HL
                LD      H, B
                LD      L, C
                OR      A
                SBC     HL, DE
                EX      DE, HL
                POP     HL
                CALL    SKIP_SPACES
                JR      EA_LOOP

EVAL_MUL:
                CALL    EVAL_ATOM
                CALL    SKIP_SPACES
EM_LOOP:
                LD      A, (HL)
                CP      '*'
                JR      Z, EM_MUL
                CP      '/'
                JR      Z, EM_DIV
                RET
EM_MUL:
                INC     HL
                PUSH    DE
                CALL    EVAL_ATOM
                POP     BC
                CALL    MUL16
                CALL    SKIP_SPACES
                JR      EM_LOOP
EM_DIV:
                INC     HL
                PUSH    DE
                CALL    EVAL_ATOM
                LD      A, D
                OR      E
                JR      NZ, EM_DIVOK
                POP     BC
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                LD      DE, 0
                RET
EM_DIVOK:
                POP     BC
                PUSH    HL
                CALL    DIV16
                POP     HL
                CALL    SKIP_SPACES
                JR      EM_LOOP

EVAL_ATOM:
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '-'
                JR      Z, EATM_NEG
                CP      '('
                JR      Z, EATM_PAR
                CALL    IS_DIGIT
                JR      C, EATM_NUM
                CALL    TO_UPPER
                CP      'A'
                JR      C, EATM_ERR
                CP      'Z'+1
                JR      NC, EATM_ERR
                SUB     'A'
                INC     HL
                CALL    GET_VAR
                RET
EATM_NUM:
                CALL    PARSE_SIGNED_NUM
                RET
EATM_NEG:
                INC     HL
                CALL    EVAL_ATOM
                PUSH    HL
                LD      H, D
                LD      L, E
                LD      DE, 0
                EX      DE, HL
                OR      A
                SBC     HL, DE
                EX      DE, HL
                POP     HL
                RET
EATM_PAR:
                INC     HL
                CALL    EVAL_EXPR
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      ')'
                JR      NZ, EATM_ERR
                INC     HL
                RET
EATM_ERR:
                LD      DE, 0
                RET

; Variable access
GET_VAR:
                PUSH    HL
                LD      L, A
                LD      H, 0
                ADD     HL, HL
                LD      DE, VAR_BASE
                ADD     HL, DE
                LD      E, (HL)
                INC     HL
                LD      D, (HL)
                POP     HL
                RET

SET_VAR:
                PUSH    HL
                LD      L, A
                LD      H, 0
                ADD     HL, HL
                PUSH    DE
                LD      DE, VAR_BASE
                ADD     HL, DE
                POP     DE
                LD      (HL), E
                INC     HL
                LD      (HL), D
                POP     HL
                RET

; Program storage
; STORE_LINE — insert or replace a numbered BASIC line.
;
;   In:  DE = 16-bit line number
;        HL = pointer to null-terminated text (the part AFTER the line
;             number; the line number itself is in DE)
;
;   Out: BASIC program storage now contains exactly one line with that
;        number, with the supplied text, in sorted (ascending) position.
;        If a line with the same number existed, it is replaced. If
;        none existed, a new line is inserted at the correct sorted
;        position.
;
;   Steps:
;     1. CALL DELETE_LINE (silent no-op if not present) — guarantees
;        that after this call there is no existing line with the same
;        number, so insertion below cannot create a duplicate.
;     2. Measure text length.
;     3. Walk PROG_BASE forward, comparing each existing line number
;        with DE, until we find the first existing line whose number
;        is strictly greater than DE — that is our insertion point.
;     4. LDDR-shift everything from the insertion point to the end of
;        program (past the 0xFFFF marker) forward by (text_len + 4)
;        bytes to open a gap.
;     5. Write the new line into the gap as:
;            [hi][lo][len][text...][0]
;
;   This is the canonical "owner" of numbered-line semantics: every
;   numbered-line commit from the editor / bridge / REPL ultimately
;   passes through this routine, so insert and replace are guaranteed
;   to be applied consistently and in pure ASM.
;
;   Companion: a line-number-only commit calls DELETE_LINE directly
;   (decision taken in the bridge ASM, not in Python or any host).
;
;   Case preservation (WORKFLOW_03B contract):
;     The text bytes pointed to by HL are copied verbatim into program
;     storage by STL_COPY below. There is no TO_UPPER, no keyword
;     normalisation, no variable-name canonicalisation. Whatever the
;     user typed is what gets stored. Canonicalisation happens later,
;     and only on demand, inside LIST (PRINT_NORMALIZED).
;
; STORE_LINE: DE=line#, HL=text pointer
; Inserts new line in sorted position (ascending line number).
; 1. Delete any existing line with same number
; 2. Measure text length
; 3. Find insertion point (first line with number > new)
; 4. Shift tail forward via LDDR to open gap
; 5. Write new line into the gap

STORE_LINE:
                LD      (SCRATCH+24), DE    ; save line number
                LD      (SCRATCH+22), HL    ; save text pointer
                ; Delete existing line with this number
                CALL    DELETE_LINE
                ; Measure text length
                LD      HL, (SCRATCH+22)
                LD      B, 0
STL_LEN:
                LD      A, (HL)
                OR      A
                JR      Z, STL_LEND
                INC     HL
                INC     B
                JR      STL_LEN
STL_LEND:
                LD      A, B
                LD      (SCRATCH+20), A     ; text length

                ; Find sorted insertion point
                LD      DE, (SCRATCH+24)    ; new line number
                LD      HL, PROG_BASE
STL_FIND:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, STL_NOTEM
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      0xFF
                JR      Z, STL_INSPT       ; end of program — insert here
STL_NOTEM:
                ; Compare existing line# at (HL) vs new line# (DE)
                ; Existing: high=(HL), low=(HL+1)
                ; New: high=D, low=E
                LD      A, (HL)             ; existing high byte
                CP      D
                JR      C, STL_SKIPLN       ; existing < new — skip forward
                JR      NZ, STL_INSPT       ; existing > new — insert here
                ; High bytes equal — compare low
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      E
                JR      C, STL_SKIPLN       ; existing < new — skip forward
                JR      STL_INSPT           ; existing >= new — insert here
STL_SKIPLN:
                INC     HL                  ; skip line# high
                INC     HL                  ; skip line# low
                LD      A, (HL)             ; length
                INC     HL                  ; skip length byte
                LD      C, A
                LD      B, 0
                ADD     HL, BC              ; skip text
                INC     HL                  ; skip null
                JR      STL_FIND

STL_INSPT:
                ; HL = insertion point
                LD      (SCRATCH+26), HL    ; save it

                ; Find end of all program data (past 0xFFFF marker)
                CALL    FIND_PROG_END       ; HL = 1 past end marker
                DEC     HL                  ; HL = last byte (2nd 0xFF)

                ; Shift amount = text_length + 4
                LD      A, (SCRATCH+20)
                ADD     A, 4
                LD      C, A
                LD      B, 0                ; BC = shift amount

                ; LDDR setup: HL=source(last byte), DE=dest(last+shift)
                LD      D, H
                LD      E, L                ; DE = source = last byte
                ADD     HL, BC              ; HL = last byte + shift
                EX      DE, HL              ; DE=dest end, HL=source end

                ; Count = source_end - insertion_point + 1
                PUSH    DE                  ; save dest end
                LD      DE, (SCRATCH+26)    ; insertion point
                OR      A
                SBC     HL, DE              ; HL = source - insert
                LD      B, H
                LD      C, L
                INC     BC                  ; BC = byte count
                ADD     HL, DE              ; HL = source end (restored)
                POP     DE                  ; DE = dest end

                ; Block copy backwards
                LDDR

                ; Write new line at insertion point
                LD      HL, (SCRATCH+26)
                ; Line number
                LD      DE, (SCRATCH+24)
                LD      (HL), D
                INC     HL
                LD      (HL), E
                INC     HL
                ; Text length
                LD      A, (SCRATCH+20)
                LD      (HL), A
                INC     HL
                ; Copy text
                LD      DE, (SCRATCH+22)
                LD      B, A
STL_COPY:
                LD      A, B
                OR      A
                JR      Z, STL_CDONE
                LD      A, (DE)
                LD      (HL), A
                INC     HL
                INC     DE
                DEC     B
                JR      STL_COPY
STL_CDONE:
                LD      (HL), 0             ; null terminator
                RET

; DELETE_LINE — remove a numbered BASIC line if it exists.
;
;   In:  DE = 16-bit line number to delete.
;
;   Out: If a line with that number is present, it is removed and the
;        remaining program is compacted forward (no gap). If no such
;        line exists, the routine is a clean no-op (returns without
;        modifying anything).
;
;   This is what the bridge/editor calls when the user commits a
;   "line-number-only" line (e.g. "20" with no statement after).
;   The decision "number-only → delete" is taken in the bridge ASM
;   (WF_DO_BASIC) — the routine itself just does the storage mutation.
;
DELETE_LINE:
                LD      HL, PROG_BASE
DL_FIND:
                LD      A, (HL)
                LD      B, A
                INC     HL
                LD      A, (HL)
                LD      C, A
                DEC     HL
                LD      A, B
                CP      0xFF
                JR      NZ, DL_NOTEM
                LD      A, C
                CP      0xFF
                RET     Z
DL_NOTEM:
                LD      A, B
                CP      D
                JR      NZ, DL_NOMATCH
                LD      A, C
                CP      E
                JR      Z, DL_FOUND
DL_NOMATCH:
                INC     HL
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      B, 0
                LD      C, A
                ADD     HL, BC
                INC     HL
                JR      DL_FIND
DL_FOUND:
                PUSH    HL
                INC     HL
                INC     HL
                LD      A, (HL)
                ADD     A, 4
                LD      C, A
                LD      B, 0
                POP     HL
                PUSH    HL
                LD      D, H
                LD      E, L
                ADD     HL, BC
DL_COPY:
                LD      A, (HL)
                LD      (DE), A
                CP      0xFF
                JR      NZ, DL_CNEXT
                INC     HL
                INC     DE
                LD      A, (HL)
                LD      (DE), A
                CP      0xFF
                JR      Z, DL_CDONE
                INC     HL
                INC     DE
                JR      DL_COPY
DL_CNEXT:
                INC     HL
                INC     DE
                JR      DL_COPY
DL_CDONE:
                POP     HL
                RET

FIND_PROG_END:
                LD      HL, PROG_BASE
FPE_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, FPE_SKIP
                INC     HL
                LD      A, (HL)
                CP      0xFF
                JR      Z, FPE_FOUND
                DEC     HL
FPE_SKIP:
                INC     HL
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      B, 0
                LD      C, A
                ADD     HL, BC
                INC     HL
                JR      FPE_LOOP
FPE_FOUND:
                INC     HL
                RET

CMD_LIST_RAW:
                ; Variant of CMD_LIST that:
                ;   * does NOT call FW_CLS
                ;   * does NOT update LIST_TOP_ROW/BOT_ROW/ACTIVE
                ;   * emits each line through OUT_CHAR_TARG (so the
                ;     workflow can capture into a buffer) terminated
                ;     by CR (0x0D), with no trailing LF
                ;   * after the final line, emits a single 0x00 byte
                ;     so the consumer knows where the listing ends
                LD      HL, PROG_BASE
CLR_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, CLR_LINE
                INC     HL
                LD      A, (HL)
                CP      0xFF
                JR      Z, CLR_DONE
                DEC     HL
CLR_LINE:
                LD      D, (HL)
                INC     HL
                LD      E, (HL)             ; DE = line number
                INC     HL
                PUSH    HL
                CALL    PRINT_UINT16_RAW    ; emit decimal line# via target
                LD      A, ' '
                CALL    OUT_CHAR_TARG
                POP     HL
                LD      A, (HL)             ; length byte (skip it)
                INC     HL
                CALL    PRINT_NORMALIZED
                LD      A, 0x0D             ; CR = end-of-line separator
                CALL    OUT_CHAR_TARG
                JR      CLR_LOOP
CLR_DONE:
                XOR     A                   ; final 0x00 = end-of-listing
                CALL    OUT_CHAR_TARG
                RET

; PRINT_UINT16_RAW: DE = unsigned 16-bit number
; Emits the decimal digits one at a time through OUT_CHAR_TARG, with no
; leading zeros (for the value 0, emits a single '0').
; Self-contained: does not depend on FW_PRINT or any console primitive.
PRINT_UINT16_RAW:
                PUSH    HL
                PUSH    BC
                ; Special-case zero
                LD      A, D
                OR      E
                JR      NZ, PURW_NONZERO
                LD      A, '0'
                CALL    OUT_CHAR_TARG
                POP     BC
                POP     HL
                RET
PURW_NONZERO:
                ; Build digit buffer in SCRATCH+30..SCRATCH+35 (high to low),
                ; then emit in reverse.
                LD      HL, SCRATCH+35
                LD      (HL), 0             ; null terminator
                DEC     HL
                LD      C, 0                ; digit count
PURW_DIGIT:
                LD      A, D
                OR      E
                JR      Z, PURW_EMIT
                PUSH    HL
                LD      B, D
                LD      C, E
                LD      DE, 10
                CALL    DIV16_U             ; DE = q, HL = remainder (digit)
                LD      A, L
                ADD     A, '0'
                POP     HL
                LD      (HL), A
                DEC     HL
                JR      PURW_DIGIT
PURW_EMIT:
                INC     HL                  ; HL = first digit
PURW_OUT:
                LD      A, (HL)
                OR      A
                JR      Z, PURW_END
                CALL    OUT_CHAR_TARG
                INC     HL
                JR      PURW_OUT
PURW_END:
                POP     BC
                POP     HL
                RET

CMD_LIST:
                CALL    FW_CLS
                ; Record LIST top row (row 0 after CLS)
                XOR     A
                LD      (LIST_TOP_ROW), A
                LD      HL, PROG_BASE
CL_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, CL_LINE
                INC     HL
                LD      A, (HL)
                CP      0xFF
                JR      Z, CL_DONE
                DEC     HL
CL_LINE:
                LD      D, (HL)
                INC     HL
                LD      E, (HL)
                INC     HL
                PUSH    HL
                CALL    PRINT_UINT16
                LD      A, ' '
                CALL    FW_PUTCHAR
                POP     HL
                LD      A, (HL)
                INC     HL
                CALL    PRINT_NORMALIZED
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                JR      CL_LOOP
CL_DONE:
                ; Record LIST bottom row (cursor row - 1, since CR/LF moved past last line)
                IN      A, (PORT_CUR_ROW)
                OR      A
                JR      Z, CL_SETBOT
                DEC     A               ; row before the current cursor (last line of LIST output)
CL_SETBOT:
                LD      (LIST_BOT_ROW), A
                LD      A, 1
                LD      (LIST_ACTIVE), A
                RET

; PRINT_NORMALIZED — emit a stored BASIC line through OUT_CHAR_TARG
; with the canonical listing case rules.
;
;   In:  HL = pointer to null-terminated source text (the part of a
;             stored BASIC line after the line number).
;   Out: HL = points one byte past the terminating null.
;
;   Case rules applied here (LIST canonicalisation contract,
;   WORKFLOW_03B, second iteration):
;
;     * Each time HL is positioned at an alphabetic character (a..z
;       or A..Z) we attempt to match a BASIC keyword starting at
;       that position. The keyword list is PN_KW_TABLE. Match uses
;       a word boundary check: the keyword must be followed by null,
;       whitespace, or any non-alpha non-digit character.
;     * On match: emit the keyword in UPPERCASE through OUT_CHAR_TARG,
;       advance HL past the matched bytes, continue scanning. The
;       special case REM also triggers PN_REMLIT (rest of line is
;       emitted byte-for-byte without case conversion).
;     * On no match (alpha but not a keyword): emit the byte VERBATIM
;       (no TO_UPPER) and advance one byte. This is what preserves
;       variable case in the listing — `counter` stays `counter`.
;     * Non-alpha bytes (digits, spaces, operators, '=' '<' '>' etc.)
;       are emitted verbatim and HL advances by one.
;     * String literals "..." are emitted byte-for-byte without case
;       conversion (PN_STR / PN_SLOOP / PN_SEND).
;
;   Result for a line like:
;     10 let counter = 1
;   becomes (after LIST):
;     10 LET counter = 1
;
;   And a line like:
;     20 print counter
;   becomes:
;     20 PRINT counter
;
;   Whereas STORE_LINE never applies any of this: it copies the
;   user's bytes verbatim into program storage. LIST is the only
;   surface that runs PRINT_NORMALIZED.
;
PRINT_NORMALIZED:
PN_LOOP:
                LD      A, (HL)
                OR      A
                JP      Z, PN_LOOP_DONE
                CP      '"'
                JP      Z, PN_STR
                ; Is the current char alphabetic?
                CALL    PN_IS_ALPHA
                JR      NC, PN_VERBATIM_ONE
                ; Alpha. Try to match a keyword starting here.
                CALL    PN_TRY_KW
                ; Returns: A=0 → matched (HL already advanced past
                ; keyword, keyword bytes already emitted in upper);
                ; A=1 → no match.
                OR      A
                JR      Z, PN_LOOP
                ; No keyword matched. Emit byte verbatim.
PN_VERBATIM_ONE:
                LD      A, (HL)
                CALL    OUT_CHAR_TARG
                INC     HL
                JR      PN_LOOP

PN_LOOP_DONE:
                INC     HL
                RET

; ── PN_IS_ALPHA: A=(HL). Returns CY=1 if a..z or A..Z, CY=0 otherwise.
;    Trashes A only.
PN_IS_ALPHA:
                LD      A, (HL)
                CP      'A'
                JR      C, PN_NOT_ALPHA
                CP      'Z'+1
                JR      C, PN_IS_ALPHA_YES
                CP      'a'
                JR      C, PN_NOT_ALPHA
                CP      'z'+1
                JR      C, PN_IS_ALPHA_YES
PN_NOT_ALPHA:
                OR      A               ; CY=0
                RET
PN_IS_ALPHA_YES:
                SCF                     ; CY=1
                RET

; ── PN_TRY_KW: HL = source position (alpha).
;    Walks PN_KW_TABLE (a list of word ptrs terminated by 0x0000).
;    For each keyword, calls PN_KW_MATCH. On first match:
;       * if keyword is "REM", emits REM upper then jumps to PN_REMLIT
;         which consumes the rest of the line literally and returns
;         to PN_TRY_KW's caller via PN_REM_DONE → A=0.
;       * otherwise emits the keyword chars in uppercase, advances
;         HL by the keyword length, returns A=0.
;    On no match: returns A=1 with HL unchanged.
PN_TRY_KW:
                LD      IX, PN_KW_TABLE
PN_TK_LOOP:
                LD      E, (IX+0)
                LD      D, (IX+1)
                LD      A, D
                OR      E
                JR      Z, PN_TK_NONE   ; reached terminator → no match
                ; DE = pointer to a keyword (uppercase, NUL-terminated)
                PUSH    DE
                CALL    PN_KW_MATCH     ; in: HL=src, DE=kw → A=0 if match
                POP     DE
                OR      A
                JR      Z, PN_TK_HIT
                INC     IX
                INC     IX
                JR      PN_TK_LOOP
PN_TK_NONE:
                LD      A, 1
                RET
PN_TK_HIT:
                ; DE = matched keyword pointer. Special-case REM by
                ; re-reading the first three keyword bytes from DE and
                ; comparing them against the literal characters
                ; 'R','E','M'. This is portable across pasmo / z80asm
                ; (no HIGH / LOW operators needed).
                LD      A, (DE)
                CP      'R'
                JR      NZ, PN_TK_GENERIC
                INC     DE
                LD      A, (DE)
                CP      'E'
                JR      NZ, PN_TK_NOTREM_RESTORE2
                INC     DE
                LD      A, (DE)
                CP      'M'
                JR      NZ, PN_TK_NOTREM_RESTORE3
                INC     DE
                LD      A, (DE)
                OR      A
                JR      NZ, PN_TK_NOTREM_RESTORE4
                ; All four bytes match "REM" + null → keyword IS REM.
                JP      PN_REM_HIT

PN_TK_NOTREM_RESTORE4:
                DEC     DE
PN_TK_NOTREM_RESTORE3:
                DEC     DE
PN_TK_NOTREM_RESTORE2:
                DEC     DE
PN_TK_GENERIC:
                ; Generic match: emit DE's bytes through OUT_CHAR_TARG
                ; (already uppercase — that's how the table is stored)
                ; while advancing HL by the same count.
PN_TK_EMIT:
                LD      A, (DE)
                OR      A
                JR      Z, PN_TK_DONE
                CALL    OUT_CHAR_TARG
                INC     DE
                INC     HL
                JR      PN_TK_EMIT
PN_TK_DONE:
                XOR     A
                RET

; ── PN_REM_HIT: emit "REM" uppercased, then copy the rest of the
;    source line byte-for-byte until NUL. HL advances over the entire
;    remainder (caller's PN_LOOP will then see the NUL and finish).
PN_REM_HIT:
                LD      A, 'R'
                CALL    OUT_CHAR_TARG
                INC     HL
                LD      A, 'E'
                CALL    OUT_CHAR_TARG
                INC     HL
                LD      A, 'M'
                CALL    OUT_CHAR_TARG
                INC     HL
PN_REMLIT:
                LD      A, (HL)
                OR      A
                JR      Z, PN_REM_END
                CALL    OUT_CHAR_TARG
                INC     HL
                JR      PN_REMLIT
PN_REM_END:
                ; Return to PN_LOOP via the return address of the CALL
                ; PN_TRY_KW that brought us here. PN_LOOP will then read
                ; (HL) — which is the source NUL — see A=0, and route
                ; through PN_LOOP_DONE, whose INC HL is the one that
                ; advances past the NUL. We must NOT add another INC HL
                ; here, or the caller (CMD_LIST_RAW, CMD_LIST, CMD_SAVE)
                ; will receive HL one byte too far into the next line —
                ; misaligning the line-number read and clobbering the
                ; first character of the next line's text.
                XOR     A
                RET

; ── PN_KW_MATCH: HL = source pointer (caller's, NOT advanced),
;    DE = keyword pointer (uppercase, NUL-terminated).
;    Returns A=0 if the source matches the keyword case-insensitively
;    AND the byte at HL+len(kw) is a word boundary (NUL, space, or
;    non-alphanumeric). HL and DE are preserved on match-or-fail.
;    A=1 on no match.
PN_KW_MATCH:
                PUSH    HL
                PUSH    DE
PN_KM_LOOP:
                LD      A, (DE)
                OR      A
                JR      Z, PN_KM_KWEND
                LD      B, A
                LD      A, (HL)
                CALL    TO_UPPER
                CP      B
                JR      NZ, PN_KM_FAIL
                INC     HL
                INC     DE
                JR      PN_KM_LOOP
PN_KM_KWEND:
                ; Word boundary check at HL.
                LD      A, (HL)
                OR      A
                JR      Z, PN_KM_OK
                CP      ' '
                JR      Z, PN_KM_OK
                ; non-alpha non-digit OK; alpha or digit fails
                CP      '0'
                JR      C, PN_KM_OK     ; below '0' → punctuation, OK
                CP      '9'+1
                JR      C, PN_KM_FAIL   ; '0'..'9' → fails (e.g. FOR1)
                CP      'A'
                JR      C, PN_KM_OK     ; between '9' and 'A' → punctuation
                CP      'Z'+1
                JR      C, PN_KM_FAIL   ; 'A'..'Z' → fails (e.g. FORMULA)
                CP      'a'
                JR      C, PN_KM_OK
                CP      'z'+1
                JR      C, PN_KM_FAIL
PN_KM_OK:
                POP     DE
                POP     HL
                XOR     A
                RET
PN_KM_FAIL:
                POP     DE
                POP     HL
                LD      A, 1
                RET

; ── PN_KW_TABLE: list of pointers to BASIC keywords for LIST
;    canonicalisation. Order matters when one keyword is a prefix of
;    another (e.g. ENDLOOP must come before LOOP, otherwise LOOP would
;    match the start of "ENDLOOP" — but here word-boundary check
;    prevents that, since after "LOOP" inside "ENDLOOP" we have 'P'
;    which is alpha, so the match would already fail. Even so, we put
;    longer keywords first as a defensive ordering choice.).
;    REM must be present so the bridge can canonicalise "rem hello" →
;    "REM hello" and stop further canonicalisation on the comment body.
;    The list is terminated by 0x0000.
PN_KW_TABLE:
                DW      KW_ENDLOOP, KW_REPEAT, KW_RETURN_FAKE
                DW      KW_RENUM, KW_PRINT, KW_INPUT, KW_WHILE
                DW      KW_BREAK, KW_UNTIL, KW_LOAD, KW_SAVE
                DW      KW_LOOP_KW, KW_NEXT, KW_THEN, KW_STOP
                DW      KW_LIST, KW_WEND, KW_STEP, KW_EXIT
                DW      KW_LET, KW_FOR, KW_NEW, KW_CLS
                DW      KW_RUN, KW_DIR, KW_PWD, KW_REM, KW_GOTO
                DW      KW_IF, KW_TO, KW_WD
                DW      0

; A label that does not exist as a real keyword in this BASIC, used
; only so the table stays well-formed if someone later wires in
; GOTO/GOSUB/RETURN. For now it points at a 0-byte string so a match
; never succeeds.
KW_RETURN_FAKE: DB      0

PN_STR:
                CALL    OUT_CHAR_TARG
                INC     HL
PN_SLOOP:
                LD      A, (HL)
                OR      A
                JR      Z, PN_STR_DONE
                CP      '"'
                JR      Z, PN_SEND
                CALL    OUT_CHAR_TARG
                INC     HL
                JR      PN_SLOOP
PN_SEND:
                CALL    OUT_CHAR_TARG
                INC     HL
                JP      PN_LOOP
PN_STR_DONE:
                INC     HL
                RET

; =====================================================================
; CMD_RENUM — Renumber program lines to 10, 20, 30, ... and remap
;             every GOTO reference to point at the new line number.
;
; Three passes:
;   A. Build a map old→new in RENUM_MAP. Each entry is 4 bytes:
;      old_hi, old_lo, new_hi, new_lo. Terminator: a single 0xFF
;      in the high byte (since real BASIC line numbers are < 65535
;      but we never expect 0xFFxx, this is safe).
;   B. Remap GOTO references inside the text of every line. For
;      each occurrence of "GOTO <digits>" (case-insensitive, with
;      a word boundary before GOTO so it doesn't fire inside a
;      string or another keyword), look up the digits in the map
;      and rewrite them. If the lookup fails, print a warning and
;      leave the digits unchanged.
;   C. Renumber the line headers using the new values from the map.
;      This is just walking the program in order again.
;
; Why not write the new line numbers in pass A?
;   Because pass B would then read the *new* number when scanning
;   lines that come earlier — and lookup would fail for any GOTO
;   to a later line. Keeping the old numbers in PROG_BASE during
;   pass B keeps the map fully usable.
; =====================================================================
CMD_RENUM:
                CALL    RENUM_BUILD_MAP
                CALL    RENUM_REMAP_REFS
                CALL    RENUM_REWRITE_NUMS
                RET

; ─────────────────────────────────────────────────────────────────
; Pass A: build the old→new map
; ─────────────────────────────────────────────────────────────────
RENUM_BUILD_MAP:
                LD      HL, PROG_BASE       ; reader
                LD      DE, RENUM_MAP       ; writer
                LD      BC, 10              ; first new number
RBM_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, RBM_LINE
                PUSH    HL
                INC     HL
                LD      A, (HL)
                POP     HL
                CP      0xFF
                JR      Z, RBM_END          ; reached 0xFF 0xFF
RBM_LINE:
                ; Read old number high byte
                LD      A, (HL)
                LD      (DE), A             ; old_hi
                INC     DE
                INC     HL
                LD      A, (HL)
                LD      (DE), A             ; old_lo
                INC     DE
                INC     HL
                ; Write new number (BC) into map
                LD      A, B
                LD      (DE), A             ; new_hi
                INC     DE
                LD      A, C
                LD      (DE), A             ; new_lo
                INC     DE
                ; Skip over length byte + text body + NUL
                LD      A, (HL)
                INC     HL
                PUSH    DE
                LD      D, 0
                LD      E, A
                ADD     HL, DE
                POP     DE
                INC     HL                  ; skip NUL
                ; BC += 10 for next line
                PUSH    HL
                LD      H, B
                LD      L, C
                LD      A, 10
                ADD     A, L
                LD      L, A
                LD      A, 0
                ADC     A, H
                LD      H, A
                LD      B, H
                LD      C, L
                POP     HL
                JR      RBM_LOOP
RBM_END:
                ; Write terminator: 0xFF in high byte of an entry.
                LD      A, 0xFF
                LD      (DE), A
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_LOOKUP — given old line# in DE, find new line# in RENUM_MAP.
;
;   In:  DE = old line number
;   Out: Z=1 (A=0) and DE = new line number on hit.
;        Z=0 (A=0xFF) on miss; DE preserved.
;   Trashes: AF, HL, BC.
; ─────────────────────────────────────────────────────────────────
RENUM_LOOKUP:
                LD      HL, RENUM_MAP
RL_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      Z, RL_MISS          ; terminator
                CP      D
                JR      NZ, RL_NEXT
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      E
                JR      NZ, RL_NEXT
                ; Match — read new value
                INC     HL
                INC     HL                  ; skip old_lo
                LD      A, (HL)             ; new_hi
                INC     HL
                LD      C, (HL)             ; new_lo
                LD      D, A
                LD      E, C
                XOR     A
                RET
RL_NEXT:
                ; Move HL to next entry (4 bytes)
                INC     HL
                INC     HL
                INC     HL
                INC     HL
                JR      RL_LOOP
RL_MISS:
                OR      0xFF
                RET

; ─────────────────────────────────────────────────────────────────
; Pass B: remap GOTO references in every line's text
; ─────────────────────────────────────────────────────────────────
RENUM_REMAP_REFS:
                LD      HL, PROG_BASE       ; pointer to current line header
RRR_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, RRR_LINE
                PUSH    HL
                INC     HL
                LD      A, (HL)
                POP     HL
                CP      0xFF
                RET     Z
RRR_LINE:
                ; HL is at line# high. Skip 2 bytes line# + 1 byte len.
                INC     HL                  ; line# low
                INC     HL                  ; length byte
                LD      A, (HL)
                INC     HL                  ; first text byte
                ; HL = start of text body. Now scan for GOTO references.
                CALL    RENUM_SCAN_LINE
                ; After RENUM_SCAN_LINE, HL points at the NUL terminator
                ; of this line's text. Skip it to land on next header.
                INC     HL
                JR      RRR_LOOP

; ─────────────────────────────────────────────────────────────────
; RENUM_SCAN_LINE — scan one line's text for GOTO refs and remap.
;
;   In:  HL = pointer to first text byte of a line (NUL-terminated).
;   Out: HL points at the NUL terminator at the end of the line.
;        The line text in PROG_BASE may have been edited; the line's
;        length byte (at HL-N-1 where N is text length) and downstream
;        program bytes may have shifted.
;
; Algorithm:
;   - Walk char by char.
;   - Skip string literals (anything between quotes, including the
;     quote characters themselves). This is critical: a string like
;     "GOTO 30" must not be remapped.
;   - At each position, check whether we have a word-boundary GOTO
;     (i.e. previous byte was non-alphanumeric or we're at the start
;     of the line). If yes, find the digits that follow, parse them,
;     look them up in RENUM_MAP, and substitute the new digits.
; ─────────────────────────────────────────────────────────────────
RENUM_SCAN_LINE:
                ; Save line-start in SCRATCH+60..61 so we can recompute
                ; word-boundary status (was the previous byte alnum?).
                LD      (SCRATCH+60), HL    ; pointer to start of text
RSL_NEXT:
                LD      A, (HL)
                OR      A
                RET     Z                   ; reached NUL
                CP      '"'
                JR      NZ, RSL_NOTQ
                ; Skip string literal: advance past closing quote (or NUL).
                INC     HL
RSL_INQ:
                LD      A, (HL)
                OR      A
                RET     Z                   ; unterminated string
                CP      '"'
                JR      Z, RSL_QEND
                INC     HL
                JR      RSL_INQ
RSL_QEND:
                INC     HL                  ; past closing quote
                JR      RSL_NEXT
RSL_NOTQ:
                ; Check word boundary: previous byte must not be alnum.
                ; If HL == SCRATCH+60 (line start), boundary is OK.
                PUSH    HL
                LD      DE, (SCRATCH+60)
                LD      A, H
                CP      D
                JR      NZ, RSL_BOUND_OK_PRE
                LD      A, L
                CP      E
                JR      Z, RSL_BOUND_TRY    ; HL == start → boundary OK
RSL_BOUND_OK_PRE:
                DEC     HL
                LD      A, (HL)
                CALL    RENUM_IS_ALNUM      ; Z=1 if NOT alnum, Z=0 if alnum
                JR      Z, RSL_BOUND_TRY    ; NOT alnum → boundary OK
                ; Was alnum → not a boundary.
                POP     HL
                INC     HL
                JR      RSL_NEXT
RSL_BOUND_TRY:
                POP     HL
                ; Try to match "GOTO" case-insensitive at HL.
                CALL    RENUM_MATCH_GOTO
                JR      Z, RSL_GOTO_HIT
                ; Not GOTO — advance one byte and continue scanning.
                INC     HL
                JR      RSL_NEXT
RSL_GOTO_HIT:
                ; HL is currently at 'G' of "GOTO". A returned the
                ; keyword length (4). Advance HL past "GOTO".
                LD      B, 0
                LD      C, A
                ADD     HL, BC              ; HL = first char after GOTO
                ; Skip spaces, then if a digit follows, remap it.
                CALL    RENUM_SKIP_SPACES
                LD      A, (HL)
                CP      '0'
                JR      C, RSL_NEXT_AFTER
                CP      '9'+1
                JR      NC, RSL_NEXT_AFTER
                ; Parse digits, look up, substitute.
                CALL    RENUM_REPLACE_NUM
                JR      RSL_NEXT
RSL_NEXT_AFTER:
                ; No digit followed; just continue scanning from here.
                JR      RSL_NEXT

; ─────────────────────────────────────────────────────────────────
; RENUM_MATCH_GOTO — case-insensitive match of "GOTO" at HL with
; trailing word-boundary check.
;
;   In:  HL = pointer to candidate position (not advanced)
;   Out: Z=1, A=4 if "GOTO" matched and the byte at HL+4 is NUL or
;        not alphanumeric. HL preserved.
;        Z=0, A=0xFF otherwise. HL preserved.
; ─────────────────────────────────────────────────────────────────
RENUM_MATCH_GOTO:
                PUSH    HL
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'G'
                JR      NZ, RMG_NO
                INC     HL
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'O'
                JR      NZ, RMG_NO
                INC     HL
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'T'
                JR      NZ, RMG_NO
                INC     HL
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'O'
                JR      NZ, RMG_NO
                INC     HL
                ; HL is now at byte after "GOTO". Must be NUL or non-alnum.
                LD      A, (HL)
                OR      A
                JR      Z, RMG_OK
                CALL    RENUM_IS_ALNUM      ; Z=1 if not alnum, Z=0 if alnum
                JR      NZ, RMG_NO          ; alnum → fail (e.g. GOTOX)
                ; fall through to RMG_OK
RMG_OK:
                POP     HL
                LD      A, 4                ; keyword length
                CP      A                   ; force Z=1, A unchanged
                RET
RMG_NO:
                POP     HL
                LD      A, 0xFF
                OR      A                   ; force Z=0
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_IS_ALNUM — Z=0 if A is alphanumeric, Z=1 if not.
;   (Note: opposite convention from regular IS_DIGIT-style helpers,
;   chosen so that "JR Z, not_alnum" reads naturally.)
; ─────────────────────────────────────────────────────────────────
RENUM_IS_ALNUM:
                CP      '0'
                JR      C, RIA_NO
                CP      '9'+1
                JR      C, RIA_YES
                CP      'A'
                JR      C, RIA_NO
                CP      'Z'+1
                JR      C, RIA_YES
                CP      'a'
                JR      C, RIA_NO
                CP      'z'+1
                JR      C, RIA_YES
RIA_NO:
                XOR     A                   ; Z=1
                RET
RIA_YES:
                OR      1                   ; Z=0
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_SKIP_SPACES — advance HL past any space chars at (HL).
; ─────────────────────────────────────────────────────────────────
RENUM_SKIP_SPACES:
                LD      A, (HL)
                CP      ' '
                RET     NZ
                INC     HL
                JR      RENUM_SKIP_SPACES

; ─────────────────────────────────────────────────────────────────
; RENUM_REPLACE_NUM — at HL we have the first digit of a target
; line number that was reached after a GOTO. Parse it, look it up
; in RENUM_MAP, and substitute the new digits. If lookup fails,
; print a warning and leave the digits alone (per user's spec).
;
;   In:  HL = first digit
;   Out: HL = byte after the (possibly resized) number. The line's
;        length byte and any downstream bytes may have shifted.
; ─────────────────────────────────────────────────────────────────
RENUM_REPLACE_NUM:
                ; Parse digits at HL into DE. Save start in SCRATCH+62.
                LD      (SCRATCH+62), HL    ; pointer to first digit
                CALL    PARSE_NUMBER        ; HL advanced past digits, DE=value
                LD      (SCRATCH+64), HL    ; pointer past last digit
                ; Look up DE in map.
                CALL    RENUM_LOOKUP
                JR      NZ, RRN_MISS
                ; DE = new value. Write new digits in place of old.
                CALL    RENUM_SPLICE_NUM
                RET
RRN_MISS:
                ; Warn: "Warning: GOTO target N not found (left as-is)"
                PUSH    HL
                LD      HL, MSG_RENUM_WARN
                CALL    FW_PRINT
                ; DE still has the original (unmapped) target number.
                CALL    PRINT_UINT16
                LD      HL, MSG_RENUM_WARN2
                CALL    FW_PRINT
                POP     HL
                ; HL stays at byte after the digits — no substitution.
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_SPLICE_NUM — substitute new ASCII digits for old in the
; line text, shifting trailing program bytes left or right.
;
;   In:  DE = new number (value)
;        SCRATCH+62 = pointer to first old digit
;        SCRATCH+64 = pointer past last old digit
;   Out: HL = pointer past the end of the new digits.
;        Line length byte (at SCRATCH+60 - 1) updated.
;        Any downstream program bytes shifted by (new_len - old_len).
;        End-of-program 0xFF 0xFF marker also moves accordingly.
; ─────────────────────────────────────────────────────────────────
RENUM_SPLICE_NUM:
                ; Convert DE to ASCII at SCRATCH+70..74 (max 5 digits).
                ; Returns: B = number of digits written.
                CALL    RENUM_NUM_TO_ASCII  ; B = digit count
                ; Save digit count in SCRATCH+67 — RENUM_SHRINK and
                ; RENUM_EXPAND trash BC, but RSN_DOCOPY needs the
                ; count, so we stash it.
                LD      A, B
                LD      (SCRATCH+67), A
                ; old_len  = SCRATCH+64 - SCRATCH+62
                ; delta    = B (new) - old_len
                LD      HL, (SCRATCH+64)
                LD      DE, (SCRATCH+62)
                OR      A
                SBC     HL, DE              ; HL = old_len
                LD      A, L                ; A = old_len (assume <256)
                LD      C, A                ; C = old_len
                LD      A, B                ; A = new_len
                SUB     C                   ; A = delta (signed)
                LD      (SCRATCH+66), A     ; remember signed delta
                OR      A
                JR      Z, RSN_SAMELEN      ; same length — easy: just copy
                ; Test sign of A explicitly. We can't use JP P / JP M
                ; because the emulator doesn't implement those opcodes.
                AND     0x80
                JR      Z, RSN_GREW_DO      ; bit7 was 0 → positive → grew
                ; new_len < old_len → shrink: shift trailing bytes left.
                LD      A, (SCRATCH+66)     ; reload signed delta (negative)
                ; Compute abs(delta) using CPL + INC A (NEG isn't
                ; implemented by the emulator).
                CPL
                INC     A                   ; A = -delta = abs(delta)
                LD      C, A                ; shrink amount
                CALL    RENUM_SHRINK
                JR      RSN_DOCOPY
RSN_GREW_DO:
                LD      A, (SCRATCH+66)     ; reload delta (positive)
                LD      C, A
                CALL    RENUM_EXPAND
                JR      RSN_DOCOPY
RSN_GREW:
                ; (Unused legacy label.)
                LD      C, A
                CALL    RENUM_EXPAND
                JR      RSN_DOCOPY
RSN_SAMELEN:
                ; Nothing to shift, just overwrite.
RSN_DOCOPY:
                ; Copy B digits from SCRATCH+70 to (SCRATCH+62).
                ; B may have been trashed by SHRINK/EXPAND, so reload
                ; the stashed count from SCRATCH+67.
                LD      A, (SCRATCH+67)
                LD      C, A
                LD      B, 0
                LD      HL, SCRATCH+70
                LD      DE, (SCRATCH+62)
                LDIR
                ; LDIR moved DE forward by C bytes; DE now points just
                ; past the new digits. Move it to HL for the caller.
                EX      DE, HL              ; HL = byte after new digits
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_NUM_TO_ASCII — convert DE (16-bit unsigned) to ASCII digits
; at SCRATCH+70 (no NUL, no padding).
;
;   In:  DE = value (0..65535)
;   Out: B = number of digits written (1..5).
;        Buffer at SCRATCH+70 has B characters '0'..'9'.
; ─────────────────────────────────────────────────────────────────
RENUM_NUM_TO_ASCII:
                ; First, write digits in reverse order to a temp buffer
                ; at SCRATCH+76, then reverse copy to SCRATCH+70.
                LD      HL, SCRATCH+76
                LD      B, 0                ; digit counter
                ; Special-case zero so we always emit at least one digit.
                LD      A, D
                OR      E
                JR      NZ, RNTA_LOOP
                LD      (HL), '0'
                INC     B
                JR      RNTA_REVERSE
RNTA_LOOP:
                LD      A, D
                OR      E
                JR      Z, RNTA_REVERSE
                ; Divide DE by 10 → quotient in DE, remainder in A.
                ; CRITICAL: RENUM_DIV_DE_10 trashes BC and HL, so save both.
                PUSH    BC
                PUSH    HL
                CALL    RENUM_DIV_DE_10
                POP     HL
                POP     BC
                ADD     A, '0'
                LD      (HL), A
                INC     HL
                INC     B
                JR      RNTA_LOOP
RNTA_REVERSE:
                ; Reverse buffer: SCRATCH+76 .. SCRATCH+76+B-1 → SCRATCH+70
                ; B digits, source = SCRATCH+76+B-1 going DOWN, dest = SCRATCH+70 going UP
                LD      HL, SCRATCH+76
                LD      A, B
                DEC     A
                LD      C, A
                LD      A, 0
                LD      D, A
                LD      E, C
                ADD     HL, DE              ; HL = SCRATCH+76 + (B-1)
                LD      DE, SCRATCH+70
                LD      C, B                ; loop count
RNTA_REVLOOP:
                LD      A, (HL)
                LD      (DE), A
                DEC     HL
                INC     DE
                DEC     C
                JR      NZ, RNTA_REVLOOP
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_DIV_DE_10 — divide DE by 10. Quotient in DE, remainder in A.
;   Trashes: AF, BC, HL.
;
;   Implementation note: simple repeated subtraction. Slow but uses
;   only basic Z80 opcodes (no ADC HL,HL / SBC HL,HL extended forms,
;   which are not implemented by the Z80yPico emulator). For a
;   16-bit dividend this is at most 6553 iterations which is plenty
;   fast for line-number formatting (max 5 digits).
; ─────────────────────────────────────────────────────────────────
RENUM_DIV_DE_10:
                LD      BC, 0               ; BC will be the quotient
RDD_LOOP:
                ; If DE < 10, we're done. Quotient = BC, remainder = DE_low.
                LD      A, D
                OR      A
                JR      NZ, RDD_SUB         ; D != 0 → DE >= 256 > 10, subtract
                LD      A, E
                CP      10
                JR      C, RDD_DONE         ; E < 10 → done
RDD_SUB:
                ; DE -= 10
                LD      A, E
                SUB     10
                LD      E, A
                LD      A, D
                SBC     A, 0
                LD      D, A
                ; Quotient++
                INC     BC
                JR      RDD_LOOP
RDD_DONE:
                ; A = E = remainder. Move quotient from BC into DE.
                LD      A, E                ; remainder
                LD      D, B
                LD      E, C
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_SHRINK — remove C bytes starting at (SCRATCH+64).
; Shifts everything from SCRATCH+64 onwards to the left by C bytes.
; The shift covers the entire program down to and including the
; 0xFF 0xFF terminator. Updates the line's length byte.
;
;   In:  C = bytes to shrink (number to remove)
; ─────────────────────────────────────────────────────────────────
RENUM_SHRINK:
                ; Save C in a stable scratch slot.
                LD      A, C
                LD      (SCRATCH+68), A     ; shrink amount
                ; Find end-of-program (HL = byte after 0xFF 0xFF).
                CALL    RENUM_FIND_PROG_END ; HL = end
                LD      (SCRATCH+72), HL    ; remember end pointer
                ; Source = (SCRATCH+64), Dest = source - shrink_amount.
                ; Bytes to copy = end - source.
                LD      DE, (SCRATCH+64)    ; src
                LD      HL, (SCRATCH+72)
                OR      A
                SBC     HL, DE              ; HL = byte count
                LD      B, H
                LD      C, L
                ; Now build dest = src - shrink_amount
                LD      A, E
                LD      HL, SCRATCH+68
                SUB     (HL)                ; A = src_lo - shrink
                LD      L, A
                LD      A, D
                SBC     A, 0
                LD      H, A                ; HL = dest
                ; Source pointer in DE already.
                EX      DE, HL              ; DE = dest, HL = src
                LDIR
                ; Update length byte: (SCRATCH+60 - 1) -= shrink_amount.
                LD      HL, (SCRATCH+60)
                DEC     HL
                LD      DE, SCRATCH+68
                LD      A, (DE)
                LD      D, A                ; D = shrink amount
                LD      A, (HL)
                SUB     D
                LD      (HL), A
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_EXPAND — insert C bytes at (SCRATCH+64). Shifts trailing
; program bytes (including 0xFF 0xFF terminator) right by C bytes.
; Uses LDDR for safe overlapping copy. Updates line's length byte.
;
;   In:  C = bytes to insert (delta, positive)
; ─────────────────────────────────────────────────────────────────
RENUM_EXPAND:
                LD      A, C
                LD      (SCRATCH+68), A     ; expand amount
                ; Find end-of-program.
                CALL    RENUM_FIND_PROG_END ; HL = end (byte AFTER 0xFFFF)
                LD      (SCRATCH+72), HL
                ; Bytes to copy = end - SCRATCH+64.
                LD      DE, (SCRATCH+64)
                OR      A
                SBC     HL, DE              ; HL = count
                LD      B, H
                LD      C, L
                ; Source (last byte) = end - 1.
                LD      HL, (SCRATCH+72)
                DEC     HL                  ; src = end - 1
                ; Dest (last byte) = src + expand_amount.
                LD      A, L
                LD      DE, SCRATCH+68
                LD      A, (DE)
                LD      D, A                ; D = expand
                LD      A, L
                ADD     A, D
                LD      E, A
                LD      A, H
                ADC     A, 0
                LD      D, A                ; DE = dest
                LDDR
                ; Update length byte.
                LD      HL, (SCRATCH+60)
                DEC     HL
                LD      DE, SCRATCH+68
                LD      A, (DE)
                LD      D, A
                LD      A, (HL)
                ADD     A, D
                LD      (HL), A
                RET

; ─────────────────────────────────────────────────────────────────
; RENUM_FIND_PROG_END — return HL = address just past the 0xFF 0xFF
; end-of-program marker.
; ─────────────────────────────────────────────────────────────────
RENUM_FIND_PROG_END:
                LD      HL, PROG_BASE
RFPE_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, RFPE_SKIP
                INC     HL
                LD      A, (HL)
                CP      0xFF
                JR      NZ, RFPE_BACK1
                ; HL is on the second 0xFF. Past it.
                INC     HL
                RET
RFPE_BACK1:
                DEC     HL
RFPE_SKIP:
                ; Skip line: 2 bytes line# + 1 length + N bytes + 1 NUL
                INC     HL
                INC     HL
                LD      A, (HL)
                INC     HL
                PUSH    DE
                LD      D, 0
                LD      E, A
                ADD     HL, DE
                POP     DE
                INC     HL                  ; past NUL
                JR      RFPE_LOOP

; ─────────────────────────────────────────────────────────────────
; Pass C: rewrite the line# headers using the values from RENUM_MAP.
; ─────────────────────────────────────────────────────────────────
RENUM_REWRITE_NUMS:
                LD      HL, PROG_BASE
                LD      IX, RENUM_MAP
RRN_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, RRN_LINE
                PUSH    HL
                INC     HL
                LD      A, (HL)
                POP     HL
                CP      0xFF
                RET     Z
RRN_LINE:
                ; Skip the OLD line# (2 bytes) — we need to replace
                ; them with the matching NEW from the map.
                ; Map entry: old_hi, old_lo, new_hi, new_lo.
                ; The line entries are in the same order as map entries
                ; (both built by walking PROG_BASE forward), so we can
                ; just zip through linearly.
                LD      A, (IX+2)           ; new_hi
                LD      (HL), A
                INC     HL
                LD      A, (IX+3)           ; new_lo
                LD      (HL), A
                INC     HL
                ; Skip length + text + NUL
                LD      A, (HL)
                INC     HL
                PUSH    DE
                LD      D, 0
                LD      E, A
                ADD     HL, DE
                POP     DE
                INC     HL
                ; Advance IX to next map entry (4 bytes).
                LD      BC, 4
                PUSH    HL
                PUSH    IX
                POP     HL
                ADD     HL, BC
                PUSH    HL
                POP     IX
                POP     HL
                JR      RRN_LOOP

; =====================================================================
; CMD_LOAD — Load a .bas or .bin file
; Entry: STMT_PTR points past "LOAD" keyword, at the filename
; =====================================================================
CMD_LOAD:
                ; LOAD_TYPE marker — used by the bridge to know what
                ; the most recent LOAD did:
                ;   0xFF — nothing loaded successfully (error path)
                ;   0x00 — text source (.bas / .txt) loaded into
                ;          PROG_BASE; bridge should rebuild editor
                ;   0x01 — raw .bin loaded at 0xC400; bridge should
                ;          execute it (CALL 0xC400) and leave editor
                ;          contents untouched
                LD      A, 0xFF
                LD      (LOAD_TYPE), A
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '"'
                JR      NZ, LOAD_NQ
                ; Extract filename from quotes into SYSCALL_BUFFER+1
                INC     HL              ; skip opening quote
                LD      DE, SYSCALL_BUFFER+1
LOAD_FNAME:
                LD      A, (HL)
                OR      A
                JR      Z, LOAD_NCLOSE  ; no closing quote
                CP      '"'
                JP      Z, LOAD_FEND
                LD      (DE), A
                INC     HL
                INC     DE
                JR      LOAD_FNAME
LOAD_NQ:
                LD      HL, ERR_FILENAME
                CALL    PRINT_ERROR
                RET
LOAD_NCLOSE:
                LD      HL, ERR_FILENAME
                CALL    PRINT_ERROR
                RET
LOAD_FEND:
                LD      A, 0
                LD      (DE), A         ; null-terminate filename
                INC     HL              ; skip closing quote
                LD      (STMT_PTR), HL
                ; Determine extension: scan backwards for '.'
                DEC     DE              ; DE points at last char of filename
                LD      B, 0            ; safety counter
LOAD_FEXT:
                LD      A, (DE)
                CP      '.'
                JR      Z, LOAD_GOTDOT
                ; Check if we've gone back to start
                PUSH    HL
                LD      HL, SYSCALL_BUFFER+1
                OR      A
                SBC     HL, DE
                POP     HL
                JR      Z, LOAD_NOEXT   ; no extension found
                DEC     DE
                INC     B
                LD      A, B
                CP      20              ; max scan
                JR      C, LOAD_FEXT
LOAD_NOEXT:
                LD      HL, ERR_BAD_EXT
                CALL    PRINT_ERROR
                RET
LOAD_GOTDOT:
                ; DE points at '.', check extension.
                ;   .BAS or .TXT  → text source with numbered lines
                ;                   (loaded line-by-line into PROG_BASE
                ;                   via LOAD_BAS). A .txt without valid
                ;                   numbered lines simply leaves the
                ;                   program empty; RUN will error
                ;                   normally on an empty program.
                ;   .BIN          → raw binary loaded at 0xC400 via
                ;                   LOAD_BIN. Caller is responsible
                ;                   for deciding whether to execute
                ;                   it (the bridge does that for the
                ;                   "load" inline command).
                INC     DE
                LD      A, (DE)
                CALL    TO_UPPER
                CP      'B'
                JR      Z, LOAD_EXT_B
                CP      'T'
                JR      Z, LOAD_CHKTXT
                JR      LOAD_NOEXT
LOAD_EXT_B:
                INC     DE
                LD      A, (DE)
                CALL    TO_UPPER
                CP      'A'
                JR      Z, LOAD_CHKBAS
                CP      'I'
                JR      Z, LOAD_CHKBIN
                JR      LOAD_NOEXT
LOAD_CHKTXT:
                ; Check for .TXT
                INC     DE
                LD      A, (DE)
                CALL    TO_UPPER
                CP      'X'
                JR      NZ, LOAD_NOEXT
                INC     DE
                LD      A, (DE)
                CALL    TO_UPPER
                CP      'T'
                JR      NZ, LOAD_NOEXT
                INC     DE
                LD      A, (DE)
                OR      A
                JR      NZ, LOAD_NOEXT
                ; It's a .txt file — same parser as .bas
                JR      LOAD_BAS
LOAD_CHKBAS:
                ; Check for .BAS
                INC     DE
                LD      A, (DE)
                CALL    TO_UPPER
                CP      'S'
                JR      NZ, LOAD_NOEXT
                INC     DE
                LD      A, (DE)
                OR      A
                JR      NZ, LOAD_NOEXT
                ; It's a .bas file
                JR      LOAD_BAS
LOAD_CHKBIN:
                ; Check for .BIN
                INC     DE
                LD      A, (DE)
                CALL    TO_UPPER
                CP      'N'
                JR      NZ, LOAD_NOEXT
                INC     DE
                LD      A, (DE)
                OR      A
                JR      NZ, LOAD_NOEXT
                ; It's a .bin file
                JR      LOAD_BIN

; --- LOAD .bas ---
LOAD_BAS:
                ; Clear current program
                CALL    NEW_PROGRAM
                ; Open file for reading: syscall SYS_FILE_OPEN
                ; Filename already at SYSCALL_BUFFER+1
                LD      A, SYS_FILE_OPEN
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A  ; trigger syscall
                ; Check result
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, LBAS_OPENED
                LD      HL, ERR_FILE_NOT_FOUND
                CALL    PRINT_ERROR
                RET
LBAS_OPENED:
                ; Read lines one at a time
LBAS_READLINE:
                LD      A, SYS_FILE_NEXT
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A  ; trigger syscall
                ; Check result: SYS_OK=got line, SYS_ERR=EOF
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      NZ, LBAS_EOF
                ; Line text is at SYSCALL_BUFFER+1 (null-terminated)
                ; Parse: must start with line number
                LD      HL, SYSCALL_BUFFER+1
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                JR      Z, LBAS_READLINE    ; empty line, skip
                ; Check if it starts with a digit
                CALL    IS_DIGIT
                JR      NC, LBAS_BADLINE    ; no line number
                CALL    PARSE_NUMBER        ; DE = line number
                CALL    SKIP_SPACES
                LD      A, (HL)
                OR      A
                JR      Z, LBAS_READLINE    ; line number only, skip
                ; HL points at source text, DE = line number
                CALL    STORE_LINE
                JR      LBAS_READLINE
LBAS_BADLINE:
                ; Non-numbered line — skip it (could warn, but keep loading)
                JR      LBAS_READLINE
LBAS_EOF:
                ; Close file
                LD      A, SYS_FILE_CLOSE
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                ; Mark: text source loaded successfully.
                LD      A, 0x00
                LD      (LOAD_TYPE), A
                ; Print confirmation
                LD      HL, MSG_LOADED
                CALL    FW_PRINT
                RET

; --- LOAD .bin ---
LOAD_BIN:
                ; Filename already at SYSCALL_BUFFER+1
                ; Write load address at known offset for emulator
                LD      A, SYS_BIN_LOAD
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A  ; trigger syscall
                ; Check result
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, LBIN_OK
                LD      HL, ERR_FILE_NOT_FOUND
                CALL    PRINT_ERROR
                RET
LBIN_OK:
                ; Mark: raw binary loaded successfully.
                LD      A, 0x01
                LD      (LOAD_TYPE), A
                LD      HL, MSG_BIN_LOADED
                CALL    FW_PRINT
                RET

; =====================================================================
; CMD_SAVE — Save current BASIC program as .bas text file
; Entry: STMT_PTR points past "SAVE" keyword, at the filename
; =====================================================================
CMD_SAVE:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '"'
                JP      NZ, SAVE_NQ
                ; Extract filename into SYSCALL_BUFFER+1
                INC     HL              ; skip opening quote
                LD      DE, SYSCALL_BUFFER+1
SAVE_FNAME:
                LD      A, (HL)
                OR      A
                JP      Z, SAVE_NCLOSE
                CP      '"'
                JR      Z, SAVE_FEND
                LD      (DE), A
                INC     HL
                INC     DE
                JR      SAVE_FNAME
SAVE_FEND:
                LD      A, 0
                LD      (DE), A         ; null-terminate filename
                INC     HL
                LD      (STMT_PTR), HL
                ; Open file for writing
                LD      A, SYS_FILE_WOPEN
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, SAVE_OPENED
                LD      HL, ERR_DISK_WRITE
                CALL    PRINT_ERROR
                RET
SAVE_OPENED:
                ; Walk program and write each line
                LD      HL, PROG_BASE
SAVE_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, SAVE_LINE
                PUSH    HL
                INC     HL
                LD      A, (HL)
                POP     HL
                CP      0xFF
                JR      Z, SAVE_DONE
SAVE_LINE:
                ; Read line number (big-endian)
                LD      D, (HL)
                INC     HL
                LD      E, (HL)
                INC     HL
                ; Save text len and pointer
                LD      A, (HL)         ; text length
                INC     HL
                ; HL now points at source text
                ; We need to build the output line in SYSCALL_BUFFER+1:
                ;   "linenum text\0"
                ; Where `text` is the LIST-canonical form of the
                ; source: keywords uppercased, variables and string
                ; literals preserved verbatim. We reuse exactly the
                ; same canonicalisation path as LIST/RENUM by routing
                ; PRINT_NORMALIZED's output through OUT_CHAR_TARG to
                ; SAVE_WRITER, which appends each byte to the buffer
                ; tracked in SAVE_BUF_PTR.
                PUSH    HL              ; save text pointer
                ; Convert line number DE to decimal in SYSCALL_BUFFER+1
                LD      HL, SYSCALL_BUFFER+1
                CALL    UINT16_TO_STR   ; writes decimal at (HL), advances HL
                ; Add space
                LD      (HL), ' '
                INC     HL
                ; SAVE_BUF_PTR := HL (where the next char should go)
                LD      (SAVE_BUF_PTR), HL
                ; Install OUT_CHAR_TARG = JP SAVE_WRITER
                LD      A, 0xC3
                LD      (OUT_CHAR_TARG), A
                LD      HL, SAVE_WRITER
                LD      A, L
                LD      (OUT_CHAR_TARG+1), A
                LD      A, H
                LD      (OUT_CHAR_TARG+2), A
                ; Emit canonicalised text bytes via PRINT_NORMALIZED.
                POP     HL              ; HL = source text pointer
                CALL    PRINT_NORMALIZED
                ; PRINT_NORMALIZED has advanced HL one past the null
                ; terminator of the source text. We need the position
                ; of the NEXT line in PROG_BASE for SAVE_LOOP — which
                ; is exactly HL.
                PUSH    HL              ; save next-line pointer
                ; Restore OUT_CHAR_TARG to JP FW_PUTCHAR (default).
                LD      A, 0xC3
                LD      (OUT_CHAR_TARG), A
                LD      HL, FW_PUTCHAR
                LD      A, L
                LD      (OUT_CHAR_TARG+1), A
                LD      A, H
                LD      (OUT_CHAR_TARG+2), A
                ; Null-terminate the assembled output line.
                LD      HL, (SAVE_BUF_PTR)
                LD      (HL), 0
                ; Write the line via syscall
                LD      A, SYS_FILE_WLINE
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                POP     HL              ; HL = next line in program
                JP      SAVE_LOOP

; ── SAVE_WRITER ─────────────────────────────────────────────────────
; Tiny writer used as the OUT_CHAR_TARG target during CMD_SAVE.
; Each call writes A at (SAVE_BUF_PTR) and advances the pointer.
; Preserves all registers seen by the caller (A is the input).
SAVE_WRITER:
                PUSH    HL
                LD      HL, (SAVE_BUF_PTR)
                LD      (HL), A
                INC     HL
                LD      (SAVE_BUF_PTR), HL
                POP     HL
                RET
SAVE_DONE:
                ; Close file
                LD      A, SYS_FILE_WCLOSE
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                LD      HL, MSG_SAVED
                CALL    FW_PRINT
                RET
SAVE_NQ:
                LD      HL, ERR_FILENAME
                CALL    PRINT_ERROR
                RET
SAVE_NCLOSE:
                LD      HL, ERR_FILENAME
                CALL    PRINT_ERROR
                RET

; =====================================================================
; UINT16_TO_STR — Convert DE to decimal ASCII at (HL), advance HL
; Destroys: A, BC, DE (DE=0 on exit)
; =====================================================================
UINT16_TO_STR:
                ; Use a small stack of digits
                PUSH    IX
                LD      IX, SCRATCH+40  ; temp digit buffer (up to 5 digits)
                LD      B, 0            ; digit count
                LD      A, D
                OR      E
                JR      NZ, UTS_DLOOP
                ; Zero case
                LD      (HL), '0'
                INC     HL
                POP     IX
                RET
UTS_DLOOP:
                LD      A, D
                OR      E
                JR      Z, UTS_COPY
                ; DE / 10 -> quotient in DE, remainder in A
                PUSH    HL
                PUSH    BC
                LD      B, D
                LD      C, E
                LD      DE, 10
                CALL    DIV16_U         ; DE=quotient, HL=remainder
                LD      A, L
                ADD     A, '0'
                POP     BC
                POP     HL
                LD      (IX+0), A
                INC     IX
                INC     B
                JR      UTS_DLOOP
UTS_COPY:
                ; Digits are in reverse order at SCRATCH+40..SCRATCH+40+B-1
                ; Copy them in reverse to (HL)
                DEC     IX
                LD      A, (IX+0)
                LD      (HL), A
                INC     HL
                DJNZ    UTS_COPY
                POP     IX
                RET

; =====================================================================
; CMD_WD — Change working directory
; Entry: STMT_PTR points at the quoted path
; =====================================================================
CMD_WD:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '"'
                JR      NZ, WD_NQ
                ; Extract path into SYSCALL_BUFFER+1
                INC     HL
                LD      DE, SYSCALL_BUFFER+1
WD_PATH:
                LD      A, (HL)
                OR      A
                JR      Z, WD_NCLOSE
                CP      '"'
                JR      Z, WD_PEND
                LD      (DE), A
                INC     HL
                INC     DE
                JR      WD_PATH
WD_PEND:
                LD      A, 0
                LD      (DE), A
                ; Issue syscall
                LD      A, SYS_CHDIR
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, WD_OK
                LD      HL, ERR_BAD_PATH
                CALL    PRINT_ERROR
                RET
WD_OK:
                ; Print new CWD for confirmation
                ; The Python side wrote the new path to SYSCALL_BUFFER+1
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                LD      HL, SYSCALL_BUFFER+1
                CALL    FW_PRINT
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                RET
WD_NQ:
                ; No quotes — send empty string to trigger directory picker
                LD      A, 0
                LD      (SYSCALL_BUFFER+1), A   ; empty filename
                LD      A, SYS_CHDIR
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, WD_OK
                LD      HL, MSG_CANCELLED
                CALL    FW_PRINT
                RET
WD_NCLOSE:
                LD      HL, ERR_FILENAME
                CALL    PRINT_ERROR
                RET

; =====================================================================
; CMD_PWD — Print working directory
; =====================================================================
CMD_PWD:
                LD      A, SYS_GETCWD
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, PWD_OK
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                RET
PWD_OK:
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                LD      HL, SYSCALL_BUFFER+1
                CALL    FW_PRINT
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                RET

; =====================================================================
; CMD_DIR — List .bas and .bin files in working directory
;
; Uses iterative directory API:
;   SYS_DIR_FIRST — begin iteration, returns first filename
;   SYS_DIR_NEXT  — returns next filename
;
; Each syscall places one null-terminated filename at SYSCALL_BUFFER+1.
; SYSCALL_BUFFER[0] = SYS_OK  if a filename was returned,
; SYSCALL_BUFFER[0] = SYS_ERR if no more files (end of listing).
; =====================================================================
CMD_DIR:
                ; Print leading CR+LF
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                ; Begin directory iteration
                LD      A, SYS_DIR_FIRST
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                ; Check result
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, DIR_PRINT
                ; SYS_ERR on first call = empty directory or error
                CP      SYS_ERR
                RET     Z               ; empty listing — done silently
                ; Any other error
                LD      HL, ERR_BAD_PATH
                CALL    PRINT_ERROR
                RET
DIR_PRINT:
                ; Print the filename at SYSCALL_BUFFER+1
                LD      HL, SYSCALL_BUFFER+1
DIR_PCHAR:
                LD      A, (HL)
                OR      A
                JR      Z, DIR_NL       ; end of this filename
                CALL    FW_PUTCHAR
                INC     HL
                JR      DIR_PCHAR
DIR_NL:
                ; Print CR+LF after filename
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                ; Request next filename
                LD      A, SYS_DIR_NEXT
                LD      (SYSCALL_BUFFER), A
                LD      A, 1
                OUT     (CTRL_PORT), A
                ; Check result
                LD      A, (SYSCALL_BUFFER)
                CP      SYS_OK
                JR      Z, DIR_PRINT    ; got another filename
                RET                     ; SYS_ERR = end of listing

; =====================================================================
; SKIP_KW_WD — Skip past "WD" keyword to argument
; =====================================================================
SKIP_KW_WD:
                LD      HL, INPUT_BUF
                CALL    SKIP_SPACES
SKWD1:
                LD      A, (HL)
                OR      A
                RET     Z
                CP      ' '
                JR      Z, SKWD2
                INC     HL
                JR      SKWD1
SKWD2:
                CALL    SKIP_SPACES
                LD      (STMT_PTR), HL
                RET

SKIP_KW_LOAD:
                LD      HL, INPUT_BUF
                CALL    SKIP_SPACES
SKL1:
                LD      A, (HL)
                OR      A
                RET     Z
                CP      ' '
                JR      Z, SKL2
                INC     HL
                JR      SKL1
SKL2:
                CALL    SKIP_SPACES
                LD      (STMT_PTR), HL
                RET

SKIP_KW_SAVE:
                LD      HL, INPUT_BUF
                CALL    SKIP_SPACES
SKS1:
                LD      A, (HL)
                OR      A
                RET     Z
                CP      ' '
                JR      Z, SKS2
                INC     HL
                JR      SKS1
SKS2:
                CALL    SKIP_SPACES
                LD      (STMT_PTR), HL
                RET

; Loop stack operations
PUSH_LOOP_FOR:
                LD      A, (LOOP_SP)
                CP      MAX_LOOPS
                JP      NC, LOOP_OVERFLOW
                CALL    GET_LOOP_TOP
                LD      (IX+0), LOOP_FOR
                LD      A, (SCRATCH)
                LD      (IX+1), A
                LD      (IX+2), C
                LD      (IX+3), B
                LD      A, (SCRATCH+2)
                LD      (IX+4), A
                LD      A, (SCRATCH+3)
                LD      (IX+5), A
                LD      HL, (EXEC_PTR)
                LD      A, (HL)
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      C, A
                LD      B, 0
                ADD     HL, BC
                INC     HL
                LD      (IX+6), L
                LD      (IX+7), H
                LD      A, (IX+2)
                LD      (SCRATCH+4), A
                LD      A, (IX+3)
                LD      (SCRATCH+5), A
                LD      A, (LOOP_SP)
                INC     A
                LD      (LOOP_SP), A
                RET

PUSH_LOOP_WHILE:
                LD      A, (LOOP_SP)
                CP      MAX_LOOPS
                JP      NC, LOOP_OVERFLOW
                CALL    GET_LOOP_TOP
                LD      (IX+0), LOOP_WHILE
                LD      HL, (EXEC_PTR)
                LD      (IX+6), L
                LD      (IX+7), H
                ; Store condition text pointer for re-evaluation by NEXT
                LD      HL, (SCRATCH+12)
                LD      (IX+8), L
                LD      (IX+9), H
                LD      A, (LOOP_SP)
                INC     A
                LD      (LOOP_SP), A
                RET

PUSH_LOOP_REPEAT:
                LD      A, (LOOP_SP)
                CP      MAX_LOOPS
                JP      NC, LOOP_OVERFLOW
                CALL    GET_LOOP_TOP
                LD      (IX+0), LOOP_REPEAT
                LD      HL, (EXEC_PTR)
                LD      A, (HL)
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      C, A
                LD      B, 0
                ADD     HL, BC
                INC     HL
                LD      (IX+6), L
                LD      (IX+7), H
                LD      A, (LOOP_SP)
                INC     A
                LD      (LOOP_SP), A
                RET

PUSH_LOOP_LOOP:
                LD      A, (LOOP_SP)
                CP      MAX_LOOPS
                JP      NC, LOOP_OVERFLOW
                CALL    GET_LOOP_TOP
                LD      (IX+0), LOOP_LOOP
                LD      HL, (EXEC_PTR)
                LD      A, (HL)
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      C, A
                LD      B, 0
                ADD     HL, BC
                INC     HL
                LD      (IX+6), L
                LD      (IX+7), H
                LD      A, (LOOP_SP)
                INC     A
                LD      (LOOP_SP), A
                RET

GET_LOOP_TOP:
                LD      A, (LOOP_SP)
                LD      L, A
                LD      H, 0
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                LD      DE, LOOP_STACK
                ADD     HL, DE
                PUSH    HL
                POP     IX
                RET

PEEK_LOOP:
                LD      A, (LOOP_SP)
                DEC     A
                LD      L, A
                LD      H, 0
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                ADD     HL, HL
                LD      DE, LOOP_STACK
                ADD     HL, DE
                PUSH    HL
                POP     IX
                RET

POP_LOOP:
                LD      A, (LOOP_SP)
                OR      A
                RET     Z
                DEC     A
                LD      (LOOP_SP), A
                CALL    GET_LOOP_TOP
                LD      B, LOOP_ENTRY_SIZE
PL_CLR:
                LD      (IX+0), 0
                INC     IX
                DJNZ    PL_CLR
                RET

LOOP_OVERFLOW:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

; Forward scan routines — all use SCRATCH+30 for depth
; and SCRATCH+31 (16-bit) for saved line header address.
; No stack operations for state preservation.

FIND_MATCH_NEXT:
                LD      HL, (EXEC_PTR)
                LD      A, 1
                LD      (SCRATCH+30), A
                CALL    SKIP_PROG_LINE
FMNX_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, FMNX_CHK
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      0xFF
                JR      Z, FMNX_ERR
FMNX_CHK:
                LD      (SCRATCH+31), HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_FOR
                CALL    KEYWORD_CMP_AT
                JR      NZ, FMNX_CN
                LD      A, (SCRATCH+30)
                INC     A
                LD      (SCRATCH+30), A
FMNX_CN:
                LD      HL, (SCRATCH+31)
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_NEXT
                CALL    KEYWORD_CMP_AT
                JR      NZ, FMNX_NXT
                LD      A, (SCRATCH+30)
                DEC     A
                LD      (SCRATCH+30), A
                JR      Z, FMNX_FND
FMNX_NXT:
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                JR      FMNX_LOOP
FMNX_FND:
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
FMNX_ERR:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

FIND_MATCH_WEND:
                LD      HL, (EXEC_PTR)
                LD      A, 1
                LD      (SCRATCH+30), A
                CALL    SKIP_PROG_LINE
FMWD_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, FMWD_CHK
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      0xFF
                JR      Z, FMWD_ERR
FMWD_CHK:
                LD      (SCRATCH+31), HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_WHILE
                CALL    KEYWORD_CMP_AT
                JR      NZ, FMWD_CW
                LD      A, (SCRATCH+30)
                INC     A
                LD      (SCRATCH+30), A
FMWD_CW:
                LD      HL, (SCRATCH+31)
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_WEND
                CALL    KEYWORD_CMP_AT
                JR      NZ, FMWD_NXT
                LD      A, (SCRATCH+30)
                DEC     A
                LD      (SCRATCH+30), A
                JR      Z, FMWD_FND
FMWD_NXT:
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                JR      FMWD_LOOP
FMWD_FND:
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
FMWD_ERR:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

FIND_MATCH_UNTIL:
                LD      HL, (EXEC_PTR)
                LD      A, 1
                LD      (SCRATCH+30), A
                CALL    SKIP_PROG_LINE
FMUT_LOOP:
                LD      A, (HL)
                CP      0xFF
                JR      NZ, FMUT_CHK
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      0xFF
                JR      Z, FMUT_ERR
FMUT_CHK:
                LD      (SCRATCH+31), HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_REPEAT
                CALL    KEYWORD_CMP_AT
                JR      NZ, FMUT_CU
                LD      A, (SCRATCH+30)
                INC     A
                LD      (SCRATCH+30), A
FMUT_CU:
                LD      HL, (SCRATCH+31)
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_UNTIL
                CALL    KEYWORD_CMP_AT
                JR      NZ, FMUT_NXT
                LD      A, (SCRATCH+30)
                DEC     A
                LD      (SCRATCH+30), A
                JR      Z, FMUT_FND
FMUT_NXT:
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                JR      FMUT_LOOP
FMUT_FND:
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
FMUT_ERR:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

FIND_MATCH_ENDLP:
                LD      HL, (EXEC_PTR)
                LD      A, 1
                LD      (SCRATCH+30), A     ; nesting depth in SCRATCH+30
                ; Skip current line (the one containing BREAK)
                CALL    SKIP_PROG_LINE
FME_LOOP:
                ; Check end marker FIRST
                LD      A, (HL)
                CP      0xFF
                JR      NZ, FME_CHECK
                INC     HL
                LD      A, (HL)
                DEC     HL
                CP      0xFF
                JR      Z, FME_ERR
FME_CHECK:
                ; Save line header address
                LD      (SCRATCH+31), HL    ; 31-32 = line header (16-bit)
                ; Point to text: skip line# (2) + length (1)
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES

                ; --- Check for "LOOP" keyword (increases nesting) ---
                LD      DE, KW_LOOP_KW
                CALL    KEYWORD_CMP_AT
                JR      NZ, FME_CHKEL
                ; Matched LOOP — increase depth
                LD      A, (SCRATCH+30)
                INC     A
                LD      (SCRATCH+30), A

FME_CHKEL:
                ; Reload text pointer for ENDLOOP check
                LD      HL, (SCRATCH+31)
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES

                ; --- Check for "ENDLOOP" keyword (decreases nesting) ---
                LD      DE, KW_ENDLOOP
                CALL    KEYWORD_CMP_AT
                JR      NZ, FME_NEXT
                ; Matched ENDLOOP — decrease depth
                LD      A, (SCRATCH+30)
                DEC     A
                LD      (SCRATCH+30), A
                JR      Z, FME_FOUND

FME_NEXT:
                ; Not matched or depth not zero — advance to next line
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                JR      FME_LOOP

FME_FOUND:
                ; Matched ENDLOOP at depth 0
                LD      HL, (SCRATCH+31)
                CALL    SKIP_PROG_LINE
                LD      (EXEC_PTR), HL
                LD      A, 1
                LD      (PC_CHANGED), A
                RET
FME_ERR:
                LD      HL, ERR_SYNTAX
                CALL    PRINT_ERROR
                XOR     A
                LD      (RUN_FLAG), A
                RET

SKIP_PROG_LINE:
                INC     HL
                INC     HL
                LD      A, (HL)
                INC     HL
                LD      C, A
                LD      B, 0
                ADD     HL, BC
                INC     HL
                RET

LINE_HAS_FOR:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_FOR
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET
LINE_HAS_NEXT:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_NEXT
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET
LINE_HAS_WHILE:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_WHILE
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET
LINE_HAS_WEND:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_WEND
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET
LINE_HAS_REPEAT:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_REPEAT
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET
LINE_HAS_UNTIL:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_UNTIL
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET
LINE_HAS_LOOPKW:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_LOOP_KW
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET
LINE_HAS_ENDLP:
                PUSH    HL
                INC     HL
                INC     HL
                INC     HL
                CALL    SKIP_SPACES
                LD      DE, KW_ENDLOOP
                CALL    KEYWORD_CMP_AT
                POP     HL
                RET

; Utility
SKIP_SPACES:
                LD      A, (HL)
                CP      ' '
                RET     NZ
                INC     HL
                JR      SKIP_SPACES

; IS_DIGIT: returns carry set if (HL) is '0'-'9', carry clear otherwise
IS_DIGIT:
                LD      A, (HL)
                CP      '0'
                JR      C, ISDIG_NO     ; A < '0' — not a digit
                CP      '9'+1
                RET                     ; carry set if A <= '9' (digit), clear if A > '9'
ISDIG_NO:
                OR      A               ; clear carry
                RET

TO_UPPER:
                CP      'a'
                RET     C
                CP      'z'+1
                RET     NC
                SUB     32
                RET

PARSE_NUMBER:
                LD      DE, 0
PNUM_LOOP:
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
                JR      PNUM_LOOP

PARSE_SIGNED_NUM:
                CALL    SKIP_SPACES
                LD      A, (HL)
                CP      '-'
                JR      NZ, PSN_POS
                INC     HL
                CALL    PARSE_NUMBER
                PUSH    HL
                LD      H, D
                LD      L, E
                LD      DE, 0
                EX      DE, HL
                OR      A
                SBC     HL, DE
                EX      DE, HL
                POP     HL
                RET
PSN_POS:
                CALL    PARSE_NUMBER
                RET

PRINT_INT16:
                BIT     7, D
                JR      Z, PRINT_UINT16
                PUSH    DE
                LD      A, '-'
                CALL    FW_PUTCHAR
                POP     DE
                PUSH    HL
                LD      H, D
                LD      L, E
                LD      DE, 0
                EX      DE, HL
                OR      A
                SBC     HL, DE
                EX      DE, HL
                POP     HL
PRINT_UINT16:
                PUSH    HL
                PUSH    BC
                LD      HL, SCRATCH + 30
                LD      (HL), 0
                DEC     HL
                LD      A, D
                OR      E
                JR      NZ, PU_LOOP
                LD      (HL), '0'
                JR      PU_PRINT
PU_LOOP:
                LD      A, D
                OR      E
                JR      Z, PU_PRINT
                PUSH    HL
                ; DIV16_U: BC / DE -> DE=quotient, HL=remainder
                ; We need: number(DE) / 10 -> quotient, remainder
                ; So: BC = number, DE = 10
                LD      B, D
                LD      C, E
                LD      DE, 10
                CALL    DIV16_U
                ; DE = quotient (number / 10), HL = remainder (digit)
                LD      A, L
                ADD     A, '0'
                POP     HL
                LD      (HL), A
                DEC     HL
                JR      PU_LOOP
PU_PRINT:
                INC     HL
                CALL    FW_PRINT
                POP     BC
                POP     HL
                RET

; 16-bit math
MUL16:
                PUSH    HL
                LD      HL, 0
                LD      A, 16
M16_LOOP:
                ADD     HL, HL
                EX      DE, HL
                ADD     HL, HL
                EX      DE, HL
                JR      NC, M16_SKIP
                ADD     HL, BC
M16_SKIP:
                DEC     A
                JR      NZ, M16_LOOP
                EX      DE, HL
                POP     HL
                RET

DIV16:
                LD      A, B
                XOR     D
                PUSH    AF
                BIT     7, B
                JR      Z, D16_BCPOS
                PUSH    DE
                LD      H, B
                LD      L, C
                LD      DE, 0
                EX      DE, HL
                OR      A
                SBC     HL, DE
                LD      B, H
                LD      C, L
                POP     DE
D16_BCPOS:
                BIT     7, D
                JR      Z, D16_DEPOS
                PUSH    BC
                LD      H, D
                LD      L, E
                LD      DE, 0
                EX      DE, HL
                OR      A
                SBC     HL, DE
                EX      DE, HL
                POP     BC
D16_DEPOS:
                CALL    DIV16_U
                POP     AF
                BIT     7, A
                RET     Z
                PUSH    HL
                LD      H, D
                LD      L, E
                LD      DE, 0
                EX      DE, HL
                OR      A
                SBC     HL, DE
                EX      DE, HL
                POP     HL
                RET

DIV16_U:
                LD      HL, 0
                LD      A, 16
D16U_LOOP:
                SLA     C
                RL      B
                RL      L
                RL      H
                PUSH    HL
                OR      A
                SBC     HL, DE
                JR      C, D16U_NOSUB
                ; Subtraction succeeded — keep new HL, discard old
                INC     SP              ; discard old HL from stack
                INC     SP              ; without touching A
                SET     0, C
                JR      D16U_CONT
D16U_NOSUB:
                POP     HL              ; restore old HL (subtraction failed)
D16U_CONT:
                DEC     A
                JR      NZ, D16U_LOOP
                LD      D, B
                LD      E, C
                RET

SIGNED_CMP_BC_DE:
                LD      A, B
                XOR     D
                AND     0x80
                JR      NZ, SCMP_DIFF
                LD      A, B
                CP      D
                RET     NZ
                LD      A, C
                CP      E
                RET
SCMP_DIFF:
                BIT     7, B
                JR      NZ, SCMP_BCNEG
                OR      A
                LD      A, 1
                OR      A
                RET
SCMP_BCNEG:
                SCF
                RET

SIGNED_CMP_DE_BC:
                PUSH    HL
                PUSH    DE
                PUSH    BC
                POP     DE
                POP     BC
                CALL    SIGNED_CMP_BC_DE
                POP     HL
                RET

; ── String variable helpers ──

; GET_SVAR_ADDR: A = var index (0=A..25=Z)
; Returns DE = address of 32-byte string buffer
GET_SVAR_ADDR:
                PUSH    HL
                LD      L, A
                LD      H, 0
                ; Multiply by 32: shift left 5 times
                ADD     HL, HL          ; x2
                ADD     HL, HL          ; x4
                ADD     HL, HL          ; x8
                ADD     HL, HL          ; x16
                ADD     HL, HL          ; x32
                LD      DE, SVAR_BASE
                ADD     HL, DE
                EX      DE, HL          ; DE = SVAR_BASE + index*32
                POP     HL
                RET

; CLEAR_SVAR_ALL: Zero all 26 string variable buffers (832 bytes)
CLEAR_SVAR_ALL:
                PUSH    HL
                PUSH    BC
                LD      HL, SVAR_BASE
                LD      BC, 832         ; 26 * 32
CSVA_LOOP:
                LD      (HL), 0
                INC     HL
                DEC     BC
                LD      A, B
                OR      C
                JR      NZ, CSVA_LOOP
                POP     BC
                POP     HL
                RET

; Keyword matching
; Case-insensitive keyword match with word boundary:
; HL=keyword (uppercase, null-terminated), DE=user text
; Returns Z if keyword matches at start of user text,
; followed by null, space, or non-alpha character.
KEYWORD_MATCH:
                PUSH    HL
                PUSH    DE
KM_LOOP:
                LD      A, (HL)
                OR      A
                JR      Z, KM_KWEND
                LD      B, A
                LD      A, (DE)
                CALL    TO_UPPER
                CP      B
                JR      NZ, KM_FAIL
                INC     HL
                INC     DE
                JR      KM_LOOP
KM_KWEND:
                LD      A, (DE)
                OR      A
                JR      Z, KM_OK
                CP      ' '
                JR      Z, KM_OK
                CALL    TO_UPPER
                CP      'A'
                JR      C, KM_OK
                CP      'Z'+1
                JR      NC, KM_OK
                JR      KM_FAIL
KM_OK:
                POP     DE
                POP     HL
                XOR     A
                RET
KM_FAIL:
                POP     DE
                POP     HL
                LD      A, 1
                OR      A
                RET

KEYWORD_MATCH_PREFIX:
                PUSH    HL
                PUSH    DE
KMP_LOOP:
                LD      A, (HL)
                OR      A
                JR      Z, KMP_OK
                LD      B, A
                LD      A, (DE)
                CALL    TO_UPPER
                CP      B
                JR      NZ, KMP_FAIL
                INC     HL
                INC     DE
                JR      KMP_LOOP
KMP_OK:
                POP     DE
                POP     HL
                XOR     A
                RET
KMP_FAIL:
                POP     DE
                POP     HL
                LD      A, 1
                OR      A
                RET

TRY_KEYWORD:
                LD      HL, (STMT_PTR)
                CALL    SKIP_SPACES
TK_LOOP:
                LD      A, (DE)
                OR      A
                JR      Z, TK_MATCH
                LD      B, A
                LD      A, (HL)
                CALL    TO_UPPER
                CP      B
                JR      NZ, TK_FAIL
                INC     HL
                INC     DE
                JR      TK_LOOP
TK_MATCH:
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'A'
                JR      C, TK_OK
                CP      'Z'+1
                JR      C, TK_FAIL
TK_OK:
                CALL    SKIP_SPACES
                LD      (STMT_PTR), HL
                XOR     A
                RET
TK_FAIL:
                LD      A, 1
                OR      A
                RET

TRY_KW_AT_HL:
                CALL    SKIP_SPACES
TKAH_LOOP:
                LD      A, (DE)
                OR      A
                JR      Z, TKAH_MATCH
                LD      B, A
                LD      A, (HL)
                CALL    TO_UPPER
                CP      B
                JR      NZ, TKAH_FAIL
                INC     HL
                INC     DE
                JR      TKAH_LOOP
TKAH_MATCH:
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'A'
                JR      C, TKAH_OK
                CP      'Z'+1
                JR      C, TKAH_FAIL
TKAH_OK:
                CALL    SKIP_SPACES
                XOR     A
                RET
TKAH_FAIL:
                LD      A, 1
                OR      A
                RET

KEYWORD_CMP_AT:
                PUSH    HL
                PUSH    DE
KCA_LOOP:
                LD      A, (DE)
                OR      A
                JR      Z, KCA_MATCH
                LD      B, A
                LD      A, (HL)
                CALL    TO_UPPER
                CP      B
                JR      NZ, KCA_FAIL
                INC     HL
                INC     DE
                JR      KCA_LOOP
KCA_MATCH:
                LD      A, (HL)
                CALL    TO_UPPER
                CP      'A'
                JR      C, KCA_OK
                CP      'Z'+1
                JR      C, KCA_FAIL
KCA_OK:
                POP     DE
                POP     HL
                XOR     A               ; A=0, Z=1 (match)
                RET
KCA_FAIL:
                POP     DE
                POP     HL
                LD      A, 1
                OR      A               ; Z=0 (no match)
                RET

; Error reporting
PRINT_ERROR:
                PUSH    HL
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                POP     HL
                CALL    FW_PRINT
                LD      A, (EXEC_MODE)
                OR      A
                RET     Z
                PUSH    HL
                LD      HL, MSG_IN_LINE
                CALL    FW_PRINT
                LD      DE, (CURRENT_LINE)
                CALL    PRINT_UINT16
                LD      A, 0x0D
                CALL    FW_PUTCHAR
                LD      A, 0x0A
                CALL    FW_PUTCHAR
                POP     HL
                RET

; Data
KW_EXIT:        DB      "EXIT", 0
KW_RUN:         DB      "RUN", 0
KW_LIST:        DB      "LIST", 0
KW_NEW:         DB      "NEW", 0
KW_CLS:         DB      "CLS", 0
KW_RENUM:       DB      "RENUM", 0
KW_LOAD:        DB      "LOAD", 0
KW_SAVE:        DB      "SAVE", 0
KW_WD:          DB      "WD", 0
KW_PWD:         DB      "PWD", 0
KW_DIR:         DB      "DIR", 0
KW_PRINT:       DB      "PRINT", 0
KW_INPUT:       DB      "INPUT", 0
KW_LET:         DB      "LET", 0
KW_IF:          DB      "IF", 0
KW_THEN:        DB      "THEN", 0
KW_FOR:         DB      "FOR", 0
KW_TO:          DB      "TO", 0
KW_STEP:        DB      "STEP", 0
KW_NEXT:        DB      "NEXT", 0
KW_WHILE:       DB      "WHILE", 0
KW_WEND:        DB      "WEND", 0
KW_REPEAT:      DB      "REPEAT", 0
KW_UNTIL:       DB      "UNTIL", 0
KW_LOOP_KW:     DB      "LOOP", 0
KW_ENDLOOP:     DB      "ENDLOOP", 0
KW_BREAK:       DB      "BREAK", 0
KW_STOP:        DB      "STOP", 0
KW_REM:         DB      "REM", 0
KW_GOTO:        DB      "GOTO", 0

MSG_READY:      DB      0x0D, 0x0A, "READY.", 0x0D, 0x0A, 0
MSG_IN_LINE:    DB      " in line ", 0
MSG_NOT_IMPL:   DB      0x0D, 0x0A, "Not implemented", 0x0D, 0x0A, 0
MSG_STOPPED:    DB      "Program stopped at line ", 0

ERR_SYNTAX:     DB      "Syntax error", 0
ERR_STEP_ZERO:  DB      "FOR step cannot be zero", 0
ERR_NEXT_NO_FOR:
                DB      "NEXT without FOR", 0
ERR_NEXT_MISMATCH:
                DB      "Mismatched NEXT variable", 0
ERR_WEND_NO_WHILE:
                DB      "WEND without WHILE", 0
ERR_UNTIL_NO_REPEAT:
                DB      "UNTIL without REPEAT", 0
ERR_ENDLOOP_NO_LOOP:
                DB      "ENDLOOP without LOOP", 0
ERR_BREAK_NO_LOOP:
                DB      "BREAK without active loop", 0
ERR_GOTO_NOLINE:
                DB      "GOTO target line not found", 0
MSG_RENUM_WARN:
                DB      0x0D, 0x0A, "Warning: GOTO target ", 0
MSG_RENUM_WARN2:
                DB      " not found (left as-is)", 0x0D, 0x0A, 0
ERR_FILENAME:   DB      "Filename must be in quotes", 0
ERR_FILE_NOT_FOUND:
                DB      "File not found", 0
ERR_BAD_EXT:    DB      "Unsupported extension (use .bas, .txt, or .bin)", 0
ERR_BAD_PATH:   DB      "Invalid path", 0
ERR_DISK_WRITE: DB      "Disk write error", 0
MSG_LOADED:     DB      0x0D, 0x0A, "Loaded.", 0x0D, 0x0A, 0
MSG_BIN_LOADED: DB      0x0D, 0x0A, "Binary loaded at C000h.", 0x0D, 0x0A, 0
MSG_SAVED:      DB      0x0D, 0x0A, "Saved.", 0x0D, 0x0A, 0
MSG_CANCELLED:  DB      0x0D, 0x0A, "Cancelled.", 0x0D, 0x0A, 0

; RAM variables
EXEC_PTR:       DW      0
STMT_PTR:       DW      0
CURRENT_LINE:   DW      0
EXEC_MODE:      DB      0
RUN_FLAG:       DB      0
PC_CHANGED:     DB      0
LOOP_SP:        DB      0
LOAD_TYPE:      DB      0xFF    ; outcome of last CMD_LOAD:
                                ; 0xFF=no load yet/error, 0=text, 1=bin

; ═══════════════════════════════════════════════════════════════════════
; FW_SCREEN_EDIT — BASIC Command-Prompt Screen Editor
; ═══════════════════════════════════════════════════════════════════════
;
; Spec: Z80yPico BASIC Editor Specification v1.1
;
; Called from BASIC_MAIN.  Same return contract as FW_INPUTLINE:
;   returns with null-terminated line at 0x7F00,
;   cursor OFF, CR/LF already output.
;
; FSM modes:
;   PromptEdit      — editing live input buffer (B/C)
;   ListNavigation  — selecting a listed line via NAV_ROW
;   PickedLineEdit  — editing a picked-up line (handled by FW_INPUTLINE)
;
; FW_INPUTLINE.bin is NOT modified.
; FW_INPUTLINE internal entry points used:
;   0x0014 = key dispatch (A=key, D=key, B=length, C=cursor)
;   0x00B1 = ENTER handler (null-term, CR/LF, cursor OFF, RET)
;
; ═══════════════════════════════════════════════════════════════════════

FW_SCREEN_EDIT:
                ; ── Mode A: PromptEdit — Initialization ──
                ; Mirrors FW_INPUTLINE init (0x0003–0x000D).
                LD      A, 0x0E         ; cursor ON
                OUT     (1), A
                LD      BC, 0x0000      ; B=length=0, C=cursor=0
                XOR     A
                LD      (INPUT_BUF), A  ; clear buffer[0]

; ─────────────────────────────────────────────────────────────────────
; MODE A — PromptEdit
; ─────────────────────────────────────────────────────────────────────
; The user is editing the live prompt line.
; B = buffer length, C = cursor position.
; All arrow keys are handled here to keep control in FSE_LOOP.
; Non-arrow keys are handed to FW_INPUTLINE via JP 0x0014.
; UP on empty buffer + LIST_ACTIVE → transitions to Mode B.

FSE_LOOP:
                PUSH    BC
                CALL    FW_GETKEY       ; A = key
                POP     BC

                ; ── Intercept all arrow keys ──
                CP      0x01            ; LEFT?
                JR      Z, FSE_LEFT
                CP      0x02            ; RIGHT?
                JR      Z, FSE_RIGHT
                CP      0x03            ; UP?
                JR      Z, FSE_CHK_UP
                CP      0x04            ; DOWN?
                JR      Z, FSE_CHK_DN

                ; ── Non-arrow key → FW_INPUTLINE dispatch ──
                ; Enters Mode C (PickedLineEdit) if buffer was pre-filled,
                ; or continues PromptEdit for fresh typing.
                ; FW_INPUTLINE loops internally and RETs on ENTER.
                LD      D, A            ; D = A (INSERT uses D)
                JP      0x0014

; ── LEFT in PromptEdit ──
FSE_LEFT:
                LD      A, C
                OR      A
                JR      Z, FSE_LOOP     ; at start → no move
                DEC     C
                LD      A, 0x08         ; BS
                OUT     (1), A
                JR      FSE_LOOP

; ── RIGHT in PromptEdit ──
FSE_RIGHT:
                LD      A, C
                CP      B
                JR      NC, FSE_LOOP    ; at end → no move
                INC     C
                LD      A, 0x09         ; cursor right
                OUT     (1), A
                JR      FSE_LOOP

; ── UP in PromptEdit ──
; If buffer is empty AND LIST region is valid → Mode B.
; Otherwise → ignored (no free cursor movement).
FSE_CHK_UP:
                LD      A, B
                OR      A
                JR      NZ, FSE_LOOP    ; buffer not empty → ignore UP
                LD      A, (LIST_ACTIVE)
                OR      A
                JR      Z, FSE_LOOP     ; no LIST region → ignore UP
                ; ── Transition to Mode B: ListNavigation ──
                LD      A, (LIST_BOT_ROW)
                LD      (NAV_ROW), A    ; start at bottom of LIST
                CALL    FSE_GOTO_NAV_ROW
                JR      FSE_NAV_LOOP

; ── DOWN in PromptEdit ──
; Never enters navigation. Ignored entirely.
FSE_CHK_DN:
                JR      FSE_LOOP        ; DOWN is a no-op in PromptEdit

; ─────────────────────────────────────────────────────────────────────
; MODE B — ListNavigation
; ─────────────────────────────────────────────────────────────────────
; The user is selecting a listed line.
; NAV_ROW is the ONLY source of truth for position.
; Cursor is driven by NAV_ROW, never by screen state.
; No LEFT/RIGHT. No free cursor movement.
; Only UP, DOWN, ENTER, ESC, or a printable key (→ pickup).

FSE_NAV_LOOP:
                CALL    FW_GETKEY       ; A = key

                CP      0x03            ; UP?
                JR      Z, FSE_NAV_UP
                CP      0x04            ; DOWN?
                JR      Z, FSE_NAV_DN
                CP      0x1B            ; ESCAPE?
                JR      Z, FSE_NAV_ESC
                CP      0x0A            ; ENTER?
                JR      Z, FSE_NAV_ENT

                ; ── Any other key: pickup + edit (→ Mode C) ──
                LD      D, A            ; save triggering key
                CALL    LINE_PICKUP_FROM_NAVROW
                LD      A, D            ; restore key
                ; D already equals A. Enter FW_INPUTLINE dispatch.
                JP      0x0014          ; → Mode C (PickedLineEdit)

; ── UP in ListNavigation ──
; NAV_ROW = max(NAV_ROW - 1, LIST_TOP_ROW)
FSE_NAV_UP:
                LD      A, (NAV_ROW)
                LD      E, A
                LD      A, (LIST_TOP_ROW)
                CP      E               ; TOP == NAV_ROW?
                JR      Z, FSE_NAV_LOOP ; already at top → no move
                LD      A, E
                DEC     A
                LD      (NAV_ROW), A
                CALL    FSE_GOTO_NAV_ROW
                JR      FSE_NAV_LOOP

; ── DOWN in ListNavigation ──
; NAV_ROW = min(NAV_ROW + 1, LIST_BOT_ROW)
FSE_NAV_DN:
                LD      A, (NAV_ROW)
                LD      E, A
                LD      A, (LIST_BOT_ROW)
                CP      E               ; BOT == NAV_ROW?
                JR      Z, FSE_NAV_LOOP ; already at bottom → no move
                LD      A, E
                INC     A
                LD      (NAV_ROW), A
                CALL    FSE_GOTO_NAV_ROW
                JR      FSE_NAV_LOOP

; ── ENTER in ListNavigation ──
; Pickup the line at NAV_ROW and commit immediately.
FSE_NAV_ENT:
                CALL    LINE_PICKUP_FROM_NAVROW
                JP      0x00B1          ; → FW_INPUTLINE ENTER handler
                                        ;   (null-term, CR/LF, cursor OFF, RET)

; ── ESC in ListNavigation ──
; Return to PromptEdit at the prompt row (LIST_BOT_ROW + 1).
FSE_NAV_ESC:
                LD      A, (LIST_BOT_ROW)
                INC     A               ; prompt row = one below LIST output
                LD      (NAV_ROW), A
                CALL    FSE_GOTO_NAV_ROW
                ; Re-enter PromptEdit with empty buffer
                LD      BC, 0x0000
                XOR     A
                LD      (INPUT_BUF), A
                JP      FSE_LOOP

; ═══════════════════════════════════════════════════════════════════════
; FSE_GOTO_NAV_ROW — Position display cursor at (NAV_ROW, 0)
; ═══════════════════════════════════════════════════════════════════════
;
; Drives the display cursor to the row stored in NAV_ROW, column 0.
; Uses CR to reset column, then UP/DOWN to reach the target row.
; Reads PORT_CUR_ROW to determine the direction and distance.
;
; This is the ONLY routine that moves the display cursor during
; navigation. The cursor is always forced to match NAV_ROW.

FSE_GOTO_NAV_ROW:
                LD      A, 0x0D         ; CR → column 0
                OUT     (1), A
FSE_GOTO_LOOP:
                IN      A, (PORT_CUR_ROW)
                LD      E, A            ; E = current display row
                LD      A, (NAV_ROW)    ; A = target row
                CP      E
                JR      Z, FSE_GOTO_DONE ; reached target
                JR      C, FSE_GOTO_UP   ; target < current → go UP
                ; target > current → go DOWN
                LD      A, 0x04
                OUT     (1), A
                JR      FSE_GOTO_LOOP
FSE_GOTO_UP:
                LD      A, 0x03
                OUT     (1), A
                JR      FSE_GOTO_LOOP
FSE_GOTO_DONE:
                RET

; ═══════════════════════════════════════════════════════════════════════
; LINE_PICKUP_FROM_NAVROW — Read logical line at NAV_ROW from VRAM
; ═══════════════════════════════════════════════════════════════════════
;
; Sets SCRATCH+24 = NAV_ROW, SCRATCH+25 = 0, then shares the
; VRAM reading logic with LINE_PICKUP.
; Returns: B = length, C = 0, buffer at 0x7F00 filled.
; Also positions cursor at start of logical line and redraws.

LINE_PICKUP_FROM_NAVROW:
                LD      A, (NAV_ROW)
                LD      (SCRATCH+24), A         ; row = NAV_ROW
                XOR     A
                LD      (SCRATCH+25), A         ; col = 0
                JR      LP_FIND_START           ; → shared VRAM reading logic

; ═══════════════════════════════════════════════════════════════════════
; LINE_PICKUP — Read the logical line at the cursor from VRAM
; ═══════════════════════════════════════════════════════════════════════
;
; Entry point for cursor-based pickup (used by LINE_PICKUP_FROM_NAVROW
; shares the main body via LP_FIND_START).
;
; Detects wrapped lines by walking backward (full rows = continuation).
; Concatenates all VRAM rows of the logical line into INPUT_BUF.
; Positions the display cursor at the start of the logical line.
; Redraws the buffer inline.
; Returns with B = length, C = 0.
;
; Trashes: A, D, E, H, L, plus SCRATCH+24..SCRATCH+26

LINE_PICKUP:
                IN      A, (PORT_CUR_ROW)
                LD      (SCRATCH+24), A         ; save cursor row
                IN      A, (PORT_CUR_COL)
                LD      (SCRATCH+25), A         ; save cursor col

LP_FIND_START:
                ; ── Find start row of logical line ──
                ; Walk backward: while previous row is full (all 32 cols non-zero)
                LD      A, (SCRATCH+24)
                LD      (SCRATCH+26), A         ; SCRATCH+26 = start_row candidate
LP_BACK:
                LD      A, (SCRATCH+26)
                OR      A
                JR      Z, LP_BACK_DONE         ; row 0, can't go higher
                DEC     A                        ; check row above
                CALL    VRAM_ROW_FULL            ; Z=not full, NZ=full
                JR      Z, LP_BACK_DONE          ; previous row not full → stop
                LD      A, (SCRATCH+26)
                DEC     A
                LD      (SCRATCH+26), A          ; start_row--
                JR      LP_BACK
LP_BACK_DONE:
                ; SCRATCH+26 = start row of logical line

                ; ── Read VRAM rows into INPUT_BUF ──
                LD      A, (SCRATCH+26)
                LD      D, A                     ; D = current row to read
                LD      HL, INPUT_BUF            ; HL = write pointer
                LD      B, 0                     ; B = total chars written

LP_READ_ROW:
                ; Calculate VRAM address for row D
                PUSH    HL
                LD      A, D
                CALL    VRAM_ROW_ADDR            ; HL = VRAM_BASE + D*32
                POP     DE                       ; DE = write pointer (was HL)
                PUSH    DE                       ; save write pointer
                EX      DE, HL                   ; HL = write ptr, DE = VRAM addr
                EX      DE, HL                   ; HL = VRAM addr, DE = write ptr
                LD      C, VRAM_COLS             ; C = 32 columns to read

LP_READ_COL:
                LD      A, (HL)                  ; read VRAM cell
                OR      A
                JR      Z, LP_ROW_END            ; null → end of visible content
                LD      (DE), A                  ; write to buffer
                INC     HL
                INC     DE
                INC     B                        ; length++
                LD      A, B
                CP      126                      ; buffer capacity check
                JR      NC, LP_READ_DONE         ; full → stop
                DEC     C
                JR      NZ, LP_READ_COL

                ; Row was fully read (all 32 cols) → check if next row continues
                POP     HL                       ; discard saved write ptr
                PUSH    DE                       ; save current write ptr
                INC     D                        ; next row
                LD      A, D
                CP      VRAM_ROWS                ; past last row?
                JR      NC, LP_READ_DONE_POP     ; yes → done

                ; Check if next row starts with a digit (new line number)
                LD      A, D
                CALL    VRAM_ROW_ADDR            ; HL = addr of next row
                LD      A, (HL)                  ; first char of next row
                CP      '0'
                JR      C, LP_CONT_ROW           ; < '0' → continuation
                CP      '9'+1
                JR      NC, LP_CONT_ROW          ; > '9' → continuation
                ; Starts with digit → new BASIC line → stop
                JR      LP_READ_DONE_POP

LP_CONT_ROW:
                POP     DE                       ; DE = write pointer
                PUSH    DE                       ; re-save
                EX      DE, HL
                EX      DE, HL
                POP     HL                       ; HL = write pointer
                JR      LP_READ_ROW

LP_ROW_END:
                POP     HL                       ; discard saved write ptr
                JR      LP_READ_STRIP

LP_READ_DONE_POP:
                POP     HL                       ; discard saved write ptr
LP_READ_DONE:
LP_READ_STRIP:
                ; ── Strip trailing spaces ──
                LD      A, B
                OR      A
                JR      Z, LP_STRIPPED
LP_STRIP:
                LD      A, B
                OR      A
                JR      Z, LP_STRIPPED
                DEC     A
                LD      H, 0x7F
                LD      L, A                     ; HL = buf[B-1]
                LD      A, (HL)
                CP      0x20
                JR      NZ, LP_STRIPPED
                DEC     B
                JR      LP_STRIP
LP_STRIPPED:
                ; Null-terminate
                LD      H, 0x7F
                LD      L, B
                LD      (HL), 0x00

                ; ── Position cursor at start of logical line ──
                LD      A, 0x0D                  ; CR → column 0
                OUT     (1), A
                ; Move cursor to start_row (SCRATCH+26)
                IN      A, (PORT_CUR_ROW)
                LD      D, A                     ; D = current row
                LD      A, (SCRATCH+26)
                LD      E, A                     ; E = target start row
LP_MOVEUP:
                LD      A, D
                CP      E
                JR      Z, LP_POSITIONED
                JR      C, LP_POSITIONED         ; already above target
                LD      A, 0x03                  ; cursor up
                OUT     (1), A
                DEC     D
                JR      LP_MOVEUP

LP_POSITIONED:
                ; ── Redraw the picked-up line (inline) ──
                ; C=0 (cursor at start), no backspace needed.
                LD      C, 0
                ; Print B characters from buffer
                PUSH    BC
                LD      A, B
                OR      A
                JR      Z, LP_RD_SPACE
                LD      HL, INPUT_BUF
                LD      E, A
LP_RD_PR:
                LD      A, (HL)
                OUT     (1), A
                INC     HL
                DEC     E
                JR      NZ, LP_RD_PR
LP_RD_SPACE:
                ; Trailing space to erase old content
                LD      A, 0x20
                OUT     (1), A
                POP     BC
                ; Back up (B+1) times to land at start (C=0)
                LD      A, B
                INC     A
                LD      E, A
LP_RD_BS:
                LD      A, 0x08
                OUT     (1), A
                DEC     E
                JR      NZ, LP_RD_BS
                ; C = 0, B = length — ready for editing
                RET

; ═══════════════════════════════════════════════════════════════════════
; VRAM helper routines
; ═══════════════════════════════════════════════════════════════════════

; ── VRAM_ROW_ADDR ──
; Input:  A = row number (0..23)
; Output: HL = VRAM_BASE + row * 32
; Trashes: A, HL
VRAM_ROW_ADDR:
                LD      H, 0
                LD      L, A            ; HL = row
                ADD     HL, HL          ; *2
                ADD     HL, HL          ; *4
                ADD     HL, HL          ; *8
                ADD     HL, HL          ; *16
                ADD     HL, HL          ; *32
                LD      A, H
                ADD     A, 0xD0         ; add high byte of VRAM_BASE (0xD000)
                LD      H, A
                RET                     ; HL = 0xD000 + row*32

; ── VRAM_ROW_FULL ──
; Input:  A = row number (0..23)
; Output: Z flag = row is NOT full (has a zero cell)
;         NZ flag = row IS full (all 32 cells non-zero)
; Trashes: A, HL, C (caller must save if needed)
VRAM_ROW_FULL:
                CALL    VRAM_ROW_ADDR   ; HL = VRAM address of row
                LD      C, VRAM_COLS    ; C = 32
VRF_CHECK:
                LD      A, (HL)
                OR      A
                RET     Z               ; found zero → not full → return Z
                INC     HL
                DEC     C
                JR      NZ, VRF_CHECK
                OR      1               ; force NZ → row is full
                RET

; ═══════════════════════════════════════════════════════════════════════
; TODO / Pending items from spec v1.1:
;
; [PENDING] §4  ENTER creates a new blank line below committed line
; [PENDING] §10 Keyword normalization on ENTER (PRINT, IF, THEN...)
; [PENDING] §11 Delete full line shifts lines up on screen
; [PENDING] §12 Insert/delete visual reflow of wrapped continuations
;
; These require additional screen manipulation routines (scroll
; regions, line insertion/deletion in VRAM) which will be added
; in a future revision.
; ═══════════════════════════════════════════════════════════════════════

BASIC_END:
