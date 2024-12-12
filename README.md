# cli4bofs 

Standalone command line interface for launching [BOF files](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/beacon-object-files_main.htm) outside of [Cobalt Strike Beacon](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/welcome_main.htm) environment. Under the hood it uses [bof-launcher library](https://github.com/The-Z-Labs/bof-launcher) to runn BOFs files on Windows (x86, x64) and Linux/UNIX (x86, x64, ARM, AARCH64) platforms directly from a filesystem. You can download binaries for all supported platforms [here](https://github.com/The-Z-Labs/cli4bofs/releases).

## Description

A swiss army knife tool for running and mainataining collection of BOFs files. Allows for running any BOF from a filesystem and for conveniently passing arguments to it. Defines simple `yaml` schema for essential information about BOF files, like: description, URL(s) of the source code, supported arguments, usage examples, etc. Handy also for testing, prototyping and developing your own BOFs.

## Program usage

### Generic commands usage

```
Usage: cli4bofs command [options]

Commands:

help     	<COMMAND>	Display help about given command
exec     	<BOF>		Execute given BOF from a filesystem
info     	<BOF>		Display BOF description and usage examples
usage    	<BOF>		See BOF usage details and parameter types
examples 	<BOF>		See the BOF usage examples
list     	[TAG]		List BOFs (all or based on provided TAG) from current collection

General Options:

-c, --collection		Provide custom BOF yaml collection
-h, --help			Print this help
-v, --version			Print version number
```

### Usage of 'exec' subcommand

`exec` subcommand allows for executing `BOF` directly from a filesystem. One can also conveniently pass arguments to `BOF` using one of `sizZb` (followed by `:`) characters as a prefix to indicate argument's type, as explained below:

```
Usage: cli4bofs exec <BOF> [[prefix:]ARGUMENT]...

Execute given BOF from filesystem with provided ARGUMENTs.

ARGUMENTS:

ARGUMENT's data type can be specified using one of following prefix:
	short OR s	 - 16-bit signed integer.
	int OR i	 - 32-bit signed integer.
	str OR z	 - zero-terminated characters string.
	wstr OR Z	 - zero-terminated wide characters string.
	file OR b	 - special type followed by file path indicating that a pointer to a buffer filled with content of the file will be passed to BOF.

If prefix is ommited then ARGUMENT is treated as a zero-terminated characters string (str / z).

EXAMPLES:

cli4bofs exec uname -a
cli4bofs exec udpScanner 192.168.2.2-10:427
cli4bofs exec udpScanner z:192.168.2.2-10:427
cli4bofs exec udpScanner 192.168.2.2-10:427 file:/tmp/udpProbes
```


## Yaml BOF collections

In addition to `BOF` execution capability, `cli4bofs` tool can be used to store and present BOF's documentation, like: BOF description, parameters specification, example BOF usage, etc. During the startup the tool looks for `BOF-collection.yaml` file in the current directory and looks for the record regarding chosen `BOF`.

For documenting BOFs, a simple `yaml` schema can be used. Example of an yaml BOF specification for our [udpScanner BOF](https://github.com/The-Z-Labs/bof-launcher/blob/main/bofs/src/udpScanner.zig) is shown below:

```
name: "udpScanner"
description: "Universal UDP port sweeper."
author: "Z-Labs"
tags: ['windows', 'linux','net-recon','z-labs']
OS: "cross"
entrypoint: "go"
sources:
    - 'https://raw.githubusercontent.com/The-Z-Labs/bof-launcher/main/bofs/src/udpScanner.zig'
examples: '
 Scanning provided IP range on most common UDP ports with builtin UDP probes:

   udpScanner str:192.168.0.1-32

 Scanning only cherry-picked ports (if no builtin UDP probe for the chosen port is available then length and content of the packet payload will be randomly generated:

   udpScanner str:192.168.0.1:123,161
   udpScanner str:102.168.1.1-128:53,427,137
   udpScanner str:192.168.0.1:100-200

 Example of running with provided UDP probes:

   udpScanner str:192.168.0.1-32 int:BUF_LEN str:BUF_MEMORY_ADDRESS

 UDP probe syntax (with example):

   <portSpec> <probeName> <hexadecimal encoded probe data>\n
   53,69,135,1761 dnsReq 000010000000000000000000

 Example of running udpScanner using cli4bofs tool and with UDP probes provided from the file:

   cli4bofs exec udpScanner 102.168.1.1-4:161,427 file:/tmp/udpPayloads
'
arguments:
  - name: IPSpec
    desc: "IP addresses specification, ex: 192.168.0.1; 10.0.0-255.1-254; 192.168.0.1:161,427,10-15"
    type: string
    required: true
  - name: BufLen
    desc: "length of UDP probes buffer"
    type: integer
    required: false
  - name: BufMemoryAddress
    desc: "memory address of UDP probes buffer"
    type: string
    required: false
```

As an example, listing available `BOFs` in the collection with `linux` tag:

    $ cli4bofs list linux

Gives:

```
BOFs with 'linux' tag:
udpScanner       | windows,linux | Universal UDP port sweeper.
tcpScanner       | windows,linux | TCP connect() port scanner
ifconfig         | linux         | Displays the status of the currently active network interfaces; Manipulates current state of the device (euid = 0 or CAP_NET_ADMIN is required for that)
cat              | linux         | Concatenate FILE to stdout
tasklist         | linux         | Report a snapshot of the current processes
pwd              | linux         | Print name of current/working directory
```

Displaying parameter specification and usage explanation for selected `BOF`:

    $ cli4bofs usage udpScanner

Gives:

```
ENTRYPOINT:

go()

ARGUMENTS:

string:IPSpec                   IP addresses specification, ex: 192.168.0.1; 10.0.0-255.1-254; 192.168.0.1:161,427,10-15
[ integer:BufLen ]              length of UDP probes buffer
[ string:BufMemoryAddress ]     memory address of UDP probes buffer
```
