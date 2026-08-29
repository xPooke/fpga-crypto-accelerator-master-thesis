/**
 * dma-proxy-sha3.h - Header for SHA3 DMA transfers
 * 
 * ON-DEMAND ALLOCATION VERSION
 * 
 * Both interfaces (zero-copy and legacy mmap) use on-demand allocation.
 * - Zero-copy: Kernel reads file, kernel allocates buffers
 * - Legacy: User mmaps buffers, user copies data, kernel allocates on mmap
 * 
 * Driver name: dma_proxy_sha3
 */
#ifndef DMA_PROXY_SHA3_H
#define DMA_PROXY_SHA3_H

#include <linux/ioctl.h>

/* ============================================================================
 * DEBUG CONFIGURATION
 * ============================================================================ */

/* Set to 1 to enable verbose kernel prints, 0 to disable */
#define DMA_PROXY_PRINTS 0

/* ============================================================================
 * BUFFER CONFIGURATION
 * ============================================================================ */

/* Size of each individual buffer chunk */
#define BUFFER_SIZE (1024 * 1024)  /* 1 MB per buffer */

/* 
 * Maximum number of buffers for any single transfer.
 * This sets the maximum file size: MAX_BUFFERS * BUFFER_SIZE
 * 
 * 1024 buffers = 1 GB max file size
 */
#define MAX_BUFFERS 1024 

/* Maximum scatter-gather entries */
#define MAX_SG_ENTRIES MAX_BUFFERS

/* ============================================================================
 * SHA3 HASH SIZES
 * ============================================================================ */

#define SHA3_224_SIZE 28   /* SHA3-224: 28 bytes */
#define SHA3_256_SIZE 32   /* SHA3-256: 32 bytes */
#define SHA3_384_SIZE 48   /* SHA3-384: 48 bytes */
#define SHA3_512_SIZE 64   /* SHA3-512: 64 bytes */

/* ============================================================================
 * IOCTL COMMANDS
 * ============================================================================ */

/* 
 * Legacy interface - mmap buffers, copy data in userspace
 * Buffers allocated on ALLOC_BUFFERS, freed on FREE_BUFFERS or close()
 */
#define ALLOC_BUFFERS    _IOW('a', 'a', unsigned int)   /* Allocate N buffers */
#define FREE_BUFFERS     _IO('a', 'b')                   /* Free allocated buffers */
#define START_XFER       _IOW('a', 'c', struct sg_transfer_config*)  /* Start and wait */
#define START_XFER_ASYNC _IOW('a', 'd', struct sg_transfer_config*)  /* Start, don't wait */
#define FINISH_XFER      _IO('a', 'e')                   /* Wait for async transfer */
#define GET_BUFFER_INFO  _IOR('a', 'f', struct buffer_info)  /* Get allocation info */

/* Zero-copy interface - kernel reads file directly */
#define HASH_FILE_DIRECT _IOWR('a', 'g', struct hash_file_request)

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================ */

/* Transfer status codes */
enum proxy_status {
    PROXY_NO_ERROR = 0,
    PROXY_BUSY = 1,
    PROXY_TIMEOUT = 2,
    PROXY_ERROR = 3
};

/* Buffer info returned by GET_BUFFER_INFO */
struct buffer_info {
    unsigned int buffer_count;     /* Number of allocated buffers */
    unsigned int buffer_size;      /* Size of each buffer */
    unsigned long total_size;      /* Total allocated size */
};

/* Single buffer structure for mmap interface */
struct channel_buffer {
    unsigned char buffer[BUFFER_SIZE];
    enum proxy_status status;
    unsigned int length;
} __attribute__ ((aligned (4096)));  /* Page-aligned for mmap */

/* Scatter-gather transfer configuration */
struct sg_transfer_config {
    int buffer_count;                      /* How many buffers in chain */
    int buffer_ids[MAX_SG_ENTRIES];        /* Which buffer indices to use */
    unsigned int lengths[MAX_SG_ENTRIES];  /* Data length in each buffer */
};

/* Zero-copy hash request structure */
struct hash_file_request {
    /* Input parameters */
    int input_fd;              /* File descriptor of file to hash */
    int hash_type;             /* Hash size: 224, 256, 384, or 512 */
    
    /* Output parameters */
    unsigned char hash[64];    /* Output hash (max 64 bytes for SHA3-512) */
    unsigned int hash_size;    /* Actual hash size in bytes */
    
    /* Statistics (output) */
    unsigned long long file_size;          /* Size of file that was hashed */
    unsigned long long transfer_time_ns;   /* DMA transfer time in nanoseconds */
    unsigned long long total_time_ns;      /* Total time including file read */
    unsigned int buffers_used;             /* Number of buffers allocated */
};

#endif /* DMA_PROXY_SHA3_H */
