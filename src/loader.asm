; ---------------------------------------------------------------------------
;  Pocket8086 CP/M 2.2 - native loader and BIOS back end (NEC V20/V30)
;
;  Loaded at 0800:0000 by the boot sector, DL = boot drive.
;
;  * checks that the CPU is an NEC V20/V30 (8080 emulation mode),
;  * builds a 64K 8080 memory image in segment ESEG (CCP, BDOS, BIOS),
;  * hooks the CALLN vectors used by the 8080 BIOS,
;  * enters 8080 mode with BRKEM.  It never returns.
;
;  While CP/M runs, CS=DS=ES=SS=ESEG.  The native stack (used by CALLN,
;  hardware interrupts and BRKEM itself) lives at ESEG:FE00-FFFF, above
;  the 8080 BIOS.  CALLN handlers switch to a private stack in LSEG.
;
;  Assemble: nasm -f bin -I../build/ loader.asm -o loader.bin
; ---------------------------------------------------------------------------
        bits    16
        cpu     8086
        org     0

%include "layout.inc"           ; NDISKS, SPT, drive tables (from build.py)

LSEG     equ    0800h           ; where this loader runs (phys 08000h)
ESEG     equ    1000h           ; 8080 memory (phys 10000h-1FFFFh)
STACKTOP equ    8000h           ; private stack top: LSEG:8000 = phys 10000h

CCPADDR  equ    0E000h
CCPLEN   equ    1600h           ; CCP + BDOS
BIOSADDR equ    0F600h
NATSTACK equ    0FE00h          ; ESEG:FE00-FFFF reserved for native stack

VBOOT    equ    0DFh            ; BRKEM vector -> 8080 cold boot
VBASE    equ    0E0h            ; CALLN vectors (match BIOS.ASM)
NVEC     equ    16

%macro  BRKEM 1
        db      0Fh, 0FFh, %1
%endmacro

start:
        cli
        mov     ax, cs
        mov     ds, ax
        mov     ss, ax
        mov     sp, STACKTOP
        sti
        cld
        mov     [bootdrv], dl

        mov     si, msg_hello
        call    puts

        ; ---- NEC V20/V30 check: AAD ignores its operand on NEC CPUs
        mov     ax, 0102h
        db      0D5h, 10h               ; AAD base 16: Intel->12h, NEC->0Ch
        cmp     al, 0Ch
        je      .is_nec
        mov     si, msg_notnec
        jmp     fatal
.is_nec:
        ; ---- disk geometry for LBA -> CHS
        mov     ah, 08h
        mov     dl, [bootdrv]
        push    es
        int     13h
        pop     es
        jc      .geofail
        and     cx, 003Fh
        jz      .geofail
        mov     [spt], cx
        mov     al, dh
        xor     ah, ah
        inc     ax
        mov     [heads], ax
        jmp     .geook
.geofail:
        mov     si, msg_geo
        jmp     fatal
.geook:
        ; ---- clear the 8080 64K and load BIOS + CCP/BDOS
        mov     ax, ESEG
        mov     es, ax
        xor     di, di
        xor     ax, ax
        mov     cx, 8000h
        rep     stosw
        mov     si, bios_img
        mov     di, BIOSADDR
        mov     cx, bios_len
        rep     movsb
        call    load_ccp

        ; ---- interrupt vectors
        xor     ax, ax
        mov     es, ax
        cli
        mov     di, VBASE*4
        mov     si, vectab
        mov     cx, NVEC
.vec:   movsw                           ; offset
        mov     ax, cs
        stosw                           ; segment
        loop    .vec
        mov     word [es:VBOOT*4], BIOSADDR
        mov     word [es:VBOOT*4+2], ESEG
        sti

        mov     si, msg_signon
        call    puts

        ; ---- go: everything points at the 8080 segment
        cli
        mov     ax, ESEG
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        xor     sp, sp                  ; native stack grows down from FFFF
        xor     ax, ax
        xor     bx, bx
        xor     cx, cx
        xor     dx, dx
        xor     bp, bp
        xor     si, si
        xor     di, di
        sti
        BRKEM   VBOOT                   ; 8080 code at ESEG:F600 (BIOS BOOT)
        ; not reached
        hlt
        jmp     $

