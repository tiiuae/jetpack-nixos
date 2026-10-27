/**
 * 
 * NVIDIA BPMP Host Proxy Kernel Module
 * (c) 2023 Unikie, Oy
 * (c) 2023 Vadim Likholetov vadim.likholetov@unikie.com
 * 
*/
#include <linux/module.h>	  // Core header for modules.
#include <linux/device.h>	  // Supports driver model.
#include <linux/kernel.h>	  // Kernel header for convenient functions.
#include <linux/fs.h>		  // File-system support.
#include <linux/uaccess.h>	  // User access copy function support.
#include <linux/slab.h>
#include <soc/tegra/bpmp.h>
#include <linux/platform_device.h>
#include <linux/version.h>
#include <linux/miscdevice.h>
#include "bpmp-host-proxy.h"


#define DEVICE_NAME "bpmp-host"   // Device name.
#define MRQ_CLK_ID_MASK GENMASK(23, 0)
#define MRQ_CLK_CMD_SHIFT 24

MODULE_LICENSE("GPL");						 ///< The license type -- this affects available functionality
MODULE_AUTHOR("Vadim Likholetov");					 ///< The author -- visible when you use modinfo
MODULE_DESCRIPTION("NVidia BPMP Host Proxy Kernel Module"); ///< The description -- see modinfo
MODULE_VERSION("0.1");						 ///< A version number to inform users


#define BPMP_HOST_VERBOSE    0

/**
 * Put this flag in 0 in order that the BPMP host proxy only allows
 * the allowed BPMP resources to be used by the VMs.
 * 
 * Put this flag in 1 in order that the BPMP host proxy allows
 * all the BPMP resources to be accessible by the virtual machines.
 * This option is useful for debugging, but is INSECURE, and it could
 * stop the host. To avoid stop the host use 
 * "clk_ignore_unused pd_ignore_unused" in kernel command line
 * 
*/
#define BPMP_HOST_ALLOWS_ALL   0

#if BPMP_HOST_VERBOSE
#define deb_info(...)     printk(KERN_INFO DEVICE_NAME ": "__VA_ARGS__)
#else
#define deb_info(...)
#endif

#define deb_error(...)    printk(KERN_ALERT DEVICE_NAME ": "__VA_ARGS__)
#define deb_warn(...)     printk(KERN_WARNING DEVICE_NAME ": "__VA_ARGS__)

struct bpmp_host_proxy {
	struct miscdevice miscdev;
	struct bpmp_allowed_res allowed;
};

/**
 * Prototype functions for file operations.
 */
static int open(struct inode *, struct file *);
static int close(struct inode *, struct file *);
static ssize_t read(struct file *, char __user *, size_t, loff_t *);
static ssize_t write(struct file *, const char __user *, size_t, loff_t *);

/**
 * File operations structure and the functions it points to.
 */
static const struct file_operations fops =
	{
		.owner = THIS_MODULE,
		.open = open,
		.release = close,
		.read = read,
		.write = write,
};

