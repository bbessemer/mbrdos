;;;
; MBR-DOS - an x86 real-mode OS that fits into a 512-byte bootsector.
;
; This is free and unencumbered software released into the public domain.
; Written 2020 by Brent Bessemer.
;;;

    bits 16
    cpu 8086

    org 0x600

    section .text

bpb:
    jmp     _start
    nop
    .oem_id:                dq  0
    .bytes_per_sector:      dw  0
    .sectors_per_cluster:   db  0
    .reserved_sectors:      dw  0
    .num_fats:              db  0
    .rootdir_entries:       dw  0
    .total_sectors:         dw  0
    .media_desc_type:       db  0
    .sectors_per_fat:       dw  0
    .sectors_per_track:     dw  0
    .num_heads:             dw  0
    .num_hidden_sectors:    dd  0
    .large_sector_count:    dd  0
    .drive_number:          db  0
    .nt_flags:              db  0
    .signature:             db  0
    .volume_id:             dd  0
    .volume_label: times 11 db  0
    .system_id:             dq  0

    global _start
_start:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    xor     sp, sp

    ;; Relocate ourselves to 0x0:0x600 from wherever we are
    ;; (doesn't have to be 0x7c00)
    call    .testaddr
.testaddr:
    pop     si
    sub     si, (.testaddr - bpb)
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     di, bpb
    mov     cx, 512
    rep     movsb
    jmp     0x0:.zero_bss

.zero_bss:
    mov     di, __bss_start
    mov     cx, (__bss_end - __bss_start)
    xor     al, al
    rep     stosb

    mov     si, welcome
    call    serial_send

halt:
    hlt
    jmp     halt


;;; SERIAL I/O

%define SERIAL(n)   (0x3f8 + n)

;;; Send a single character over the default serial port.
;;; Inputs: character to send in al.
serial_sendchar:
    push    dx
    push    ax
    mov     dx, SERIAL(5)
.wait_thre:
    in      al, dx
    test    al, 0x20
    jz      .wait_thre
    pop     ax
    mov     dx, SERIAL(0)
    out     dx, al
    pop     dx
    ret

;;; Send a string over the default serial port.
;;; String terminated by either null byte or specified limit.
;;;
;;; Inputs: address of string in si
;;;         maximum length to send in cx
serial_send:
    lodsb
    test    al, al
    jz      .end
    call    serial_sendchar
    dec     cx
    jnz     serial_send
.end:
    ret

;;; Recieve a single character over the default serial port.
;;; Outputs: character received in al
serial_recvchar:
    push    dx
    mov     dx, SERIAL(5)
.wait_dr:
    in      al, dx
    test    al, 1
    jz      .wait_dr
    mov     dx, SERIAL(0)
    in      al, dx
    pop     dx
    ret

;;; Recieve a string over the default serial port.
;;; String terminated by either newline or specified limit.
;;; A null byte is written either way.
;;;
;;; Inputs: address to write string to in di
;;; Outputs: number of characters actually read (not counting null) in cx
serial_recv:
    push    ax
    push    cx
.loop:
    call    serial_recvchar
    cmp     al, `\r`
    je      .loop               ; CR is completely ignored
    cmp     al, `\n`
    je      .end
    stosb
    dec     cx
    jnz     .loop
.end:
    pop     ax                  ; Original max count
    neg     cx                  ; cx = -(remaining count)
    add     cx, ax              ; cx = count actually read
    mov     byte [di], 0        ; null terminator
    pop     ax
    ret

;;; FLOPPY DISK DRIVER

%define HEADS       2
%define CYLINDERS   80
%define SPC         18

;;; Convert logical block address to cylinder/head/sector address.
;;; Since this is a floppy, we can assume that the cylinder number fits into
;;; one byte and doesn't require storing the high bits in other registers.
;;;
;;; Inputs: LBA in ax
;;; Outputs: cylinder in ch
;;;          head in dh
;;;          sector in cl
lba2chs:
    push    dx
    mov     cl, SPC
    div     cl                  ; ah = sector
    mov     dl, ah
    xor     ah, ah
    mov     cl, HEADS
    div     cl                  ; ah = cylinder; al = head
    pop     dx
    mov     ch, ah
    mov     dh, al
    mov     cl, dl
    ret

;;; Read several sectors from the first floppy disk.
;;;
;;; See below for inputs and outputs. This function additionally
;;; takes the number of sectors to read in cx.
read_sectors:
    call    read_sector
    test    ax, ax              ; nonzero = failure, pass it on
    jnz     .end
    dec     cx
    jnz     read_sectors
.end:
    ret

;;; Read a single sector from the first floppy disk.
;;;
;;; Inputs: LBA of sector to read in ax
;;;         Destination buffer at [es:di]
;;; Outputs: ax = 0 on success, != 0 on failure
read_sector:
    push    bx
    push    cx
    mov     bx, di
    call    lba2chs
    mov     ax, 0x0201          ; ah = function (read); al = # of sectors
    jmp     floppy_common

;;; Write several sectors to the first floppy disk.
;;;
;;; See below for inputs and outputs. This function additionally
;;; takes the number of sectors to write in cx.
write_sectors:
    call    write_sector
    test    ax, ax              ; nonzero = failure, pass it on
    jnz     .end
    dec     cx
    jnz     write_sectors
.end:
    ret

;;; Write a single sector to the first floppy disk.
;;;
;;; Inputs: LBA of sector to write to in ax
;;;         Source buffer at [ds:si]
;;; Outputs: ax = 0 on success, != 0 on failure
write_sector:
    push    bx
    push    cx
    mov     bx, ds
    mov     es, bx
    mov     bx, si
    call    lba2chs
    mov     ax, 0x0301          ; ah = function (write); al = # of sectors
    ;; FALLTHRU

floppy_common:
    xor     dl, dl              ; drive number = 0 (first floppy)
    int     0x13                ; BIOS interrupt
    jc      .error              ; BIOS reports error with carry flag
    test    al, al              ; BIOS returns number of sectors actually read
    mov     al, 0
    jnz     .success
.error:
    inc     al
.success:
    pop     cx                  ; Were pushed in read_ or write_ functions
    pop     bx
    ret

;;; FAT12 DRIVER

    ;; TODO

;;; DATA

welcome: db `Welcome to MBR-DOS v0.1.0\r\n`, 0

;;; MBR PADDING AND SIGNATURE

    times 510-($-$$) db 0
    db 0x55
    db 0xaa

    section .bss
__bss_start:

__bss_end:
