# cli4bofs 

Standalone command line interface for launching [BOF files](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/beacon-object-files_main.htm) outside of [Cobalt Strike Beacon](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/welcome_main.htm) environment. Under the hood it uses our [bof-launcher library](https://github.com/The-Z-Labs/bof-launcher) to accomplish its main task: running BOFs files on Windows (x86, x64) and Linux/UNIX (x86, x64, ARM, AARCH64) platforms.

## Description

Swiss army knife tool for running and mainataining collection of BOFs files. Allows for running any BOF from filesystem and for conveniently passing arguments to it. Defines simple `yaml` schema for essential information about BOF files, like: description, URL(s) of the source code, arguments, usage examples, etc. Handy also for testing, prototyping and developing BOFs.

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

