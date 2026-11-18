; ---------------------------------------------------------------------------
;  Pocket8086 CP/M 2.2 - stage 1 boot sector (LBA 0 of the card)
;
;  Loaded by the PC BIOS at 0000:7C00 with DL = boot drive.  Loads
;  LOADER_SECTORS sectors starting at LBA 1 to 0800:0000 and jumps there.
;  The partition table (0x1BE..0x1FD) is filled in by build.py.
;
;  Assemble:  nasm -f bin -DLOADER_SECTORS=n boot.asm -o boot.bin
; ---------------------------------------------------------------------------
        bits    16
        cpu     8086
        org     7C00h

%ifndef LOADER_SECTORS
%error "LOADER_SECTORS not defined"
%endif

LOADSEG equ     0800h

start:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, 7C00h
        sti
        cld
        mov     [drive], dl

        mov     si, msg_boot
        call    puts

        ; get the drive geometry the BIOS uses for CHS translation
        mov     ah, 08h
        mov     dl, [drive]
        push    ds
        int     13h
        pop     ds
        jc      fail
        and     cx, 003Fh               ; sectors per track
        jz      fail
        mov     [spt], cx
        mov     al, dh
        xor     ah, ah
        inc     ax                      ; heads = max head + 1
        mov     [heads], ax

        mov     word [lba], 1
        mov     bp, LOADER_SECTORS
        mov     ax, LOADSEG
        mov     es, ax
.next:
        mov     ax, [lba]
        xor     dx, dx
        div     word [spt]              ; ax = lba / spt, dx = sector-1
        mov     cl, dl
        inc     cl                      ; sector (1-based)
        xor     dx, dx
        div     word [heads]            ; ax = cylinder, dx = head
        mov     dh, dl
        mov     ch, al
        ror     ah, 1
        ror     ah, 1
        and     ah, 0C0h
        or      cl, ah                  ; cylinder bits 8-9
        mov     dl, [drive]
        xor     bx, bx
        mov     di, 4                   ; tries
.try:
        mov     ax, 0201h
        push    cx
        push    dx
        int     13h
        pop     dx
        pop     cx
        jnc     .ok
        xor     ah, ah
        int     13h                     ; reset and retry
        dec     di
        jnz     .try
        jmp     fail
.ok:
        mov     al, '.'
        call    putc
        mov     ax, es
        add     ax, 512/16
        mov     es, ax
        inc     word [lba]
        dec     bp
        jnz     .next

        mov     dl, [drive]
        jmp     LOADSEG:0000h

fail:
        mov     si, msg_fail
        call    puts
        xor     ax, ax
        int     16h
        int     19h

puts:
        lodsb
        or      al, al
        jz      .done
        call    putc
        jmp     puts
.done:  ret

putc:
        mov     ah, 0Eh
        mov     bx, 0007h
        int     10h
        ret

msg_boot db     'CP/M boot', 0
msg_fail db     13, 10, 'Disk error - press a key', 0

drive   db      0
spt     dw      0
heads   dw      0
lba     dw      0

        times   1BEh - ($ - $$) db 0
        times   64 db 0                 ; partition table (filled by build.py)
        dw      0AA55h
