# cli4bofs 

Command line interface for (running) BOFs.

## Description

Swiss army knife tool for mainataining collection of BOFs files. Allows for running any BOF from filesystem and pass arguments to it. Handy for testing, prototyping and developing BOFs.

## BOF collection

Example of `BOF-collection.yaml` file:

```
name: "udpScanner"
description: "UDP scanner"
author: "Z-Labs"
tags: ['net recon']
OS: "cross"
header: ['thread', 'sb']
sources:
    - 'https://raw.githubusercontent.com/The-Z-Labs/bof-launcher/main/bofs/src/cUDPscan.zig'
usage: '<targetSpecification:portSpecification> [bufferPtr]'
examples:
    - "cUDPScan 192.168.0.1:21,80"
    - "cUDPScan 192.168.0.1:80-85"
    - "cUDPScan 102.168.1.1-2:22"
    - "cUDPScan 102.168.1.1-32:22-32,427"

#
# Third party BOFs
#

---
name: "zerologon"
description: "Exploit for CVE-2020-1472, a.k.a. Zerologon. This allows for an attacker to reset the machine account of a target Domain Controller, leading to Domain Admin compromise. **This exploit will break the functionality of this domain controller!**"
author: "Rsmudge"
tags: ['exploit']
OS: "windows"
header: ['inline', 'ZZZ']
sources:
    - 'https://raw.githubusercontent.com/rsmudge/ZeroLogon-BOF/master/src/zerologon.c'
usage: "zerologon <dc_fqdn> <dc_netbios> <dc_account>"
examples:
    - "zerologon DC.corp.acme.com DC DC$"
```

## Usage

Usage commands:

```
Usage: ./zig-out/bin/cli4bofs [command] [options]

Commands:

exec		Execute given BOF from filesystem
info		Display details about BOF

General Options:

-c, --collection	Provide custom BOF yaml collection
-h, --help		    Print this help
```

Usage of `exec` subcommand:

```
Usage: ./zig-out/bin/cli4bofs_lin_x64 <BOF> [[prefix:]ARGUMENT]...

Execute given BOF from filesystem with provided ARGUMENTs.

ARGUMENTS:

ARGUMENT's data type can be specified using one of following prefix:
	short OR s	 - 16-bit signed integer.
	int OR i	 - 32-bit signed integer.
	str OR z	 - zero-terminated characters string.
	wstr OR Z	 - zer-terminated wide characters string.
	file OR b	 - special type followed by file path indicating that a pointer to a buffer filled with content of the file will be passed to BOF.

If prefix is ommited then ARGUMENT is treated as a zero-terminated characters string (str / z).

EXAMPLES:

cli4bofs uname -a
cli4bofs udpScanner 192.168.2.2-10:427
cli4bofs udpScanner z:192.168.2.2-10:427
cli4bofs udpScanner 192.168.2.2-10:427 file:/path/to/file/with/udpPayloads
```