fatal:
        call    puts
        mov     si, msg_key
        call    puts
        xor     ax, ax
        int     16h
        int     19h

; ---------------------------------------------------------------------------
;  CALLN dispatch.  On entry SS:SP = ESEG stack holding IP, CS, PSW of the
;  8080 code, and the 8080 registers are in AL, CX, DX, BX, BP.
;  Handlers get DS = LSEG, ES = ESEG; return the 8080 A in AL.
; ---------------------------------------------------------------------------
%macro  ENTRY 1
v_%1:   push    ax
        mov     ax, f_%1
        jmp     dispatch
%endmacro

        ENTRY   none
        ENTRY   wboot
        ENTRY   const
        ENTRY   conin
        ENTRY   conout
        ENTRY   list
        ENTRY   punch
        ENTRY   reader
        ENTRY   home
        ENTRY   seldsk
        ENTRY   settrk
        ENTRY   setsec
        ENTRY   setdma
        ENTRY   read
        ENTRY   write
        ENTRY   listst

vectab  dw      v_none, v_wboot, v_const, v_conin, v_conout, v_list, v_punch
        dw      v_reader, v_home, v_seldsk, v_settrk, v_setsec, v_setdma
        dw      v_read, v_write, v_listst

dispatch:
        mov     [cs:fnptr], ax
        pop     ax
        mov     [cs:save_ss], ss
        mov     [cs:save_sp], sp
        push    cs
        pop     ss                      ; (interrupts held off for one insn)
        mov     sp, STACKTOP
        sti
        push    ds
        push    es
        push    si
        push    di
        push    bp
        push    cx
        push    dx
        push    bx
        push    ax
        push    cs
        pop     ds
        mov     si, ESEG
        mov     es, si
        cld
        call    [fnptr]
        mov     [ret_al], al
        pop     ax
        mov     al, [ret_al]            ; new 8080 A, AH preserved
        pop     bx
        pop     dx
        pop     cx
        pop     bp
        pop     di
        pop     si
        pop     es
        pop     ds
        cli
        mov     ss, [cs:save_ss]
        mov     sp, [cs:save_sp]
        iret                            ; restores PSW with MD=0 -> 8080 mode

f_none:
        ret

; ---- warm boot: fresh CCP + BDOS
f_wboot:
        mov     byte [cvalid], 0
load_ccp:
        mov     si, ccp_img
        mov     di, CCPADDR
        mov     cx, CCPLEN/2
        rep     movsw
        ret

; ---- console: PC keyboard + direct video memory, ADM-3A / Kaypro codes
;
;  Output codes understood (ADM-3A / Kaypro II compatible):
;    CR LF BS BEL TAB, ^K up, ^L right, ^^ home, ^Z clear screen,
;    ^X clear to end of line, ^W clear to end of screen,
;    ESC = row+32 col+32    cursor position
;    ESC E insert line   ESC R delete line   ESC T clear to end of line
;    ESC Y clear to end of screen   ESC * clear screen
;    ESC B n / ESC C n      attribute n on / off (0 reverse, 1 bright)
;  Characters go straight into video memory.  The hardware cursor is moved
;  only when a program looks at the keyboard (CONST/CONIN), which keeps
;  screen output fast.

f_const:
        call    syncur
        mov     ah, 01h
        int     16h
        mov     al, 0
        jz      .r
        mov     al, 0FFh
.r:     ret

f_conin:
        call    syncur
.again: xor     ah, ah
        int     16h
        or      al, al
        jnz     .r
        mov     dl, ah                  ; extended key: map its scan code
        mov     si, keymap