#if BPMP_HOST_VERBOSE
// Usage:
//     hexDump(desc, addr, len, perLine);
//         desc:    if non-NULL, printed as a description before hex dump.
//         addr:    the address to start dumping from.
//         len:     the number of bytes to dump.
//         perLine: number of bytes on each output line.
void static hexDump (
    const char * desc,
    const void * addr,
    const int len
) {
    // Silently ignore silly per-line values.

    int i;
    unsigned char buff[17];
	unsigned char out_buff[4000];
	unsigned char *p_out_buff = out_buff;
    const unsigned char * pc = (const unsigned char *)addr;



    // Output description if given.

    if (desc != NULL) printk ("%s:\n", desc);

    // Length checks.

    if (len == 0) {
        printk(DEVICE_NAME ":   ZERO LENGTH\n");
        return;
    }
    if (len < 0) {
        printk(DEVICE_NAME ":   NEGATIVE LENGTH: %d\n", len);
        return;
    }

	if(len > 400){
        printk(DEVICE_NAME ":   VERY LONG: %d\n", len);
        return;
    }

    // Process every byte in the data.

    for (i = 0; i < len; i++) {
        // Multiple of perLine means new or first line (with line offset).

        if ((i % 16) == 0) {
            // Only print previous-line ASCII buffer for lines beyond first.

            if (i != 0) {
				p_out_buff += sprintf (p_out_buff, "  %s\n", buff);
			}
            // Output the offset of current line.

            p_out_buff += sprintf (p_out_buff,"  %04x ", i);
        }

        // Now the hex code for the specific character.

        p_out_buff += sprintf (p_out_buff, " %02x", pc[i]);

        // And buffer a printable ASCII character for later.

        if ((pc[i] < 0x20) || (pc[i] > 0x7e)) // isprint() may be better.
            buff[i % 16] = '.';
        else
            buff[i % 16] = pc[i];
        buff[(i % 16) + 1] = '\0';
    }

    // Pad out last line if not exactly perLine characters.

    while ((i % 16) != 0) {
        p_out_buff += sprintf (p_out_buff, "   ");
        i++;
    }

    // And print the final ASCII buffer.

    p_out_buff += sprintf (p_out_buff, "  %s\n", buff);

	printk(DEVICE_NAME ": %s", out_buff);
}
#else
	#define hexDump(...)
#endif

/**
 * Initializes module at installation
 */
static int bpmp_host_proxy_probe(struct platform_device *pdev)
{
	struct bpmp_host_proxy *proxy;
	const char *device_name;
	int i;
	int ret;

	deb_info("%s, installing module.", __func__);

	proxy = devm_kzalloc(&pdev->dev, sizeof(*proxy), GFP_KERNEL);
	if (!proxy)
		return -ENOMEM;

	ret = of_property_read_string(pdev->dev.of_node, "device-name", &device_name);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "missing device-name\n");

	proxy->allowed.clocks_size = of_property_read_variable_u32_array(
		pdev->dev.of_node, "allowed-clocks", proxy->allowed.clock, 0,
		BPMP_HOST_MAX_CLOCKS_SIZE);
	if (proxy->allowed.clocks_size <= 0 && !BPMP_HOST_ALLOWS_ALL)
		return dev_err_probe(&pdev->dev, -EINVAL, "no allowed clocks defined\n");

	for (i = 0; i < proxy->allowed.clocks_size; i++)
		deb_info("allowed clock %d", proxy->allowed.clock[i]);

	proxy->allowed.resets_size = of_property_read_variable_u32_array(
		pdev->dev.of_node, "allowed-resets", proxy->allowed.reset, 0,
		BPMP_HOST_MAX_RESETS_SIZE);
	if (proxy->allowed.resets_size <= 0 && !BPMP_HOST_ALLOWS_ALL)
		return dev_err_probe(&pdev->dev, -EINVAL, "no allowed resets defined\n");

	for (i = 0; i < proxy->allowed.resets_size; i++)
		deb_info("allowed reset %d", proxy->allowed.reset[i]);

	proxy->allowed.pd_size = of_property_read_variable_u32_array(
		pdev->dev.of_node, "allowed-power-domains", proxy->allowed.pd, 0,
		BPMP_HOST_MAX_POWER_DOMAINS_SIZE);
	for (i = 0; i < proxy->allowed.pd_size; i++)
		deb_info("allowed power domain %d", proxy->allowed.pd[i]);

	proxy->miscdev.minor = MISC_DYNAMIC_MINOR;
	proxy->miscdev.name = devm_kstrdup(&pdev->dev, device_name, GFP_KERNEL);
	proxy->miscdev.fops = &fops;
	proxy->miscdev.parent = &pdev->dev;
	if (!proxy->miscdev.name)
		return -ENOMEM;

	ret = misc_register(&proxy->miscdev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "failed to register %s\n", device_name);

	platform_set_drvdata(pdev, proxy);
	return 0;
}



/*
 * Removes module, sends appropriate message to kernel
 */
