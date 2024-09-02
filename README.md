# zig-dotslash

Tooling for generating [DotSlash](https://dotslash-cli.com/) files
for Zig compiler versions.

## Context

[dotslash](https://dotslash-cli.com/) is a tool to distribute executables
as lightweight plain text files that are downloaded and cached on first run
by the tool itself.

Read more about it:

- [Motivation](https://dotslash-cli.com/docs/motivation/)
- [Announcement blog post](https://engineering.fb.com/2024/02/26/developer-tools/dotslash-meta-tech-podcast/)

This repository is for experimenting with using DotSlash
to pin the version of Zig used by a project.

## Usage

### Use an existing file

1. Install DotSlash
2. Grab a file for your preferred version from the versions/ folder
   and place it in your project directory.
3. Run it like it's the Zig compiler.

### Generating DotSlash files

1. Install DotSlash.

2. Run the tool with a version specifier or 'master' for the latest nightly.

    ```sh
    ./tools/zig build run -- 0.13.0
    ```

    This will generate a file named `zig-${version}` in the current directory.

3. Run the generated file like it's a Zig compiler executable.

    ```sh
    ./zig-0.13.0 build
    ```

# License

This software is made available under the BSD3 license.
See the license file for more information.
