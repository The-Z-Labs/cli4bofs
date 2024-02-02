# cli4bofs 

Standalone command line interface for launching [BOF files](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/beacon-object-files_main.htm) outside of [Cobalt Strike Beacon](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/welcome_main.htm) environment. Under the hood it uses our [bof-launcher library](https://github.com/The-Z-Labs/bof-launcher) to accomplish its main task: running BOFs files on Windows (x86, x64) and Linux/UNIX (x86, x64, ARM, AARCH64) platforms directly from a filesystem.

## Description

Swiss army knife tool for running and mainataining collection of BOFs files. Allows for running any BOF from filesystem and for conveniently passing arguments to it. Defines simple `yaml` schema for essential information about BOF files, like: description, URL(s) of the source code, arguments, usage examples, etc. Handy also for testing, prototyping and developing BOFs.

## BOF collection

Example of an entry in `BOF-collection.yaml` file:

```
name: "udpScanner"
description: "Universal UDP port sweeper."
author: "Z-Labs"
tags: ['net-recon']
OS: "cross"
header: ['thread', 'zib']
sources:
    - 'https://raw.githubusercontent.com/The-Z-Labs/bof-launcher/main/bofs/src/udpScanner.zig'
usage: '
    udpScanner str:IPSpec[:portSpec] [int:BUF_LEN str:BUF_MEMORY_ADDR]

Arguments:

    str:IPSpec[:portSpec]    ex: 192.168.0.1; 10.0.0-255.1-254; 192.168.0.1:161,427,10-15
    [int:BUF_LEN]            length of UDP probes buffer
    [str:BUF_MEMORY_ADDR]    pointer to the buffer containing one or more UDP probe(s). One probe per line is allowed.

UDP probe syntax (with example):

<portSpec> <probeName> <hexadecimal encoded probe data>\n
53,69,135,1761 dnsReq 000010000000000000000000'

examples: '
    Scanning provided IP range on most common UDP ports with builtin UDP probes:

      udpScanner str:192.168.0.1-32

    Scanning only cherry-picked ports (if no builtin UDP probe for the chosen port is available then length and content of the packet payload will be randomly generated: 

      udpScanner str:192.168.0.1:123,161
      udpScanner str:102.168.1.1-128:53,427,137
      udpScanner str:192.168.0.1:100-200

    Example of running with provided UDP probes:

      udpScanner str:192.168.0.1-32 int:BUF_LEN str:BUF_MEMORY_ADDRESS

    Example of running udpScanner using cli4bofs tool and with UDP probes provided from the file:

      cli4bofs exec udpScanner 102.168.1.1-4:161,427 file:/tmp/udpPayloads'
```

## Usage

Usage commands:

```
Usage: ./zig-out/bin/cli4bofs command [options]

Commands:

help     	COMMAND	Display help about given command
exec     	BOF		Execute given BOF from a filesystem
info     	BOF		Display BOF description and usage examples
usage    	BOF		See BOF invocation details and parameter types
examples 	BOF		See the BOF usage examples

General Options:

-c, --collection		Provide custom BOF yaml collection
-h, --help			Print this help
```

Usage of `exec` subcommand:

```
Usage: cli4bofs <BOF> [[prefix:]ARGUMENT]...

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
cli4bofs udpScanner 192.168.2.2-10:427 file:/tmp/udpProbes
```

