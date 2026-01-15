const std = @import("std");
const builtin = @import("builtin");

const Status = enum {
    ok,
    fail,
    skip,
    leak,
    text,

    fn color(self: @This()) std.io.tty.Color {
        return switch (self) {
            .ok => .green,
            .fail => .red,
            .leak => .yellow,
            .skip => .cyan,
            else => .reset,
        };
    }
};

const Printer = struct {
    __buffer: [1024]u8 = undefined,
    __writer: std.fs.File.Writer = undefined,
    __stream: *std.Io.Writer = undefined,
    __tty_conf: std.io.tty.Config = .escape_codes,

    fn init(self: *@This()) void {
        self.setWriter(std.fs.File.stdout().writer(self.ptrBuffer()));
        self.setStream(&self.ptrWriter().interface);
    }

    fn ptrBuffer(self: *@This()) *[1024]u8 {
        return &self.__buffer;
    }

    fn ptrWriter(self: *@This()) *std.fs.File.Writer {
        return &self.__writer;
    }

    fn setWriter(self: *@This(), writer: std.fs.File.Writer) void {
        self.ptrWriter().* = writer;
    }

    fn ptrStream(self: *@This()) *std.Io.Writer {
        return self.__stream;
    }

    fn setStream(self: *@This(), stream: *std.Io.Writer) void {
        self.__stream = stream;
    }

    fn getTTYConf(self: @This()) std.io.tty.Config {
        return self.__tty_conf;
    }

    fn print(self: *@This(), status: Status, comptime format: []const u8, args: anytype) !void {
        try self.getTTYConf().setColor(self.ptrStream(), status.color());
        try self.ptrStream().print(format ++ "\n", args);
        try self.getTTYConf().setColor(self.ptrStream(), .reset);
        try self.ptrStream().flush();
    }
};

pub const panic = @import("recover").panic;

pub fn main() !void {
    var printer: Printer = .{};
    printer.init();

    var ok: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    for (builtin.test_functions) |func| {
        std.testing.allocator_instance = .{};
        var status: Status = .ok;

        const result = func.func();

        if (std.testing.allocator_instance.deinit() == .leak) {
            status = .leak;
            leak += 1;
        } else if (result) |_| {
            ok += 1;
        } else |err| {
            switch (err) {
                error.SkipZigTest => {
                    status = .skip;
                    skip += 1;
                },
                else => {
                    status = .fail;
                    fail += 1;
                    try printer.print(status, "[{s}: {s}] \"{s}\"\n", .{
                        @tagName(status), @errorName(err), func.name,
                    });
                    if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
                    continue;
                },
            }
        }
        try printer.print(status, "[{s}] \"{s}\"", .{
            @tagName(status), func.name,
        });
    }

    const total = ok + fail + skip + leak;
    try printer.print(.text, "*" ** 80 ++ "\nFor {d} test{s}:", .{
        total, if (total > 1) "s" else "",
    });
    try printer.print(.ok, "- {d} test{s} succeded", .{
        ok, if (ok > 1) "s" else "",
    });
    try printer.print(.fail, "- {d} test{s} failed", .{
        fail, if (fail > 1) "s" else "",
    });
    try printer.print(.leak, "- {d} test{s} leaked", .{
        leak, if (leak > 1) "s" else "",
    });
    try printer.print(.skip, "- {d} test{s} skipped", .{
        skip, if (skip > 1) "s" else "",
    });
    try printer.print(.text, "*" ** 80, .{});
}
