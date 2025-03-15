const external_dir_name = "external";

const actions = [_]FullAction{
    // jemalloc
    .{
        .nix = "jemalloc",
        .nix_path = "result",
        .action = .copy_file,
        .paths = .{
            .in = &.{ "result", "lib", "libjemalloc.so.2" },
            .out = &.{ external_dir_name, "jemalloc", "libjemalloc.so.2" },
        },
    },
    .{
        .nix = "jemalloc",
        .nix_path = "result",
        .action = .sym_link,
        .paths = .{
            .in = &.{ external_dir_name, "jemalloc", "libjemalloc.so" },
            .out = &.{"libjemalloc.so.2"},
        },
    },
    .{
        .nix = "jemalloc",
        .nix_path = "result",
        .action = .copy_dir,
        .paths = .{
            .in = &.{ "result", "include", "jemalloc" },
            .out = &.{ external_dir_name, "jemalloc", "include" },
        },
    },

    // mimalloc
    .{
        .nix = "mimalloc",
        .nix_path = "result",
        .action = .copy_file,
        .paths = .{
            .in = &.{ "result", "lib", "libmimalloc.a" },
            .out = &.{ external_dir_name, "mimalloc", "libmimalloc.a" },
        },
    },
    .{
        .nix = "mimalloc-dev",
        .nix_path = "result-dev",
        .action = .copy_dir,
        .paths = .{
            .in = &.{ "result-dev", "include" },
            .out = &.{ external_dir_name, "mimalloc", "include" },
        },
    },
};

const Action = enum {
    copy_file,
    copy_dir,
    sym_link,

    pub fn apply(action: Action, paths: Paths, alloc: Allocator) !void {
        const cwd = fs.cwd();

        switch (action) {
            .copy_dir => {
                const in_path = try fs.path.joinZ(alloc, paths.in);
                defer alloc.free(in_path);

                var in = try cwd.openDir(in_path, .{ .iterate = true });
                defer in.close();

                const out_path = try fs.path.joinZ(alloc, paths.out);
                defer alloc.free(out_path);

                var out = try cwd.makeOpenPath(out_path, .{ .iterate = true });
                defer out.close();

                try copyDir(in, out);
            },
            .copy_file => {
                const in_path = try fs.path.joinZ(alloc, paths.in);
                defer alloc.free(in_path);

                const out_path = try fs.path.joinZ(alloc, paths.out);
                defer alloc.free(out_path);

                var out_dir = try cwd.makeOpenPath(fs.path.dirname(out_path) orelse ".", .{});
                defer out_dir.close();

                try cwd.copyFile(in_path, out_dir, fs.path.basename(out_path), .{});
            },
            .sym_link => {
                const link_path = try fs.path.joinZ(alloc, paths.in);
                defer alloc.free(link_path);

                const target_path = try fs.path.joinZ(alloc, paths.out);
                defer alloc.free(target_path);

                try cwd.symLinkZ(target_path, link_path, .{});
            },
        }
    }
};

const Paths = struct {
    in: []const []const u8,
    out: []const []const u8,
};

const FullAction = struct {
    nix: []const u8,
    nix_path: []const u8,
    action: Action,
    paths: Paths,
};

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    // Check if nix is in path
    {
        const ret = try Child.run(.{
            .allocator = alloc,
            .argv = &.{ "nix", "flake", "info" },
        });
        defer alloc.free(ret.stderr);
        defer alloc.free(ret.stdout);

        if (ret.term != .Exited or ret.term.Exited != 0) {
            std.log.debug("stdout: \n{s}\n\n", .{ret.stdout});
            std.log.debug("stderr: \n{s}\n\n", .{ret.stderr});

            std.log.err("Could not find nix in path", .{});
            return;
        }
    }

    const cwd = fs.cwd();

    blk: {
        cwd.accessZ(external_dir_name, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk,
            else => return err,
        };
        cwd.deleteTree(external_dir_name ++ ".old") catch {};
        try cwd.renameZ(external_dir_name, external_dir_name ++ ".old");
    }

    inline for (actions) |elem| {
        std.log.info("Installing {s}", .{elem.paths.out});

        // Do the nix build
        {
            const ret = try Child.run(.{
                .allocator = alloc,
                .argv = &.{ "nix", "build", ".#" ++ elem.nix },
            });
            defer alloc.free(ret.stderr);
            defer alloc.free(ret.stdout);

            if (ret.term != .Exited or ret.term.Exited != 0) {
                std.log.debug("stdout: \n{s}\n\n", .{ret.stdout});
                std.log.debug("stderr: \n{s}\n\n", .{ret.stderr});

                std.log.err("Failed to install {s}", .{elem.nix});
                return;
            }
        }

        try elem.action.apply(elem.paths, alloc);

        // // Copy the result
        // const inPath = try std.fs.path.joinZ(alloc, elem.path);
        // defer alloc.free(inPath);
        // var inDir = if (elem.is_dir)
        //     try cwd.makeOpenPath(inPath, .{ .iterate = true })
        // else
        //     try cwd.makeOpenPath(fs.path.dirname(inPath) orelse "", .{});
        //
        // const outPath = try std.fs.path.joinZ(alloc, elem.dir);
        // var outDir = try cwd.makeOpenPath(outPath, .{});
        // defer outDir.close();
        //
        // if (elem.is_dir) {
        //     try copyDir(inDir, outDir);
        // } else {
        //     const file_name = fs.path.basename(inPath);
        //     try inDir.copyFile(file_name, outDir, file_name, .{});
        // }

        try cwd.deleteTree(elem.nix_path);
    }

    std.log.info("Success", .{});
}

fn copyDir(src: Dir, dest: Dir) !void {
    var iter = src.iterate();
    while (try iter.next()) |entry| switch (entry.kind) {
        .file => try src.copyFile(entry.name, dest, entry.name, .{}),

        .directory => {
            var inner_src = try src.openDir(entry.name, .{ .iterate = true });
            defer inner_src.close();

            var inner_dest = try dest.makeOpenPath(entry.name, .{ .iterate = true });
            defer inner_dest.close();

            try copyDir(inner_src, inner_dest);
        },

        .sym_link => {
            const stat = try src.statFile(entry.name);
            switch (stat.kind) {
                .file => try src.copyFile(entry.name, dest, entry.name, .{}),

                .directory => {
                    var inner_src = try src.openDir(entry.name, .{ .iterate = true });
                    defer inner_src.close();

                    var inner_dest = try dest.makeOpenPath(entry.name, .{ .iterate = true });
                    defer inner_dest.close();

                    try copyDir(inner_src, inner_dest);
                },

                .sym_link,
                .block_device,
                .character_device,
                .named_pipe,
                .unix_domain_socket,
                .whiteout,
                .door,
                .event_port,
                .unknown,
                => unreachable,
            }
        },

        .block_device,
        .character_device,
        .named_pipe,
        .unix_domain_socket,
        .whiteout,
        .door,
        .event_port,
        .unknown,
        => unreachable,
    };
}

const std = @import("std");
const fs = std.fs;

const Dir = fs.Dir;
const Child = std.process.Child;
const Allocator = std.mem.Allocator;
