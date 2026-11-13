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
/// The last op lists all of that into [`MID_LISTING`] while the run is still
/// in flight (`.at_end()` puts it after the others).
async fn undo_fs(h: &Host<Vars>) -> Result<(), TraceError> {
    h.file("/srv/tpfs/tp-undo-file").content("new bytes\n");
    h.file("/srv/tpfs/tp-undo-gone").absent();
    h.file("/var/tmp/tp-undo-fs/gone").absent();
    // HACK(test): lists the run's own undo data mid-run, which no primitive reads (the proof must see it before cleanup)
    sh!(
        h,
        "( for d in /srv/tpfs/.telepatch/tmp/$__tp_run/undo/root/*/; do [ -d \"$d\" ] && echo \"backup $d\"; done; \
         for l in /var/tmp/telepatch/$__tp_run/undo/root/*; do \
           if [ -L \"$l\" ]; then echo \"link $l -> $(readlink \"$l\")\"; \
           elif [ -d \"$l\" ]; then echo \"stagedir $l\"; fi; done; \
         if [ -e /.telepatch ]; then echo 'root-telepatch PRESENT'; else echo 'root-telepatch absent'; fi; \
         echo \"run $__tp_run\" ) > /root/tp-undo-fs-mid.txt"
    )
    .at_end();
    Ok(())
}
