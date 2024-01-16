# Arch Linux - Root on ZFS

<p align="center"><img src="img/logos.png" alt="logos" width="500"/></p>

> [!IMPORTANT]
> For linux, root on ZFS is pretty much PITA to set up and maintain, mostly
> because it cannot be included into the kernel due to licensing
> incompatibilities.
> As soon as [bcachefs](https://bcachefs.org/) is ready and has all the
> features like zfs-like send/recv etc. implemented, I'm pretty certainly going
> to switch and simplify this setup.

This is a step-by-step guide on my approach to install arch linux root on
openZFS where we use zfs-datasets to reasonably "partition" the system and
enable auto-snapshots and frequent remote backups on top.

For simplicity, I reduced this guide for a single-boot laptop-like system (no
mirror or ZRAID) and made some opinionated year-2023-choices:

- use GPT instead of MBR partition tables
- use rEFInd as boot manager
- use ZRAM instead of a swap partition
- use native ZFS encryption for everything (except EFI)
- prevent snapshot pollution by introducing a **smart dataset layout**

For deviating configurations check out the linked resources, in particular:

- https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html
- https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS#Get_ZFS_module_on_archiso_system

The setup is divided into three parts, each with its own full-text walk-trough
and script for automation (see `scripts` folder).

| Step | Topic         | Walk-through             | Script                           |
| ---- | ------------- | ------------------------ | -------------------------------- |
| 1    | Bootstrap     | [link](bootstrap.md)     | [link](scripts/bootstrap.sh)     |
| 2    | Configuration | [link](configuration.md) | [link](scripts/configuration.sh) |
| 3    | Backup        | [link](backup.md)        | -                                |