.m:     lodsw                           ; al = scan code, ah = character
        or      al, al
        jz      .again                  ; unmapped key: ignore it
        cmp     al, dl
        jne     .m
        mov     al, ah
.r:     ret

; move the hardware cursor to our cursor position if it changed
syncur:
        cmp     byte [cdirty], 0
        je      .r
        mov     byte [cdirty], 0
        mov     ah, 02h
        xor     bh, bh
        mov     dh, [crow]
        mov     dl, [ccol]
        int     10h
.r:     ret

; first output: find the video buffer and pick up the BIOS cursor
con_init:
        push    es
        xor     ax, ax
        mov     es, ax
        mov     word [vseg], 0B800h
        cmp     byte [es:449h], 7       ; monochrome text mode?
        jne     .c
        mov     word [vseg], 0B000h
.c:     mov     ax, [es:44Ah]           ; columns
        cmp     ax, 40
        jb      .c80
        cmp     ax, 132
        jbe     .cok
.c80:   mov     ax, 80
.cok:   mov     [ncols], ax
        mov     al, [es:484h]           ; rows-1 (EGA/VGA BIOS), else 0
        inc     al
        cmp     al, 24
        jb      .r25
        cmp     al, 60
        jbe     .rok
.r25:   mov     al, 25
.rok:   mov     [nrows], al
        mov     ax, [es:44Eh]           ; start of the active page
        mov     [vbase], ax
        pop     es
        mov     ah, 03h
        xor     bh, bh
        int     10h
        mov     [crow], dh
        mov     [ccol], dl
        mov     byte [cinit], 1
        ret

f_conout:
        cmp     byte [cinit], 0
        jne     .go
        call    con_init
.go:    mov     byte [cdirty], 1
        mov     al, cl
        and     al, 7Fh
        mov     ah, [escstate]
        or      ah, ah
        jnz     con_esc
        cmp     al, 7Fh
        je      .r                      ; DEL: nothing
        cmp     al, 20h
        jae     con_print
        mov     bl, al                  ; control character: jump table
        xor     bh, bh
        shl     bx, 1
        jmp     [ctltab+bx]
.r:     ret

con_print:
        push    ax
        call    vaddr                   ; (uses AX)
        pop     ax
        mov     ah, [cattr]
        stosw
        inc     byte [ccol]
        mov     al, [ccol]
        cmp     al, [ncols]
        jb      .r
        mov     byte [ccol], 0
        jmp     c_lf
.r:     ret

c_ignore:
        ret
c_bel:
        mov     ax, 0E07h
        mov     bx, 0007h
        int     10h
        ret
c_bs:
        cmp     byte [ccol], 0
        je      .r
        dec     byte [ccol]
.r:     ret
c_tab:
        mov     al, [ccol]
        add     al, 8
        and     al, 0F8h
        mov     ah, [ncols]
        dec     ah
        cmp     al, ah
        jbe     .s
        mov     al, ah
.s:     mov     [ccol], al
        ret
c_lf:
        inc     byte [crow]
        mov     al, [crow]
        cmp     al, [nrows]
        jb      .r
        dec     byte [crow]
        xor     al, al
        jmp     del_line                ; scroll up
.r:     ret
c_up:
        cmp     byte [crow], 0
        je      .r
        dec     byte [crow]
.r:     ret
c_right:
        mov     al, [ccol]
        inc     al
        cmp     al, [ncols]
        jae     .r
        mov     [ccol], al
.r:     ret
c_cr:
        mov     byte [ccol], 0
        ret
c_home:
        mov     word [crow], 0          ; crow and ccol
        ret
c_cls:
        mov     word [crow], 0
c_eos:
        call    vaddr
        mov     al, [nrows]
        mul     byte [ncols]
        shl     ax, 1
        add     ax, [vbase]
        sub     ax, di
        shr     ax, 1
        mov     cx, ax
        jmp     blank
c_eol:
        call    vaddr
        mov     cl, [ncols]
        sub     cl, [ccol]
        xor     ch, ch
