/*
 * SukiSU Ultra - "hide SELinux modifications" for kernels older than 5.10.
 *
 * The 5.10+ implementation (feature/selinux_hide.c) leans on struct
 * selinux_policy, sidtab_entry and an inline hook engine: it hooks
 * selinuxfs and serves a forged /sys/fs/selinux/status page. None of that
 * exists on this 4.19 tree, but the tree does carry the ACK backport of
 * struct selinux_state / struct selinux_ss, so the two effects that actually
 * matter can be reproduced without hooking anything:
 *
 *   1. keep a copy of the policy as it was before KernelSU touched it. This
 *      is what the feature reports as "available" (upstream refuses to enable
 *      the toggle without it) and what a future context check would use.
 *   2. keep /sys/fs/selinux/status looking untouched. KernelSU reloads the
 *      policy in place, which bumps the policyload counter and the sequence
 *      number of that mmap'ed page - a well known "policy was modified"
 *      signal. After every policy write we put the stock values back.
 *
 * AVC log spoofing is a separate SUSFS feature and is not implemented here.
 */

static DEFINE_MUTEX(selinux_hide_mutex);
bool ksu_selinux_hide_enabled __read_mostly = false;
bool ksu_selinux_hide_running __read_mostly = false;

struct ksu_policy_backup {
	struct policydb policydb;
};

static struct ksu_policy_backup *backup_policy __read_mostly;

static struct policydb *ksu_live_policydb(void)
{
	struct selinux_ss *ss = selinux_state.ss;

	return ss ? &ss->policydb : NULL;
}

/*
 * Copy a policydb through its on-disk representation: that is the only
 * documented way to duplicate one, and it also guarantees the copy is
 * self-contained (no pointers shared with the live policy).
 */
static struct ksu_policy_backup *ksu_dup_policydb(struct policydb *src)
{
	struct ksu_policy_backup *dst;
	struct policy_file fp;
	void *data = NULL;
	size_t len, used;
	int ret, attempt;

	dst = kzalloc(sizeof(*dst), GFP_KERNEL);
	if (!dst)
		return NULL;

	len = src->len ? src->len : (4U << 20);
	for (attempt = 0; attempt < 4; attempt++) {
		data = vmalloc(len);
		if (!data) {
			kfree(dst);
			return NULL;
		}
		fp.data = data;
		fp.len = len;
		ret = policydb_write(src, &fp);
		if (!ret)
			break;
		vfree(data);
		data = NULL;
		len <<= 1;
	}
	if (!data) {
		pr_err("selinux_hide: policydb_write failed: %d\n", ret);
		kfree(dst);
		return NULL;
	}
	used = len - fp.len;

	fp.data = data;
	fp.len = used;
	ret = policydb_read(&dst->policydb, &fp);
	vfree(data);
	if (ret) {
		pr_err("selinux_hide: policydb_read failed: %d\n", ret);
		kfree(dst);
		return NULL;
	}
	dst->policydb.len = used;

	pr_info("selinux_hide: saved a %zu bytes copy of the stock policy\n", used);
	return dst;
}

void ksu_selinux_hide_save_backup(void)
{
	struct policydb *db;

	mutex_lock(&selinux_hide_mutex);
	if (!backup_policy) {
		db = ksu_live_policydb();
		if (db && db->policyvers)
			backup_policy = ksu_dup_policydb(db);
	}
	mutex_unlock(&selinux_hide_mutex);
}

/*
 * Put the stock values back into the status page. The page is created lazily
 * by selinuxfs on the first access, so this is a no-op until somebody looked
 * at it - which is fine, because then nothing can have been observed yet.
 */
static void ksu_status_restore_stock(void)
{
	struct selinux_ss *ss = selinux_state.ss;
	struct selinux_kernel_status *status;

	if (!ss)
		return;

	mutex_lock(&ss->status_lock);
	if (ss->status_page) {
		status = page_address(ss->status_page);
		status->sequence = 0;
		status->policyload = 0;
		status->enforcing = enforcing_enabled(&selinux_state) ? 1 : 0;
	}
	mutex_unlock(&ss->status_lock);
}

/* Called by reset_avc_cache() after every policy write. */
void ksu_selinux_hide_refresh_status(void)
{
	if (!ksu_selinux_hide_running)
		return;
	ksu_status_restore_stock();
}

static int selinux_hide_feature_get(u64 *value)
{
	*value = ksu_selinux_hide_enabled ? 1 : 0;
	return 0;
}

static int ksu_selinux_hide_enable(void)
{
	if (!backup_policy) {
		pr_err("selinux_hide: no backup policy yet, save the feature and reboot\n");
		return -EAGAIN;
	}
	ksu_status_restore_stock();
	return 0;
}

static int selinux_hide_feature_set(u64 value)
{
	bool enable = value != 0;
	int ret = 0;

	pr_info("selinux_hide: set to %d\n", enable);
	mutex_lock(&selinux_hide_mutex);
	ksu_selinux_hide_enabled = enable;
	if (enable) {
		if (!ksu_selinux_hide_running) {
			ret = ksu_selinux_hide_enable();
			if (!ret)
				ksu_selinux_hide_running = true;
		}
	} else {
		ksu_selinux_hide_running = false;
	}
	pr_info("selinux_hide: enabled: %d, running: %d\n", ksu_selinux_hide_enabled,
		ksu_selinux_hide_running);
	mutex_unlock(&selinux_hide_mutex);
	return ret;
}

static const struct ksu_feature_handler selinux_hide_handler = {
	.feature_id = KSU_FEATURE_SELINUX_HIDE,
	.name = "selinux_hide",
	.get_handler = selinux_hide_feature_get,
	.set_handler = selinux_hide_feature_set,
};

void __init ksu_selinux_hide_init(void)
{
	if (ksu_register_feature_handler(&selinux_hide_handler))
		pr_err("Failed to register selinux_hide feature handler\n");
}

void __exit ksu_selinux_hide_exit(void)
{
	ksu_unregister_feature_handler(KSU_FEATURE_SELINUX_HIDE);
}

void ksu_selinux_hide_handle_second_stage(void)
{
	ksu_selinux_hide_save_backup();
	ksu_selinux_hide_refresh_status();
}

void ksu_selinux_hide_handle_post_fs_data(void)
{
	ksu_selinux_hide_refresh_status();
}

void ksu_selinux_hide_drop_backup_if_unused(void)
{
	mutex_lock(&selinux_hide_mutex);
	if (!ksu_selinux_hide_running && backup_policy) {
		pr_info("selinux_hide is not enabled - drop the policy backup\n");
		policydb_destroy(&backup_policy->policydb);
		kfree(backup_policy);
		backup_policy = NULL;
	}
	mutex_unlock(&selinux_hide_mutex);
}
