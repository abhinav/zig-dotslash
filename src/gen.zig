const std = @import("std");

const DOWNLOADS_URL =
    std.Uri.parse("https://ziglang.org/download/index.json") catch unreachable;

const PLATFORMS = .{
    .{ .slug = "linux-aarch64", .os = Os.linux, .arch = Arch.aarch64 },
    .{ .slug = "linux-x86_64", .os = Os.linux, .arch = Arch.x86_64 },
    .{ .slug = "macos-x86_64", .os = Os.macos, .arch = Arch.x86_64 },
    .{ .slug = "macos-aarch64", .os = Os.macos, .arch = Arch.aarch64 },
    .{ .slug = "windows-x86_64", .os = Os.windows, .arch = Arch.x86_64 },
    .{ .slug = "windows-aarch64", .os = Os.windows, .arch = Arch.aarch64 },
};

pub fn main() !void {
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();

    var exit_code: u8 = 0;
    run(allocator.allocator()) catch |err| {
        exit_code = 1;
        switch (err) {
            error.Help => {
                try usage();
                exit_code = 0;
            },
            error.Explained => {}, // explained
            else => return err, // let Zig print a traceback
        }
    };

    std.process.exit(exit_code);
}

fn usage() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\Usage: gen-zig-dotslash <version>
        \\
        \\Generates a DotSlash file for the given Zig version.
        \\<version> may be a release tag (e.g. '0.13.0') or 'master'.
        \\
        \\Options:
        \\
        \\  -o <file>
        \\    Write the output to <file> instead of zig-<version>.
        \\    Use '-' to write to stdout.
        \\  -C <dir>
        \\    Change to <dir> before writing the output.
        \\
    , .{});
}

const Args = struct {
    const Error = error{
        /// Show help and exit with success.
        Help,

        /// Exit with failure, but don't show help.
        Explained,
    } || std.mem.Allocator.Error;

    allocator: std.mem.Allocator,

    version: []const u8,
    output: ?[]const u8, // destination file
    dir: ?[]const u8, // working directory

    pub fn parse(allocator: std.mem.Allocator, args_iter: anytype) Error!Args {
        var version: ?[]const u8 = null;
        var output: ?[]const u8 = null;
        var dir: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return error.Help;
            }

            if (std.mem.eql(u8, arg, "-o")) {
                const value = args_iter.next() orelse {
                    std.log.err("missing argument for option: -o", .{});
                    return error.Explained;
                };

                output = try allocator.dupe(u8, value);
                continue;
            }

            if (std.mem.eql(u8, arg, "-C")) {
                const value = args_iter.next() orelse {
                    std.log.err("missing argument for option: -C", .{});
                    return error.Explained;
                };

                dir = try allocator.dupe(u8, value);
                continue;
            }

            if (version != null) {
                std.log.err("unexpected argument: {s}", .{arg});
                return error.Explained;
            } else {
                version = try allocator.dupe(u8, arg);
            }
        }

        if (version == null) {
            std.log.err("missing required argument: <version>", .{});
            return error.Explained;
        }

        return Args{
            .allocator = allocator,
            .version = version orelse unreachable,
            .output = output,
            .dir = dir,
        };
    }

    pub fn deinit(self: Args) void {
        self.allocator.free(self.version);
        if (self.output) |o|
            self.allocator.free(o);
    }
};

fn run(allocator: std.mem.Allocator) !void {
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // skip the program name

    var args = try Args.parse(allocator, &args_iter);
    defer args.deinit();

    var dir_h: ?std.fs.Dir = null;
    if (args.dir) |dir| {
        const d = try std.fs.cwd().openDir(dir, .{});
        try d.setAsCwd();
        dir_h = d;
    }
    defer if (dir_h) |*d| d.close();

    var is_master = false;
    if (std.mem.eql(u8, args.version, "master")) {
        const latest = try latestMasterVersion(allocator, DOWNLOADS_URL);
        allocator.free(args.version);
        args.version = latest;
        is_master = true;
    }

    std.log.info("Generating DotSlash file for Zig version {s}", .{args.version});

    var platforms = std.json.ObjectMap.init(allocator);
    defer platforms.deinit();
    inline for (PLATFORMS) |platform| {
        try platforms.put(
            platform.slug,
            try createUrlEntry(
                allocator,
                platform.os,
                platform.arch,
                args.version,
                is_master,
            ),
        );
    }

    var package = std.json.ObjectMap.init(allocator);
    defer package.deinit();

    try package.put("name", .{ .string = "zig" });
    try package.put("platforms", .{ .object = platforms });

    // Generate an output file name if not provided.
    const output_file_name = args.output orelse
        try std.fmt.allocPrint(allocator, "zig-{s}", .{args.version});

    const output_file: std.fs.File =
        if (std.mem.eql(u8, output_file_name, "-"))
        std.io.getStdOut()
    else
        try std.fs.cwd().createFile(output_file_name, .{
            .truncate = true,
            .mode = 0o755, // executable
        });
    defer output_file.close();

    var buffered_writer = std.io.bufferedWriter(output_file.writer());
    defer buffered_writer.flush() catch unreachable;
    const out_w = buffered_writer.writer();

    try out_w.writeAll("#!/usr/bin/env dotslash\n");

    try std.json.stringify(
        std.json.Value{ .object = package },
        .{ .whitespace = .indent_2 },
        out_w,
    );

    if (std.mem.eql(u8, output_file_name, "-")) {
        std.log.info("Wrote DotSlash file to stdout", .{});
    } else {
        std.log.info("Wrote DotSlash file: {s}", .{output_file_name});
    }
}

