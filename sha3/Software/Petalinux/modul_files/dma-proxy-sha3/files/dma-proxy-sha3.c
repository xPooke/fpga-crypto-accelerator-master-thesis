/**
 * dma-proxy-sha3.c - Kernel driver for SHA3 DMA transfers
 * 
 * ON-DEMAND ALLOCATION VERSION
 * 
 * Both interfaces use on-demand buffer allocation:
 * 
 * 1. ZERO-COPY INTERFACE (HASH_FILE_DIRECT):
 *    - User passes file descriptor
 *    - Kernel allocates buffers, reads file, does DMA, frees buffers
 *    - Most efficient - no userspace copying
 * 
 * 2. LEGACY MMAP INTERFACE (ALLOC_BUFFERS + mmap + START_XFER):
 *    - User requests N buffers via ALLOC_BUFFERS
 *    - User mmaps the buffers and copies data
 *    - User triggers DMA via START_XFER
 *    - Buffers freed on FREE_BUFFERS or file close
 * 
 * IMPORTANT: Entire file must be sent in ONE DMA transfer because
 * SHA3 hardware uses TLAST signal for padding detection.
 */

#include <linux/dmaengine.h>
#include <linux/module.h>
#include <linux/version.h>
#include <linux/kernel.h>
#include <linux/dma-mapping.h>
#include <linux/slab.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/platform_device.h>
#include <linux/of_dma.h>
#include <linux/ioctl.h>
#include <linux/uaccess.h>
#include <linux/ktime.h>
#include <linux/completion.h>
#include <linux/property.h>
#include <linux/spinlock.h>
#include <linux/mutex.h>
#include <linux/fdtable.h>
#include <linux/file.h>
#include <linux/mm.h>

#include "dma-proxy-sha3.h"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Marko Gavrilović");
MODULE_DESCRIPTION("DMA Proxy SHA3 driver with on-demand allocation");

#define DRIVER_NAME "dma_proxy_sha3"

/* ============================================================================
 * DEBUG PRINT MACROS
 * ============================================================================ */

#if DMA_PROXY_PRINTS
#define DBG_PRINT(fmt, ...) pr_info("dma_proxy_sha3: " fmt, ##__VA_ARGS__)
#define INFO_PRINT(fmt, ...) pr_info("dma_proxy_sha3: " fmt, ##__VA_ARGS__)
#else
#define DBG_PRINT(fmt, ...) do {} while(0)
#define INFO_PRINT(fmt, ...) do {} while(0)
#endif

#define ERR_PRINT(fmt, ...) pr_err("dma_proxy_sha3: " fmt, ##__VA_ARGS__)

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================ */

/* Per-open-file state for legacy mmap interface */
struct mmap_session {
    struct channel_buffer *buffers;    /* mmap-able buffer array */
    dma_addr_t buffers_phys;           /* Physical address */
    int buffer_count;                   /* Number of allocated buffers */
    dma_addr_t *dma_handles;           /* DMA address for each buffer */
    
    /* Transfer state */
    int transfer_active;
    struct completion transfer_cmp;
    dma_cookie_t cookie;
    struct scatterlist *sg_list;       /* Keep sg_list alive during async transfer */
    
    /* Store config for async finish */
    int xfer_buffer_count;
    int xfer_buffer_ids[MAX_SG_ENTRIES];
    unsigned int xfer_lengths[MAX_SG_ENTRIES];
};

/* One DMA channel (TX or RX) */
struct dma_proxy_channel {
    struct device *proxy_device_p;
    struct device *dma_device_p;
    dev_t dev_node;
    struct cdev cdev;
    struct class *class_p;

    struct dma_chan *channel_p;
    u32 direction;
    char *name;
    
    struct mutex channel_mutex;  /* Protect channel operations */
};

/* Main driver structure */
struct dma_proxy {
    int channel_count;
    struct dma_proxy_channel *channels;
    char **names;
    
    struct dma_proxy_channel *tx_channel;
    struct dma_proxy_channel *rx_channel;
};

static int total_count;
static struct class *global_class_p = NULL;

/* ============================================================================
 * DMA CALLBACK
 * ============================================================================ */

static void sync_callback(void *completion)
{
    complete(completion);
}

/* ============================================================================
 * HELPER FUNCTIONS
 * ============================================================================ */

static int get_hash_size_from_type(int hash_type)
{
    switch (hash_type) {
    case 224: return SHA3_224_SIZE;
    case 256: return SHA3_256_SIZE;
    case 384: return SHA3_384_SIZE;
    case 512: return SHA3_512_SIZE;
    default:  return -EINVAL;
    }
}

