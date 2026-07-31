# OpenRC QEMU tests

This directory contains the host runner, image builder, and guest-side tests.
QEMU runs never modify the base image: every invocation creates a qcow2 overlay
and a private shared directory under one run directory.

## Layout

```text
tools/qemu/
├── image-build.sh
├── image-run.sh
├── image-update-openrc.sh
├── tests-run.sh
├── tests-run-guest.sh
├── lib/
│   ├── common.sh
│   ├── files.sh
│   ├── guest.sh
│   ├── qemu.sh
│   └── ssh.sh
└── guest/
    ├── setup/
    │   ├── grub-direct.sh
    │   └── install-openrc.sh
    └── tests/
        ├── cgroup2/{boot,delegated,service}.sh
        ├── cgroups/common.sh
        ├── lib/common.sh
        └── upgrade/{cgroup-cleanup,services}.sh
```

The runtime tree defaults to `qemu-tests`:

```text
qemu-tests/
├── images/
│   ├── gentoo-base.qcow2
│   ├── gentoo-base.qcow2.sha256
│   └── ssh/
└── runs/
    └── 20260721T120000Z-1234/
        ├── base-image.sha256
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
Each run keeps a copy of the base image checksum; rebuilding the image requires
a new `RUN_ID`.
While a VM is running, its SSH forwarding socket has a short, deterministic
name such as `/tmp/openrc_qemu_0123456789abcdef01234567.socket`. The runner
prints the exact path and removes the socket when QEMU exits.

## Build the image

```sh
tools/qemu/image-build.sh qemu-tests
```

Building needs network access plus QEMU, libguestfs,
`app-emulation/guestfs-tools[ocaml]`, `curl`, OpenSSH, and `socat`. The
completed qcow2 image is sparsified and compressed before it is published. The
image contains OpenRC as PID 1, a binary kernel, GRUB, OpenSSH, `dhcpcd`,
BusyBox, Vim, Git, GDB, Valgrind, strace, and the dependencies of
`sys-apps/openrc-9999`. Test-only SSH keys are stored under
`qemu-tests/images/ssh`.

OpenRC in the base image is built without sanitizers, with
`debug sysv-utils -sysvinit`, debug symbols, and frame pointers. The alternative
`sys-apps/sysvinit` setting is commented in
`/etc/portage/package.use/openrc-qemu`; swap the lines and rebuild OpenRC to
change PID 1:

```text
sys-apps/openrc debug sysv-utils -sysvinit
# sys-apps/openrc debug -sysv-utils sysvinit
```

The guest uses static address `10.0.2.15/24`, gateway `10.0.2.2`, and DNS
`10.0.2.3`. Outbound traffic is blocked by default; enable it when needed:

```sh
NET=NAT tools/qemu/image-run.sh qemu-tests
```

`NET=OFF` and `NET=NONE` alias the default `NET=ISOLATED`. SSH remains
available through a per-run Unix socket in every mode. `dhcpcd` is installed
but disabled in favor of the static `net.eth0` service; no guest agent is used.

## Shell variable convention

Global context owned and populated by a library uses the `G_` prefix and is
declared explicitly at the beginning of that library. For example,
`qemu_run_paths` populates `G_RUN_DIR`, `G_RESULTS_DIR`, and `G_SSH_SOCKET`.
Globals owned by an executable script use ordinary upper-case names such as
`SOURCE_DIR` and `CURRENT_VERSION`. Lower-case names are reserved for variables
declared `local` inside functions. Public environment settings keep their
existing names, including `NET`, `QEMU_ACCEL`, `MEM`, and `UPGRADE_FROM`.

## Run tests

```sh
tools/qemu/tests-run.sh qemu-tests .
```

This snapshots the tracked and unignored worktree files, installs
`openrc-9999`, reboots, and runs the cgroup2 tests. To test an upgrade:

```sh
UPGRADE_FROM=0.55 tools/qemu/tests-run.sh qemu-tests .
```

The upgrade workflow checks service state and cgroup cleanup before and after
reboot. Use `UPGRADE_EXPECTED_VERSION` when the revision name differs from the
reported version.

Useful runner settings include `RUN_ID`, `QEMU_ACCEL=tcg`, `MEM`, `SMP`,
`SSH_WAIT`, and the whitespace-separated `GUEST_TESTS` list:

```sh
GUEST_TESTS=cgroup2/boot.sh tools/qemu/tests-run.sh
```

Rerun one staged test in a running guest with:

```sh
tools/qemu/tests-run-guest.sh \
    qemu-tests/runs/RUN_ID cgroup2/service.sh