// latestMasterVersion determines the latest master version of Zig
// by querying the Zig downloads page at the given URL.
//
// The caller must free the returned string.
fn latestMasterVersion(allocator: std.mem.Allocator, downloads_url: std.Uri) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var server_header_buffer: [4096]u8 = undefined;
    var request = try client.open(.GET, downloads_url, .{
        .server_header_buffer = &server_header_buffer,
        .headers = .{
            .user_agent = .{ .override = "gen-zig-dotslash" },
        },
    });
    defer request.deinit();

    try request.send();
    try request.wait();

    const res_body = request.reader();
    var json_reader = std.json.reader(allocator, res_body);
    defer json_reader.deinit();

    // The format of the JSON is:
    //
    // {
    //   "master": {
    //     "version": "0.13.0+dev.1234+abcd1234",
    //     ...,
    //  },
    //  "x86_64-linux": {
    //    ...,
    //  },
    //  ...
    // }
    //
    // We only care about master.version.
    try traverseKey(&json_reader, &.{ "master", "version" });

    const token = try json_reader.next();
    if (token != .string) {
        std.log.err("expected string, got: {}", .{token});
        return error.Explained;
    }

    return allocator.dupe(u8, token.string);
}

// traverseKey traverses down a JSON object using the given keys.
// This is equivalent to, json_r[keys[0]][keys[1]][keys[2]]...[keys[n]].
fn traverseKey(scanner: anytype, keys: []const []const u8) !void {
    for (keys) |key| {
        // Ensure we're inside an object.
        const start_tok = try scanner.next();
        if (start_tok != .object_begin) {
            std.log.err("expected object, got: {}", .{start_tok});
            return error.BadJSONOutput;
        }

        // Inside the object, look for the key.
        object_loop: while (true) {
            const token: std.json.Token = try scanner.next();
            if (token != .string) {
                std.log.err("expected string, got: {}", .{token});
                return error.BadJSONOutput;
            }

            if (std.mem.eql(u8, token.string, key)) {
                break :object_loop;
            }

            try scanner.skipValue();
        }
    }
}

const Os = enum { macos, linux, windows };
const Arch = enum { x86_64, aarch64 };

fn createUrlEntry(
    allocator: std.mem.Allocator,
    os: Os,
    arch: Arch,
    version: []const u8,
    is_master: bool,
) !std.json.Value {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    {
        const url_w = buffer.writer();
        if (is_master) {
            try url_w.print(
                "https://ziglang.org/builds/zig-{s}-{s}-{s}.",
                .{ @tagName(os), @tagName(arch), version },
            );
        } else {
            try url_w.print(
                "https://ziglang.org/download/{s}/zig-{s}-{s}-{s}.",
                .{ version, @tagName(os), @tagName(arch), version },
            );
        }
        if (os == Os.windows) {
            try url_w.writeAll("zip");
        } else {
            try url_w.writeAll("tar.xz");
        }
    }
    const zig_url = try buffer.toOwnedSlice();

    var child = std.process.Child.init(&.{
        "dotslash", "--", "create-url-entry", zig_url,
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const stdout = child.stdout.?.reader();
    var json_reader = std.json.reader(allocator, stdout);
    defer json_reader.deinit();

    var value = try std.json.parseFromTokenSourceLeaky(
        std.json.Value,
        allocator,
        &json_reader,
        .{},
    );

    buffer.clearRetainingCapacity();
    {
        const path_w = buffer.writer();
        try path_w.print(
            "zig-{s}-{s}-{s}/zig",
            .{ @tagName(os), @tagName(arch), version },
        );
        if (os == Os.windows) {
            try path_w.writeAll(".exe");
        }
    }
    const path = try buffer.toOwnedSlice();

    // Add mirrors as providers.
    //   https://pkg.machengine.org/zig/zig-{os}-{arch}-{version}.{tar.xz,zip}
    var machMirror = std.json.ObjectMap.init(allocator);
    buffer.clearRetainingCapacity();
    {
        const url_w = buffer.writer();
        try url_w.print(
            "https://pkg.machengine.org/zig/zig-{s}-{s}-{s}.",
            .{ @tagName(os), @tagName(arch), version },
        );
        if (os == Os.windows) {
            try url_w.writeAll("zip");
        } else {
            try url_w.writeAll("tar.xz");
        }
    }
    const mach_url = try buffer.toOwnedSlice();
    try machMirror.put("url", .{ .string = mach_url });

    switch (value) {
        .object => |*obj| {
            try obj.put("path", .{ .string = path });

            if (obj.getPtr("providers")) |providers| {
                try providers.array.insert(0, .{ .object = machMirror });
            }
        },
        else => {
            return error.BadJSONOutput;
        },
    }

    return value;
}
