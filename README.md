# CFCheck

### CouchDB dbs and views file checking and analysing tool

## Overview

cfcheck is a tool to analyze CouchDB 2.0 database and view files. It recursively scans provided path to CouchDB installation, collects all the files with `.couch` and `.view` extention and then reads each of them, locating and parsing latest header and optionally walking the b-trees. To speed the things up cfcheck spawns a process per file and then aggregates the results. It does not depends on CouchDB to be up and running.

The tool can handle files compressed with either standard erlang's binary gzip compressor or [snappy](https://code.google.com/p/snappy/)

Aggregated information shows number of the files of each type, total size of the files, document count, including deleted and purged documents, active and extended sizes and grouped by disk versions count of the database files (views don't have versioning).

Additionally the tool can walk the b-trees of the database and view files and aggregate total depth of the trees and minimal and maximum number of the branches per KP and KV nodes. Also it fetches a database security object if presented.

The tool uses JSON to output the information for possible post-processing.

By default, because on the large setups the run can be rather time consuming, the tool caches the detailed output into `/tmp/cfcheck.json`. This file can be read either directly or by the tool, so the first run can be just for a summary output and then cache can be re-read with `-c` flag if summary points to something suspicious.

## Installation

The build uses [erlang.mk](https://github.com/ninenines/erlang.mk). Just running `make` will fetch and compile dependencies and build shell-executable archive named `cfcheck`.

Because the script depends on NIFs, `snappy` for decompressing couch files and `jiffy` to output JSON, it's not really a self-contained and depends on `*.so` libs been located at `priv` directory on executable's root level. This is how `erlang:load_nif/2` works, not sure if anything could be done about it.

## Usage

```
Usage: cfcheck [<path>] [-d <details>] [-c [<cache>]]
               [--cache_file <cache_file>] [--regex <regex>]
               [--conflicts [<conflicts>]] [--with_tree [<with_tree>]]
               [--with_sec_object [<with_sec_object>]] [-q [<quiet>]]
               [-v [<verbose>]] [-? [<help>]]

  <path>             Path to CouchDB data directory
  -d, --details      Output the details for each file
  -c, --cache        Read the results from a cache [default: false]
  --cache_file       Path to the cache file
  --regex            Filter-in the files to parse with a given regex
  --conflicts        Count conflicts [default: false]
  --with_tree        Analyze b-trees [default: false]
  --with_sec_object  Read and report security object from each shard
                     [default: false]
  -q, --quiet        Output nothing [default: false]
  -v, --verbose      Verbose output [default: false]
  -?, --help         Print help message [default: false]

```

## Output example

Summary output:

```bash
$ cfcheck ~/opt/deimos/ --with_tree --conflicts | jq .
```

Output:
```json
{
  "error": {
    "files_size": 0,
    "files_count": 0
  },
  "view": {
    "tree_stats": {
      "id_tree": {
        "kv_nodes": {
          "max": 7,
          "min": 0
        },
        "kp_nodes": {
          "max": 3,
          "min": 0
        },
        "depth": 2
      }
    },
    "external_size": 8295,
    "active_size": 10692,
    "files_size": 101646,
    "files_count": 24
  },
  "db": {
    "tree_stats": {
      "local_tree": {
        "kv_nodes": {
          "max": 0,
          "min": 0
        },
        "kp_nodes": {
          "max": 0,
          "min": 0
        },
        "depth": 0
      },
      "seq_tree": {
        "kv_nodes": {
          "max": 14,
          "min": 0
        },
        "kp_nodes": {
          "max": 14,
          "min": 0
        },
        "depth": 2
      },
      "id_tree": {
        "kv_nodes": {
          "max": 10,
          "min": 0
        },
        "kp_nodes": {
          "max": 9,
          "min": 0
        },
        "depth": 2
      }
    },
    "disk_version": [
      {
        "files_count": 36,
        "disk_version": 6
      },
      {
        "files_count": 2,
        "disk_version": 5
      }
    ],
    "conflicts": 76,
    "files_count": 36,
    "files_size": 4245909,
    "active_size": 191692,
    "external_size": 142881,
    "doc_count": 54,
    "del_doc_count": 0,
    "doc_info_count": 54,
    "purged_doc_count": 0
  }
}
```

Detailed output. _It can be quite long_

```bash
$ ./cfcheck ~/opt/deimos/ -d --with_tree --with_sec_object --conflicts | jq .
```

Output:
```json
[
  {
    "local_tree": {
      "kv_nodes": {
        "max": 2,
        "min": 2,
        "count": 2
      },
      "kp_nodes": {
        "max": 2,
        "min": 2,
        "count": 1
      },
      "depth": 2
    },
    "seq_tree": {
      "kv_nodes": {
        "max": 0,
        "min": 0,
        "count": 0
      },
      "kp_nodes": {
        "max": 0,
        "min": 0,
        "count": 0
      },
      "depth": 0
    },
    "update_seq": 2,
    "disk_version": 6,
    "fragmentation": "99.05%",
    "external_size": 0,
    "active_size": 1011,
    "file_type": "db",
    "file_size": 106645,
    "file_name": "/home/vagrant/opt/deimos/node3/data/shards/40000000-5fffffff/people.1426074095.couch",
    "purge_seq": 0,
    "compacted_seq": 0,
    "doc_count": 0,
    "del_doc_count": 0,
    "doc_info_count": 0,
    "purged_doc_count": 0,
    "conflicts": 0,
    "security_object": {
      "members": {
        "roles": [
          "spectator",
          "developer"
        ],
        "names": [
          "alice",
          "bob",
          "caren"
        ]
      },
      "admins": {
        "roles": [
          "admin"
        ],
        "names": [
          "root",
          "admin"
        ]
      }
    },
  ...
  {
    "id_tree": {
      "kv_nodes": {
        "max": 3,
        "min": 3,
        "count": 1
      },
      "kp_nodes": {
        "max": 0,
        "min": 0,
        "count": 0
      },
      "depth": 1
    },
    "fragmentation": "83.14%",
    "file_name": "/home/vagrant/opt/deimos/node3/data/.shards/60000000-7fffffff/people.1426074095_design/mrview/5b2daba646cc119813a99922b8971c8d.view",
    "file_size": 4241,
    "file_type": "view",
    "view_signature": "5b2daba646cc119813a99922b8971c8d",
    "update_seq": 5,
    "purge_seq": 0,
    "active_size": 907,
    "external_size": 715
  },
  ...
]
```

## Caching

The script always caches the results of the run in a plain json file. This is done to allow a quick look at the details in case there are something suspicious in the summary.

By default the cache file stored at `/tmp/cfcheck.[$USERNAME].json`. The file suffixed with the user name to avoid permissions clash in case the script ran on the same host by different users. The path to the cache file could be overriden with `--cache_file` option.

## Packaging

Makefile's target `make package` generates debian's binary package for the script. For now it installs the main script in `/usr/bin` and libs in `/usr/lib/cfcheck` with symlink to `/usr/priv` to satisfy erlang nif's search path.

The make target expects [dch](http://man.he.net/man1/dch), [dpkg-deb](http://man.he.net/man1/dpkg-deb) and [fakeroot](http://man.he.net/man1/fakeroot) to be available on a build host.

Makefile's target `make lint-package` lints the built package with [lintian](http://man.he.net/man1/lintian)

cfcheck (1) man page for the script included in */man* directory in markdown and roff formats. If necessary, it could be updated in markdown and rebuilt to roff with makefile's target `make man`. [ronn](https://rtomayko.github.io/ronn/ronn.1.html) is required to be available on a build host.

## License

[Apache 2.0](https://github.com/cloudant/cfcheck/blob/master/LICENSE.txt)
