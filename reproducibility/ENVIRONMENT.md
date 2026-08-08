# Test environments

Exact provisioning for the VMs used in `FINDINGS.md`, so results can be
re-derived rather than taken on trust.

Four VMs were used and it matters which. Findings were established on different
ZFS versions, and the version is recorded in every row of `ATTEMPTS.md`. Build
the one matching the finding you want to check.

| | VM `zfslab` | VM `zfs234` | VM `truenas-lab` | VM `zfs243` |
|---|---|---|---|---|
| Guest | Ubuntu 26.04 LTS | Ubuntu 24.04.4 LTS | Debian 13.6 (Trixie) | Debian 13 (Trixie) |
| Kernel | `7.0.0-28-generic`, aarch64 | `6.8.0-134-generic`, aarch64 | `6.12.95+deb13-cloud-arm64`, aarch64 | `6.12.95+deb13-cloud-arm64`, aarch64 |
| ZFS | `2.4.1-1ubuntu5` | `2.2.2-0ubuntu9.4` | tag `zfs-2.3.4` (built from source) | tag `zfs-2.4.3` (built from source) |
| Carries `1e1d64d`? | No | No | No | Yes |
| Used for | findings 1, 2, 3, 4, 6, 7, 8 (and the manual freeze and healthy-removal runs) | findings 5, 9, 10, 11, including the reproduced removal hang, with the first captured stack | finding 13, ZFS 2.3.4 verification | findings 14, 15, 16, 17: the hardened tree and the incident's own repair commit |

Full finding-to-VM attribution, checked row by row against `ATTEMPTS.md`:

| Finding | VM(s) | Where in `ATTEMPTS.md` |
|---|---|---|
| 1 | `zfslab` (2.4.1) | 07-29, manual freeze + remove |
| 2 | `zfslab` (2.4.1); later also `truenas-lab` and `zfs243` via `01` | 07-29 manual; `01` rows on 07-29, 07-30, 07-31 |
| 3 | `zfslab` (2.4.1); later also `truenas-lab` and `zfs243` via `01` | 07-29 manual healthy removal; the same `01` rows |
| 4 | `zfslab` (2.4.1) | 07-29, freeze combined with remove |
| 5 | `zfslab` (2.4.1) first, then `zfs234`, `truenas-lab`, `zfs243` | `03` rows on 07-29 (x2), 07-30, 07-31 |
| 6 | `zfslab` (2.4.1) first, then `zfs234`, `truenas-lab`, `zfs243` | `04` rows on 07-29 (x2), 07-30, 07-31 |
| 7 | `zfslab` (2.4.1) only | `05` row, 07-29 |
| 8 | `zfslab` (2.4.1) only | `05` row, 07-29 |
| 9 | source reading, then `zfs234`, `truenas-lab`, `zfs243` | `vdev_removal.c` review 07-29; `06` rows on 07-29, 07-30, 07-31 |
| 10 | `zfs234` (2.2.2), the captured stack | `07` row, 07-29 |
| 11 | `zfs234` (2.2.2) only | 07-29, manual offline + remove |
| 12 | no VM, an enumeration of the preceding runs, not an experiment | 07-29, "enumeration complete" |
| 13 | `truenas-lab` (`zfs-2.3.4`) | the five 07-30 rows |
| 14 | `zfs243` (`zfs-2.4.3`) | the `[S2]` rows, 07-31 |
| 15 | `zfs243` | the `[S3]` rows, 07-31 |
| 16 | `zfs243` | the `[S4]` rows, 07-31 |
| 17 | `zfs243` | the `[S5]` rows, 07-31 |

Findings 5, 6 and 9 were each produced on more than one VM and cannot be
attributed to a single one; findings 7 and 8 come from a single `zfslab` run of
`05` and were never re-run elsewhere; finding 12 has no VM. The "Used for" row
above lists first-observation VMs only; use this table for anything that
depends on which build actually ran.