static int bpmp_host_proxy_remove_impl(struct platform_device *pdev)
{
	struct bpmp_host_proxy *proxy = platform_get_drvdata(pdev);

	misc_deregister(&proxy->miscdev);
	return 0;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
static void bpmp_host_proxy_remove(struct platform_device *pdev)
{
	bpmp_host_proxy_remove_impl(pdev);
}
#else
static int bpmp_host_proxy_remove(struct platform_device *pdev)
{
	return bpmp_host_proxy_remove_impl(pdev);
}
#endif

/*
 * Opens device module, sends appropriate message to kernel
 */
static int open(struct inode *inodep, struct file *filep)
{
	deb_info("device opened.\n");
	return 0;
}

/*
 * Closes device module, sends appropriate message to kernel
 */
static int close(struct inode *inodep, struct file *filep)
{
	deb_info("device closed.\n");
	return 0;
}

/*
 * Reads from device, displays in userspace, and deletes the read data
 */
static ssize_t read(struct file *filep, char __user *buffer, size_t len, loff_t *offset)
{
	deb_info("read stub");
	return 0;
}

/*
 * Checks if the msg that wants to transmit through the
 * bpmp-host is allowed by the device tree configuration
 */
/*
 * Host-critical shared clock roots the host TCB depends on (always-on). The
 * guest's display clock tree parents up to these, so they must be allow-listed
 * -- but MRQ_CLK is gated by id, not command, so a guest could otherwise
 * DISABLE/reparent/rerate them and destabilise the host. Enable (a BPMP
 * refcount no-op on always-on roots) and reads stay permitted; mutating
 * commands on these ids are denied in check_if_allowed().
 */
static const uint32_t protected_clk_roots[] = {
	14,  /* TEGRA234_CLK_CLK_M */
	102, /* TEGRA234_CLK_PLLP_OUT0 */
	103, /* TEGRA234_CLK_UTMIP_PLL: parent of mgbe0_app, also feeds host USB */
	292, /* TEGRA234_CLK_UTMIPLL_CLKOUT480: 480 MHz output feeding mgbe0_app */
	91,  /* TEGRA234_CLK_OSC */
	288, /* TEGRA234_CLK_PLLREFE_VCOOUT: shared reference PLL (PCIe/UPHY) */
	327, /* TEGRA234_CLK_PLLREFE_VCOOUT_GATED */
};

static bool clk_root_is_protected(uint32_t clk_id)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(protected_clk_roots); i++)
		if (protected_clk_roots[i] == clk_id)
			return true;
	return false;
}

static bool check_if_allowed(const struct bpmp_allowed_res *allowed,
			     struct tegra_bpmp_message *msg)
{
	struct mrq_reset_request *reset_req = NULL;
	struct mrq_clk_request *clock_req = NULL;
	struct mrq_pg_request *pg_req = NULL;
	uint32_t clk_cmd = 0;
	uint32_t clk_id = 0;
	int i = 0;

	// Allow get information, DVFS, ISO Client and bandwidth mrqs
	if(msg->mrq == MRQ_PING ||
	   msg->mrq == MRQ_QUERY_TAG ||
	   msg->mrq == MRQ_THREADED_PING ||
	   msg->mrq == MRQ_QUERY_ABI ||
	   msg->mrq == MRQ_EMC_DVFS_LATENCY ||
	   msg->mrq == MRQ_EMC_DVFS_EMCHUB ||
	   msg->mrq == MRQ_ISO_CLIENT ||
	   msg->mrq == MRQ_STRAP ||
	   msg->mrq == MRQ_BWMGR || 
	   msg->mrq == MRQ_QUERY_FW_TAG ){
		return true;
	}

	/* The policed MRQs below read a request struct out of tx. tx.data is NULL
	 * when the guest sends tx.size == 0, and both fields are guest-controlled,
	 * so a missing or truncated request must be denied, not dereferenced. */

