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