The Ubuntu VMs use stock distro packages. Nothing was patched for any of this
reproduction work. The Debian VM (`truenas-lab`) builds the `zfs-2.3.4` release
tag from source to narrow the version gap to the incident.

Provenance of the source build, verified 2026-07-31. The loaded module on
`truenas-lab` embeds the git revision string `zfs-2.3.4-0-g34f96a1`: zero
commits past the `zfs-2.3.4` tag, at commit `34f96a1`. `zfs_config.h` in
`/usr/src/zfs-2.3.4` gives `ZFS_META_VERSION "2.3.4"` and
`ZFS_META_RELEASE "1"`, and `/sys/module/zfs/version` reads `2.3.4-1`. It is a
clean release-tag build with no local patches. Reproduce the check with:

```bash
sudo xz -dc /lib/modules/$(uname -r)/extra/zfs.ko.xz | strings | grep '^zfs-2\.3'
```

It still does not match the incident's build. TrueNAS describes the release
as `2.3.4-1`, but the module running on the affected system identified itself
as `zfs-2.3.3-107-gec5aa9bfd`, a snapshot 107 commits past the `zfs-2.3.3` tag.
Set side by side in the same notation, the gap is exact and countable:

| | git revision | relation to a tag |
|---|---|---|
| Incident | `zfs-2.3.3-107-gec5aa9bfd` | 107 commits past `zfs-2.3.3` |
| `truenas-lab` | `zfs-2.3.4-0-g34f96a1` | the `zfs-2.3.4` tag exactly |
| Incident repair environment | `zfs-2.4.3-0-g83020cf-dirty-dist` | the `zfs-2.4.3` tag (`83020cf`), plus local edits |
| `zfs243` | `zfs-2.4.3-0-g83020cf` | the `zfs-2.4.3` tag exactly, the same commit as the repair environment, without the local edits |

See `../incident/evidence/2026-07-30-post-repair-history.txt`.

The three original VMs were re-queried live on 2026-07-31 and every version
string in the table above was confirmed unchanged. `zfs243` was built the same
day. The host has since point-upgraded to macOS 26.6; the captures in
`evidence/` dated 2026-07-29 and 2026-07-30 record 26.5.2, which was correct at
capture time, and the 2026-07-31 capture records 26.6.

Host for all four: Apple Silicon (arm64), Lima 2.2.0 on the Apple
Virtualization.framework backend.

## Why four VMs and four ZFS versions

Four VMs, four ZFS versions: 2.4.1, 2.2.2, `zfs-2.3.4` and `zfs-2.4.3`.

The affected pool was damaged on TrueNAS SCALE 25.10.4, which ships TrueNAS's
build of ZFS 2.3.4. An early hypothesis was that 2.4.x had already been
hardened against the defect by amotin's `1e1d64d`, which would have explained
several negative results without needing an exotic sequence.

The second VM (`zfs234`) was built to test that and was named after the target
version. In the event Ubuntu 24.04 shipped 2.2.2, not 2.3.4, and ZFS 2.3.4
itself was never built or tested. The name is a leftover; every result from
that VM is a 2.2.2 result.

And the comparison it was built to make does not work either. The pair does not
compare 2.2.2 ("predates amotin's fix") against 2.4.1 ("contains it"): 2.4.1
does not contain it. `1e1d64d` was authored 2026-03-04 and first ships in
`zfs-2.4.3`; it is absent from 2.4.0, 2.4.1, 2.4.2 and every 2.3.x. So all three
of the original VMs run trees that lack the hardening, and their agreeing with
each other says nothing about it. The hypothesis was not disproved, only
untested; see `../CLAIMS.md` 3.29 and 4.5. That is what the fourth VM (`zfs243`)
was built to fix.

Both original VMs are still documented, because the negative results for the
precondition depend on having checked both.

