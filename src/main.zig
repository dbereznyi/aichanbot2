const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const print = std.debug.print;

const DYNAMIC_CMDS_FILENAME = "dynamic_cmds.ini";
var dynamic_cmds: Ini = undefined;

const ConfigError = error {
    NoConfigFile,
    MissingNick,
    MissingPass,
    MissingChannel,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var config = try readIniFile(alloc, "config.ini") catch |err| blk: {
        if (err == std.fs.File.OpenError.FileNotFound) {
            print("No configuration file found. Modify config.ini_example and rename it to config.ini.\n", .{});
            break :blk ConfigError.NoConfigFile;
        }
        return;
    };
    defer config.free();

    dynamic_cmds = readIniFile(alloc, DYNAMIC_CMDS_FILENAME) catch |err| blk: {
        if (err == std.fs.File.OpenError.FileNotFound) {
            try std.fs.cwd().writeFile(DYNAMIC_CMDS_FILENAME, &([_]u8{}));
            break :blk try readIniFile(alloc, DYNAMIC_CMDS_FILENAME);
        }
        return;
    };
    defer dynamic_cmds.free();

    const nick = config.map.get("nick") orelse return ConfigError.MissingNick;
    const pass = config.map.get("pass") orelse return ConfigError.MissingPass;
    const channel = config.map.get("channel") orelse return ConfigError.MissingChannel;

    var irc = try Irc.init(alloc);
    defer irc.deinit();

    try irc.registerHandler(Irc.Handler {
        .match = matchPing,
        .handle = handlePing,
    });

    try irc.registerHandler(Irc.Handler {
        .match = matchPrivmsg,
        .handle = handlePrivmsg,
    });

    try irc.connect("irc.chat.twitch.tv", 6667);
    try irc.send("CAP REQ :twitch.tv/tags\n", .{});
    try irc.authenticate(nick, pass);
    try irc.join(channel);
    try irc.run();
}

const BotCommandEntry = struct {
    name: []const u8,
    aliases: []const []const u8,
    handler: fn (irc: *Irc, msg: *const TwitchMessage) anyerror!void,
};
const BOT_COMMANDS = [_]BotCommandEntry{
    .{ 
        .name = "hi", 
        .aliases = &([_][]const u8{}), 
        .handler = cmdHi, 
    },
    .{
        .name = "cmds",
        .aliases = &([_][]const u8{ "commands", "list" }),
        .handler = cmdCmds,
    },
    .{
        .name = "add",
        .aliases = &([_][]const u8{}),
        .handler = cmdAdd,
    },
    .{
        .name = "remove",
        .aliases = &([_][]const u8{}),
        .handler = cmdRemove,
    },
};

fn cmdHi(irc: *Irc, msg: *const TwitchMessage) !void {
    try irc.send("PRIVMSG {s} :Hi @{s}!\n", .{msg.command.channel, msg.source.?.nick});
}

fn cmdCmds(irc: *Irc, msg: *const TwitchMessage) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(irc.alloc);
    defer arena_allocator.deinit();
    const alloc = arena_allocator.allocator();

    var cmd_name_list = std.ArrayList([]const u8).init(alloc);

    for (BOT_COMMANDS) |cmd| {
        var name_buf = try alloc.alloc(u8, cmd.name.len + 1);
        const name = try std.fmt.bufPrint(name_buf, "!{s}", .{cmd.name});
        try cmd_name_list.append(name);
    }

    var dyn_cmds = dynamic_cmds.map.iterator();
    while (dyn_cmds.next()) |dyn_cmd| {
        var name_buf = try alloc.alloc(u8, dyn_cmd.value_ptr.*.len + 1);
        const name = try std.fmt.bufPrint(name_buf, "!{s}", .{dyn_cmd.key_ptr.*});
        try cmd_name_list.append(name);
    }

    const cmp_str_asc = struct {
        fn f(context: void, x: []const u8, y: []const u8) bool {
            _ = context;
            return std.mem.lessThan(u8, x, y);
        }
    }.f;

    std.sort.sort([]const u8, cmd_name_list.items, {}, cmp_str_asc);

    const reply = try std.mem.join(alloc, ", ", cmd_name_list.items);

    try irc.send("PRIVMSG {s} :@{s} Available commands: {s}\n",
        .{msg.command.channel, msg.source.?.nick, reply});
}