blank:
        mov     ax, 0720h
        cld
        rep     stosw
        ret
c_esc:
        mov     byte [escstate], 1
        ret

; escape sequences
con_esc:
        mov     byte [escstate], 0
        cmp     ah, 1
        jne     .s2
        cmp     al, '='
        je      .pos
        cmp     al, 'B'
        je      .aon
        cmp     al, 'C'
        je      .aoff
        cmp     al, 'E'
        je      .ins
        cmp     al, 'R'
        je      .del
        cmp     al, 'T'
        je      c_eol
        cmp     al, 'Y'
        je      c_eos
        cmp     al, '*'
        je      c_cls
        ret
.pos:   mov     byte [escstate], 2
        ret
.aon:   mov     byte [escstate], 4
        ret
.aoff:  mov     byte [escstate], 5
        ret
.ins:   mov     al, [crow]
        jmp     ins_line
.del:   mov     al, [crow]
        jmp     del_line
.s2:    cmp     ah, 2
        jne     .s3
        sub     al, 20h
        mov     [escrow], al
        mov     byte [escstate], 3
        ret
.s3:    cmp     ah, 3
        jne     .s4
        sub     al, 20h                 ; column
        mov     ah, [ncols]
        dec     ah
        cmp     al, ah
        jbe     .c1
        mov     al, ah
.c1:    mov     [ccol], al
        mov     al, [escrow]
        mov     ah, [nrows]
        dec     ah
        cmp     al, ah
        jbe     .c2
        mov     al, ah
.c2:    mov     [crow], al
        ret
.s4:    cmp     ah, 4
        jne     .s5
        mov     ah, 70h                 ; ESC B 0: reverse
        cmp     al, '0'
        je      .sa
        mov     ah, 0Fh                 ; ESC B 1: bright
        cmp     al, '1'
        je      .sa
        ret
.s5:    cmp     al, '0'                 ; ESC C 0 / ESC C 1: back to normal
        je      .norm
        cmp     al, '1'
        jne     .r
.norm:  mov     ah, 07h
.sa:    mov     [cattr], ah
.r:     ret

; vaddr: ES:DI = video address of (crow, ccol)
vaddr:
        mov     al, [crow]
        mul     byte [ncols]
        add     al, [ccol]
        adc     ah, 0
        shl     ax, 1
        add     ax, [vbase]
        mov     di, ax
        mov     es, [vseg]
        ret

; rowaddr: AL = row -> AX = video offset of its first character
rowaddr:
        mul     byte [ncols]
        shl     ax, 1
        add     ax, [vbase]
        ret

; del_line: AL = row; rows below move up one, last row blanked
del_line:
        mov     bl, al
        call    rowaddr
        mov     di, ax                  ; destination: row r
        mov     ax, [ncols]
        shl     ax, 1
        mov     si, di
        add     si, ax                  ; source: row r+1
        mov     al, [nrows]
        dec     al
        sub     al, bl                  ; rows to move
        mul     byte [ncols]
        mov     cx, ax
        mov     es, [vseg]
        push    ds
        mov     ds, [vseg]
        cld
        rep     movsw
        pop     ds
        mov     cx, [ncols]             ; DI is now at the last row
        jmp     blank

; ins_line: AL = row; it and the rows below move down one, row blanked
ins_line:
        mov     bl, al
        mov     al, [nrows]
        dec     al
        sub     al, bl
        mul     byte [ncols]
        mov     cx, ax                  ; words to move
        mov     al, [nrows]
        dec     al
        call    rowaddr                 ; start of last row
        mov     di, ax
        add     di, [ncols]
        add     di, [ncols]
        sub     di, 2                   ; last word of the last row
        mov     ax, [ncols]
        shl     ax, 1
        mov     si, di
        sub     si, ax                  ; last word of the row above
        mov     es, [vseg]
        push    ds
        mov     ds, [vseg]
        std
        rep     movsw
        cld
        pop     ds
        mov     al, bl
        call    rowaddr
        mov     di, ax
        mov     cx, [ncols]
        jmp     blank

