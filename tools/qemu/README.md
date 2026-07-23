# OpenRC QEMU tests

This directory contains the host runner, image builder, and guest-side tests.
QEMU runs never modify the base image: every invocation creates a qcow2 overlay
and a private shared directory under one run directory.

## Layout

```text
tools/qemu/
├── image-build.sh
├── image-run.sh
├── tests-run.sh
├── tests-run-guest.sh
├── lib/
│   ├── common.sh
│   ├── files.sh
│   ├── guest.sh
│   ├── qemu.sh
│   └── ssh.sh
└── guest/
    ├── setup/install-openrc.sh
    └── tests/
        ├── cgroup2/{boot,delegated,service}.sh
        ├── lib/common.sh
        └── upgrade/services.sh
```

The runtime tree defaults to `qemu-tests`:

```text
qemu-tests/
├── images/
│   ├── gentoo-base.qcow2
│   └── ssh/
└── runs/
    └── 20260721T120000Z-1234/
        ├── overlay.qcow2
        ├── share/
        │   ├── source/
        │   └── tests/
        ├── results/
        ├── serial.log
        └── qemu.log
```

Run directories and overlays are deliberately preserved after success and
failure so that logs and the final guest state can be inspected together. They
can be removed manually when no longer needed. `qemu-tests/` is ignored by Git.
While a VM is running, its SSH forwarding socket has a short, deterministic
name such as `/tmp/openrc_qemu_0123456789abcdef01234567.socket`. The runner
prints the exact path and removes the socket when QEMU exits.

## Build the image

From the repository root:

```sh
tools/qemu/image-build.sh qemu-tests
```

The host needs QEMU, libguestfs, `curl`, OpenSSH, and `socat`; the scripts check
individual commands before using them.

The builder downloads a Gentoo OpenRC stage3, installs a binary kernel, GRUB,
OpenSSH, and the build dependencies of `sys-apps/openrc-9999`. Building the
image therefore needs network access. The generated client and guest host keys
are kept in `qemu-tests/images/ssh`; they are test-only credentials.

The guest has a static `eth0` address, `10.0.2.15/24`, with gateway
`10.0.2.2`. Runtime networking uses QEMU slirp with `restrict=on`, so the guest
cannot initiate external network connections. SSH is forwarded directly from
a per-run Unix socket to guest TCP port 22:

```text
-netdev user,id=testnet,restrict=on,hostfwd=unix:/tmp/openrc_qemu_ID.socket-:22
-device virtio-net-pci,netdev=testnet
```

The dash-free path works around a host-forwarding parser bug in QEMU through
10.2. It is derived from the absolute run directory, so helper processes can
reconstruct it without storing additional runtime state.

No QEMU guest agent is installed. SSH supplies command exit status, readiness,
reboot, and shutdown handling, so a second control channel is unnecessary.

## Shell variable convention

Global context owned and populated by a library uses the `G_` prefix and is
declared explicitly at the beginning of that library. For example,
`qemu_run_paths` populates `G_RUN_DIR`, `G_RESULTS_DIR`, and `G_SSH_SOCKET`.
Globals owned by an executable script use ordinary upper-case names such as
`SOURCE_DIR` and `CURRENT_VERSION`. Lower-case names are reserved for variables
declared `local` inside functions. Public environment settings keep their
existing names, including `QEMU_ACCEL`, `MEM`, and `UPGRADE_FROM`.

## Run tests

Install the current worktree into a fresh overlay and run all guest tests:

```sh
tools/qemu/tests-run.sh qemu-tests .
```

The current tracked and untracked, non-ignored files are copied into a small
temporary Git repository in that run's read-only share. Portage builds
`openrc-9999` from that snapshot, the guest reboots, and the cgroup2 tests run.

To test an upgrade from an older tag or revision:

```sh
UPGRADE_FROM=0.55 tools/qemu/tests-run.sh qemu-tests .
```

This workflow installs the old revision, reboots, records the started runlevel
services, installs the current worktree, and checks that those services remain
started both immediately after the live package upgrade and after the next
reboot. If the tag text differs from the version printed by OpenRC, set
`UPGRADE_EXPECTED_VERSION` as well.

Useful runner settings include `RUN_ID`, `QEMU_ACCEL=tcg`, `MEM`, `SMP`,
`SSH_WAIT`, and a whitespace-separated `GUEST_TESTS` list. For example:

```sh
GUEST_TESTS=cgroup2/boot.sh tools/qemu/tests-run.sh
```

To rerun one already staged test while its guest is still running:

```sh
tools/qemu/tests-run-guest.sh \
    qemu-tests/runs/RUN_ID cgroup2/service.sh
```

## Start an image manually

```sh
tools/qemu/image-run.sh qemu-tests
```

This creates the same isolated run layout and attaches the serial console to
the terminal. Set `SERIAL_MODE=file` to put it in `serial.log` instead. The
image intentionally allows root autologin on its serial test console; do not
use it as a general-purpose or exposed VM.

For manual SSH, use the socket and key printed by `image-run.sh`, for example:

```sh
ssh -o 'ProxyCommand=socat - UNIX-CONNECT:/tmp/openrc_qemu_ID.socket' \
    -o HostKeyAlias=openrc-qemu \
    -o UserKnownHostsFile=qemu-tests/images/ssh/known_hosts \
    -i qemu-tests/images/ssh/id_ed25519 root@openrc-qemu
```
======================

Как проверить:

```sh
tools/qemu/image-build.sh qemu-tests
```

Обычный тест текущего дерева:

```sh
tools/qemu/tests-run.sh qemu-tests .
```

Upgrade с тега:

```sh
UPGRADE_FROM=0.55 tools/qemu/tests-run.sh qemu-tests .
```

Ручной запуск образа:

```sh
tools/qemu/image-run.sh qemu-tests
```
