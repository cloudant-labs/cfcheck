cfcheck(1) -- Gather statistics on CouchDB files
=============================================

## SYNOPSIS

`cfcheck` <path> [<opt>...]

## DESCRIPTION

**CFCheck** is a tool to analyze CouchDB 2.0 database and view files. It recursively scans provided path to CouchDB installation, collects all the files with `.couch` and `.view` extention and then reads each of them, locating and parsing latest header and optionally walking the b-trees. To speed the things up cfcheck spawns a process per file and then aggregates the results. It does not depends on CouchDB to be up and running.

The tool uses JSON to output the information for possible post-processing.

## FILES

The `cfcheck` command expects input to be a complete path to data directory
of CouchDB.

## OPTIONS

These options control what kind of statistics the utility gathers and output.

  * `-d`, `--details`:
    Output the details for each file.

  * `-c`, `--cache`:
    Read the results from a cache.

  * `--cache_file`:
    Path to the cache file

  * `--regex`:
    Filter-in the files to parse with a given regex

  * `--conflicts`:
    Count conflicts

  * `--with_tree`:
    Analyze b-trees

  * `--with_sec_object`:
    Read and report security object from each shard

  * `-q`, `--quiet`:
    Output nothing

  * `-v`, `--verbose`:
    Verbose output

  * `-?`, `--help`
    Print help message

## EXAMPLES

Parse all the files including stats on b-trees and documents conflicts.

    $ cfcheck ~/opt/deimos/ --with_tree --conflicts

## COPYRIGHT

Copyright IBM Corp. 2017

## SEE ALSO

couchdb(1)
