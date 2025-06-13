# cli4bofs 

Standalone command line interface for launching [BOF files](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/beacon-object-files_main.htm) outside of [Cobalt Strike Beacon](https://hstechdocs.helpsystems.com/manuals/cobaltstrike/current/userguide/content/topics/welcome_main.htm) environment. Under the hood it uses [bof-launcher library](https://github.com/The-Z-Labs/bof-launcher) to run BOFs files on `Windows (x86, x64)` and `Linux (x86, x64, ARM, AARCH64)` platforms directly from a filesystem. You can download binaries for all supported platforms [here](https://github.com/The-Z-Labs/cli4bofs/releases).

## Description

A swiss army knife tool for running and mainataining collection of BOFs files. Allows for running any BOF from a filesystem and for conveniently passing arguments to it. Defines simple YAML schema for essential information about BOF files, like: description, URL(s) of the source code, supported arguments, usage examples, etc. Handy also for testing, prototyping and developing your own BOFs.

## Program usage

### Generic commands usage

```
Usage: cli4bofs command [options]

Commands:

help     	<COMMAND>		    Display help about given command
exec     	<BOF>			    Execute given BOF from a filesystem
inject   	file:<BOF> i:<PID>	Inject given BOF to a process with given pid
info     	<BOF>			    Display BOF description and usage examples
list     	[TAG]			    List BOFs (all or based on provided TAG) from current collection

General Options:

-h, --help			    Print this help
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

### BOFs injection to remote proccess with 'inject' subcommand

### Yaml BOF collection and 'info' subcommand

In addition to `BOF` execution capability, `cli4bofs` tool can be used to store and present BOF's documentation, like: BOF description, parameters specification, example BOF usage, etc. During the startup the tool looks for `BOF-collection.yaml` file in the current directory and looks for the record regarding chosen `BOF`.

This repository also contains the YAML collection ([BOF-3rdparty-collection.yaml](BOF-3rdparty-collection.yaml)) for various BOFs that we found useful. To take advantage of it just drop the file in the directory with your `cli4bofs` binary and rename it to `BOF-collection.yaml`. You're encouraged to contribute YAML doc entries for additional BOFs to the collection!

Documenting BOFs is very easy and is a matter of creating simple YAML file entry. For an example of YAML doc entry see [udpScanner BOF](https://github.com/The-Z-Labs/bof-launcher/blob/main/bofs/src/udpScanner.zig) source file.

Displaying description and parameter specification for selected `BOF`:

    $ cli4bofs info udpScanner

Gives:

```
Name: udpScanner
Description: Universal UDP port sweeper.
BOF authors(s): Z-Labs

ENTRYPOINT:

go()

ARGUMENTS:

string:IPSpec                   IP addresses specification, ex: 192.168.0.1; 10.0.0-255.1-254; 192.168.0.1:161,427,10-15
[ integer:BufLen ]              length of UDP probes buffer
[ string:BufMemoryAddress ]     memory address of UDP probes buffer

POSSIBLE ERRORS:


EXAMPLES: 
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
```
