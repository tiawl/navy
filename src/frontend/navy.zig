const std = @import("std");

const build_options = @import("build_options");
const backend = @import("backend");

const index = @import("index.zig");

const options = index.options;
const Options = options.Options;
const ArgIterator = options.ArgIterator;

var singleton: ?Navy = null;

pub fn isInit() bool {
    return singleton != null;
}

pub fn init(allocator: std.mem.Allocator, args: *ArgIterator) !void {
    if (!isInit()) {
        singleton = undefined;
        try singleton.?.init(allocator, args);
    }
}

pub fn deinit() void {
    if (singleton) |*navy| navy.deinit();
    singleton = null;
}

pub fn instance() *Navy {
    return if (singleton) |*navy| navy else unreachable;
}

const Navy = struct {
    __allocator: std.mem.Allocator,
    __opts: Options,

    fn init(self: *@This(), allocator: std.mem.Allocator, args: *ArgIterator) !void {
        self.* = .{
            .__allocator = allocator,
            .__opts = undefined,
        };

        self.setOpts(try Options.init(allocator));
        errdefer self.ptrOpts().deinit();

        try self.ptrOpts().parse(args);
    }

    fn deinit(self: *@This()) void {
        self.ptrOpts().deinit();
        backend.deinit();
    }

    fn getAllocator(self: @This()) std.mem.Allocator {
        return self.__allocator;
    }

    fn getOpts(self: @This()) Options {
        return self.__opts;
    }

    fn ptrOpts(self: *@This()) *Options {
        return &self.__opts;
    }

    fn setOpts(self: *@This(), opts: Options) void {
        self.ptrOpts().* = opts;
    }

    fn help() void {
        std.debug.print("TODO\n", .{});
    }

    fn version() void {
        std.debug.print("TODO %s\n", .{
            build_options.version,
        });
    }

    pub fn run(self: *@This()) !void {
        try backend.init(self.getAllocator());
        errdefer backend.deinit();

        std.debug.print("TODO\n", .{});
    }
};