```

## Start an image manually

```sh
tools/qemu/image-run.sh qemu-tests
```

This creates the same isolated run layout and attaches the serial console to
the terminal with root autologin. `SERIAL_MODE=file` redirects it to
`serial.log`. Without `RUN_ID` a new overlay is created; the printed resume
command reuses it with all guest changes:

```sh
RUN_ID=20260721T120000Z-1234 tools/qemu/image-run.sh qemu-tests
```

Network mode is selected on every boot. For example, rebuild a packaged OpenRC
release with outbound access:

```sh
# Host:
NET=NAT RUN_ID=20260721T120000Z-1234 tools/qemu/image-run.sh qemu-tests

# Guest:
USE='sysv-utils -sysvinit debug' \
    emerge --ask=n --oneshot =sys-apps/openrc-0.63.1
```

After `poweroff`, resume without `NET=NAT`; the package and downloaded files
remain in the overlay.

## Install a specific OpenRC commit

Install and reboot-test an exact commit without modifying the base image:

```sh
OPENRC_USE='sysv-utils -sysvinit debug' \
OPENRC_ASAN=1 \
tools/qemu/image-update-openrc.sh qemu-tests . 0123456789abcdef
```

The helper creates a run, installs from the local Git checkout, reboots,
verifies PID 1, and powers off. Use `RUN_ID` to update an existing overlay:

```sh
RUN_ID=20260721T120000Z-1234 \
OPENRC_USE='sysv-utils -sysvinit debug' \
OPENRC_ASAN=0 \
tools/qemu/image-update-openrc.sh qemu-tests . 89abcdef01234567
```

`OPENRC_REVISION` can replace the positional commit. `OPENRC_USE` overrides
`package.use`, including negative flags such as `-sysv-utils sysvinit`;
`OPENRC_ASAN=1` enables ASan/UBSan for that update only, defaults to `0`, and
forces `-pam` because an ASan-instrumented `pam_openrc.so` cannot be loaded
safely by the uninstrumented login programs in the image;
`OPENRC_EXPECTED_VERSION` overrides the version check. NAT is the default for
this helper, or use `NET=ISOLATED` with cached dependencies.

To enter the running guest immediately after installation, without running the
version check, rebooting, or running the post-reboot checks, use:

```sh
OPENRC_ASAN=1 \
OPENRC_SHELL=1 \
tools/qemu/image-update-openrc.sh qemu-tests . 0123456789abcdef
```

This opens an interactive root shell over SSH in the same QEMU boot. The serial
console continues to be written to the run's `serial.log`. Exiting the shell
powers off QEMU and preserves the run overlay.

Open the saved guest with:

```sh
RUN_ID=20260721T120000Z-1234 tools/qemu/image-run.sh qemu-tests
```

Guest edits survive `poweroff` and later runs. Install and verification logs
are stored under the run's `results/` directory.

## Manual SSH

For manual SSH, use the socket and key printed by `image-run.sh`, for example:

```sh
ssh -o 'ProxyCommand=socat - UNIX-CONNECT:/tmp/openrc_qemu_ID.socket' \
    -o HostKeyAlias=openrc-qemu \
    -o UserKnownHostsFile=qemu-tests/images/ssh/known_hosts \
    -i qemu-tests/images/ssh/id_ed25519 root@openrc-qemu
```