/* ============================================================================
 * MMAP SESSION MANAGEMENT
 * ============================================================================ */

static struct mmap_session *alloc_mmap_session(void)
{
    struct mmap_session *session;
    
    session = kzalloc(sizeof(*session), GFP_KERNEL);
    if (!session)
        return NULL;
    
    init_completion(&session->transfer_cmp);
    return session;
}

static void free_mmap_buffers(struct device *dev, struct mmap_session *session)
{
    if (!session || !session->buffers)
        return;
    
    DBG_PRINT("Freeing %d mmap buffers\n", session->buffer_count);
    
    dma_free_coherent(dev,
                      sizeof(struct channel_buffer) * session->buffer_count,
                      session->buffers,
                      session->buffers_phys);
    
    kfree(session->dma_handles);
    session->buffers = NULL;
    session->dma_handles = NULL;
    session->buffer_count = 0;
}

static int alloc_mmap_buffers(struct device *dev, struct mmap_session *session, 
                              int count)
{
    int i;
    
    if (count <= 0 || count > MAX_BUFFERS) {
        ERR_PRINT("Invalid buffer count %d (max %d)\n", count, MAX_BUFFERS);
        return -EINVAL;
    }
    
    /* Free existing buffers if any */
    if (session->buffers) {
        free_mmap_buffers(dev, session);
    }
    
    /* Allocate buffer array (contiguous for mmap) */
    session->buffers = dma_alloc_coherent(dev,
                                          sizeof(struct channel_buffer) * count,
                                          &session->buffers_phys,
                                          GFP_KERNEL);
    if (!session->buffers) {
        ERR_PRINT("Failed to allocate %d buffers (%zu bytes)\n",
                  count, sizeof(struct channel_buffer) * count);
        return -ENOMEM;
    }
    
    /* Allocate DMA handle array */
    session->dma_handles = kzalloc(sizeof(dma_addr_t) * count, GFP_KERNEL);
    if (!session->dma_handles) {
        dma_free_coherent(dev,
                          sizeof(struct channel_buffer) * count,
                          session->buffers,
                          session->buffers_phys);
        session->buffers = NULL;
        return -ENOMEM;
    }
    
    /* Calculate DMA handle for each buffer */
    for (i = 0; i < count; i++) {
        session->dma_handles[i] = session->buffers_phys +
                                  (sizeof(struct channel_buffer) * i) +
                                  offsetof(struct channel_buffer, buffer);
    }
    
    session->buffer_count = count;
    
    INFO_PRINT("Allocated %d buffers (%d MB)\n",
               count, (count * BUFFER_SIZE) / (1024 * 1024));
    
    return 0;
}

/* ============================================================================
 * LEGACY MMAP INTERFACE - DMA TRANSFER
 * ============================================================================ */

