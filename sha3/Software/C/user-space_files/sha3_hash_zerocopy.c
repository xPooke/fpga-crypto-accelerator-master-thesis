/**
 * sha3_hash_zerocopy.c - SHA3 file hashing with zero-copy DMA
 * 
 * Kernel reads file directly into DMA buffers - no userspace copying.
 * 
 * Usage: ./sha3_hash_zerocopy <input_file> [output | -] [hash_size] [-q]
 * 
 * COMPILATION:
 *   gcc -o sha3_hash_zerocopy sha3_hash_zerocopy.c -O3 -Wall
 */

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

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
    printf("SHA3 Hardware Accelerator (Zero-Copy)\n");
    printf("=====================================\n\n");
    printf("Usage: %s <input_file> [output | -] [hash_size] [-q]\n\n", prog);
    printf("  input_file:  File to hash (max %d MB)\n", (MAX_BUFFERS * BUFFER_SIZE) / (1024*1024));
    printf("  output:      Output file for hash (use '-' for none)\n");
    printf("  hash_size:   224, 256, 384, or 512 (default: 256)\n");
    printf("  -q:          Quiet mode\n\n");
    printf("Examples:\n");
    printf("  %s data.bin\n", prog);
    printf("  %s data.bin - 512 -q\n", prog);
}

void print_hash(const unsigned char *hash, int size)
{
    for (int i = 0; i < size; i++)
        printf("%02x", hash[i]);
    printf("\n");
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

const char *fmt_size(unsigned long long b, char *buf, size_t len) {
    if (b >= 1024ULL*1024*1024) snprintf(buf, len, "%.2f GB", b/(1024.0*1024*1024));
    else if (b >= 1024*1024) snprintf(buf, len, "%.2f MB", b/(1024.0*1024));
    else if (b >= 1024) snprintf(buf, len, "%.2f KB", b/1024.0);
    else snprintf(buf, len, "%llu B", b);
    return buf;
}

/* ============================================================================
 * MAIN
 * ============================================================================ */

int main(int argc, char *argv[])
{
    const char *input_file = NULL;
    const char *output_file = NULL;
    int hash_type = 256;
    int dev_fd = -1, input_fd = -1;
    FILE *fout = NULL;
    struct hash_file_request req;
    struct stat st;
    int ret = 1;
    char sbuf[64];

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
            case 2: hash_type = atoi(argv[i]); break;
        }
    }

    if (!input_file) { print_usage(argv[0]); return 1; }

    if (hash_type != 224 && hash_type != 256 && hash_type != 384 && hash_type != 512) {
        PRINT_ERR("Invalid hash size %d\n", hash_type);
        return 1;
    }

    if (stat(input_file, &st) < 0) {
        PRINT_ERR("Cannot stat %s: %s\n", input_file, strerror(errno));
        return 1;
    }

    PRINT("\n================================================\n");
    PRINT("SHA3 Hardware Accelerator (Zero-Copy)\n");
    PRINT("================================================\n\n");
    PRINT("Input:     %s\n", input_file);
    PRINT("Size:      %s (%lld bytes)\n", fmt_size(st.st_size, sbuf, sizeof(sbuf)), (long long)st.st_size);
    PRINT("Hash:      %s\n\n", hash_name(hash_type));

    dev_fd = open("/dev/dma_proxy_sha3_tx", O_RDWR);
    if (dev_fd < 0) {
        PRINT_ERR("Cannot open device: %s\n", strerror(errno));
        goto cleanup;
    }

    input_fd = open(input_file, O_RDONLY);
    if (input_fd < 0) {
        PRINT_ERR("Cannot open input: %s\n", strerror(errno));
        goto cleanup;
    }

    memset(&req, 0, sizeof(req));
    req.input_fd = input_fd;
    req.hash_type = hash_type;

    PRINT("Hashing...\n\n");

    if (ioctl(dev_fd, HASH_FILE_DIRECT, &req) < 0) {
        PRINT_ERR("HASH_FILE_DIRECT failed: %s\n", strerror(errno));
        goto cleanup;
    }

    double dma_ms = req.transfer_time_ns / 1000000.0;
    double total_ms = req.total_time_ns / 1000000.0;
    double dma_gbps = (dma_ms > 0) ? (req.file_size / (1024.0*1024*1024)) / (dma_ms/1000) * 8 : 0;
    double total_gbps = (total_ms > 0) ? (req.file_size / (1024.0*1024*1024)) / (total_ms/1000) * 8 : 0;

    PRINT("================================================\n");
    PRINT("Performance\n");
    PRINT("================================================\n");
    PRINT("Buffers:   %u\n", req.buffers_used);
    PRINT("DMA time:  %.3f ms (%.2f Gbps)\n", dma_ms, dma_gbps);
    PRINT("Total:     %.3f ms (%.2f Gbps)\n\n", total_ms, total_gbps);

    PRINT("================================================\n");
    PRINT("%s\n", hash_name(hash_type));
    PRINT("================================================\n");
    print_hash(req.hash, req.hash_size);

    if (output_file) {
        fout = fopen(output_file, "wb");
        if (!fout || fwrite(req.hash, 1, req.hash_size, fout) != req.hash_size) {
            PRINT_ERR("Cannot write output\n");
            goto cleanup;
        }
        PRINT("\nSaved to: %s\n", output_file);
    }

    PRINT("================================================\n\n");
    ret = 0;

cleanup:
    if (fout) fclose(fout);
    if (input_fd >= 0) close(input_fd);
    if (dev_fd >= 0) close(dev_fd);
    return ret;
}
