# openZFS Backup Server

## Introduction

This article demonstrates how to set up a multi-client openZFS backup server
based on the `sanoid`/`syncoid` toolchain. Data on the backup system
will be sent encrypted and will also rest fully encrypted _at all times_. So
even in case the host was compromised, a potential attacker still would need to
crack your password in order to gain access to your data.

By exploiting ZFS's privilege delegation we also make sure that in case any of
the clients (or their SSH keys) were compromised, a potential attacker could
never delete any already backed-up data (only create and push new ones), and
harmful actions would be restricted to only the datasets belonging to this very
client and no other.

Security can be enhanced even further by allowing SSH users only to run a
specific set of commands via the [restricted-ssh-commands feature](https://manpages.ubuntu.com/manpages/xenial/man1/restricted-ssh-commands.1.html).
See also [this repo](https://github.com/Derkades/ssh-zfs-receive/).

Assumptions:

- Server
  - runs Ubuntu (standard server setup, no root-on-zfs required)
  - commands run as root
  - has (at least) one spare SSD accessible as `/dev/disk/by-id/<ID>`
- Client
  - runs Arch Linux
  - commands run as unprivileged user
  - has an encrypted parent dataset (`zroot/encr`)

## Terminology

We'll encounter two types of backups (read: data copies) throughout this
article:

1. local ZFS snapshots
2. "remote" copies of ZFS datasets on backup server

Strictly speaking, snapshot do not qualify as backup at all. If your local disk
fails, all snapshots are gone as well together with the "primary data". So just
think of (local) ZFS snapshots as Linux hard links.

> Looking back at about 10 years of personally relying on the presented
> openZFS setup, I can tell that, since luckily none of my disks ever failed,
> the "backup" (read: local data copy) I've invoked most often is and
> probably will always will be: snapshots. With a snapshot frequency of
> 15min, I was able to always recover accidentially deleted files and the like
> comfortably within seconds.

But even combined with the server component to which you send snapshots on a
daily basis, this setup does not fully qualify as proper backup from the
client's perspective according to the [3-2-1
rule](https://www.backblaze.com/blog/the-3-2-1-backup-strategy/):

- Have at least 3 copies of your data (primary storage included)
- Two may be local but on different media (e.g. laptop disk and on-site ZFS server)
- Keep 1 copy off-site (cloud or grandma's basement :wink:)

Assuming your ZFS server is located in your home, you're still missing a third
truly remote (i.e. physically and geographicaly separated, air-gapped) copy.

Cloud backups would qualify as such, so I highly recommend to complement
snapshots + local ZFS server with sth. like
[Backblaze B2](https://www.backblaze.com/cloud-storage), preferably with
[object lock](https://www.backblaze.com/docs/cloud-storage-object-lock)
(make remote data immutable) and possibly extended by
[cloud replication](https://www.backblaze.com/docs/cloud-storage-cloud-replication)
(spread another set of copies across different cloud locations).

> [!NOTE]
> Personally, I wouldn't go with two ZFS servers, one on-site and one off-site.
> Having copies "on different media" can be interpreted not only as "on
> different disks" but rather "on different storage types", e.g. openZFS block
> storage and S3 object storage.

## Server configuration

> [!TIP]
> No need for a full-blown Proxmox-based backup solution running on a huge NAS.
> My personal backup server runs on an Intel Celeron powered mini PC, has
> roughly the size of an Xbox controller and was less than 170€ on sale
> (M.2 SSD included) :wink:.

> [!WARNING]
> As of 2021 / kernel 5.x, openZFS does unfortunately still not run satisfyingly
> on ARM architecture, so most SBCs are not suitable as backup server.
> Hopefully this will change soon. :eyes:

### Backup pool

If not already available, install zfs tools

```
apt install zfsutils-linux
```

Create pool (for simplicity on a single-disk vdev, but can easily be
extended to mirror or RAID-Z)

```
# single vdev
zpool create \
 -o ashift=12 -o autotrim=on \
 -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off \
 -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
 -O mountpoint=none \
 backup /dev/disk/by-id/<ID>

# adding 2nd mirror drive afterwards (can be done any time)
zpool attach backup <existing-disk> <new-disk>

# 2-disk mirror from the start
zpool create [...] backup mirror <disk1> <disk2>

```

Export and re-import **without mounting** (`-N`), cache in
`/etc/zfs/zpool.cache` will be automatically generated.

```
zpool export backup
zpool import -d /dev/disk/by-id/ -N backup
```

Run trim & scrub manually once and check pool status

```
zpool trim backup
zpool scrub backup
watch zpool status
```

Make it persistent with `crontab -e`

```cron
# m h dom mon dow command
15  8 * * 1,3,5 zpool scrub backup
15  8 * * 1,3,5 zpool trim  backup
```

> [!TIP]
> There's also a nice [web dashboard](https://github.com/rouben/zfswatcher)
> available for openZFS servers, showing the pool states, statistics and logs.

### Power Settings

I prefer to let servers shut down when they are only needed for a very short
time a day. Say, the backup server is configured via BIOS to start at 7:55 a.m.,
then a client could send its data 8:00 a.m. and cronjobs could follow right
after every other day. Since the whole procedure shouldn't take much longer than
30min, we can add this line to the server's crontab

```cron
@reboot shutdown -P +45
```

to shut it down for the remaining 23h of the day. Reduces energy consumption
and safes $$ :wink:.

### Snapshot management

Install sanoid and configure it to **not** create new snapshots but **prune** old
ones.

```
apt install pv lzop mbuffer sanoid
```

Check that services are running (only timer) and enabled (both)

```
systemctl status sanoid.timer
systemctl status sanoid-prune.service
```

Put template configuration into `/etc/sanoid/sanoid.conf`. Example:

```text
[template_backup]
    frequently = 0
    hourly = 0
    daily = 30
    weekly = 12
    monthly = 6
    yearly = 0

    autosnap = 0
    autoprune = 1

[backup]
    use_template = backup
    recursive = yes

# overrides for individual clients
# [backup/client]
#
#   use_template = backup
#   recursive = yes
#   [...other client-specific overrides...]
```

> [!IMPORTANT]
> Make sure to disable `autosnap` and enable `autoprune`!

> [!NOTE]
> On the server side it's better to set `recursive` to `yes` instead of `zfs`.
> There, snapshots will not be created, only destroyed, hence `recursive`
> ensures to have them correctly deleted even if they have not been created
> atomically via ZFS-native recursion.

## Client configuration

### Snapshot management

Install sanoid

```
sudo pacman -S pv lzop mbuffer
yay sanoid  # please vote to finally bring this from AUR to community! :pray:
```

Start and enable services

```
sudo systemctl enable --now sanoid.timer
sudo systemctl enable --now sanoid-prune.service
```

and configure `/etc/sanoid/sanoid.conf` to periodically create new snapshots

```text
[template_default]
	frequently = 96
	hourly = 48
	daily = 14
	weekly = 8
	monthly = 3
	yearly = 0

	autosnap = yes
	autoprune = yes

	hourly_warn = 4h
	hourly_crit = 6h
	daily_warn = 2d
	daily_crit = 4d

[zroot/encr/system]
	use_template = default
	recursive = zfs

[zroot/encr/userdata]
	use_template = default
	recursive = zfs
```

> [!IMPORTANT]
> This example config assumes a dataset structure as created in the
> bootstrapping part, i.e. user data in `userdata`, system data in `system` and
> tmp, caches, logs etc. in `nobackup` (hence no entry in sanoid).

> [!NOTE]
> Make sure to understand the difference between `recursive = yes` and
> `recursive = zfs`. With my setup, I prefer to have atomic snapshots via the
> zfs-native recursion.

### Privilege delegation

On client side, the sending user needs permissions to temporarily `hold`
snapshots and of course `send` them.

```
zfs allow <USER> hold,send zroot/encr
```

Check with

```
zfs allow zroot/encr
```

## Adding new clients

### SSH key

On the client, we need a dedicated SSH key that is not password-protected such
that connections to the backup server can be established unattended.

Personally, I like to include the hostname, purpose and creation date into the
SSH key's comment like so:

```
ssh-keygen -t ed25519 -C "<CLIENT>::zfs-backup::$(date +'%Y-%m-%d')" -f ~/.ssh/backup
```

### Parent dataset

On the server, for each new client create a separate parent dataset

```
zfs create -o mountpoint=none -o canmount=off backup/<CLIENT>
```

and, if you want to override any retention settings, add additional entries in
`/etc/sanoid/sanoid.conf` (see
[example](https://github.com/jimsalterjrs/sanoid/blob/master/sanoid.conf)
for possible config options)

```text
[backup/<CLIENT>]
    hourly = 24
```

### Privilege delegation

On the server, create a new user

```
adduser --disabled-password --gecos "zfs backup user for <CLIENT>" <CLIENT>
```

and add the client's SSH key to the _new user's_ `authorized_keys`

```
su - <CLIENT>
mkdir ~/.ssh
vim ~/.ssh/authorized_keys
```

Grant this user all required ZFS permissions

```
zfs allow work rollback,create,receive,mount backup/<CLIENT>
```

Check with

```
zfs allow backup/<CLIENT>
```

After the initial transfer (see below), this can be limited to only the
descendants of the newly created parent dataset

```
zfs unallow work rollback,create,receive,mount backup/<CLIENT>
zfs allow -d work rollback,create,receive,mount backup/<CLIENT>
```

> [!NOTE]
>
> - Although we do not mount any encrypted datasets on the server, the `mount`
>   permission is required nevertheless. Without we would see this error:
>   _"cannot receive new file system stream: permission denied"_
> - `rollback` can only roll back to the latest snapshot as long as `destroy` is
>   not granted
> - `destroy` is not required b/c `sanoid` takes care of removing old snapshots
>   and does not create new ones (_on the backup server_!)

> [!TIP]
> If you want to understand openZFS privilege delegation more deeply, check
> [this excellent article](https://klarasystems.com/articles/improving-replication-security-with-openzfs-delegation/).

## Backup routine

### Syncoid setup

Pushing snapshots to the remote backup server is handled by `syncoid` which
comes as part of the `sanoid` installation.

For our purpose, the full backup command reads

```
syncoid \
  --recursive \               # enable recursion
  --sendoptions="w" \         # send encrypted raw data
  --no-privilege-elevation \  # no root b/c we've set up privilege delegation
  --no-sync-snap \            # do not create tmp snapshots, use existing ones
  zroot/encr ${<CLIENT>}@backup:backup/${<CLIENT>}/encr
```

This will recursively send new snapshots of the encrypted parent dataset as raw
data stream to the backup server via SSH, hence no unencrypted data ever leaves
the client.

Single child datasets can be (recursively) excluded from the backup via

```
sudo zfs set syncoid:sync=false zroot/encr/nobackup
```

Check excludes with

```
sudo zfs get -r -s local syncoid:sync zroot/encr
```

In order to automate this backup procedure just create a cronjob entry with the
above command.

> [!TIP]
> I prefer some visual feedback on my daily backup transfers, so my `syncoid`
> command is wrapped in a shell script which sends a desktop notification on
> start/end and an alert to my `#monitoring` Slack channel in case of failure
> together with the error messages.<br>
> See [this file](https://github.com/PandaScience/dotfiles/blob/main/bin/syncoid.sh)
> for details.

### Initial transfer

There's a tiny subtlety we need to work around with this particular
sanoid/syncoid/security setup:

The `zroot/encr` dataset on the client has no automatic `sanoid` snapshots, but
we use it as root dataset for `syncoid`, which in turn will refuse to sync this
dataset given the `--no-sync-snap` option, which in turn is required to prevent
more powerful and potentially dangerous ZFS user privilege delegation (namely
`destroy`!).

Fortunately, there's a super easy workaround for that: Just create a
non-recursive dummy snapshot before the first replication and prevent its
deletion

```
sudo zfs snapshot zroot/encr@keep-for-syncoid
sudo zfs hold keep zroot/encr@keep-for-syncoid
```

Check

```
# list all non-sanoid snapshots
zfs list -t snapshot | grep -v "autosnap"

# list all held snapshots
zfs get -Ht snapshot -o name userrefs | xargs zfs holds
```

## Troubleshooting

### Hidden clones

After incomplete transfers, there might remain leftovers on the server which
will mess with subsequent backup streams.

A possible error message could look like this:

```
cannot resume send: 'zroot/encr/system/ROOT@autosnap_2023-09-29_04:00:18_hourly' used in the initial send no longer exists
cannot receive: failed to read from stream
WARN: resetting partially receive state because the snapshot source no longer exists
cannot destroy 'backup/work/encr/system/ROOT/%recv': permission denied
CRITICAL ERROR: ssh      -S /tmp/syncoid-work@backup-1700990525-824 work@backup  zfs receive -A ''"'"'backup/work/encr/system/ROOT'"'"'' failed: 256 at /usr/bin/syncoid line 2177.
```

Instead of giving general destroy permissions, which would contradict our
security considerations from above (search for privilege delegation), just
remove the offending dataset manually

```
sudo zfs destroy backup/work/encr/system/ROOT/%recv
```

> [!NOTE] > `%recv` is called "hidden clone" and created when receiving incremental send
> streams. To list such snapshots run
>
> ```
> zfs list -t all -r <dataset>
> ```

### Bulk remove snapshots

Sometimes you may need to delete a whole bunch of snapshots.

```
# delete all except last 10 snapshots, dry-run version
zfs list -t snapshot -o name -S creation <dataset> | grep [-v] <includes or excludes> | tail -n +10 | xargs -n1 echo zfs destroy -vr
```

Helpful resources:

- https://serverfault.com/questions/340837/how-to-delete-all-but-last-n-zfs-snapshots
- https://github.com/bahamas10/zfs-prune-snapshots

## Recovery

### From snapshot

Accidential `rm -rf *` in wrong folder while working late?

First disable snapshotting on client (but allow for 1 more frequent snapshot to evaluate damage)

```
systemctl stop sanoid.timer
```

Identify affected files

> [!IMPORTANT]
> This only works for sanoid-based auto snapshots, if they have been
> configured with the `recursive = zfs` option!

```
# show latest snapshots for "root" dataset
zfs list -t snap -o name,creation -s creation zroot/encr/data | tail

# get relevant datasets
datasets=$(zfs list -H -o name zroot/encr/data -r)

# determine snapshots right before and after the accidential delete
snap1=autosnap_2023-12-10_10:15:00_frequently
snap2=autosnap_2023-12-10_10:30:26_frequently

# show diffs for each dataset
while IFS= read -r ds; do zfs diff ${ds}@{$snap1,$snap2} | less; done <<< $datasets
```

Recover either via rsync from `.zfs/snapshot/<snapshot>` or perform a rollback.

> [!IMPORTANT]
> Rollbacks of the system dataset can obviously not be done on a running client.
> Instead, boot into a live system via thumb drive, import the ZFS pool and
> run the rollback command there (no need to mount or decrypt any datasets!).

If multiple datasets are affected, note that there is no recursive rollback for
child datasets. You need to manually construct a suitable command:

```
zfs list -r -H -o name zroot/encr/data | xargs -I{}  zfs rollback -r {}@autosnap_2023-12-10_10:30:26_frequently
```

### From server

In case you need to recover from the remote server, this typically means your
local disk has failed or you managed to loose your primary data including all
local snapshots of a specific dataset somehow.

The easiest option is to just sync back either the entire backup (and let
sanoid purge older snapshots) or only transfer the latest snapshot.

Either way, get a new disk, prepare the ZFS environment as exlpained in the
[bootstrap part](bootstrap.md), create a new zpool and send the deleted dataset
recursively from the server with a plain `zfs send/recv`:

```
# recommended:
# run cmd as root on backup server -> put backup server's SSH key on live system
zfs send -vwR backup/<client>/<dataset>@<snapshot> | ssh root@client zfs recv -uF zroot/<dataset>

# technically also possible:
# ssh to root@backup server from live system -> e.g. via yubikey
ssh root@backup zfs send -wR backup/<client>/<dataset>@<snapshot> | zfs recv -uFv zroot/<dataset>
```