static int do_legacy_transfer(struct dma_proxy_channel *pchannel_p,
                              struct mmap_session *session,
                              struct sg_transfer_config *config,
                              int wait)
{
    struct scatterlist *sg_list = NULL;
    struct dma_async_tx_descriptor *desc;
    enum dma_ctrl_flags flags;
    unsigned long timeout;
    enum dma_status status;
    int i, ret = 0;

    if (!session->buffers) {
        ERR_PRINT("No buffers allocated\n");
        return -EINVAL;
    }

    if (config->buffer_count <= 0 || config->buffer_count > session->buffer_count) {
        ERR_PRINT("Invalid buffer count %d (allocated %d)\n",
                  config->buffer_count, session->buffer_count);
        return -EINVAL;
    }

    /* Validate buffer IDs */
    for (i = 0; i < config->buffer_count; i++) {
        if (config->buffer_ids[i] < 0 || 
            config->buffer_ids[i] >= session->buffer_count) {
            ERR_PRINT("Invalid buffer ID %d\n", config->buffer_ids[i]);
            return -EINVAL;
        }
    }

    mutex_lock(&pchannel_p->channel_mutex);

    if (session->transfer_active) {
        mutex_unlock(&pchannel_p->channel_mutex);
        ERR_PRINT("Transfer already active\n");
        return -EBUSY;
    }

    /* Allocate SG list */
    sg_list = kzalloc(sizeof(struct scatterlist) * config->buffer_count, GFP_KERNEL);
    if (!sg_list) {
        mutex_unlock(&pchannel_p->channel_mutex);
        return -ENOMEM;
    }

    sg_init_table(sg_list, config->buffer_count);

    /* Build SG list */
    for (i = 0; i < config->buffer_count; i++) {
        int buf_id = config->buffer_ids[i];
        
        /* Sync buffer for DMA */
        if (pchannel_p->direction == DMA_MEM_TO_DEV) {
            dma_sync_single_for_device(pchannel_p->dma_device_p,
                                       session->dma_handles[buf_id],
                                       config->lengths[i],
                                       DMA_TO_DEVICE);
        }
        
        sg_dma_address(&sg_list[i]) = session->dma_handles[buf_id];
        sg_dma_len(&sg_list[i]) = config->lengths[i];
    }
    sg_mark_end(&sg_list[config->buffer_count - 1]);

    /* Prepare DMA descriptor */
    flags = DMA_CTRL_ACK | DMA_PREP_INTERRUPT;
    desc = dmaengine_prep_slave_sg(pchannel_p->channel_p, sg_list,
                                    config->buffer_count,
                                    pchannel_p->direction, flags);
    if (!desc) {
        ERR_PRINT("prep_slave_sg failed\n");
        ret = -ENOMEM;
        goto out;
    }

    /* Setup completion */
    reinit_completion(&session->transfer_cmp);
    desc->callback = sync_callback;
    desc->callback_param = &session->transfer_cmp;

    /* Submit */
    session->cookie = dmaengine_submit(desc);
    if (dma_submit_error(session->cookie)) {
        ERR_PRINT("DMA submit failed\n");
        ret = -EINVAL;
        goto out;
    }

    session->transfer_active = 1;
    session->buffers[config->buffer_ids[0]].status = PROXY_BUSY;
    
    /* Store config for async finish */
    session->sg_list = sg_list;
    session->xfer_buffer_count = config->buffer_count;
    for (i = 0; i < config->buffer_count; i++) {
        session->xfer_buffer_ids[i] = config->buffer_ids[i];
        session->xfer_lengths[i] = config->lengths[i];
    }

    /* Start DMA */
    dma_async_issue_pending(pchannel_p->channel_p);

    DBG_PRINT("DMA started: %d buffers, direction %s\n",
              config->buffer_count,
              pchannel_p->direction == DMA_MEM_TO_DEV ? "TX" : "RX");

    if (!wait) {
        /* Non-blocking - caller will call FINISH_XFER */
        /* Don't free sg_list here - it's needed until DMA completes */
        mutex_unlock(&pchannel_p->channel_mutex);
        return 0;
    }

    /* Wait for completion */
    timeout = msecs_to_jiffies(30000 + (config->buffer_count * 100));
    timeout = wait_for_completion_timeout(&session->transfer_cmp, timeout);

    status = dma_async_is_tx_complete(pchannel_p->channel_p,
                                       session->cookie, NULL, NULL);

    /* Sync buffers for CPU if RX */
    if (pchannel_p->direction == DMA_DEV_TO_MEM) {
        for (i = 0; i < config->buffer_count; i++) {
            int buf_id = config->buffer_ids[i];
            dma_sync_single_for_cpu(pchannel_p->dma_device_p,
                                    session->dma_handles[buf_id],
                                    config->lengths[i],
                                    DMA_FROM_DEVICE);
        }
    }

    session->transfer_active = 0;
    
    /* Now safe to free sg_list */
    kfree(sg_list);
    session->sg_list = NULL;

    if (timeout == 0) {
        session->buffers[config->buffer_ids[0]].status = PROXY_TIMEOUT;
        dmaengine_terminate_sync(pchannel_p->channel_p);
        ret = -ETIMEDOUT;
    } else if (status != DMA_COMPLETE) {
        session->buffers[config->buffer_ids[0]].status = PROXY_ERROR;
        ret = -EIO;
    } else {
        session->buffers[config->buffer_ids[0]].status = PROXY_NO_ERROR;
        ret = 0;
    }

    mutex_unlock(&pchannel_p->channel_mutex);
    return ret;

out:
    kfree(sg_list);
    session->sg_list = NULL;
    mutex_unlock(&pchannel_p->channel_mutex);
    return ret;
}

static int finish_legacy_transfer(struct dma_proxy_channel *pchannel_p,
                                  struct mmap_session *session)
{
    unsigned long timeout;
    enum dma_status status;
    int i;

    mutex_lock(&pchannel_p->channel_mutex);

    if (!session->transfer_active) {
        mutex_unlock(&pchannel_p->channel_mutex);
        return -EINVAL;
    }

    /* Wait for completion */
    timeout = wait_for_completion_timeout(&session->transfer_cmp,
                                          msecs_to_jiffies(30000));

    status = dma_async_is_tx_complete(pchannel_p->channel_p,
                                       session->cookie, NULL, NULL);

