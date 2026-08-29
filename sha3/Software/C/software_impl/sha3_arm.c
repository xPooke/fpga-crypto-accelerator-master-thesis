/**
 * sha3_arm.c - SHA3 Software Implementation for ARM Cortex-A53 (KR260)
 *
 * Single-threaded implementation optimized for Cortex-A53.
 * Multi-threading provides no benefit for SHA3 due to sequential
 * nature of Keccak permutation and its 24-round data dependencies.
 *
 * Cross-compile:
 *   aarch64-linux-gnu-gcc -O3 -flto -funroll-loops -fomit-frame-pointer \
 *       -ftree-vectorize -mcpu=cortex-a53 -mtune=cortex-a53 \
 *       -march=armv8-a+simd -o sha3_arm sha3_arm.c
 *
 * Usage:
 *   ./sha3_arm <filename> [hash_type] [-q]
 *
 *   hash_type: 224, 256, 384, or 512 (default: 256)
 */

#define _GNU_SOURCE
#define _POSIX_C_SOURCE 199309L

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

/* ===== Print Control ===== */

#define APP_PRINTS_DEFAULT 1

static int quiet_mode = 0;

#define PRINT(fmt, ...) do { if (!quiet_mode) printf(fmt, ##__VA_ARGS__); } while(0)
#define PRINT_ERR(fmt, ...) fprintf(stderr, "Error: " fmt, ##__VA_ARGS__)

/* ===== Configuration ===== */

/* I/O buffer size - 128KB is optimal for Cortex-A53 L2 cache */
#define IO_BUF_SIZE (128 * 1024)

/* Maximum rate bytes (for SHA3-224: (1600 - 2*224) / 8 = 144) */
#define MAX_RATE_BYTES 144

/* Maximum output bytes (for SHA3-512: 64) */
#define MAX_OUT_BYTES 64

/* ===== SHA3 Parameters Structure ===== */

typedef struct {
    int bits;           /* Output bits: 224, 256, 384, 512 */
    int out_bytes;      /* Output bytes */
    int rate_bytes;     /* Rate in bytes */
    int rate_words;     /* Rate in 64-bit words */
} sha3_params_t;

static int init_sha3_params(sha3_params_t *params, int hash_type)
{
    switch (hash_type) {
        case 224:
            params->bits = 224;
            params->out_bytes = 28;
            params->rate_bytes = 144;  /* (1600 - 2*224) / 8 */
            break;
        case 256:
            params->bits = 256;
            params->out_bytes = 32;
            params->rate_bytes = 136;  /* (1600 - 2*256) / 8 */
            break;
        case 384:
            params->bits = 384;
            params->out_bytes = 48;
            params->rate_bytes = 104;  /* (1600 - 2*384) / 8 */
            break;
        case 512:
            params->bits = 512;
            params->out_bytes = 64;
            params->rate_bytes = 72;   /* (1600 - 2*512) / 8 */
            break;
        default:
            return -1;
    }
    params->rate_words = params->rate_bytes / 8;
    return 0;
}

/* ===== Keccak Constants ===== */

static const uint8_t rho_offsets[5][5] = {
    {  0, 36,  3, 41, 18 },
    {  1, 44, 10, 45,  2 },
    { 62,  6, 43, 15, 61 },
    { 28, 55, 25, 21, 56 },
    { 27, 20, 39,  8, 14 }
};

static const uint64_t RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL,
    0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL,
    0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL,
    0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL,
    0x0000000080000001ULL, 0x8000000080008008ULL
};

#define ROTL64(x, n) (((x) << (n)) | ((x) >> (64 - (n))))

/* ===== Keccak-f[1600] Optimized for Cortex-A53 ===== */

