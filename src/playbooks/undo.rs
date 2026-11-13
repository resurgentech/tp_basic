//! Test-only playbook for inverse capture on a second filesystem (T106), not
//! in any YAML.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError, sh};

use crate::vars::Vars;

/// Every undo playbook.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![Playbook::new("undo_fs", undo_fs_entry)]
}

fn undo_fs_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { undo_fs(&h).await })
}

/// Where the last op writes what exists mid-run. `scripts/test-vm.sh` reads
/// it over SSH; the stage tree it lists is gone when the run ends. (The
/// engine prints no sh output in the run log, so a file is the channel.)
pub const MID_LISTING: &str = "/root/tp-undo-fs-mid.txt";

/// The served files of the fetch case (T119): the setup puts them on the root
/// filesystem and the playbook fetches them as `file://` URLs, so the VM needs
/// no network. `BLOB` is `tp fetch bytes\n`; `PKG` is a tgz holding
/// `pkg-1.0/{README,bin/tool}` (the setup decodes it from base64, so its
/// bytes and this sum are fixed).
const BLOB_URL: &str = "file:///var/lib/tp-fetch/blob.txt";
const BLOB_SUM: &str = "9c2355ab6d8d2a8020c65547e567e31f80eb41eede1ce611e591d82779be5cc0";
const PKG_URL: &str = "file:///var/lib/tp-fetch/pkg.tgz";
const PKG_SUM: &str = "2d44dca14b5af2c8e4f1c784d246deacf22fb8c613641a9422696514249c0789";

/// The proof of the real device walk, with no `TP_FS_ROOTS` seam
/// (`scripts/test-vm.sh undo_fs`). The script's setup, as root in the VM,
/// loop-mounts a 64 MiB ext4 image at `/srv/tpfs` and creates what the ops
/// below act on, so every target exists before the run: the file
/// `/srv/tpfs/tp-undo-file` (the content op backs it up), the directory
/// `/srv/tpfs/tp-undo-gone` and the directory `/var/tmp/tp-undo-fs/gone`
/// (`.absent()` moves each into an undo directory).
///
/// The first two targets are on another filesystem than `/var/tmp`, so their
/// backups go to `/srv/tpfs/.telepatch/tmp/<run>/undo/root/<id>/` with a
/// stage link each; the third is on the stage's filesystem, a plain directory
/// under `/var/tmp/telepatch/<run>/undo/root/<id>/` and no `/.telepatch`.
///
/// The fetch case (T119): a `.from` and an `.unpack` of two `file://` files
/// served from the root filesystem (`/var/lib/tp-fetch`), their targets
/// `/srv/tpfs/tp-fetch-blob.txt` and `/srv/tpfs/tp-fetch-tree` (new, so no
/// backup) on the second filesystem. Mid-run the download is on
/// `/srv/tpfs/.telepatch/` (the cache entries there, `fetchcache` lines, and
/// the run's `fetch` directory) and the stage holds only links to it
/// (`fetchlink` lines, and no regular file but the `fsroots` index).
///
/// The last op lists all of that into [`MID_LISTING`] while the run is still
/// in flight (`.at_end()` puts it after the others).
async fn undo_fs(h: &Host<Vars>) -> Result<(), TraceError> {
    h.file("/srv/tpfs/tp-undo-file").content("new bytes\n");
    h.file("/srv/tpfs/tp-undo-gone").absent();
    h.file("/var/tmp/tp-undo-fs/gone").absent();
    let blob = h.fetch(BLOB_URL).sha256(BLOB_SUM);
    h.file("/srv/tpfs/tp-fetch-blob.txt").from(&blob);
    let pkg = h.fetch(PKG_URL).sha256(PKG_SUM);
    h.file("/srv/tpfs/tp-fetch-tree").unpack(&pkg).strip(1);
    // HACK(test): lists the run's own undo data mid-run, which no primitive reads (the proof must see it before cleanup)
    sh!(
        h,
        "( for d in /srv/tpfs/.telepatch/tmp/$__tp_run/undo/root/*/; do [ -d \"$d\" ] && echo \"backup $d\"; done; \
         for l in /var/tmp/telepatch/$__tp_run/undo/root/*; do \
           if [ -L \"$l\" ]; then echo \"link $l -> $(readlink \"$l\")\"; \
           elif [ -d \"$l\" ]; then echo \"stagedir $l\"; fi; done; \
         for f in /var/tmp/telepatch/$__tp_run/*; do \
           if [ -L \"$f\" ]; then echo \"fetchlink $f -> $(readlink \"$f\")\"; \
           elif [ -f \"$f\" ] && [ \"$(basename \"$f\")\" != fsroots ]; then echo \"stagefile $f\"; fi; done; \
         for f in /srv/tpfs/.telepatch/cache/sha256/*; do [ -f \"$f\" ] && echo \"fetchcache $f\"; done; \
         for f in /srv/tpfs/.telepatch/tmp/$__tp_run/fetch/*; do [ -e \"$f\" ] && echo \"fetchtmp $f\"; done; \
         if [ -d /srv/tpfs/.telepatch/tmp/$__tp_run/fetch ]; then echo 'fetchdir present'; else echo 'fetchdir absent'; fi; \
         if [ -e /.telepatch ]; then echo 'root-telepatch PRESENT'; else echo 'root-telepatch absent'; fi; \
         echo \"run $__tp_run\" ) > /root/tp-undo-fs-mid.txt"
    )
    .at_end();
    Ok(())
}