	// Check for reset and clock mrq
	if(msg->mrq == MRQ_RESET){
		if (!msg->tx.data || msg->tx.size < sizeof(*reset_req)) {
			deb_warn("Warning, reset mrq with truncated tx (%zu), denied", msg->tx.size);
			return false;
		}
		reset_req = (struct mrq_reset_request*) msg->tx.data;

		for(i = 0; i < allowed->resets_size; i++){
			if(allowed->reset[i] == reset_req->reset_id){
				return true;
			}
		}
		deb_warn("Warning, reset not allowed for: %d", reset_req->reset_id);
		return false;
	}
	else if (msg->mrq == MRQ_CLK){
		if (!msg->tx.data || msg->tx.size < sizeof(clock_req->cmd_and_id)) {
			deb_warn("Warning, clk mrq with truncated tx (%zu), denied", msg->tx.size);
			return false;
		}
		clock_req = (struct mrq_clk_request*) msg->tx.data;
		clk_cmd = clock_req->cmd_and_id >> MRQ_CLK_CMD_SHIFT;
		clk_id = clock_req->cmd_and_id & MRQ_CLK_ID_MASK;

		/* Clock discovery is read-only and the Linux BPMP clock provider
		 * performs it across the complete firmware clock namespace. Restricting
		 * these queries to an ownership list makes unrelated clock probes fail
		 * and can prevent an otherwise-owned device clock from registering.
		 * Keep all state-changing operations policed by the per-VM list below. */
		if (clk_cmd == CMD_CLK_GET_RATE ||
		    clk_cmd == CMD_CLK_GET_PARENT ||
		    clk_cmd == CMD_CLK_IS_ENABLED ||
		    /* Linux 7.1 removed these legacy discovery commands from the
		     * upstream BPMP ABI after consolidating discovery in
		     * CMD_CLK_GET_ALL_INFO. NVIDIA 6.6 and 6.12 still expose them. */
#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 1, 0)
		    clk_cmd == CMD_CLK_PROPERTIES ||
		    clk_cmd == CMD_CLK_POSSIBLE_PARENTS ||
		    clk_cmd == CMD_CLK_NUM_POSSIBLE_PARENTS ||
		    clk_cmd == CMD_CLK_GET_POSSIBLE_PARENT ||
#endif
		    clk_cmd == CMD_CLK_GET_ALL_INFO ||
		    clk_cmd == CMD_CLK_GET_MAX_CLK_ID ||
		    clk_cmd == CMD_CLK_GET_FMAX_AT_VMIN)
			return true;

		/* The protected roots are firmware-owned, always-on clocks. Preparing
		 * a guest child walks through CMD_CLK_ENABLE on its parent, but enabling
		 * these roots is a BPMP refcount no-op. Permit that single operation for
		 * every consumer while continuing to reject disable, rate and parent
		 * changes below. */
		if (clk_cmd == CMD_CLK_ENABLE && clk_root_is_protected(clk_id))
			return true;

		for(i = 0; i < allowed->clocks_size; i++){
			// bits[23..0] are the clock id
			if(allowed->clock[i] == clk_id){
				// A guest may enable/read an allowed clock, but must never
				// disable, reparent or rerate a host-critical shared root.
				if(clk_root_is_protected(clk_id) &&
				   (clk_cmd == CMD_CLK_DISABLE ||
				    clk_cmd == CMD_CLK_SET_RATE ||
				    clk_cmd == CMD_CLK_SET_PARENT)){
					deb_warn("Warning, protected clock root %d: command %d denied",
						clk_id, clk_cmd);
					return false;
				}
				return true;
			}
		}

		deb_warn("Warning, clock not allowed for: %d, with command: %d", 
			clk_id, clk_cmd);
		return false;
	}
	else if(msg->mrq == MRQ_PG){
		if (!msg->tx.data || msg->tx.size < offsetofend(struct mrq_pg_request, id)) {
			deb_warn("Warning, pg mrq with truncated tx (%zu), denied", msg->tx.size);
			return false;
		}
		pg_req = (struct mrq_pg_request*) msg->tx.data;

		for(i = 0; i < allowed->pd_size; i++){
			if(allowed->pd[i] == pg_req->id){
				return true;
			}
		}
		
		// If there is a get info command, allow it no matters the ID
		if(pg_req->cmd == CMD_PG_GET_STATE ||
		   pg_req->cmd == CMD_PG_GET_NAME ||
		   pg_req->cmd == CMD_PG_GET_MAX_ID){
			return true;
		}

		deb_warn("Warning, pg not allowed for: %d, with command: %d", 
			pg_req->id, pg_req->cmd);
		return false;
	}