static inline void keccak_f1600(uint64_t state[5][5])
{
    uint64_t C[5], D[5];
    uint64_t temp[5][5];

    for (int r = 0; r < 24; ++r) {
        /* Theta - compute column parities */
        C[0] = state[0][0] ^ state[0][1] ^ state[0][2] ^ state[0][3] ^ state[0][4];
        C[1] = state[1][0] ^ state[1][1] ^ state[1][2] ^ state[1][3] ^ state[1][4];
        C[2] = state[2][0] ^ state[2][1] ^ state[2][2] ^ state[2][3] ^ state[2][4];
        C[3] = state[3][0] ^ state[3][1] ^ state[3][2] ^ state[3][3] ^ state[3][4];
        C[4] = state[4][0] ^ state[4][1] ^ state[4][2] ^ state[4][3] ^ state[4][4];

        D[0] = C[4] ^ ROTL64(C[1], 1);
        D[1] = C[0] ^ ROTL64(C[2], 1);
        D[2] = C[1] ^ ROTL64(C[3], 1);
        D[3] = C[2] ^ ROTL64(C[4], 1);
        D[4] = C[3] ^ ROTL64(C[0], 1);

        /* Fused Theta + Rho + Pi - reduces memory accesses */
        #define THETA_RHO_PI(x, y) \
            temp[y][(2*x + 3*y) % 5] = ROTL64(state[x][y] ^ D[x], rho_offsets[x][y])

        THETA_RHO_PI(0, 0); THETA_RHO_PI(0, 1); THETA_RHO_PI(0, 2); THETA_RHO_PI(0, 3); THETA_RHO_PI(0, 4);
        THETA_RHO_PI(1, 0); THETA_RHO_PI(1, 1); THETA_RHO_PI(1, 2); THETA_RHO_PI(1, 3); THETA_RHO_PI(1, 4);
        THETA_RHO_PI(2, 0); THETA_RHO_PI(2, 1); THETA_RHO_PI(2, 2); THETA_RHO_PI(2, 3); THETA_RHO_PI(2, 4);
        THETA_RHO_PI(3, 0); THETA_RHO_PI(3, 1); THETA_RHO_PI(3, 2); THETA_RHO_PI(3, 3); THETA_RHO_PI(3, 4);
        THETA_RHO_PI(4, 0); THETA_RHO_PI(4, 1); THETA_RHO_PI(4, 2); THETA_RHO_PI(4, 3); THETA_RHO_PI(4, 4);

        #undef THETA_RHO_PI

        /* Chi - optimized for A53 in-order pipeline */
        for (int y = 0; y < 5; ++y) {
            uint64_t t0 = temp[0][y];
            uint64_t t1 = temp[1][y];
            uint64_t t2 = temp[2][y];
            uint64_t t3 = temp[3][y];
            uint64_t t4 = temp[4][y];

            state[0][y] = t0 ^ ((~t1) & t2);
            state[1][y] = t1 ^ ((~t2) & t3);
            state[2][y] = t2 ^ ((~t3) & t4);
            state[3][y] = t3 ^ ((~t4) & t0);
            state[4][y] = t4 ^ ((~t0) & t1);
        }

        /* Iota */
        state[0][0] ^= RC[r];
    }
}

/* ===== SHA3 Helper Functions ===== */

static inline void absorb_block(uint64_t state[5][5], const uint8_t *block, int words)
{
    for (int i = 0; i < words; ++i) {
        uint64_t lane;
        memcpy(&lane, block + i * 8, sizeof(uint64_t));
        state[i % 5][i / 5] ^= lane;
    }
}

static void pad_and_absorb_final(uint64_t state[5][5], const uint8_t *data,
                                  size_t len, const sha3_params_t *params)
{
    uint8_t block[MAX_RATE_BYTES];

    memset(block, 0, params->rate_bytes);
    if (len > 0) {
        memcpy(block, data, len);
    }

    /* SHA3 padding: 0x06 at end of data, 0x80 at end of block */
    block[len] = 0x06;
    block[params->rate_bytes - 1] |= 0x80;

    absorb_block(state, block, params->rate_words);
    keccak_f1600(state);
}

static void squeeze_hash(uint64_t state[5][5], uint8_t *hash, int out_bytes)
{
    int full_lanes = out_bytes / 8;
    int remaining = out_bytes % 8;
    int idx = 0;

    for (int i = 0; i < full_lanes; ++i) {
        uint64_t lane = state[i % 5][i / 5];
        memcpy(hash + idx, &lane, sizeof(uint64_t));
        idx += 8;
    }

    if (remaining) {
        uint64_t lane = state[full_lanes % 5][full_lanes / 5];
        memcpy(hash + idx, &lane, remaining);
    }
}

/* ===== File Hashing ===== */