    /* Sync buffers for CPU if RX */
    if (pchannel_p->direction == DMA_DEV_TO_MEM) {
        for (i = 0; i < session->xfer_buffer_count; i++) {
            int buf_id = session->xfer_buffer_ids[i];
            dma_sync_single_for_cpu(pchannel_p->dma_device_p,
                                    session->dma_handles[buf_id],
                                    session->xfer_lengths[i],
                                    DMA_FROM_DEVICE);
        }
    }

    session->transfer_active = 0;
    
    /* Free sg_list that was kept alive */
    if (session->sg_list) {
        kfree(session->sg_list);
        session->sg_list = NULL;
    }

    mutex_unlock(&pchannel_p->channel_mutex);

    if (timeout == 0) {
        dmaengine_terminate_sync(pchannel_p->channel_p);
        return -ETIMEDOUT;
    } else if (status != DMA_COMPLETE) {
        return -EIO;
    }

    return 0;
}

/* ============================================================================
 * ZERO-COPY FILE HASHING
 * ============================================================================ */

static int do_zero_copy_hash(struct dma_proxy *lp, struct hash_file_request *req)
{
    struct dma_proxy_channel *tx_chan = lp->tx_channel;
    struct dma_proxy_channel *rx_chan = lp->rx_channel;
    struct file *input_file = NULL;
    void **tx_cpu_addrs = NULL;
    dma_addr_t *tx_dma_addrs = NULL;
    void *rx_cpu_addr = NULL;
    dma_addr_t rx_dma_addr;
    struct scatterlist *tx_sg_list = NULL;
    struct scatterlist rx_sg;
    struct dma_async_tx_descriptor *tx_desc, *rx_desc;
    enum dma_ctrl_flags flags;
    struct completion tx_cmp, rx_cmp;
    dma_cookie_t tx_cookie, rx_cookie;
    loff_t file_size, pos = 0;
    ktime_t time_start, time_start_dma, time_file_loaded, time_dma_done, total_dma_time;
    int hash_size;
    int num_buffers;
    ssize_t bytes_read;
    size_t total_read = 0;
    unsigned long timeout;
    enum dma_status status;
    int ret = 0;
    int i;

    /* Validate hash type */
    hash_size = get_hash_size_from_type(req->hash_type);
    if (hash_size < 0) {
        ERR_PRINT("Invalid hash type %d\n", req->hash_type);
        return -EINVAL;
    }
    req->hash_size = hash_size;

    /* Get file */
    input_file = fget(req->input_fd);
    if (!input_file) {
        ERR_PRINT("Invalid file descriptor %d\n", req->input_fd);
        return -EBADF;
    }

    /* Get file size */
    file_size = i_size_read(file_inode(input_file));
    if (file_size <= 0) {
        ERR_PRINT("Empty file or cannot get size\n");
        ret = -EINVAL;
        goto out_fput;
    }
    req->file_size = file_size;

    /* Calculate buffers needed */
    num_buffers = (file_size + BUFFER_SIZE - 1) / BUFFER_SIZE;
    if (num_buffers > MAX_BUFFERS) {
        ERR_PRINT("File too large: %lld bytes (%d buffers, max %d)\n",
                  file_size, num_buffers, MAX_BUFFERS);
        ret = -EFBIG;
        goto out_fput;
    }
    req->buffers_used = num_buffers;

    INFO_PRINT("Zero-copy hash: %lld bytes, %d buffers, SHA3-%d\n",
               file_size, num_buffers, req->hash_type);

    /* Take mutexes */
    mutex_lock(&tx_chan->channel_mutex);
    mutex_lock(&rx_chan->channel_mutex);

    time_start = ktime_get();

    /* Allocate TX buffer tracking arrays */
    tx_cpu_addrs = kzalloc(sizeof(void *) * num_buffers, GFP_KERNEL);
    tx_dma_addrs = kzalloc(sizeof(dma_addr_t) * num_buffers, GFP_KERNEL);
    if (!tx_cpu_addrs || !tx_dma_addrs) {
        ret = -ENOMEM;
        goto out_unlock;
    }

    /* Allocate TX DMA buffers */
    for (i = 0; i < num_buffers; i++) {
        tx_cpu_addrs[i] = dma_alloc_coherent(tx_chan->dma_device_p, BUFFER_SIZE,
                                              &tx_dma_addrs[i], GFP_KERNEL);
        if (!tx_cpu_addrs[i]) {
            ERR_PRINT("Failed to allocate TX buffer %d\n", i);
            ret = -ENOMEM;
            goto out_free_tx;
        }
    }

    /* Read file into TX buffers */
    for (i = 0; i < num_buffers; i++) {
        size_t to_read = min_t(size_t, BUFFER_SIZE, file_size - pos);
        
        bytes_read = kernel_read(input_file, tx_cpu_addrs[i], to_read, &pos);
        if (bytes_read < 0) {
            ERR_PRINT("kernel_read failed: %zd\n", bytes_read);
            ret = bytes_read;
            goto out_free_tx;
        }
        if (bytes_read == 0)
            break;
        
        total_read += bytes_read;
        
        dma_sync_single_for_device(tx_chan->dma_device_p, tx_dma_addrs[i],
                                   bytes_read, DMA_TO_DEVICE);
    }

    time_file_loaded = ktime_get();
    DBG_PRINT("File loaded: %zu bytes\n", total_read);

    /* Allocate RX buffer */
    rx_cpu_addr = dma_alloc_coherent(rx_chan->dma_device_p, SHA3_512_SIZE,
                                      &rx_dma_addr, GFP_KERNEL);
    if (!rx_cpu_addr) {
        ERR_PRINT("Failed to allocate RX buffer\n");
        ret = -ENOMEM;
        goto out_free_tx;
    }

    /* Setup RX */
    sg_init_one(&rx_sg, rx_cpu_addr, hash_size);
    sg_dma_address(&rx_sg) = rx_dma_addr;
    sg_dma_len(&rx_sg) = hash_size;

    flags = DMA_CTRL_ACK | DMA_PREP_INTERRUPT;
    rx_desc = dmaengine_prep_slave_sg(rx_chan->channel_p, &rx_sg, 1,
                                       DMA_DEV_TO_MEM, flags);
    if (!rx_desc) {
        ERR_PRINT("RX prep failed\n");
        ret = -ENOMEM;
        goto out_free_rx;
    }

    init_completion(&rx_cmp);
    rx_desc->callback = sync_callback;
    rx_desc->callback_param = &rx_cmp;

    rx_cookie = dmaengine_submit(rx_desc);
    if (dma_submit_error(rx_cookie)) {
        ret = -EINVAL;
        goto out_free_rx;
    }

    dma_async_issue_pending(rx_chan->channel_p);

    /* Setup TX SG list */
    tx_sg_list = kzalloc(sizeof(struct scatterlist) * num_buffers, GFP_KERNEL);
    if (!tx_sg_list) {
        ret = -ENOMEM;
        goto out_terminate_rx;
    }

    sg_init_table(tx_sg_list, num_buffers);
    pos = 0;
    for (i = 0; i < num_buffers; i++) {
        size_t chunk = min_t(size_t, BUFFER_SIZE, total_read - pos);
        sg_dma_address(&tx_sg_list[i]) = tx_dma_addrs[i];
        sg_dma_len(&tx_sg_list[i]) = chunk;
        pos += chunk;
    }
    sg_mark_end(&tx_sg_list[num_buffers - 1]);

    tx_desc = dmaengine_prep_slave_sg(tx_chan->channel_p, tx_sg_list,
                                       num_buffers, DMA_MEM_TO_DEV, flags);
    if (!tx_desc) {
        ERR_PRINT("TX prep failed\n");
        ret = -ENOMEM;
        goto out_free_sg;
    }

    init_completion(&tx_cmp);
    tx_desc->callback = sync_callback;
    tx_desc->callback_param = &tx_cmp;

    tx_cookie = dmaengine_submit(tx_desc);
    if (dma_submit_error(tx_cookie)) {
        ret = -EINVAL;
        goto out_free_sg;
    }
    /* start DMA timer */
    time_start_dma = ktime_get();
    dma_async_issue_pending(tx_chan->channel_p);
    DBG_PRINT("TX started: %zu bytes\n", total_read);

    /* Wait for TX */
    timeout = msecs_to_jiffies(3000); // 3 seconds
    timeout = wait_for_completion_timeout(&tx_cmp, timeout);
    if (timeout == 0) {
        ERR_PRINT("TX timeout\n");
        dmaengine_terminate_sync(tx_chan->channel_p);
        ret = -ETIMEDOUT;
        goto out_terminate_rx;
    }

    status = dma_async_is_tx_complete(tx_chan->channel_p, tx_cookie, NULL, NULL);
    if (status != DMA_COMPLETE) {
        ERR_PRINT("TX error %d\n", status);
        ret = -EIO;
        goto out_terminate_rx;
    }

    /* Wait for RX */
    timeout = wait_for_completion_timeout(&rx_cmp, msecs_to_jiffies(3000));
    if (timeout == 0) {
        ERR_PRINT("RX timeout\n");
        dmaengine_terminate_sync(rx_chan->channel_p);
        ret = -ETIMEDOUT;
        goto out_free_sg;
    }

    status = dma_async_is_tx_complete(rx_chan->channel_p, rx_cookie, NULL, NULL);
    if (status != DMA_COMPLETE) {
        ERR_PRINT("RX error %d\n", status);
        ret = -EIO;
        goto out_free_sg;
    }
    /* end DMA timer */
    time_dma_done = ktime_get();

    /* Get hash */
    dma_sync_single_for_cpu(rx_chan->dma_device_p, rx_dma_addr,
                            hash_size, DMA_FROM_DEVICE);
    memcpy(req->hash, rx_cpu_addr, hash_size);

    req->transfer_time_ns = ktime_to_ns(ktime_sub(time_dma_done, time_start_dma));
    req->total_time_ns = ktime_to_ns(ktime_sub(time_dma_done, time_start));
    total_dma_time = ktime_to_ns(ktime_sub(time_dma_done,time_file_loaded));
    INFO_PRINT("Hash done: DMA %.3f ms, Total DMA time %3f ms, Total %.3f ms\n",
               req->transfer_time_ns / 1000000.0,
               total_dma_time / 1000000.0 , 
               req->total_time_ns / 1000000.0
               );

    ret = 0;

out_terminate_rx:
    if (ret < 0)
        dmaengine_terminate_sync(rx_chan->channel_p);
out_free_sg:
    kfree(tx_sg_list);
out_free_rx:
    if (rx_cpu_addr)
        dma_free_coherent(rx_chan->dma_device_p, SHA3_512_SIZE,
                          rx_cpu_addr, rx_dma_addr);
out_free_tx:
    for (i = 0; i < num_buffers; i++) {
        if (tx_cpu_addrs && tx_cpu_addrs[i])
            dma_free_coherent(tx_chan->dma_device_p, BUFFER_SIZE,
                              tx_cpu_addrs[i], tx_dma_addrs[i]);
    }
    kfree(tx_cpu_addrs);
    kfree(tx_dma_addrs);
out_unlock:
    mutex_unlock(&rx_chan->channel_mutex);
    mutex_unlock(&tx_chan->channel_mutex);
out_fput:
    fput(input_file);

    return ret;
}