ctltab  dw      c_ignore, c_ignore, c_ignore, c_ignore  ; 00-03
        dw      c_ignore, c_ignore, c_ignore, c_bel     ; 04-07
        dw      c_bs,     c_tab,    c_lf,     c_up      ; 08-0B
        dw      c_right,  c_cr,     c_ignore, c_ignore  ; 0C-0F
        dw      c_ignore, c_ignore, c_ignore, c_ignore  ; 10-13
        dw      c_ignore, c_ignore, c_ignore, c_eos     ; 14-17 (^W)
        dw      c_eol,    c_ignore, c_cls,    c_esc     ; 18-1B (^X ^Z ESC)
        dw      c_ignore, c_ignore, c_home,   c_ignore  ; 1C-1F (^^)

; ---- printer (LPT1) and serial (COM1)
f_list:
        mov     al, cl
        xor     ah, ah
        xor     dx, dx
        int     17h
        ret

f_listst:
        mov     ah, 02h
        xor     dx, dx
        int     17h
        mov     al, 0
        test    ah, 80h                 ; 1 = not busy
        jz      .r
        mov     al, 0FFh
.r:     ret

f_punch:
        mov     al, cl
        mov     ah, 01h
        xor     dx, dx
        int     14h
        ret

f_reader:
        mov     ah, 02h
        xor     dx, dx
        int     14h
        test    ah, 80h                 ; timeout?
        jz      .r
        mov     al, 1Ah                 ; return ^Z (end of file)
.r:     ret

; ---- disk parameters
f_home:
        mov     word [track], 0
        ret
f_seldsk:
        mov     [drive], cl
        ret
f_settrk:
        mov     [track], cx
        ret
f_setsec:
        mov     [sector], cx
        ret
f_setdma:
        mov     [dma], cx
        ret

; ---- read one 128-byte record into the DMA buffer
f_read:
        call    calc_lba
        jc      dskerr
        call    fetch
        jc      dskerr
        mov     si, cache
        add     si, [recoff]
        mov     di, [dma]
        mov     cx, 64
        rep     movsw                   ; DS:cache -> ESEG:dma
        xor     al, al
        ret
dskerr:
        mov     al, 1
        ret

; ---- write one 128-byte record (read-modify-write, write-through)
f_write:
        call    calc_lba
        jc      dskerr
        call    fetch
        jc      dskerr
        mov     di, cache
        add     di, [recoff]
        mov     si, [dma]
        push    ds
        push    es
        push    ds
        push    es
        pop     ds                      ; DS = ESEG
        pop     es                      ; ES = LSEG
        mov     cx, 64
        rep     movsw                   ; ESEG:dma -> LSEG:cache
        pop     es
        pop     ds
        mov     ah, 03h
        call    diskio
        jc      .bad
        xor     al, al
        ret
.bad:
        mov     byte [cvalid], 0
        jmp     dskerr

; calc_lba: from drive/track/sector -> DX:AX = absolute LBA, [recoff]
calc_lba:
        mov     bl, [drive]
        cmp     bl, NDISKS
        jae     .bad
        xor     bh, bh
        mov     ax, [sector]
        cmp     ax, SPT
        jae     .bad
        mov     cl, 7
        mov     dx, ax
        and     dx, 3
        shl     dx, cl
        mov     [recoff], dx            ; (sector & 3) * 128
        shl     bx, 1
        mov     ax, [track]
        cmp     ax, [drv_tracks+bx]
        jae     .bad
        mov     cl, 4
        shl     ax, cl                  ; track * 16 host sectors
        mov     dx, [sector]
        shr     dx, 1
        shr     dx, 1
        add     ax, dx
        shl     bx, 1
        xor     dx, dx
        add     ax, [drv_base+bx]
        adc     dx, [drv_base+bx+2]
        clc
        ret