static int hash_file(const char *path, const sha3_params_t *params,
                     uint8_t *hash, double *elapsed, long *file_size)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        PRINT_ERR("Cannot open '%s': %s\n", path, strerror(errno));
        return -1;
    }

    /* Get file size */
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size) *file_size = size;

    /* Allocate I/O buffer */
    uint8_t *iobuf = (uint8_t *)malloc(IO_BUF_SIZE);
    if (!iobuf) {
        PRINT_ERR("Memory allocation failed\n");
        fclose(f);
        return -1;
    }

    uint64_t state[5][5] = {{0}};
    const int rate = params->rate_bytes;
    const int words = params->rate_words;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* Process file in chunks */
    size_t tail = 0;
    while (1) {
        size_t bytes_read = fread(iobuf + tail, 1, IO_BUF_SIZE - tail, f);
        if (bytes_read == 0) break;

        size_t available = tail + bytes_read;
        size_t processed = 0;

        /* Absorb complete blocks */
        while (processed + rate <= available) {
            absorb_block(state, iobuf + processed, words);
            keccak_f1600(state);
            processed += rate;
        }

        /* Keep remaining bytes for next iteration */
        tail = available - processed;
        if (tail > 0) {
            memmove(iobuf, iobuf + processed, tail);
        }
    }

    /* Final block with padding */
    pad_and_absorb_final(state, iobuf, tail, params);

    clock_gettime(CLOCK_MONOTONIC, &t1);

    fclose(f);
    free(iobuf);

    /* Extract hash */
    squeeze_hash(state, hash, params->out_bytes);

    /* Calculate elapsed time */
    if (elapsed) {
        *elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    }

    return 0;
}

/* ===== Main ===== */

int main(int argc, char **argv)
{
    const char *filename = NULL;
    int hash_type = 256;  /* Default: SHA3-256 */

    quiet_mode = !APP_PRINTS_DEFAULT;

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-q") == 0 || strcmp(argv[i], "--quiet") == 0) {
            quiet_mode = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            fprintf(stderr, "Usage: %s <filename> [hash_type] [-q]\n", argv[0]);
            fprintf(stderr, "\nSHA3 software implementation for ARM Cortex-A53\n");
            fprintf(stderr, "  hash_type:    224, 256, 384, or 512 (default: 256)\n");
            fprintf(stderr, "  -q, --quiet   Suppress verbose output\n");
            return EXIT_SUCCESS;
        } else if (filename == NULL) {
            filename = argv[i];
        } else {
            /* Try to parse as hash type */
            int t = atoi(argv[i]);
            if (t == 224 || t == 256 || t == 384 || t == 512) {
                hash_type = t;
            }
        }
    }

    if (filename == NULL) {
        fprintf(stderr, "Usage: %s <filename> [hash_type] [-q]\n", argv[0]);
        fprintf(stderr, "\nSHA3 software implementation for ARM Cortex-A53\n");
        fprintf(stderr, "  hash_type:    224, 256, 384, or 512 (default: 256)\n");
        fprintf(stderr, "  -q, --quiet   Suppress verbose output\n");
        return EXIT_FAILURE;
    }

    if (access(filename, R_OK) != 0) {
        PRINT_ERR("Cannot access '%s': %s\n", filename, strerror(errno));
        return EXIT_FAILURE;
    }

    /* Initialize SHA3 parameters */
    sha3_params_t params;
    if (init_sha3_params(&params, hash_type) != 0) {
        PRINT_ERR("Invalid hash type: %d (use 224, 256, 384, or 512)\n", hash_type);
        return EXIT_FAILURE;
    }

    uint8_t hash[MAX_OUT_BYTES];
    double elapsed;
    long file_size;

    if (hash_file(filename, &params, hash, &elapsed, &file_size) != 0) {
        return EXIT_FAILURE;
    }

    /* Print hash (always, regardless of quiet mode) */
    printf("SHA3-%d: ", params.bits);
    for (int i = 0; i < params.out_bytes; ++i) {
        printf("%02x", hash[i]);
    }
    printf("\n");

    /* Print performance stats (respects quiet mode) */
    double size_mb = file_size / (1024.0 * 1024.0);
    double throughput_mbs = size_mb / elapsed;
    double throughput_gbps = throughput_mbs * 8 / 1024;

    PRINT("\nFile size:   %.2f MB\n", size_mb);
    PRINT("Time:        %.3f s\n", elapsed);
    PRINT("Throughput:  %.2f MB/s (%.3f Gbps)\n", throughput_mbs, throughput_gbps);

    return EXIT_SUCCESS;
}