fn cmdAdd(irc: *Irc, msg: *const TwitchMessage) !void {
    if (msg.source == null) {
        return;
    }
    if (msg.bot_command == null) {
        return;
    }
    if (msg.permissions == TwitchMessage.Permissions.none) {
        return;
    }
    var args = msg.bot_command.?.args;
    if (args.len < 2) {
        return;
    }
    try dynamic_cmds.put_new(args[0], args[1]);
    try writeIniFile(irc.alloc, DYNAMIC_CMDS_FILENAME, &dynamic_cmds);
    try irc.send("PRIVMSG {s} :@{s} Added command !{s}\n",
        .{msg.command.channel, msg.source.?.nick, args[0]});
}

fn cmdRemove(irc: *Irc, msg: *const TwitchMessage) !void {
    if (msg.source == null) {
        return;
    }
    if (msg.bot_command == null) {
        return;
    }
    if (msg.permissions == TwitchMessage.Permissions.none) {
        return;
    }
    const args = msg.bot_command.?.args;
    if (args.len == 0) {
        return;
    }
    const removed = dynamic_cmds.map.remove(args[0]);
    if (!removed) {
        return;
    }
    try writeIniFile(irc.alloc, DYNAMIC_CMDS_FILENAME, &dynamic_cmds);
    try irc.send("PRIVMSG {s} :@{s} Removed command !{s}\n",
        .{msg.command.channel, msg.source.?.nick, args[0]});
}

fn matchPrivmsg(msg: *const TwitchMessage) bool {
    return std.mem.eql(u8, msg.command.command, "PRIVMSG");
}

fn handlePrivmsg(irc: *Irc, msg: *const TwitchMessage) !void {
    if (msg.source == null) {
        return;
    }
    if (msg.bot_command == null) {
        return;
    }
    const cmd_name = msg.bot_command.?.name;
    outer: for (BOT_COMMANDS) |cmd| {
        if (std.mem.eql(u8, cmd_name, cmd.name)) {
            try cmd.handler(irc, msg);
            break;
        }
        for (cmd.aliases) |alias| {
            if (std.mem.eql(u8, cmd_name, alias)) {
                try cmd.handler(irc, msg);
                break :outer;
            }
        }
        var dyn_cmds = dynamic_cmds.map.iterator();
        while (dyn_cmds.next()) |dyn_cmd| {
            if (std.mem.eql(u8, cmd_name, dyn_cmd.key_ptr.*)) {
                try irc.send("PRIVMSG {s} :{s}\n", .{msg.command.channel, dyn_cmd.value_ptr.*});
                break :outer;
            }
        }
    }
}

fn matchPing(msg: *const TwitchMessage) bool {
    return std.mem.eql(u8, msg.command.command, "PING");
}

fn handlePing(irc: *Irc, msg: *const TwitchMessage) !void {
    try irc.send("PONG :{s}\n", .{msg.parameters});
}

const Parser = struct {
    buf: []const u8,
    i: usize,

    pub fn init(buf: []const u8) Parser {
        return Parser {
            .buf = buf,
            .i = 0,
        };
    }

    pub fn byte(self: *Parser, b: u8) ?u8 {
        if (self.i >= self.buf.len) {
            return null;
        }
        var ret: ?u8 = null;
        if (self.buf[self.i] == b) {
            ret = b;
            self.i += 1;
        }
        return ret;
    }

    pub fn peekByte(self: *Parser, b: u8) ?u8 {
        if (self.i >= self.buf.len) {
            return null;
        }
        var ret: ?u8 = null;
        if (self.buf[self.i] == b) {
            ret = b;
        }
        return ret;
    }

    pub fn untilByte(self: *Parser, b: u8) ?[]const u8 {
        if (self.i >= self.buf.len) {
            return null;
        }
        const start = self.i;
        var found = false;
        while (self.i < self.buf.len) {
            if (self.buf[self.i] == b) {
                found = true;
                break;
            }
            self.i += 1;
        }
        if (!found) {
            self.i = start;
            return null;
        }
        const s = self.buf[start..self.i];
        self.i += 1;
        return s;
    }

    pub fn surroundedBy(self: *Parser, b: u8) ?[]const u8 {
        if (self.i >= self.buf.len) {
            return null;
        }
        if (self.buf[self.i] != b) {
            return null;
        }
        self.i += 1;
        const start = self.i;
        while (self.i < self.buf.len and self.buf[self.i] != b) {
            self.i += 1;
        }
        if (self.i == self.buf.len) {
            return self.buf[start..];
        }
        const s = self.buf[start..self.i];
        self.i += 2;
        return s;
    }

    pub fn separatedBy(self: *Parser, alloc: Allocator, b: u8, end_byte: u8) [][]const u8 {
        var entries = std.ArrayList([]const u8).init(alloc);
        while (true) {
            const entry = self.untilByte(b) orelse break;
            entries.append(entry) catch return entries.toOwnedSlice();
        }
        const last = self.untilByte(end_byte);
        if (last != null) {
            entries.append(last.?) catch return entries.toOwnedSlice();
        }
        return entries.toOwnedSlice();
    }

    pub fn toEnd(self: *Parser) ?[]const u8 {
        if (self.i >= self.buf.len) {
            return null;
        }
        const start = self.i;
        self.i = self.buf.len;
        return self.buf[start..];
    }
};