/* ============================================================================
 * CHARACTER DEVICE OPERATIONS
 * ============================================================================ */

static int local_open(struct inode *ino, struct file *file)
{
    struct dma_proxy_channel *pchannel_p;
    struct mmap_session *session;

    pchannel_p = container_of(ino->i_cdev, struct dma_proxy_channel, cdev);

    session = alloc_mmap_session();
    if (!session)
        return -ENOMEM;

    file->private_data = session;
    
    /* Store channel pointer in session for later use */
    /* We use a trick: store it after the session struct */
    
    DBG_PRINT("Opened %s\n", pchannel_p->name);
    return 0;
}

static int release(struct inode *ino, struct file *file)
{
    struct dma_proxy_channel *pchannel_p;
    struct mmap_session *session = file->private_data;

    pchannel_p = container_of(ino->i_cdev, struct dma_proxy_channel, cdev);

    if (session) {
        /* Terminate any active transfer */
        if (session->transfer_active) {
            dmaengine_terminate_sync(pchannel_p->channel_p);
            session->transfer_active = 0;
        }
        
        /* Free sg_list if still allocated */
        if (session->sg_list) {
            kfree(session->sg_list);
            session->sg_list = NULL;
        }
        
        /* Free buffers */
        free_mmap_buffers(pchannel_p->dma_device_p, session);
        kfree(session);
    }

    DBG_PRINT("Closed %s\n", pchannel_p->name);
    return 0;
}