.bad:
        stc
        ret

; fetch: make sure the host sector DX:AX is in the cache
fetch:
        cmp     byte [cvalid], 0
        je      .load
        cmp     ax, [clba]
        jne     .load
        cmp     dx, [clba+2]
        jne     .load
        clc
        ret
.load:
        mov     byte [cvalid], 0
        mov     [clba], ax
        mov     [clba+2], dx
        mov     ah, 02h
        call    diskio
        jc      .r
        mov     byte [cvalid], 1
.r:     ret

; diskio: AH = 02h (read) / 03h (write) the sector [clba] <-> cache
diskio:
        push    es
        mov     [diskop], ah
        mov     ax, [clba]
        mov     dx, [clba+2]
        cmp     dx, [spt]
        jae     .fail                   ; quotient would overflow
        div     word [spt]
        inc     dx
        mov     cl, dl                  ; sector (1-based)
        xor     dx, dx
        div     word [heads]            ; ax = cylinder, dx = head
        cmp     ax, 1024
        jae     .fail
        mov     dh, dl
        mov     ch, al
        ror     ah, 1
        ror     ah, 1
        and     ah, 0C0h
        or      cl, ah
        mov     dl, [bootdrv]
        push    ds
        pop     es
        mov     bx, cache
        mov     di, 4
.try:
        mov     ah, [diskop]
        mov     al, 1
        push    cx
        push    dx
        int     13h
        pop     dx
        pop     cx
        jnc     .ok
        xor     ah, ah
        int     13h
        dec     di
        jnz     .try
.fail:
        stc
.ok:
        pop     es
        ret

; ---------------------------------------------------------------------------
puts:
        lodsb
        or      al, al
        jz      .d
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        jmp     puts
.d:     ret

; extended-key map: scan code -> CP/M control character (WordStar style)
keymap  db      48h, 05h                ; up     -> ^E
        db      50h, 18h                ; down   -> ^X
        db      4Bh, 13h                ; left   -> ^S
        db      4Dh, 04h                ; right  -> ^D
        db      53h, 7Fh                ; Del    -> DEL
        db      0, 0

msg_hello  db   13, 10, 'Pocket8086 CP/M 2.2 loader', 13, 10, 0
msg_notnec db   'This needs an NEC V20 or V30 CPU (8080 emulation mode).', 13, 10
           db   'An Intel 8086/8088 is installed.', 13, 10, 0
msg_geo    db   'Cannot read the disk geometry.', 13, 10, 0
msg_key    db   'Press a key to reboot.', 13, 10, 0
msg_signon db   13, 10, '63K CP/M 2.2 - running in NEC V20/V30 8080 mode', 13, 10
           db   DRIVES_MSG, 13, 10, 0

bootdrv db      0
spt     dw      0
heads   dw      0
fnptr   dw      0
save_ss dw      0
save_sp dw      0
ret_al  db      0
escstate db     0
escrow  db      0
vseg    dw      0B800h
vbase   dw      0
ncols   dw      80
nrows   db      25
crow    db      0               ; crow, ccol: keep together
ccol    db      0
cattr   db      07h
cinit   db      0
cdirty  db      0
drive   db      0
track   dw      0
sector  dw      0
dma     dw      80h
recoff  dw      0
diskop  db      0
cvalid  db      0
clba    dd      0

        DRIVE_TABLES                    ; drv_base (dd), drv_tracks (dw)

        align   2
ccp_img:
        incbin  "cpm22.bin"
ccp_end:
bios_img:
        incbin  "bios.bin"
bios_end:
bios_len equ    bios_end - bios_img

%if ccp_end - ccp_img != CCPLEN
%error "cpm22.bin must be exactly 1600h bytes"
%endif

cache   equ     ($ - $$ + 15) & ~15     ; 512-byte host sector buffer
LOADER_END equ  cache + 512

%if LOADER_END > STACKTOP - 1024
%error "loader too large"
%endif