const BotCommand = struct {
    alloc: Allocator,
    name: []const u8,
    args: [][]const u8,

    pub fn free(self: *BotCommand) void {
        self.alloc.free(self.args);
    }
};

test "bot command no args" {
    const cmd_string = "!mycommand";
    const alloc = std.testing.allocator;
    var cmd = parseBotCommand(alloc, cmd_string);
    defer cmd.?.free();
    try std.testing.expect(std.mem.eql(u8, cmd.?.name, "mycommand")); 
    try std.testing.expect(cmd.?.args.len == 0); 
}

test "bot command args" {
    const cmd_string = "!mycommand arg1 arg2 arg3";
    const alloc = std.testing.allocator;
    var cmd = parseBotCommand(alloc, cmd_string);
    defer cmd.?.free();
    try std.testing.expect(std.mem.eql(u8, cmd.?.name, "mycommand")); 
    try std.testing.expect(std.mem.eql(u8, cmd.?.args[0], "arg1")); 
    try std.testing.expect(std.mem.eql(u8, cmd.?.args[1], "arg2")); 
    try std.testing.expect(std.mem.eql(u8, cmd.?.args[2], "arg3")); 
}

test "bot command double quotes" {
    const cmd_string = "!mycommand arg1 \"arg2 with spaces\" arg3";
    const alloc = std.testing.allocator;
    var cmd = parseBotCommand(alloc, cmd_string);
    defer cmd.?.free();
    try std.testing.expect(std.mem.eql(u8, cmd.?.name, "mycommand")); 
    try std.testing.expect(std.mem.eql(u8, cmd.?.args[0], "arg1")); 
    try std.testing.expect(std.mem.eql(u8, cmd.?.args[1], "arg2 with spaces")); 
    try std.testing.expect(std.mem.eql(u8, cmd.?.args[2], "arg3")); 
}

fn parseBotCommand(alloc: Allocator, msg: []const u8) ?BotCommand {
    var p = Parser.init(msg);

    _ = p.byte('!') orelse return null;
    const name = p.untilByte(' ') orelse p.toEnd() orelse return null;

    var args = std.ArrayList([]const u8).init(alloc);
    while (true) {
        const arg = p.surroundedBy('"') orelse p.untilByte(' ') orelse p.toEnd() orelse break;
        args.append(arg) catch |err| {
            print("Failed to append argument to ArrayList: {}\n", .{err});
            return null;
        };
    }

    return BotCommand {
        .alloc = alloc,
        .name = name,
        .args = args.toOwnedSlice(),
    };
}

test "parse twitch message no tags no nick" {
    const msg = ":tmi.twitch.tv 001 mybotname :Welcome, GLHF!";
    var twitch_msg = parseTwitchMessage(std.testing.allocator, msg);
    defer twitch_msg.?.free();
    try std.testing.expect(twitch_msg.?.source.?.nick == null);
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.source.?.host, "tmi.twitch.tv"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.command.command, "001"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.command.channel.?, "mybotname"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.parameters.?, "Welcome, GLHF!"));
}