	/* DIAGNOSTIC: log EVERY rejected MRQ with its command/payload so a display
	 * bring-up that needs a display-specific MRQ (e.g. MRQ_UPHY) the proxy does
	 * not relay is visible. tx.data[0] is the MRQ sub-command for most MRQs. */
	{
		const u32 *d = (const u32 *)msg->tx.data;
		deb_warn("REJECTED mrq=%u tx_size=%zu data0=0x%08x data1=0x%08x",
			 msg->mrq, msg->tx.size,
			 (d && msg->tx.size >= 4) ? d[0] : 0u,
			 (d && msg->tx.size >= 8) ? d[1] : 0u);
	}

	return false;
}

extern int tegra_bpmp_transfer(struct tegra_bpmp *, struct tegra_bpmp_message *);
extern struct tegra_bpmp *tegra_bpmp_host_device;

/*
 * Matches the QEMU device's 512-byte TX/RX windows (MESSAGE_SIZE in
 * nvidia_bpmp_guest.c). A larger bound would let copy_to_user() reach past
 * those windows into adjacent QEMU device state.
 */
#define BUF_SIZE 512

/*
 * Stable userspace ABI shared with QEMU's nvidia_bpmp_guest device.
 *
 * Do not use struct tegra_bpmp_message as the wire format. It is a
 * kernel-internal type: it gained an `unsigned long flags` member in v6.7
 * (backported to 6.6.y as 9c9312fccdc9), so it is 56 bytes on both the
 * 6.6.129 host and the 6.12 guest. QEMU's device previously declared its own
 * copy of that layout, written before `flags` existed, and so sent 48 bytes
 * into a 56-byte cast. This struct is the contract instead; it is 48 bytes by
 * definition and must not track the kernel type.
 */
struct bpmp_proxy_wire_message {
	u32 mrq;
	u32 reserved0;

	struct {
		u64 data;
		u64 size;
	} tx;

	struct {
		u64 data;
		u64 size;
		s32 ret;
		u32 reserved0;
	} rx;
};

static_assert(sizeof(struct bpmp_proxy_wire_message) == 48);

/*
 * Writes to the device
 */