static int dma_proxy_mmap(struct file *file, struct vm_area_struct *vma)
{
    struct dma_proxy_channel *pchannel_p;
    struct mmap_session *session = file->private_data;
    size_t size = vma->vm_end - vma->vm_start;
    size_t expected_size;

    pchannel_p = container_of(file->f_inode->i_cdev, struct dma_proxy_channel, cdev);

    if (!session || !session->buffers) {
        ERR_PRINT("No buffers allocated for mmap\n");
        return -EINVAL;
    }

    expected_size = sizeof(struct channel_buffer) * session->buffer_count;
    if (size > expected_size) {
        ERR_PRINT("mmap size %zu > allocated %zu\n", size, expected_size);
        return -EINVAL;
    }

    return dma_mmap_coherent(pchannel_p->dma_device_p, vma,
                             session->buffers, session->buffers_phys, size);
}

static long ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct dma_proxy_channel *pchannel_p;
    struct mmap_session *session = file->private_data;
    struct dma_proxy *lp;
    struct sg_transfer_config sg_config;
    struct hash_file_request hash_req;
    struct buffer_info buf_info;
    unsigned int count;
    int ret;

    pchannel_p = container_of(file->f_inode->i_cdev, struct dma_proxy_channel, cdev);
    lp = dev_get_drvdata(pchannel_p->dma_device_p);

    switch (cmd) {
    case ALLOC_BUFFERS:
        if (copy_from_user(&count, (void __user *)arg, sizeof(count)))
            return -EFAULT;
        return alloc_mmap_buffers(pchannel_p->dma_device_p, session, count);

    case FREE_BUFFERS:
        free_mmap_buffers(pchannel_p->dma_device_p, session);
        return 0;

    case GET_BUFFER_INFO:
        buf_info.buffer_count = session->buffer_count;
        buf_info.buffer_size = BUFFER_SIZE;
        buf_info.total_size = (unsigned long)session->buffer_count * BUFFER_SIZE;
        if (copy_to_user((void __user *)arg, &buf_info, sizeof(buf_info)))
            return -EFAULT;
        return 0;

    case START_XFER:
        if (copy_from_user(&sg_config, (void __user *)arg, sizeof(sg_config)))
            return -EFAULT;
        return do_legacy_transfer(pchannel_p, session, &sg_config, 1);

    case START_XFER_ASYNC:
        if (copy_from_user(&sg_config, (void __user *)arg, sizeof(sg_config)))
            return -EFAULT;
        return do_legacy_transfer(pchannel_p, session, &sg_config, 0);

    case FINISH_XFER:
        return finish_legacy_transfer(pchannel_p, session);

    case HASH_FILE_DIRECT:
        if (!lp || !lp->tx_channel || !lp->rx_channel) {
            ERR_PRINT("Driver not initialized for zero-copy\n");
            return -EINVAL;
        }
        if (copy_from_user(&hash_req, (void __user *)arg, sizeof(hash_req)))
            return -EFAULT;
        ret = do_zero_copy_hash(lp, &hash_req);
        if (ret < 0)
            return ret;
        if (copy_to_user((void __user *)arg, &hash_req, sizeof(hash_req)))
            return -EFAULT;
        return 0;

    default:
        return -EINVAL;
    }
}

