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
    sub     si, (.testaddr - _start)
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     di, _start
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
;;;          dl destroyed
lba2chs:
    mov     cl, SPC
    div     cl                  ; ah = sector
    mov     dl, ah
    xor     ah, ah
    mov     cl, HEADS
    div     cl                  ; ah = cylinder; al = head
    mov     ch, ah
    mov     dh, al
    mov     cl, dl
    inc     cl
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


;;; TAR DRIVER

    struc   tarfile
tar_fsize:  resw 1
tar_pos:    resw 1
tar_stsec:  resw 1
tar_flags:  resw 1
tar_size:
    endstruc

    %define TAR_DIRECTORY   1

;;; Only supporting the original tar format, not USTAR
    struc   tar_header
th_name:    resb 100
th_mode:    resb 8
th_uid:     resb 8
th_gid:     resb 8
th_fsize:   resb 12
th_mtime:   resb 12
th_cksum:   resb 8
th_type:    resb 1
th_lnknam:  resb 100
th_size:
    endstruc

;;; Convert ASCII octal string to number
;;;
;;; Inputs:  pointer to null-terminated string in si
;;; Outputs: value in cx
atoi_octal:
    push    ax
    xor     cx, cx
    xor     ax, ax
.read:
    lodsb
    test    al, al
    jz      .end
    shl     cx, 3
    add     cx, ax
    jmp     .read
.end:
    pop     ax
    ret

;;; Read bytes from a file in a tarball on disk
;;;
;;; Inputs:  bx = pointer to tarfile struct
;;;          cx = number of bytes to read
;;;          es:di = location to read to
;;; Outputs: ax = 0 on success or error code
;;;          cx = number of bytes actually read
tar_read_internal:
    push    dx
    push    si
    mov     ax, [bx+tar_pos]
    mov     dx, [bx+tar_size]
    sub     dx, ax
    cmp     dx, cx
    jl      .expect_eof
    mov     dx, cx
.expect_eof:
    push    dx
    mov     si, ax
    shr     ax, 9
    and     si, 511
.read_loop:
    test    dx, dx
    jz      .success
    push    es
    push    di
    xor     di, di
    mov     es, di
    mov     di, sector_buf
    push    ax
    call    read_sector
    test    ax, ax
    jnz     .end
    pop     ax
    pop     di
    pop     es

    mov     cx, 512
    sub     cx, si
    cmp     cx, dx
    jge     .read_full_sector
    mov     cx, dx
.read_full_sector:
    add     si, sector_buf
    rep     movsb

    inc     ax
    sub     dx, cx
    ja      .read_loop
.success:
    xor     ax, ax
.end:
    pop     cx
    sub     cx, dx
    pop     si
    pop     dx
    ret

tar_read:
    push    dx
    push    bx
    mov     bx, tar_size
    mul     bx
    mov     bx, ax
    add     bx, tarfiles
    call    tar_read_internal
    pop     bx
    pop     dx
    retf

tar_open_internal:
    push    es
    push    di
    push    cx
    xor     ax, ax
    mov     bx, tarfiles
.search_space:
    cmp     bx, tarfiles.end
    jge     .fail
    cmp     word [bx+tar_stsec], 0
    je      .found_space
    add     bx, tar_size
    jmp     .search_space
.found_space:
    push    ax
    xor     di, di
    mov     es, di
    mov     ax, 1
.search_file:
    mov     di, sector_buf
    push    ax
    call    read_sector
    test    ax, ax
    jnz     .fail
    pop     ax
    mov     cx, 100
    repe    cmpsb
    je      .found_file
    call    tar_get_size
    add     ax, cx
    cmp     ax, 2880            ; TODO this is super inefficient
    jge     .fail
    jmp     .search_file
.found_file:
    call    tar_get_size
    mov     [bx+tar_fsize], cx
    mov     [bx+tar_stsec], ax
    mov     [bx+tar_pos], word 0
    mov     [bx+tar_flags], word 0
    cmp     [sector_buf+th_type], byte "5"
    jne     .notdir
    or      [bx+tar_flags], word TAR_DIRECTORY
.notdir:
    pop     ax
    jmp     .success
.fail:
    xor     ax, ax
    dec     ax
.success:
    pop     di
    pop     es
    ret

tar_get_size:
    push    ds
    push    si
    xor     si, si
    mov     ds, si
    mov     si, sector_buf+th_fsize
    call    atoi_octal
    pop     si
    pop     ds
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
;;; [0] exit
;;; [1] fork
;;; [2] create handle
;;; [3] transfer handle
;;;
;;; PID 1 will additionally get these (which will be inherited)
;;; [4] read working directory
;;; [5] open from working directory

;;; TODO: this returns to the calling process and probably should not be used
proc_exit:
    push    si
    mov     si, cs
    shr     si, 12
    dec     byte [used_pids+si]
    pop     si
    retf

;;; Kernel capability. Clones the calling process.
;;;
;;; Inputs:  dx = start address in new process
;;; Outputs: ax = handle to entry point of new process
proc_fork:
    push    cx
    push    di

    xor     ax, ax              ; Preload failure value
    dec     ax

    xor     di, di
.search:
    inc     di
    cmp     di, 9
    jg      .end
    cmp     byte [used_pids+di], 0
    je      .search
    ;; di = pid of new process
    push    di
    inc     byte [used_pids-1+di]
    shl     di, 12
    mov     es, di

    ;; Copy the old process's memory into the new process's space
    xor     di, di
    xor     si, si
    mov     cx, -1
    rep     movsb

    pop     di
    mov     si, ds
    shr     si, 12
    call    proc_make_handle_internal
.end:
    pop     di
    pop     cx
    retf

proc_make_handle:
    call    proc_make_handle_internal
    retf

;;; Inputs:  si = process to which handle should refer
;;;          di = process to which to give handle
;;;          dx = entry point
;;; Outputs: ax = new handle, or -1 on failure
proc_make_handle_internal:
    shl     si, 12
    shl     di, 12
    push    es
    mov     es, di
    xor     di, di
    xor     ax, ax
    dec     ax
.search:
    cmp     di, 0x100
    jge     .end
    cmp     word [di+hnd_ptr], 0
    je      .found
    add     di, hnd_size
    jmp     .search
.found:
    mov     [di+hnd_ptr], dx
    mov     [di+hnd_seg], si
    mov     word [di+hnd_rindex], 0
    mov     ax, di
    shr     ax, 12
.end:
    pop     es
    ret

proc_give_handle:
    retf

;;; DATA

;;; MBR PADDING AND SIGNATURE

    times 510-($-$$) db 0
    db 0x55
    db 0xaa

    section .bss
__bss_start:

sector_buf: resb 512

used_pids:  resb 9

tarfiles:   resb 256 * tar_size
    .end:

__bss_end:
