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

; ---- console: PC keyboard + screen with a small ADM-3A subset
f_const:
        mov     ah, 01h
        int     16h
        mov     al, 0
        jz      .r
        mov     al, 0FFh
.r:     ret

f_conin:
        xor     ah, ah
        int     16h
        or      al, al
        jnz     .r
        mov     dl, ah                  ; extended key: map its scan code
        mov     si, keymap
.m:     lodsw                           ; al = scan code, ah = character
        or      al, al
        jz      f_conin                 ; unmapped key: ignore it
        cmp     al, dl
        jne     .m
        mov     al, ah
.r:     ret

f_conout:
        mov     al, cl
        and     al, 7Fh
        mov     ah, [escstate]
        or      ah, ah
        jnz     .esc
        cmp     al, 20h
        jae     .put
        cmp     al, 0Dh
        je      .put
        cmp     al, 0Ah
        je      .put
        cmp     al, 08h
        je      .put
        cmp     al, 07h
        je      .put
        cmp     al, 1Bh
        je      .escstart
        cmp     al, 1Ah
        je      .clear
        cmp     al, 1Eh
        je      .home
        cmp     al, 0Bh
        je      .up
        cmp     al, 0Ch
        je      .right
        ret                             ; other control codes: ignore
.put:
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        ret
.escstart:
        mov     byte [escstate], 1
        ret
.esc:
        cmp     ah, 1
        jne     .esc2
        mov     byte [escstate], 0
        cmp     al, '='
        jne     .r
        mov     byte [escstate], 2
.r:     ret
.esc2:
        cmp     ah, 2
        jne     .esc3
        sub     al, 20h
        mov     [escrow], al
        mov     byte [escstate], 3
        ret
.esc3:
        mov     byte [escstate], 0
        sub     al, 20h
        mov     dl, al
        mov     dh, [escrow]
        cmp     dl, 79
        jbe     .c1
        mov     dl, 79
.c1:    cmp     dh, 24
        jbe     .setcur
        mov     dh, 24
        jmp     .setcur
.clear:
        mov     ax, 0600h
        mov     bh, 07h
        xor     cx, cx
        mov     dx, 184Fh
        int     10h
.home:
        xor     dx, dx
.setcur:
        mov     ah, 02h
        xor     bh, bh
        int     10h
        ret
.up:
        mov     ah, 03h
        xor     bh, bh
        int     10h
        or      dh, dh
        jz      .setcur
        dec     dh
        jmp     .setcur
.right:
        mov     ah, 03h
        xor     bh, bh
        int     10h
        cmp     dl, 79
        jae     .setcur
        inc     dl
        jmp     .setcur

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