The third VM (`truenas-lab`) was built to test the `zfs-2.3.4` release tag, the
closest available release to the incident, on the same base OS (Debian) that
TrueNAS SCALE uses. Finding 13: ZFS 2.3.4 behaves identically to 2.2.2 on every
path tested, and to 2.4.1 on every path where both were run. Since behaviour is
stable across that range, a version-specific explanation for the
hole-plus-dirty-header state is less likely. This says nothing about TrueNAS's
own build.

The fourth VM (`zfs243`) was built on 2026-07-31 to fix the flaw described
above: it runs the `zfs-2.4.3` tag, the only release containing `1e1d64d`, and
the same commit (`83020cf`) the incident repair was built from. Finding 14: all
four precondition paths behave identically there too, and the removal hang
reproduces with a captured stack. The hardening hypothesis is now properly
tested and disproved (`../CLAIMS.md` 4.5), and the reproduction work and the
incident work finally share a tree. One behavioural difference did turn up:
`txg_quiesce` is not wedged on 2.4.3, unlike 2.2.2. See finding 14.

This VM also carried findings 15, 16 and 17: the `failmode` runs, the
synthesised precondition, and the claimed-chain variant. Findings 16 and 17
both need a hooked module to build the state and a pristine one to measure
it; see "swapping between stock and patched modules" below, and note that every
import recorded in findings 16 and 17 was made on a module verified
byte-identical to the archived stock build.

