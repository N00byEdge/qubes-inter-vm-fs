# Qubes inter-vm file system

Lets you share your directories between your qubes. All data is sent over qubes rpc and share access is managed by dom0. The share is mounted on your client using fuse.

## Setup

Please note that the `{service_name}` (default `n00byedge.qubes-inter-vm-fs`) referred to in here should match the one set in the source code. The same goes for `{config_dir}` (default `/rw/config/inter-vm-fs/`)

The executable created by this repo is assumed to be installed as `/usr/bin/{service_name}`. There is also assumed to be an RPC endpoint file: `/etc/qubes-rpc/{service_name}` on the qube that should share the files with others, and it should look something like the following:
```sh
#!/bin/bash
exec /usr/bin/{service_name} server $QREXEC_SERVICE_ARGUMENT
```

This passes on the share name as the QREXEC argument, which we will set up dom0 to check in a bit. That means the server executable can just blindly trust this value.

### Share creation
Decide on a name for the share, we're going to call this `share_name`. On the qube that is going to share files, create the following single line file `{config_dir}/{share_name}`:

```
/absolute/path/to/my/share/dir r
```

OR

```
/absolute/path/to/my/share/dir rw
```

with the `r` meaning readonly access is provided to the directory, and `rw` meaning the remote also gets to modify the contents.

### Allow access through dom0
* If you want dom0 to ask you every time you want to connect to a share, you can create the following file only once `/etc/qubes-rpc/policy/{service_name}` with the following contents:
    ```
    $anyvm $anyvm ask
    ```
* If you want dom0 to always allow a specific VM access to a specific share, create the following file: `/etc/qubes-rpc/policy/{service_name}+{share_name}`:
    ```
    {client} {server} allow
    ```

### Connecting a client
```
{service_name} client {server} {share_name} {mount_dir}
```

