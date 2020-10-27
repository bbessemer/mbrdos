;;;
; MBR-DOS - an x86 real-mode OS that fits into a 512-byte bootsector.
;
; This is free and unencumbered software released into the public domain.
; Written 2020 by Brent Bessemer.
;;;

    bits 16
    cpu 386

    org 0x600

    section .text

bpb:
    jmp     _start
    nop
    .oem_id:                db  "MBRDOS01"
    .bytes_per_sector:      dw  512
    .sectors_per_cluster:   db  1
    .reserved_sectors:      dw  1
    .num_fats:              db  2
    .rootdir_entries:       dw  0xe0
    .total_sectors:         dw  2880
    .media_desc_type:       db  0xf0
    .sectors_per_fat:       dw  9
    .sectors_per_track:     dw  18
    .num_heads:             dw  2
    .hidden_sectors:        dd  0
    .large_sector_count:    dd  0
    .drive_number:          db  0
    .nt_flags:              db  0
    .signature:             db  0x29
    .volume_id:             dd  0
    .volume_label:          db  "MBRDOS     "
    .system_id:             db  "FAT12   "

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

    shr     ax, 9

    ;; mov     si, welcome
    ;; mov     cx, welcome.end - welcome
    ;; call    serial_send

halt:
    hlt
    jmp     halt


;;; FLOPPY DISK DRIVER

%define HEADS       2
%define CYLINDERS   80
%define SPC         18          ; cylinders per sector

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
    pop     cx
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
    push    dx
    push    si
    push    word [bx+fat_pos]

    ;; Compute the current offset into the current cluster
    mov     si, [bx+fat_pos]
    and     si, 511

    ;; Convert the bytes into full clusters and remaining bytes.
    mov     dx, cx
    shr     cx, 9
    and     dx, 511
    push    dx
    inc     cx                  ; include last partial cluster

    mov     ax, [bx+fat_cclus]

;;; ax = number of cluster to read
;;; cx = number of clusters remaining (including last partial one)
;;; si = byte offset into cluster to start reading
;;; dx = number of bytes to read from last cluster
.read_cluster:
    cmp     ax, 0xff8
    jge     .success            ; EOF was reached

    push    ax
    push    cx
    cmp     cx, 1
    mov     cx, dx
    je      .use_last_cluster_bytes
    mov     cx, 512
    sub     cx, si
.use_last_cluster_bytes:
    ;; If we are almost at the end of the file, don't read a whole cluster
    push    dx
    mov     dx, [bx+fat_size]
    sub     dx, [bx+fat_pos]
    cmp     dx, cx
    jb      .use_full_count
    mov     cx, dx
.use_full_count:
    pop     dx

    ;; If final count is zero, end.
    ;; This should never happen; we should have hit EOF marker in FAT.
    test    cx, cx
    jz      .success            ; TODO: is this really a success condition?

    call    fat_read_cluster
    test    ax, ax              ; abort if error
    jnz     .end

    xor     si, si              ; will be zero on non-initial clusters
    pop     cx                  ; Number of clusters remaining
    pop     ax                  ; Cluster number
    call    fat_next_cluster
    mov     [bx+fat_cclus], ax
    dec     cx
    jnz     .read_cluster

.success:
    xor     ax, ax
.end:
    pop     cx                  ; initial fat_pos
    sub     cx, [bx+fat_pos]
    neg     cx
    pop     si
    pop     dx
    ret


;;; Read a single FAT cluster (which should be 1 sector) or a portion thereof.
;;;
;;; Inputs:  ax = cluster number (not sector number)
;;;          si = offset into cluster to start reading
;;;          cx = total bytes to read
;;; Outputs: ax = 0 on success or error code
fat_read_cluster:
    ;; Read whole sector into temporary buffer
    add     ax, [bpb.reserved_sectors]
    push    es                  ; 7
    push    di                  ; 8
    xor     di, di
    mov     es, di
    mov     di, sector_buf
    call    read_sector
    pop     di                  ; 7
    pop     es                  ; 6
    test    ax, ax
    jnz     .end

    ;; Copy from temporary buffer into destination, w/ byte offset
    add     si, sector_buf
    rep     movsb
    add     [bx+fat_pos], cx
.end:
    ret

;;; Given a FAT cluster number, use the FAT to find the next cluster.
;;;
;;; Inputs:  ax = current cluster
;;; Outputs: ax = next cluster
fat_next_cluster:
    push    cx
    push    dx
    mov     cx, ax
    shr     ax, 1
    add     ax, cx              ; ax = byte offset of current cluster in FAT
    mov     ax, cx
    mov     si, cx
    shr     ax, 9
    and     si, 511
    add     ax, [bpb.reserved_sectors]

    push    es
    push    di
    xor     di, di
    mov     es, di
    mov     di, sector_buf
    call    read_sector
    pop     di
    pop     es

    mov     ax, [sector_buf+si]
    pop     dx
    test    dx, dx
    jz      .even
.odd:
    shr     ax, 4
    jmp     .end
.even:
    and     ax, 0xfff
.end:
    pop     dx
    pop     cx
    ret

;;; INTERRUPTS AND SYSTEM CALLS

ivt_init:
    mov     word [0x80*4], handle_dispatch
    mov     word [0x80*4+2], 0
    ret

    struc   proc_handle
hnd_ptr:    resw 1
hnd_seg:    resw 1
hnd_rindex: resw 1
_reserved:  resw 1
hnd_size:
    endstruc

handle_dispatch:
    cmp     ax, 0x100
    jge     invalid_handle
    push    bx
    mov     bx, 8
    push    dx
    xor     dx, dx
    mul     bx
    pop     dx
    mov     bx, ax
    cmp     word [bx], 0
    je      invalid_handle
    mov     ax, [bx+hnd_rindex]
    ;; TODO: push floating-point registers
    call    far [bx]
    pop     bx
    iret

invalid_handle:
    xor     ax, ax
    dec     ax
    iret

;;; FUNCTIONS FOR USER PROCESSES

;;; The initial list of handles for a process looks like this:
;;; [0] read standard input (inherited from parent)
;;; [1] write standard output (inherited)
;;; [2] write standard error (inherited)
;;; [3] read working directory (inherited)
;;; [4] open from working directory (inherited)
;;; [5] exit
;;; [6] fork
;;; [7] create handle

proc_new:
    push    di

    xor     di, di
.search:
    inc     di
    cmp     byte [used_pids+di], 0
    je      .search
    ;; di = pid of new process
    inc     byte [used_pids-1+di]
    push    di
    mov     ax, 0x1000
    xor     dx, dx
    mul     di
    mov     es, ax
    xor     di, di
    mov     cx, 0x100
    xor     al, al
    rep     stosb

    ;; handles 0-4 will be inherited from the parent,
    ;; or created specially for PID 1.
    mov     di, 7*hnd_size

    mov     word [es:di+hnd_ptr], proc_exit
    mov     word [es:di+hnd_seg], 0
    add     di, 8

    mov     word [es:di+hnd_ptr], proc_fork
    mov     word [es:di+hnd_seg], 0
    add     di, 8

    mov     word [es:di+hnd_ptr], proc_create_handle
    mov     word [di+hnd_seg], 0
    add     di, 8

proc_exit:
    ret

proc_fork:
    ret

proc_create_handle:
    ret

;;; DATA

;;; MBR PADDING AND SIGNATURE

    times 510-($-$$) db 0
    db 0x55
    db 0xaa

    section .bss
__bss_start:

sector_buf: resb 512

used_pids:  resb 9

__bss_end:
