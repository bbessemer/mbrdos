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
    .hidden_sectors:        dd  0
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
    mov     cx, welcome.end - welcome
    call    serial_send

halt:
    hlt
    jmp     halt


;;; SERIAL I/O

%define SERIAL(n)   (0x3f8 + n)

;;; Send a single character over the default serial port.
;;; Inputs: character to send in al.
serial_sendchar:
    cmp     al, `\n`
    jne     .not_newline
    mov     al, `\r`
    call    .not_newline
    mov     al, `\n`
.not_newline:
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
;;;
;;; Inputs: address of string in si
;;;         length to send in cx
serial_send:
    lodsb
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

    struc   fatfile
fat_size:   resw 1
fat_pos:    resw 1
fat_sclus:  resw 1
fat_cclus:  resw 1
    endstruc

;;; Read bytes from a FAT file.
;;;
;;; Inputs:  pointer to fatfile structure in bx
;;;          number of bytes to read in cx
;;;          destination buffer at [es:di]
;;; Outputs: ax = 0 on success, 1 on disk failure
;;;          cx = number of bytes actually read
fat_read:
    push    ax                  ; 1
    push    dx                  ; 2
    push    si                  ; 3

    ;; Compute the number of bytes per cluster.
    ;; TODO: maybe we should hardcode these to save instructions?
    xor     ah, ah
    mov     al, byte [bpb.sectors_per_cluster]
    mul     word [bpb.bytes_per_sector]

    ;; Compute the current offset into the current cluster
    push    cx                  ; 4
    mov     cx, ax
    mov     ax, [bx+fat_pos]
    div     cx
    mov     si, dx

    ;; Convert the bytes into full clusters and remaining bytes.
    pop     ax                  ; 3 - Argument originally passed in cx
    xor     dx, dx
    div     cx
    push    dx                  ; 4
    mov     cx, ax

    mov     ax, [bx+fat_cclus]

;;; ax = number of cluster to read
;;; cx = number of clusters remaining
;;; si = byte offset into cluster to start reading
.read_cluster:
    test    cx, cx
    jz      .read_last_cluster

    ;; Compute the sector offset into the current cluster
    ;; and byte offset into that sector.
    push    ax                  ; 5
    mov     ax, si
    xor     dx, dx
    div     word [bpb.bytes_per_sector]
    mov     si, dx
    mov     dx, ax

    ;; Convert cluster number + offset to (LBA) sector number
    ;; dx = offset in sectors
    pop     ax                  ; 4 - Cluster number
    push    ax                  ; 5
    push    dx                  ; 6
    mul     word [bpb.sectors_per_cluster]
    pop     dx                  ; 5
    add     ax, [bpb.reserved_sectors]
    ;; add     ax, [bpb.hidden_sectors]
    add     ax, dx

    ;; Compute number of sectors to read.
    push    cx                  ; 6
    mov     cx, [bpb.sectors_per_cluster]
    sub     cx, dx

.read_sector:
    ;; Read whole sector into temporary buffer
    push    es                  ; 7
    push    di                  ; 8
    xor     di, di
    mov     es, di
    mov     di, sector_buf
    call    read_sector
    pop     di                  ; 7
    pop     es                  ; 6

    ;; Copy from temporary buffer into destination, w/ byte offset
    push    cx                  ; 7
    add     si, sector_buf
    mov     cx, sector_buf + 512
    sub     cx, si
    rep     movsb
    pop     cx                  ; 6

    ;; Prepare for next iteration of inner (sector) loop
    xor     si, si              ; On subsequent sectors, offset will def be 0
    dec     cx
    jnz     .read_sector

    ;; Prepare for next iteration of outer (cluster) loop
    pop     cx                  ; 5 - Number of clusters remaining
    pop     ax                  ; 4 - Cluster number
    call    fat_next_cluster
    dec     cx
    jmp     .read_cluster

.read_last_cluster:

;;; DATA

welcome:
    db `Welcome to MBR-DOS v0.1.0\n`
.end:

;;; MBR PADDING AND SIGNATURE

    times 510-($-$$) db 0
    db 0x55
    db 0xaa

    section .bss
__bss_start:

sector_buf: resb 512

__bss_end:
