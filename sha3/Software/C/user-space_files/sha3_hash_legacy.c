/**
 * sha3_hash_legacy.c - SHA3 file hashing (legacy mmap interface)
 * 
 * Userspace reads file into mmap'd DMA buffers, then triggers DMA.
 * Buffers are allocated on-demand via ALLOC_BUFFERS ioctl.
 * 
 * Usage: ./sha3_hash_legacy <input_file> [output | -] [hash_size] [-q]
 * 
 * COMPILATION:
 *   gcc -o sha3_hash_legacy sha3_hash_legacy.c -O3 -Wall
 */

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <errno.h>

#include "dma-proxy-sha3.h"

/* ============================================================================
 * PRINT CONTROL
 * ============================================================================ */

#define APP_PRINTS_DEFAULT 1

static int quiet_mode = 0;

#define PRINT(fmt, ...) do { if (!quiet_mode) printf(fmt, ##__VA_ARGS__); } while(0)
#define PRINT_ERR(fmt, ...) fprintf(stderr, "Error: " fmt, ##__VA_ARGS__)

/* ============================================================================
 * HELPERS
 * ============================================================================ */

void print_usage(const char *prog)
{
    printf("SHA3 Hardware Accelerator (Legacy mmap)\n");
    printf("=======================================\n\n");
    printf("Usage: %s <input_file> [output | -] [hash_size] [-q]\n\n", prog);
    printf("  input_file:  File to hash (max %d MB)\n", (MAX_BUFFERS * BUFFER_SIZE) / (1024*1024));
    printf("  output:      Output file for hash (use '-' for none)\n");
    printf("  hash_size:   224, 256, 384, or 512 (default: 256)\n");
    printf("  -q:          Quiet mode\n\n");
}

void print_hash(const unsigned char *hash, int size)
{
    for (int i = 0; i < size; i++)
        printf("%02x", hash[i]);
    printf("\n");
}

int get_hash_bytes(int bits) {
    switch(bits) {
        case 224: return SHA3_224_SIZE;
        case 256: return SHA3_256_SIZE;
        case 384: return SHA3_384_SIZE;
        case 512: return SHA3_512_SIZE;
        default: return -1;
    }
}

const char *hash_name(int t) {
    switch(t) {
        case 224: return "SHA3-224";
        case 256: return "SHA3-256";
        case 384: return "SHA3-384";
        case 512: return "SHA3-512";
        default: return "Unknown";
    }
}

static double time_diff_ms(struct timeval *s, struct timeval *e) {
    return (e->tv_sec - s->tv_sec) * 1000.0 + (e->tv_usec - s->tv_usec) / 1000.0;
}

/* ============================================================================
 * MAIN
 * ============================================================================ */