test "parse twitch message bot command add" {
    const msg = ":username123!username123@tmi.twitch.tv PRIVMSG #channelname :!add test \"This is my test command\"";
    var twitch_msg = parseTwitchMessage(std.testing.allocator, msg);
    defer twitch_msg.?.free();
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.source.?.nick.?, "username123"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.source.?.host, "username123@tmi.twitch.tv"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.command.command, "PRIVMSG"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.command.channel.?, "#channelname"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.parameters.?, "!add test \"This is my test command\""));
    const bot_cmd = twitch_msg.?.bot_command;
    try std.testing.expect(std.mem.eql(u8, bot_cmd.?.name, "add"));
    try std.testing.expect(std.mem.eql(u8, bot_cmd.?.args[0], "test"));
    try std.testing.expect(std.mem.eql(u8, bot_cmd.?.args[1], "This is my test command"));
}

test "parse twitch message with tags" {
    const msg = "@badges=staff/1,broadcaster/1,turbo/1;color=#FF0000;display-name=PetsgomOO;emote-only=1;emotes=33:0-7;flags=0-7:A.6/P.6,25-36:A.1/I.2;id=c285c9ed-8b1b-4702-ae1c-c64d76cc74ef;mod=0;room-id=81046256;subscriber=0;turbo=0;tmi-sent-ts=1550868292494;user-id=81046256;user-type=staff :petsgomoo!petsgomoo@petsgomoo.tmi.twitch.tv PRIVMSG #petsgomoo :DansGame";
    var twitch_msg = parseTwitchMessage(std.testing.allocator, msg);
    defer twitch_msg.?.free();
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.source.?.nick.?, "petsgomoo"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.source.?.host, "petsgomoo@petsgomoo.tmi.twitch.tv"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.command.command, "PRIVMSG"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.command.channel.?, "#petsgomoo"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.parameters.?, "DansGame"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("badges") orelse "", "staff/1,broadcaster/1,turbo/1"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("color") orelse "", "#FF0000"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("display-name") orelse "", "PetsgomOO"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("emote-only") orelse "", "1"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("emotes") orelse "", "33:0-7"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("flags") orelse "", "0-7:A.6/P.6,25-36:A.1/I.2"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("id") orelse "", "c285c9ed-8b1b-4702-ae1c-c64d76cc74ef"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("mod") orelse "", "0"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("room-id") orelse "", "81046256"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("subscriber") orelse "", "0"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("turbo") orelse "", "0"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("tmi-sent-ts") orelse "", "1550868292494"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("user-id") orelse "", "81046256"));
    try std.testing.expect(std.mem.eql(u8, twitch_msg.?.tags.?.get("user-type") orelse "", "staff"));
}

const TwitchMessage = struct {
    const Permissions = enum {
        none,
        moderator,
        broadcaster,
    };
    const Command = struct {
        command: []const u8,
        channel: ?[]const u8,
    };
    const Source = struct {
        nick: ?[]const u8,
        host: []const u8,
    };

    alloc: Allocator,

    tags: ?std.StringHashMap([]const u8),
    permissions: Permissions,
    source: ?Source,
    command: Command,
    parameters: ?[]const u8,
    bot_command: ?BotCommand,

    pub fn free(self: *TwitchMessage) void {
        if (self.bot_command != null) { 
            self.bot_command.?.free();
        }
        if (self.tags != null) {
            self.tags.?.deinit();
        }
    }
};

fn printTwitchMessage(msg: TwitchMessage) void {
    print("tags = {s}\n", .{msg.tags});
    if (msg.source != null) {
        print("nick = {s}, host = {s}\n", .{msg.source.?.nick, msg.source.?.host});
    } else {
        print("no source\n", .{});
    }
    print("command = {s}, channel = {s}\n", .{msg.command.command, msg.command.channel});
    print("parameters = {s}\n", .{msg.parameters});
    print("\n", .{});
}