static const struct file_operations dm_fops = {
    .owner          = THIS_MODULE,
    .open           = local_open,
    .release        = release,
    .unlocked_ioctl = ioctl,
    .mmap           = dma_proxy_mmap
};

/* ============================================================================
 * DEVICE SETUP
 * ============================================================================ */

static int cdevice_init(struct dma_proxy_channel *pchannel_p, char *name)
{
    int rc;

    rc = alloc_chrdev_region(&pchannel_p->dev_node, 0, 1, "dma_proxy_sha3");
    if (rc)
        return rc;

    cdev_init(&pchannel_p->cdev, &dm_fops);
    pchannel_p->cdev.owner = THIS_MODULE;
    rc = cdev_add(&pchannel_p->cdev, pchannel_p->dev_node, 1);
    if (rc)
        goto err_region;

    if (!global_class_p) {
        global_class_p = class_create(
#if LINUX_VERSION_CODE <= KERNEL_VERSION(6, 3, 13)
            THIS_MODULE,
#endif
            DRIVER_NAME
        );
        if (IS_ERR(global_class_p)) {
            rc = PTR_ERR(global_class_p);
            global_class_p = NULL;
            goto err_cdev;
        }
    }
    pchannel_p->class_p = global_class_p;

    pchannel_p->proxy_device_p = device_create(pchannel_p->class_p, NULL,
                                               pchannel_p->dev_node, NULL, name);
    if (IS_ERR(pchannel_p->proxy_device_p)) {
        rc = PTR_ERR(pchannel_p->proxy_device_p);
        goto err_cdev;
    }

    return 0;

err_cdev:
    cdev_del(&pchannel_p->cdev);
err_region:
    unregister_chrdev_region(pchannel_p->dev_node, 1);
    return rc;
}

static void cdevice_exit(struct dma_proxy_channel *pchannel_p)
{
    if (pchannel_p->proxy_device_p) {
        device_destroy(pchannel_p->class_p, pchannel_p->dev_node);
        cdev_del(&pchannel_p->cdev);
        unregister_chrdev_region(pchannel_p->dev_node, 1);
        pchannel_p->proxy_device_p = NULL;
    }
}