int main(int argc, char *argv[])
{
    const char *input_file = NULL;
    const char *output_file = NULL;
    int hash_bits = 256;
    int hash_bytes;
    
    int tx_fd = -1, rx_fd = -1;
    struct channel_buffer *tx_buf = NULL, *rx_buf = NULL;
    FILE *fin = NULL, *fout = NULL;
    struct stat st;
    struct sg_transfer_config tx_cfg, rx_cfg;
    struct timeval t_start, t_loaded, t_done;
    unsigned int num_buffers;
    size_t total_bytes = 0;
    int ret = 1;

    quiet_mode = !APP_PRINTS_DEFAULT;

    /* Parse args */
    if (argc < 2) { print_usage(argv[0]); return 1; }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-q") == 0 || strcmp(argv[i], "--quiet") == 0)
            quiet_mode = 1;
    }

    int pos = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-q") == 0 || strcmp(argv[i], "--quiet") == 0)
            continue;
        switch(pos++) {
            case 0: input_file = argv[i]; break;
            case 1: if (strcmp(argv[i], "-") != 0) output_file = argv[i]; break;
            case 2: hash_bits = atoi(argv[i]); break;
        }
    }

    if (!input_file) { print_usage(argv[0]); return 1; }

    hash_bytes = get_hash_bytes(hash_bits);
    if (hash_bytes < 0) {
        PRINT_ERR("Invalid hash size %d\n", hash_bits);
        return 1;
    }

    if (stat(input_file, &st) < 0) {
        PRINT_ERR("Cannot stat %s: %s\n", input_file, strerror(errno));
        return 1;
    }

    if (st.st_size > (long)MAX_BUFFERS * BUFFER_SIZE) {
        PRINT_ERR("File too large (max %d MB)\n", (MAX_BUFFERS * BUFFER_SIZE) / (1024*1024));
        return 1;
    }

    num_buffers = (st.st_size + BUFFER_SIZE - 1) / BUFFER_SIZE;

    PRINT("\n================================================\n");
    PRINT("SHA3 Hardware Accelerator (Legacy mmap)\n");
    PRINT("================================================\n\n");
    PRINT("Input:     %s\n", input_file);
    PRINT("Size:      %ld bytes (%.2f MB)\n", st.st_size, st.st_size / (1024.0*1024));
    PRINT("Buffers:   %u\n", num_buffers);
    PRINT("Hash:      %s\n\n", hash_name(hash_bits));

    /* Open devices */
    tx_fd = open("/dev/dma_proxy_sha3_tx", O_RDWR);
    if (tx_fd < 0) {
        PRINT_ERR("Cannot open TX device: %s\n", strerror(errno));
        goto cleanup;
    }

    rx_fd = open("/dev/dma_proxy_sha3_rx", O_RDWR);
    if (rx_fd < 0) {
        PRINT_ERR("Cannot open RX device: %s\n", strerror(errno));
        goto cleanup;
    }

    /* Allocate TX buffers */
    PRINT("Allocating %u TX buffers...\n", num_buffers);
    if (ioctl(tx_fd, ALLOC_BUFFERS, &num_buffers) < 0) {
        PRINT_ERR("TX ALLOC_BUFFERS failed: %s\n", strerror(errno));
        goto cleanup;
    }

    /* Allocate RX buffer (just 1 for hash) */
    unsigned int rx_count = 1;
    if (ioctl(rx_fd, ALLOC_BUFFERS, &rx_count) < 0) {
        PRINT_ERR("RX ALLOC_BUFFERS failed: %s\n", strerror(errno));
        goto cleanup;
    }

    /* mmap TX buffers */
    tx_buf = mmap(NULL, sizeof(struct channel_buffer) * num_buffers,
                  PROT_READ | PROT_WRITE, MAP_SHARED, tx_fd, 0);
    if (tx_buf == MAP_FAILED) {
        PRINT_ERR("TX mmap failed: %s\n", strerror(errno));
        tx_buf = NULL;
        goto cleanup;
    }

    /* mmap RX buffer */
    rx_buf = mmap(NULL, sizeof(struct channel_buffer),
                  PROT_READ | PROT_WRITE, MAP_SHARED, rx_fd, 0);
    if (rx_buf == MAP_FAILED) {
        PRINT_ERR("RX mmap failed: %s\n", strerror(errno));
        rx_buf = NULL;
        goto cleanup;
    }

    PRINT("Buffers mapped successfully\n\n");

    /* === TIMING START === */
    gettimeofday(&t_start, NULL);

    /* Load file into TX buffers */
    fin = fopen(input_file, "rb");
    if (!fin) {
        PRINT_ERR("Cannot open input: %s\n", strerror(errno));
        goto cleanup;
    }

    for (unsigned int i = 0; i < num_buffers; i++) {
        size_t to_read = (i == num_buffers - 1) ? 
                         (st.st_size - (size_t)i * BUFFER_SIZE) : BUFFER_SIZE;
        size_t got = fread(tx_buf[i].buffer, 1, to_read, fin);
        if (got != to_read) {
            PRINT_ERR("Read error at buffer %u\n", i);
            goto cleanup;
        }
        tx_cfg.buffer_ids[i] = i;
        tx_cfg.lengths[i] = got;
        total_bytes += got;
    }
    tx_cfg.buffer_count = num_buffers;
    fclose(fin);
    fin = NULL;

    gettimeofday(&t_loaded, NULL);
    PRINT("File loaded: %zu bytes in %.1f ms\n", total_bytes, time_diff_ms(&t_start, &t_loaded));

    /* Setup RX config */
    memset(rx_buf[0].buffer, 0, hash_bytes);
    rx_cfg.buffer_count = 1;
    rx_cfg.buffer_ids[0] = 0;
    rx_cfg.lengths[0] = hash_bytes;

    /* Start RX (async) */
    PRINT("Starting RX...\n");
    if (ioctl(rx_fd, START_XFER_ASYNC, &rx_cfg) < 0) {
        PRINT_ERR("RX START_XFER_ASYNC failed: %s\n", strerror(errno));
        goto cleanup;
    }

    /* Start TX (async) */
    PRINT("Starting TX...\n");
    if (ioctl(tx_fd, START_XFER_ASYNC, &tx_cfg) < 0) {
        PRINT_ERR("TX START_XFER_ASYNC failed: %s\n", strerror(errno));
        goto cleanup;
    }

    /* Wait for TX */
    if (ioctl(tx_fd, FINISH_XFER, NULL) < 0) {
        PRINT_ERR("TX FINISH_XFER failed: %s\n", strerror(errno));
        goto cleanup;
    }
    PRINT("TX complete\n");

    /* Wait for RX */
    if (ioctl(rx_fd, FINISH_XFER, NULL) < 0) {
        PRINT_ERR("RX FINISH_XFER failed: %s\n", strerror(errno));
        goto cleanup;
    }
    PRINT("RX complete\n\n");

    gettimeofday(&t_done, NULL);

    /* Calculate performance */
    double load_ms = time_diff_ms(&t_start, &t_loaded);
    double dma_ms = time_diff_ms(&t_loaded, &t_done);
    double total_ms = time_diff_ms(&t_start, &t_done);
    double dma_gbps = (total_bytes / (1024.0*1024*1024)) / (dma_ms/1000) * 8;
    double total_gbps = (total_bytes / (1024.0*1024*1024)) / (total_ms/1000) * 8;

    PRINT("================================================\n");
    PRINT("Performance\n");
    PRINT("================================================\n");
    PRINT("File load: %.3f ms\n", load_ms);
    PRINT("DMA time:  %.3f ms (%.2f Gbps)\n", dma_ms, dma_gbps);
    PRINT("Total:     %.3f ms (%.2f Gbps)\n\n", total_ms, total_gbps);

    PRINT("================================================\n");
    PRINT("%s\n", hash_name(hash_bits));
    PRINT("================================================\n");
    print_hash(rx_buf[0].buffer, hash_bytes);

    if (output_file) {
        fout = fopen(output_file, "wb");
        if (!fout || fwrite(rx_buf[0].buffer, 1, hash_bytes, fout) != (size_t)hash_bytes) {
            PRINT_ERR("Cannot write output\n");
            goto cleanup;
        }
        PRINT("\nSaved to: %s\n", output_file);
    }

    PRINT("================================================\n\n");
    ret = 0;

cleanup:
    if (fin) fclose(fin);
    if (fout) fclose(fout);
    if (tx_buf) munmap(tx_buf, sizeof(struct channel_buffer) * num_buffers);
    if (rx_buf) munmap(rx_buf, sizeof(struct channel_buffer));
    if (tx_fd >= 0) close(tx_fd);  /* This also frees buffers */
    if (rx_fd >= 0) close(rx_fd);
    return ret;
}
