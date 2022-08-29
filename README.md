# Barn

Barn is a tool to mirror your local directory on a remote machine.

## demo

[![asciicast](https://asciinema.org/a/ZDBRvZRtip7ZFiNF7xG5q4liR.svg)](https://asciinema.org/a/ZDBRvZRtip7ZFiNF7xG5q4liR)

### Prerequisite

**Zig version:** 0.10 or master
Make sure the remote machine's kernel has enabled `CONFIG_FUSE_FS`.
This is the only dependency, no others!

## Usage

1. Start server on the remote machine:

```
# barn server
```

By default, it will select a unused port to listen on. Of course you could specify the port with `--port` option:

```
# barn server --port=xxx
```

2. Connect to the server from your local machine:

```
# barn client --remote=<remote machine's ip address> --port=<the listenning port>
```

3. Once the initialization is done between server and client,
you should see the mirror directory like this on server's output:

```
serving from <ip>:<port>, the mirror root directory: /tmp/barn_xxx
```

However, you could also find the location through mount point:

```
# mount
...
/dev/fuse on /tmp/barn_xxx type fuse (rw,nosuid,nodev,relatime,user_id=0,group_id=0)
```

4. Now, everything is set successfully, you could do whatever you want in the mirror directory,
everything there is a mirror of your local root directory.
You could even `chroot` into that directory:

```
# chroot /tmp/barn_xxx /bin/bash
```

Have fun!

## Installation

You could either download the [prebuilt binary](https://github.com/tw4452852/barn/releases/latest) or build from source.

### How to build

```
git clone https://github.com/tw4452852/barn
cd barn
zig build -Dtarget=x86_64-linux-musl
```

If everything is ok, the binary will be located in `./zig-out/bin/barn`.

## Inspiration

This tool is heavily inspired by the [u-root's cpu](https://github.com/u-root/cpu)
which is an implementation of [plan9's cpu](http://man.cat-v.org/plan_9/1/cpu).
There is [an excellant article](https://book.linuxboot.org/cpu/) to talk about it.