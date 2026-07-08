# Proxmox Cluster Rolling Reboot Script

`rolling-reboot.sh` is a Bash helper for safely rebooting every node in a Proxmox VE cluster from a Proxmox node or from a local workstation such as macOS.

It detects cluster members with `pvecm nodes`, connects to each node over SSH, migrates VMs and containers away from the node that is about to be rebooted, checks cluster quorum and Ceph health, reboots one node at a time, and waits for the cluster to recover before continuing.

## What It Does

- Detects Proxmox VE cluster nodes automatically.
- Can run directly on a Proxmox node or remotely through a cluster control node.
- Verifies SSH access to each node before processing it.
- Reboots one node at a time.
- Moves the control node to the end of the reboot order.
- Checks cluster quorum before processing and before rebooting each node.
- Requires Ceph to report `HEALTH_OK` before each reboot.
- Migrates VMs and containers away from the node being rebooted.
- Supports migrating all guests or only running guests.
- Supports selecting or excluding specific nodes.
- Supports dry-run checks without migrating or rebooting anything.
- Waits for remote nodes to return after reboot.
- Waits for Proxmox services, cluster quorum, and Ceph `HEALTH_OK` before moving on.
- Stops immediately if a node cannot be drained safely.

## Requirements

- A Proxmox VE cluster node to act as the cluster control host.
- Bash 3.2 or newer.
- Root privileges when running directly on a Proxmox node.
- `pvecm` available on the cluster control host.
- `ceph` available on the cluster control host.
- SSH key-based login from the operator machine to the cluster control host.
- SSH key-based login from the cluster control host to every cluster node, unless you use `--direct-node-ssh`.
- SSH key-based login from the operator machine to every cluster node if you use `--direct-node-ssh`.
- VM/container storage that supports migration, or explicit migration options that fit your cluster.

## Usage

Review the script before running it:

```bash
less rolling-reboot.sh
```

Make it executable:

```bash
chmod +x rolling-reboot.sh
```

Run a dry run first:

```bash
./rolling-reboot.sh --dry-run
```

Run it as root from a Proxmox VE cluster node:

```bash
./rolling-reboot.sh
```

Run it from macOS or another workstation by targeting a remote Proxmox control node:

```bash
./rolling-reboot.sh --cluster-host root@pve1.example.com --dry-run
```

When `--cluster-host` is set, `pvecm`, `ceph`, `qm`, and `pct` are run on Proxmox nodes over SSH. Other node commands are relayed through the cluster host by default, so your workstation only needs to reach the control node directly.

If your workstation can resolve and SSH to every cluster node directly, disable the relay behavior:

```bash
./rolling-reboot.sh --cluster-host root@pve1.example.com --direct-node-ssh --dry-run
```

If your SSH user is not included in `--cluster-host`, it defaults to `root`. You can override it:

```bash
./rolling-reboot.sh --cluster-host pve1.example.com --ssh-user root --dry-run
```

To pass additional local OpenSSH options, repeat `--ssh-option`:

```bash
./rolling-reboot.sh --cluster-host root@pve1.example.com --ssh-option StrictHostKeyChecking=accept-new --dry-run
```

The script asks for confirmation before starting. To run non-interactively, pass:

```bash
./rolling-reboot.sh --yes
```

To reboot only specific nodes, use a comma-separated list:

```bash
./rolling-reboot.sh --nodes pve1,pve3
```

To skip specific nodes, use:

```bash
./rolling-reboot.sh --exclude pve2
```

By default, the script migrates all VMs and containers it finds on each node, including stopped guests. To drain only active workloads, use:

```bash
./rolling-reboot.sh --running-only
```

For guests on local storage, default migration commands may fail. The script stops instead of rebooting if a guest cannot be migrated. If your cluster needs explicit migration options, you can pass a target storage name:

```bash
./rolling-reboot.sh --target-storage local-zfs
```

For QEMU guests that require local disk migration, you can also pass:

```bash
./rolling-reboot.sh --qm-with-local-disks
```

You can combine these options:

```bash
./rolling-reboot.sh --dry-run --nodes pve1,pve3 --running-only
```

## Important Notes

The script reboots one node at a time. It does not support parallel reboots, because the goal is to keep cluster state, Ceph health, and guest placement controlled throughout the maintenance window.

In local mode, the script must run as root on a Proxmox node. In remote mode, the script does not need local root privileges; it uses SSH to run privileged commands on the Proxmox control host and cluster nodes.

The Ceph gate requires `ceph health` to begin with `HEALTH_OK` before a node is rebooted and after each remote node returns. Clusters with persistent Ceph warnings will intentionally block until the warning is fixed or until you explicitly run with `--skip-ceph-check`.

Migration target selection is automatic. For each guest, the script tries available cluster nodes in order of lowest current guest count and stops if the guest cannot be moved away from the node being rebooted.

If the control node is selected for reboot, it is moved to the end of the order. In local mode, the script exits after scheduling that reboot because its own host is rebooting. In remote mode, the script waits for the control node to return and verifies cluster/Ceph health after it comes back.

The script does not migrate guests back to their original nodes after the rolling reboot. It leaves guests where the successful migration commands placed them.

SSH commands use batch mode, a 10-second connection timeout, one connection attempt, and server-alive checks to detect dead SSH sessions. Remote commands are also wrapped with `timeout`: quick checks use 120 seconds, each guest migration uses 14400 seconds by default, and each remote reboot cycle uses 1800 seconds by default.

## Safety Checklist

Before running this on a live cluster:

1. Confirm you have working backups.
2. Confirm cluster quorum is healthy.
3. Confirm Ceph reports `HEALTH_OK`.
4. Confirm SSH root access works to all nodes.
5. Confirm guest migration works for your storage layout.
6. Run `./rolling-reboot.sh --dry-run` locally, or `./rolling-reboot.sh --cluster-host root@pve1.example.com --dry-run` from a workstation.
7. Plan a maintenance window.

## Verification

The script has been checked with:

```bash
bash -n rolling-reboot.sh
shellcheck rolling-reboot.sh
```