static int create_channel(struct platform_device *pdev,
                          struct dma_proxy_channel *pchannel_p,
                          char *name, struct dma_proxy *lp)
{
    int rc;
    u32 direction;

    if (strstr(name, "tx") || strstr(name, "TX") || strstr(name, "mm2s")) {
        direction = DMA_MEM_TO_DEV;
        lp->tx_channel = pchannel_p;
        INFO_PRINT("Channel %s: TX\n", name);
    } else {
        direction = DMA_DEV_TO_MEM;
        lp->rx_channel = pchannel_p;
        INFO_PRINT("Channel %s: RX\n", name);
    }

    pchannel_p->dma_device_p = &pdev->dev;
    pchannel_p->direction = direction;
    pchannel_p->name = name;
    mutex_init(&pchannel_p->channel_mutex);

    pchannel_p->channel_p = dma_request_chan(&pdev->dev, name);
    if (IS_ERR(pchannel_p->channel_p)) {
        ERR_PRINT("DMA channel request failed: %s\n", name);
        return PTR_ERR(pchannel_p->channel_p);
    }

    rc = cdevice_init(pchannel_p, name);
    if (rc)
        return rc;

    return 0;
}

/* ============================================================================
 * PLATFORM DRIVER
 * ============================================================================ */

static int dma_proxy_sha3_probe(struct platform_device *pdev)
{
    struct dma_proxy *lp;
    struct device *dev = &pdev->dev;
    int rc, i;

#if DMA_PROXY_PRINTS
    pr_info("========================================\n");
    pr_info("DMA Proxy SHA3 (On-Demand Allocation)\n");
    pr_info("========================================\n");
    pr_info("Buffer size: %d MB\n", BUFFER_SIZE / (1024 * 1024));
    pr_info("Max buffers: %d (%d MB max)\n", MAX_BUFFERS,
            (MAX_BUFFERS * BUFFER_SIZE) / (1024 * 1024));
    pr_info("========================================\n");
#endif

    lp = devm_kzalloc(dev, sizeof(*lp), GFP_KERNEL);
    if (!lp)
        return -ENOMEM;

    dev_set_drvdata(dev, lp);

    lp->channel_count = device_property_read_string_array(dev, "dma-names",
                                                          NULL, 0);
    if (lp->channel_count <= 0) {
        ERR_PRINT("No DMA channels found\n");
        return -ENODEV;
    }

    lp->names = devm_kmalloc_array(dev, lp->channel_count,
                                   sizeof(char *), GFP_KERNEL);
    if (!lp->names)
        return -ENOMEM;

    rc = device_property_read_string_array(dev, "dma-names",
                                           (const char **)lp->names,
                                           lp->channel_count);
    if (rc < 0)
        return rc;

    lp->channels = devm_kzalloc(dev, sizeof(struct dma_proxy_channel) *
                                lp->channel_count, GFP_KERNEL);
    if (!lp->channels)
        return -ENOMEM;

    for (i = 0; i < lp->channel_count; i++) {
        rc = create_channel(pdev, &lp->channels[i], lp->names[i], lp);
        if (rc)
            return rc;
        total_count++;
    }

    INFO_PRINT("Driver loaded\n");
    return 0;
}

static void dma_proxy_sha3_remove(struct platform_device *pdev)
{
    struct dma_proxy *lp = dev_get_drvdata(&pdev->dev);
    int i;

    for (i = 0; i < lp->channel_count; i++) {
        if (lp->channels[i].channel_p)
            dmaengine_terminate_sync(lp->channels[i].channel_p);
    }

    for (i = 0; i < lp->channel_count; i++) {
        cdevice_exit(&lp->channels[i]);
        total_count--;
    }

    for (i = 0; i < lp->channel_count; i++) {
        if (lp->channels[i].channel_p) {
            dma_release_channel(lp->channels[i].channel_p);
            lp->channels[i].channel_p = NULL;
        }
    }

    if (total_count == 0 && global_class_p) {
        class_destroy(global_class_p);
        global_class_p = NULL;
    }

    INFO_PRINT("Driver unloaded\n");
}

static const struct of_device_id dma_proxy_sha3_of_ids[] = {
    { .compatible = "xlnx,dma_proxy_sha3", },
    { }
};
MODULE_DEVICE_TABLE(of, dma_proxy_sha3_of_ids);

static struct platform_driver dma_proxy_sha3_driver = {
    .driver = {
        .name           = "dma_proxy_sha3_driver",
        .owner          = THIS_MODULE,
        .of_match_table = dma_proxy_sha3_of_ids,
    },
    .probe  = dma_proxy_sha3_probe,
    .remove = dma_proxy_sha3_remove,
};

module_platform_driver(dma_proxy_sha3_driver);