fn parseTwitchMessage(alloc: Allocator, msg: []const u8) ?TwitchMessage {
    var p = Parser.init(msg);

    const tags = parseTags: {
        _ = p.byte('@') orelse break :parseTags null;
        var entries = p.separatedBy(alloc, ';', ' ');
        defer alloc.free(entries);
        var map = std.StringHashMap([]const u8).init(alloc);
        for (entries) |entry| {
            const sep_ix = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
            map.put(entry[0..sep_ix], entry[sep_ix+1..]) catch return null;
        }

        break :parseTags map;
    };
    
    var permissions = parsePermissions: {
        if (tags == null) {
            break :parsePermissions TwitchMessage.Permissions.none;
        }
        const badges = tags.?.get("badges")
            orelse break :parsePermissions TwitchMessage.Permissions.none;
        if (std.mem.indexOf(u8, badges, "broadcaster") != null) {
            break :parsePermissions TwitchMessage.Permissions.broadcaster;
        }
        if (std.mem.indexOf(u8, badges, "moderator") != null) {
            break :parsePermissions TwitchMessage.Permissions.moderator;
        }
        break :parsePermissions TwitchMessage.Permissions.none;
    };

    const source = parseSource: {
        _ = p.byte(':') orelse break :parseSource null;
        const src = p.untilByte(' ') orelse return null;
        const separator_ix = std.mem.indexOfScalar(u8, src, '!');
        if (separator_ix == null) {
            break :parseSource TwitchMessage.Source {
                .nick = null,
                .host = src,
            };
        } else {
            break :parseSource TwitchMessage.Source {
                .nick = src[0..separator_ix.?],
                .host = src[separator_ix.?+1..],
            };
        }
    };

    const command = parseCommand: {
        const command = p.untilByte(' ') orelse return null;    

        var channel: ?[]const u8 = null;
        if (p.peekByte(':') == null) {
            channel = p.untilByte(' ');
        }

        break :parseCommand TwitchMessage.Command {
            .command = command,
            .channel = channel,
        };
    };

    const parameters = parseParameters: {
        _ = p.byte(':') orelse break :parseParameters null;
        break :parseParameters p.toEnd();
    };

    const bot_command = if (parameters != null) parseBotCommand(alloc, parameters.?) else null;

    return TwitchMessage {
        .alloc = alloc,
        .tags = tags,
        .permissions = permissions,
        .source = source,
        .command = command,
        .parameters = parameters,
        .bot_command = bot_command,
    };
}