static ssize_t write(struct file *filep, const char __user *buffer, size_t len, loff_t *offset)
{
	struct miscdevice *miscdev = filep->private_data;
	struct bpmp_host_proxy *proxy =
		container_of(miscdev, struct bpmp_host_proxy, miscdev);
	struct bpmp_proxy_wire_message wire;
	struct tegra_bpmp_message message = { 0 };
	void __user *usertxbuf;
	void __user *userrxbuf;
	void *txbuf = NULL;
	void *rxbuf = NULL;
	int ret;

	if (len != sizeof(wire)) {
		deb_error("count %zu does not match message header size %zu\n",
			  len, sizeof(wire));
		return -EINVAL;
	}

	if (copy_from_user(&wire, buffer, sizeof(wire))) {
		deb_error("copy_from_user(1) failed\n");
		return -EFAULT;
	}

	deb_info("\nwants to write %zu bytes, with mrq: %d\n", len, wire.mrq);

	// A malformed or malicious guest can set tx.size/rx.size larger than the
	// BUF_SIZE bounce buffers below; copy_from_user would then overflow the host
	// slab and corrupt unrelated allocations (observed as SLUB freelist faults in
	// __kmem_cache_alloc_node from unrelated syscalls). Real MRQs are bounded by
	// the guest BPMP window (< MESSAGE_SIZE), so anything larger is rejected. The
	// guest proxy only caps tx.size, so rx.size must be checked here.
	if (wire.tx.size > BUF_SIZE || wire.rx.size > BUF_SIZE) {
		deb_error("tx.size %llu / rx.size %llu exceeds %d, rejecting\n",
			  wire.tx.size, wire.rx.size, BUF_SIZE);
		return -EINVAL;
	}

	usertxbuf = u64_to_user_ptr(wire.tx.data);
	userrxbuf = u64_to_user_ptr(wire.rx.data);

	if (wire.tx.size > 0) {
		txbuf = kmalloc(BUF_SIZE, GFP_KERNEL);
		if (!txbuf) {
			ret = -ENOMEM;
			goto out;
		}
		memset(txbuf, 0, BUF_SIZE);
		if (copy_from_user(txbuf, usertxbuf, wire.tx.size)) {
			deb_error("copy_from_user(2) failed\n");
			ret = -EFAULT;
			goto out;
		}
	}

	rxbuf = kmalloc(BUF_SIZE, GFP_KERNEL);
	if (!rxbuf) {
		ret = -ENOMEM;
		goto out;
	}

	memset(rxbuf, 0, BUF_SIZE);
	if (copy_from_user(rxbuf, userrxbuf, wire.rx.size)) {
		deb_error("copy_from_user(3) failed\n");
		ret = -EFAULT;
		goto out;
	}

	message.mrq = wire.mrq;
	message.tx.data = txbuf;
	message.tx.size = wire.tx.size;
	message.rx.data = rxbuf;
	message.rx.size = wire.rx.size;

	if (!tegra_bpmp_host_device) {
		deb_error("host device not initialised, can't do transfer!");
		ret = -ENODEV;
		goto out;
	}

	// Only continue if allowed or BPMP_HOST_ALLOWS_ALL
	if (!check_if_allowed(&proxy->allowed, &message) && !BPMP_HOST_ALLOWS_ALL) {
		ret = -EPERM;
		goto out;
	}

	hexDump(DEVICE_NAME ": message", &message, sizeof(message));
	hexDump(DEVICE_NAME ": txbuf", txbuf, message.tx.size);

	ret = tegra_bpmp_transfer(tegra_bpmp_host_device, &message);
	if (ret < 0)
		goto out;

	if (message.rx.size > BUF_SIZE) {
		deb_error("response size %zu exceeds %d\n", message.rx.size, BUF_SIZE);
		ret = -EOVERFLOW;
		goto out;
	}

	if (copy_to_user(usertxbuf, message.tx.data, message.tx.size)) {
		deb_error("copy_to_user(2) failed\n");
		ret = -EFAULT;
		goto out;
	}

	if (copy_to_user(userrxbuf, message.rx.data, message.rx.size)) {
		deb_error("copy_to_user(3) failed\n");
		ret = -EFAULT;
		goto out;
	}

	wire.rx.size = message.rx.size;
	wire.rx.ret = message.rx.ret;

	/*
	 * This character-device write ABI is intentionally bidirectional: QEMU
	 * consumes the updated response fields from the same userspace header.
	 * file_operations.write requires a const buffer, so cast away const only
	 * for this response copy.
	 */
	if (copy_to_user((void __user *)buffer, &wire, sizeof(wire))) {
		deb_error("copy_to_user(1) failed\n");
		ret = -EFAULT;
		goto out;
	}

	ret = len;
out:
	kfree(txbuf);
	kfree(rxbuf);
	return ret;
}

static const struct of_device_id bpmp_host_proxy_ids[] = {
	{ .compatible = "nvidia,bpmp-host-proxy" },
	{ }
};

static struct platform_driver bpmp_host_proxy_driver = {
	.driver = {
		.name = "bpmp_host_proxy",
		.of_match_table = bpmp_host_proxy_ids,
	},
	.probe = bpmp_host_proxy_probe,
	.remove = bpmp_host_proxy_remove,
};
builtin_platform_driver(bpmp_host_proxy_driver);