What remains untested: a TrueNAS-faithful environment generally (TrueNAS's own
`2.3.3-107` build, kernel `6.12.91-production+truenas`, x86-64, removal driven
through `middlewared`), and any non-default `failmode`. Every result recorded
here was produced at the default `failmode=wait`; `lib.sh` now exposes a
`FAILMODE` variable so `continue` and `panic` can be tested, and on `zfs243`
they since have been (finding 15), so "any non-default `failmode`" is now
untested on 2.2.2, 2.3.4 and 2.4.1 only. Note this is a task for the test
environment by necessity: on the incident hardware `failmode` could not be
reached during the load, for reasons confirmed in source (`../CLAIMS.md` 3.23
and 3.24). Also untested: the removal hang on 2.4.1 specifically.
`07-path-h-yank-live-log.sh` has been run on `zfs234` (2.2.2), `truenas-lab`
(2.3.4) and `zfs243` (2.4.3), with verified stacks on the first and last, but
never on `zfslab` (2.4.1). That gap no longer matters much, since the releases
on either side of 2.4.1 both hang. The full fidelity gap is charted in
[`../CONCLUSIONS.md`](../CONCLUSIONS.md#3-how-they-relate-the-gap-between-the-synthesis-and-the-incident)
and argued in [`../CONCLUSIONS.md`](../CONCLUSIONS.md) §3.

## Why aarch64 is valid

The defects are control flow, not architecture dependent. The one piece of
architecture-specific work in this project, the binary NOP patch to `zfs.ko`
described in `../incident/recovery-breakdown.md` §10, was x86-64 only, and it
is not part of this reproduction work or of any external contribution.

## Build a VM

```bash
brew install lima

# for findings 1, 2, 3, 4, 6, 7, 8 (see the attribution table above)
limactl start --tty=false --name=zfslab \
    --cpus=4 --memory=8 --disk=40 \
    template://ubuntu-26.04

# for findings 5, 9, 10, 11 -- including the reproduced removal hang, with stack
limactl start --tty=false --name=zfs234 \
    --cpus=4 --memory=8 --disk=40 \
    template://ubuntu-24.04

# for finding 13, ZFS 2.3.4 verification (closest release to the incident, not its build)
limactl start --tty=false --name=truenas-lab \
    --cpus=4 --memory=8 --disk=80 \
    template://debian-13

# for findings 14 to 17, ZFS 2.4.3 (the incident's repair commit, and the only
# release carrying amotin's 1e1d64d)
limactl start --tty=false --name=zfs243 \
    --cpus=4 --memory=8 --disk=80 \
    template://debian-13
```

## Install ZFS in the guest

### Ubuntu VMs (zfslab, zfs234)

Identical on both:

```bash
limactl shell <vm-name>

sudo apt-get update
sudo apt-get install -y zfsutils-linux   # zpool, zfs, zdb
sudo apt-get install -y zfs-test         # zinject, NOT in zfsutils-linux

sudo modprobe zfs
cat /sys/module/zfs/version
zfs version
```

### Debian VM (zfs243) - ZFS 2.4.3 from source

Identical to the `truenas-lab` recipe below, with `--branch zfs-2.4.3`. Verify
before testing that you are on the right tree:

```bash
cd /tmp/zfs && git log -1 --format='%H %d'
# 83020cf8259d057d4cc9102010c05f07ffdfc136  (grafted, HEAD, tag: zfs-2.4.3)

# 1e1d64d must be PRESENT in this tree, and absent in every other VM here:
grep -c 'memset(zh, 0, sizeof (zil_header_t))' module/zfs/zil.c      # 2, not 1
grep -c 'ASSERT0(vd->vdev_stat.vs_alloc)' module/zfs/vdev_removal.c  # 1, not 2
grep -n 'If the log is empty' module/zfs/zil.c                       # zil.c:1171
```

The build takes roughly five minutes at `make -j4` on 4 vCPUs.

### Debian VM (truenas-lab) - ZFS 2.3.4 from source

This VM builds ZFS from source to test the closest release to the incident's
build (`zfs-2.3.3-107-gec5aa9bfd`; see the version-gap table above, it is not
the same tree):

```bash
limactl shell truenas-lab

# Install build dependencies
sudo apt-get update
sudo apt-get install -y build-essential autoconf automake libtool \
    pkg-config libssl-dev libz-dev libcurl4-openssl-dev \
    python3 python3-dev python3-setuptools python3-cffi \
    libffi-dev libudev-dev libcap-dev libblkid-dev git-core \
    libtirpc-dev linux-headers-$(uname -r)

# Clone and build ZFS 2.3.4
cd /tmp
git clone --depth 1 --branch zfs-2.3.4 https://github.com/openzfs/zfs.git
cd zfs
./autogen.sh
./configure --prefix=/usr
make -j$(nproc)
sudo make install
sudo ldconfig
sudo depmod -a

# Load and verify
sudo modprobe zfs
cat /sys/module/zfs/version
zfs version
```

### zfs243 only: capture the kernel console before testing `FAILMODE=panic`

Without this you will get no panic output and the test proves nothing. By
default the Debian cloud image puts kernel messages on `tty0`, which Lima's
`vz` serial log does not capture, and journald loses its buffer when the kernel
dies. The first `FAILMODE=panic` run was discarded for exactly this reason.

```bash
sudo sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="console=tty0 console=hvc0 ignore_loglevel"|' /etc/default/grub
sudo update-grub && sudo reboot

# after reboot, verify BOTH consoles are present:
cat /proc/consoles          # want hvc0 AND tty0
# and prove the host is capturing them:
sudo bash -c 'echo MARKER > /dev/kmsg'
grep -c MARKER ~/.lima/zfs243/serialv.log   # on the HOST; want 1
```

The panic then lands verbatim in `~/.lima/zfs243/serialv.log` on the host, and
survives the forced power cycle.

### zfs243 only: swapping between stock and patched modules

Findings 16 and 17 need a hooked module to build the state and a pristine one
to measure it. Back up the stock module before any patching, then swap
without rebuilding:

```bash
K=$(uname -r)
sudo cp /lib/modules/$K/extra/zfs.ko.xz /root/zfs.ko.xz.STOCK-2.4.3   # once

# restore stock:
sudo rmmod zfs
sudo cp /root/zfs.ko.xz.STOCK-2.4.3 /lib/modules/$K/extra/zfs.ko.xz
sudo depmod -a && sudo modprobe zfs
ls /sys/module/zfs/parameters/ | grep -c lab_skip_reset_logs   # want 0
```

Tar the synthesised pool before importing it; the import mutates it and the
state is expensive to rebuild:

```bash
sudo tar czf /root/precondition-v2.tgz -C /var/tmp ziltest
```

Two archived states exist inside `zfs243` and they are not interchangeable:

| Archive | State | Used by |
|---|---|---|
| `/root/precondition-state.tgz` | unclaimed chain, `claim_txg 0`, `flags 0x0` | finding 16 |
| `/root/CLAIMED-CHAIN-state.tgz` | claimed chain, `claim_txg 37`, `flags 0x2` | finding 17 |

The claimed state is derived from the unclaimed one by importing once and
exporting; the import mutates the pool, so restore from the tarball before
every run rather than reusing a pool that has already been imported. Verify
which one you have with:

```bash
sudo zdb -e -p /var/tmp/ziltest -iiiii ziltest | grep claim_txg
```

Before measuring anything, confirm the module is the stock one; findings 16 and
17 are void if the hook is loaded:

```bash
md5sum /lib/modules/$(uname -r)/extra/zfs.ko.xz /root/zfs.ko.xz.STOCK-2.4.3
# both must read 20ca91a6a39fbe1a90cdea39feba95e5
ls /sys/module/zfs/parameters/ | grep -c lab_skip_reset_logs   # want 0
```

`zinject` is required by `03-path-c-failed-log.sh` and ships only in
`zfs-test`. `dmsetup` and `losetup`, required by `07-path-h-yank-live-log.sh`,
are in the base image.

## Copy the scripts in

Lima does not mount the host home directory by default:

```bash
tar cf - reproducibility | limactl shell <vm-name> bash -lc 'tar xf - -C ~ && chmod +x ~/reproducibility/*.sh'
```

## Recovering a wedged VM

Expect this. `07-path-h-yank-live-log.sh` reproduces an unkillable hang by
design, and a hung ZFS operation blocks all later `zfs` and `zpool` commands,
including `modprobe -r zfs`.

```bash
limactl stop --force <vm-name>
limactl start <vm-name>
limactl shell <vm-name> bash -lc 'sudo dmsetup remove --force slogdev 2>/dev/null; \
    for l in $(losetup -a | cut -d: -f1); do sudo losetup -d $l; done; \
    sudo rm -rf /var/tmp/ziltest*'
```

Lima's `vz` backend does not support snapshots. Treat the VMs as disposable and
rebuild if state becomes unclear.

## Traps worth knowing about

Buffering. Piping script output through `grep` or `sed` buffers it. If a run
hangs, the buffer never flushes and you get no output at all, which looks like
the script failed to start rather than like a reproduced hang. This cost time
twice. Use `tee` to a file inside the guest, then read the file from a second
shell.

`/tmp` is tmpfs. Anything written to `/tmp` inside the guest (script logs, a
cloned source tree) is gone after a panic or a forced power cycle. Both
happened during the 2026-07-31 session: a `FAILMODE=panic` script log was lost
and had to be re-run, and the `/tmp/zfs` source tree had to be re-cloned. Write
run logs to the guest's home directory, and use `stdbuf -oL` so they are
flushed line by line:

```bash
nohup sudo -E env FAILMODE=panic stdbuf -oL -eL ./07-path-h-yank-live-log.sh \
    > ~/07-panic.log 2>&1 &
```

Host-side commands can block too. `limactl shell` against a guest whose kernel
has died will hang, and so will anything piped through it. Wrap host-side calls
in a timeout. macOS has no `timeout(1)` by default; either
`brew install coreutils` for `gtimeout`, or kill the process group, because
`limactl shell` leaves an `ssh` child behind that survives killing the parent.

## Pinning for repeat runs

Record both with every result, since both matter:

```bash
uname -srm
cat /sys/module/zfs/version
```