const Irc = struct {
    const Handler = struct {
        match: fn (msg: *const TwitchMessage) bool,
        handle: fn (irc: *Irc, msg: *const TwitchMessage) anyerror!void,
    };

    alloc: Allocator,
    stream: std.net.Stream,
    write_buf: []u8,
    read_buf: []u8,
    handlers: std.ArrayList(Irc.Handler),
    message_buf: std.ArrayList([]const u8),
    channel_name: []const u8,

    pub fn init(alloc: Allocator) !Irc {
        var write_buf = try alloc.alloc(u8, 4*1024);
        var read_buf = try alloc.alloc(u8, 4*1024);

        return Irc {
            .alloc = alloc,
            .stream = undefined,
            .write_buf = write_buf,
            .read_buf = read_buf,
            .handlers = std.ArrayList(Irc.Handler).init(alloc),
            .message_buf = try std.ArrayList([]const u8).initCapacity(alloc, 100),
            .channel_name = undefined,
        };
    }

    pub fn deinit(self: *Irc) void {
        self.stream.close();
        self.alloc.free(self.write_buf);
        self.alloc.free(self.read_buf);
        self.handlers.clearAndFree();
        self.message_buf.clearAndFree();
    }

    pub fn registerHandler(self: *Irc, handler: Irc.Handler) !void {
        try self.handlers.append(handler);
    }

    pub fn connect(self: *Irc, hostname: []const u8, port: u16) !void {
        self.stream = try std.net.tcpConnectToHost(self.alloc, hostname, port);
    }

    pub fn run(self: *Irc) !void {
        while (true) {
            const len = try self.read();
            
            self.message_buf.clearRetainingCapacity();
            var i: usize = 0;
            while (i < len) {
                const start = i;
                for (self.read_buf[i..]) |byte| {
                    if (byte == '\r') {
                        try self.message_buf.append(self.read_buf[start..i]);
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            }

            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const alloc = arena.allocator();

            for (self.message_buf.items) |msg| {
                var twitch_msg = parseTwitchMessage(alloc, msg) orelse {
                    print("Failed to parse message: {s}\n", .{msg});
                    break;
                };
                for (self.handlers.items) |handler| {
                    if (handler.match(&twitch_msg)) {
                        handler.handle(self, &twitch_msg) catch |err| {
                            print("Handler failed with: {s}\n", .{err});
                        };
                    }
                }
            }
        }
    }

    pub fn authenticate(self: *Irc, nick: []const u8, pass: []const u8) !void {
        try self.sendPass("PASS {s}\n", .{pass});
        try self.send("NICK {s}\n", .{nick});
    }

    pub fn join(self: *Irc, channel_name: []const u8) !void {
        try self.send("JOIN {s}\n", .{channel_name});
        self.channel_name = channel_name;
    }

    pub fn sendPass(self: *Irc, comptime msgFmt: []const u8, params: anytype) !void {
        const msg = try std.fmt.bufPrint(self.write_buf, msgFmt, params);
        _ = try self.stream.write(msg);
        print("<-- PASS <hidden>\n", .{});
    }
    
    pub fn send(self: *Irc, comptime msgFmt: []const u8, params: anytype) !void {
        const msg = try std.fmt.bufPrint(self.write_buf, msgFmt, params);
        _ = try self.stream.write(msg);
        print("<-- {s}", .{msg});
    }

    pub fn read(self: *Irc) !u64 {
        const bytesRead = try self.stream.read(self.read_buf);
        if (bytesRead == 0) {
            return 0;
        }

        // Can't print byte-by-byte due to unicode, so we copy the message to a temporary
        // buffer, replacing "\n" with "\n--> ".
        const msg = self.read_buf[0..bytesRead];
        const num_newlines = std.mem.count(u8, msg, "\n");
        var formatted_msg = try self.alloc.alloc(u8, bytesRead + num_newlines*4);
        defer self.alloc.free(formatted_msg);

        _ = std.mem.replace(u8, msg[0..bytesRead], "\n", "\n--> ", formatted_msg[0..]);
        print("--> ", .{});
        print("{s}", .{formatted_msg[0..bytesRead + (num_newlines - 1)*4]}); // num_newlines - 1 so we don't print the last one

        return bytesRead;
    }
};

const Ini = struct {
    alloc: Allocator,
    data: []u8, // Backing data (e.g. when read from a file)
    extra: std.SinglyLinkedList([]const u8),
    map: std.StringHashMap([]const u8),

    pub fn put_new(self: *Ini, key: []const u8, value: []const u8) !void {
        var key_copy = try self.alloc.alloc(u8, key.len);
        var value_copy = try self.alloc.alloc(u8, value.len);
        std.mem.copy(u8, key_copy, key);
        std.mem.copy(u8, value_copy, value);
        try self.map.put(key_copy, value_copy);
    }

    pub fn free(self: *Ini) void {
        self.alloc.free(self.data);
        var it = self.extra.first;
        while (it) |node| : (it = node.next) {
            self.alloc.free(node.data);
        }
        self.map.deinit();
    }
};

fn readIniFile(alloc: Allocator, filepath: []const u8) !Ini {
    var data = try std.fs.cwd().readFileAlloc(alloc, filepath, 1024);
    return try readIni(alloc, data);
}

fn readIni(alloc: Allocator, data: []u8) !Ini {
    var map = std.StringHashMap([]const u8).init(alloc);

    var i: usize = 0;
    while (i < data.len) {
        const keyStart = i;
        for (data[i..]) |byte| {
            if (byte == ':') {
                i += 1;
                break;
            }
            i += 1;
        }
        const key = data[keyStart..i-1];

        const valStart = i;
        for (data[i..]) |byte| {
            if (byte == '\n') {
                i += 1;
                break;
            }
            i += 1;
        }
        const val = data[valStart..i-1];

        try map.put(key, val);
    }

    var extra = std.SinglyLinkedList([]const u8){};

    return Ini {
        .alloc = alloc,
        .data = data,
        .extra = extra,
        .map = map,
    };
}

fn writeIniFile(alloc: Allocator, filepath: []const u8, ini: *Ini) !void {
    var data = try std.ArrayList(u8).initCapacity(alloc, 4*1024);
    defer data.deinit();

    var iterator = ini.map.iterator();
    while (iterator.next()) |entry| {
        try data.appendSlice(entry.key_ptr.*);
        try data.append(':');
        try data.appendSlice(entry.value_ptr.*);
        try data.append('\n');
    }

    try std.fs.cwd().writeFile(filepath, data.items);
}
