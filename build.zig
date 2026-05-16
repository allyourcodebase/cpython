pub const Version = enum {
    @"3.11.13",
    @"3.12.11",
    pub fn libName(self: Version) []const u8 {
        return switch (self) {
            .@"3.11.13" => "3.11",
            .@"3.12.11" => "3.12",
        };
    }

    pub const latest: Version = .@"3.12.11";
};

/// There are 3 stages of the python exe, the first two are used compile and embed modules for
/// the next stage which is referred to as "freezing" modules.
const PythonExeStage = union(enum) {
    /// stage1: used to "freeze" the modules used by bootstrap
    freeze_module,
    /// stage2: used to freeze the remaining modules for the final exe
    bootstrap: Stage2FrozenMods,
    /// stage3: the final python exe
    final: struct {
        stage2: Stage2FrozenMods,
        deepfreeze_c: std.Build.LazyPath,
        frozen_headers: []const std.Build.LazyPath,
    },

    pub fn stage2FrozenMods(self: PythonExeStage) ?Stage2FrozenMods {
        return switch (self) {
            .freeze_module => null,
            .bootstrap => |mods| mods,
            .final => |final| final.stage2,
        };
    }
};
const Stage2FrozenMods = struct {
    getpath_h: std.Build.LazyPath,
    importlib_bootstrap_h: std.Build.LazyPath,
    importlib_bootstrap_external_h: std.Build.LazyPath,
    zipimport_h: std.Build.LazyPath,
};

pub fn build(b: *std.Build) !void {
    const version: Version = b.option(Version, "version", "Python Version") orelse .latest;

    const replace_exe = b.addExecutable(.{
        .name = "replace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("replace.zig"),
            .target = b.graph.host,
        }),
    });
    const configquery_exe = b.addExecutable(.{
        .name = "configquery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("configquery.zig"),
            .target = b.graph.host,
        }),
    });
    const makesetup_exe = b.addExecutable(.{
        .name = "makesetup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("makesetup.zig"),
            .target = b.graph.host,
        }),
    });

    const upstream: *std.Build.Dependency = switch (version) {
        .@"3.11.13" => if (b.lazyDependency("upstream_3.11.13", .{})) |d| d else noUpstream(b),
        .@"3.12.11" => if (b.lazyDependency("upstream_3.12.11", .{})) |d| d else noUpstream(b),
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ssl_enabled = b.option(bool, "ssl", "enable ssl") orelse switch (target.result.os.tag) {
        .macos => false, // there's an issue building openssl on macos
        else => true,
    };

    const libs_host: Libs = .{ .zlib = null, .openssl = null };
    const libs_target: Libs = .{
        .zlib = (b.dependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })).artifact("z"),
        .openssl = if (ssl_enabled) (if (b.lazyDependency("openssl", .{
            .target = target,
            .optimize = optimize,
        })) |dep| dep.artifact("openssl") else null) else null,
    };

    const makesetup_host = addMakesetup(b, version, upstream, libs_host, .{
        .os_tag = b.graph.host.result.os.tag,
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
    });
    const makesetup_target = addMakesetup(b, version, upstream, libs_target, .{
        .os_tag = target.result.os.tag,
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
    });
    const pyconfig_host = try addPyconfig(b, version, upstream, b.graph.host, .{ .zlib = null, .openssl = null }, configquery_exe);

    const freeze_module_exe = addPythonExe(b, upstream, b.graph.host, .Debug, .{
        .name = "freeze_module",
        .makesetup_out = makesetup_host,
        .pyconfig = pyconfig_host,
        .stage = .freeze_module,
    });

    const stage2_frozen_mods: Stage2FrozenMods = .{
        .getpath_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("getpath");
            freeze.addFileArg(upstream.path("Modules/getpath.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/getpath.h");
        },
        .importlib_bootstrap_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap.h");
        },
        .importlib_bootstrap_external_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap_external");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap_external.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap_external.h");
        },
        .zipimport_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("zipimport");
            freeze.addFileArg(upstream.path("Lib/zipimport.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/zipimport.h");
        },
    };

    const frozen_headers, const deepfreeze_c = blk_deepfreeze_c: {
        const bootstrap_python_exe = addPythonExe(b, upstream, b.graph.host, .Debug, .{
            .name = "bootstrap_python",
            .makesetup_out = makesetup_host,
            .pyconfig = pyconfig_host,
            .stage = .{ .bootstrap = stage2_frozen_mods },
        });
        const bootstrap_packaged = packagePython(b, version, upstream, bootstrap_python_exe);

        const frozen_headers = b.allocator.alloc(std.Build.LazyPath, frozen_modules.len) catch @panic("OOM");
        // don't free

        const freeze_step = b.step("freeze", "");
        for (frozen_modules, frozenModuleNames(version), frozen_headers) |mod_path, mod_name, *header| {
            const freeze = std.Build.Step.Run.create(b, b.fmt("run _freeze_module.py for '{s}'", .{mod_path}));
            freeze.addFileArg(bootstrap_packaged.exe);
            freeze.addFileArg(upstream.path("Programs/_freeze_module.py"));
            freeze.addArg(mod_name);
            freeze.addFileArg(upstream.path(mod_path));
            header.* = freeze.addOutputFileArg(b.fmt("frozen_modules/{s}.h", .{mod_name}));
            freeze_step.dependOn(&freeze.step);
        }

        const run = std.Build.Step.Run.create(b, "run deepfreeze.py");
        run.addFileArg(bootstrap_packaged.exe);
        run.addFileArg(upstream.path(switch (version) {
            .@"3.11.13" => "Tools/scripts/deepfreeze.py",
            else => "Tools/build/deepfreeze.py",
        }));
        run.addArg("-o");
        const deepfreeze_c = run.addOutputFileArg("deepfreeze.c");
        {
            // Need to create a custom step because std.Build.Step.Run doesn't
            // have addSuffixedOutputArg.
            const AddModules = struct {
                step: std.Build.Step,
                version: Version,
                run_deepfreeze: *std.Build.Step.Run,
                headers: []const std.Build.LazyPath,
            };
            const add_modules_make = struct {
                fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
                    _ = options;
                    const b2 = step.owner;
                    const self: *AddModules = @fieldParentPtr("step", step);
                    for (frozenModuleNames(self.version), self.headers) |mod_name, header| {
                        self.run_deepfreeze.addArg(b2.fmt("{s}:{s}", .{ header.getPath(b2), mod_name }));
                    }
                }
            }.make;
            const add_modules = b.allocator.create(AddModules) catch @panic("OOM");
            add_modules.* = .{
                .step = std.Build.Step.init(.{
                    .id = .custom,
                    .name = "add modules to run deepfreeze.py",
                    .owner = b,
                    .makeFn = &add_modules_make,
                }),
                .version = version,
                .run_deepfreeze = run,
                .headers = frozen_headers,
            };
            add_modules.step.dependOn(freeze_step);
            run.step.dependOn(&add_modules.step);
        }

        b.step("deepfreeze", "").dependOn(&run.step);
        break :blk_deepfreeze_c .{ frozen_headers, deepfreeze_c };
    };

    const final_exe = addPythonExe(b, upstream, target, optimize, .{
        .name = "python",
        .makesetup_out = makesetup_target,
        .pyconfig = try addPyconfig(b, version, upstream, target, libs_target, configquery_exe),
        .stage = .{
            .final = .{
                .stage2 = stage2_frozen_mods,
                .frozen_headers = frozen_headers,
                .deepfreeze_c = deepfreeze_c,
            },
        },
    });
    const final_packaged = packagePython(b, version, upstream, final_exe);
    const install_final = b.addInstallDirectory(.{
        .source_dir = final_packaged.root,
        .install_dir = .prefix,
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&install_final.step);

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    try ci(b, version, ssl_enabled, upstream, ci_step, .{
        .replace_exe = replace_exe,
        .makesetup_exe = makesetup_exe,
        .configquery_exe = configquery_exe,
        .stage2_frozen_mods = stage2_frozen_mods,
        .frozen_headers = frozen_headers,
        .deepfreeze_c = deepfreeze_c,
    });
}

fn noUpstream(b: *std.Build) *std.Build.Dependency {
    const dependency = b.allocator.create(std.Build.Dependency) catch @panic("OOM");
    dependency.* = .{ .builder = b };
    return dependency;
}

fn addMakesetup(
    b: *std.Build,
    version: Version,
    upstream: *std.Build.Dependency,
    libs: Libs,
    args: struct {
        os_tag: std.Target.Os.Tag,
        replace_exe: *std.Build.Step.Compile,
        makesetup_exe: *std.Build.Step.Compile,
    },
) std.Build.LazyPath {
    const is_posix = (args.os_tag != .windows);

    const stdlib_modules_common = .{
        ._ssl = (libs.openssl != null),
        .zlib = (libs.zlib != null),

        // Modules that should always be present (POSIX and Windows):
        ._asyncio = true,
        ._bisect = true,
        ._contextvars = true,
        ._csv = true,
        ._datetime = true,
        ._decimal = false, // depends on libmpdec, disabled until it's available
        ._heapq = true,
        ._json = true,
        ._lsprof = true,
        ._multiprocessing = true,
        ._opcode = true,
        ._pickle = true,
        ._queue = true,
        ._random = true,
        ._socket = (args.os_tag != .windows),
        ._statistics = true,
        ._struct = true,
        ._zoneinfo = true,
        .array = true,
        .audioop = true,
        .binascii = true,
        .cmath = true,
        .math = true,
        .mmap = true,
        .select = true,

        // text encodings and unicode
        ._codecs_cn = false,
        ._codecs_hk = false,
        ._codecs_iso2022 = false,
        ._codecs_jp = false,
        ._codecs_kr = false,
        ._codecs_tw = false,
        ._multibytecodec = true,
        .unicodedata = true,

        // Modules with some UNIX dependencies
        ._posixsubprocess = is_posix,
        .fcntl = is_posix,
        ._posixshmem = is_posix,
        .grp = is_posix,
        .ossaudiodev = (args.os_tag == .linux),
        .resource = (args.os_tag == .linux),
        .spwd = (args.os_tag == .linux),
        .syslog = is_posix,
        .termios = is_posix,

        ._md5 = true,
        ._sha1 = true,
        ._sha3 = true,
        ._blake2 = true,

        ._bz2 = false,
        ._lzma = false,

        ._dbm = false,
        ._gdbm = false,
        .readline = false,
        .pyexpat = false,
        ._elementtree = false,
        ._crypt = false,
        .nis = false,
        ._ctypes = true,
        ._curses = false,
        ._curses_panel = false,
        ._sqlite3 = false,
        ._hashlib = false,
        ._uuid = false,
        ._tkinter = false,
        ._scproxy = false,
        ._xxtestfuzz = false,
        ._testbuffer = false,
        ._testinternalcapi = false,
        ._testcapi = false,
        ._testclinic = false,
        ._testimportmultiple = false,
        ._testmultiphase = false,
        ._ctypes_test = false,
        .xxlimited = false,
        .xxlimited_35 = false,
        ._xxsubinterpreters = false,
    };
    const @"stdlib_modules_3.11.13" = .{
        ._typing = true,
        ._sha256 = true,
        ._sha512 = true,
    };
    const @"stdlib_modules_3.12.11" = .{
        ._sha2 = false,
        .xxsubtype = false,
        ._xxinterpchannels = false,
    };

    const setup_bootstrap = blk: {
        const replace = b.addRunArtifact(args.replace_exe);
        replace.addFileArg(upstream.path("Modules/Setup.bootstrap.in"));
        const out = replace.addOutputFileArg("Setup.bootstrap");

        const pwd_enabled = is_posix;
        const value_str = if (pwd_enabled) "" else "#";
        replace.addArg(b.fmt("MODULE_PWD_TRUE={s}", .{value_str}));
        break :blk out;
    };

    const setup_stdlib = blk_stdlib: {
        const replace = b.addRunArtifact(args.replace_exe);
        replace.addFileArg(upstream.path("Modules/Setup.stdlib.in"));
        const out = replace.addOutputFileArg("Setup.stdlib");
        replace.addArg("MODULE_{NAME}_TRUE=MODULE_{NAME}_TRUE");
        replace.addArg("MODULE_BUILDTYPE=static");
        addReplaceModuleArgs(b, replace, @TypeOf(stdlib_modules_common), stdlib_modules_common);
        switch (version) {
            .@"3.11.13" => addReplaceModuleArgs(b, replace, @TypeOf(@"stdlib_modules_3.11.13"), @"stdlib_modules_3.11.13"),
            .@"3.12.11" => {
                replace.addArg("MODULE__CTYPES_MALLOC_CLOSURE=");
                addReplaceModuleArgs(b, replace, @TypeOf(@"stdlib_modules_3.12.11"), @"stdlib_modules_3.12.11");
            },
        }
        break :blk_stdlib out;
    };

    const generate = b.addRunArtifact(args.makesetup_exe);
    generate.addDirectoryArg(upstream.path("."));
    const makesetup_out = generate.addOutputDirectoryArg("gen");
    generate.addFileArg(setup_bootstrap);
    generate.addFileArg(setup_stdlib);
    generate.addFileArg(upstream.path("Modules/Setup"));
    return makesetup_out;
}

fn addReplaceModuleArgs(b: *std.Build, replace: *std.Build.Step.Run, comptime Modules: type, modules: Modules) void {
    inline for (std.meta.fields(Modules)) |field| {
        const name = field.name;
        const value = @field(modules, name);
        var upcase_buf: [100]u8 = undefined;
        for (name, 0..) |c, i| {
            upcase_buf[i] = std.ascii.toUpper(c);
        }
        const value_str = if (value) "" else "#";
        replace.addArg(b.fmt("MODULE_{s}_TRUE={s}", .{ upcase_buf[0..name.len], value_str }));
    }
}

fn packagePython(b: *std.Build, version: Version, upstream: *std.Build.Dependency, exe: *std.Build.Step.Compile) struct {
    root: std.Build.LazyPath,
    exe: std.Build.LazyPath,
} {
    const write_files = b.addNamedWriteFiles(exe.name);
    _ = write_files.addCopyDirectory(upstream.path("Lib"), b.fmt("lib/python{s}", .{version.libName()}), .{});
    const empty_dir = b.addWriteFiles().getDirectory();
    _ = write_files.addCopyDirectory(empty_dir, b.fmt("lib/python{s}/lib-dynload", .{version.libName()}), .{});
    if (exe.producesPdbFile()) {
        _ = write_files.addCopyFile(exe.getEmittedPdb(), b.fmt("bin/{s}.pdb", .{exe.name}));
    }
    return .{
        .root = write_files.getDirectory(),
        .exe = write_files.addCopyFile(
            exe.getEmittedBin(),
            b.fmt("bin/{s}", .{exe.out_filename}),
        ),
    };
}

fn addPythonExe(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: struct {
        name: []const u8,
        makesetup_out: std.Build.LazyPath,
        pyconfig: Pyconfig,
        stage: PythonExeStage,
    },
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = args.name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addCMacro("Py_BUILD_CORE", "");
    exe.root_module.addCMacro("_GNU_SOURCE", "");
    switch (optimize) {
        .Debug => {},
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => {
            const release_date = switch (args.pyconfig.version) {
                .@"3.11.13" => "June 3, 2025",
                .@"3.12.11" => "June 3, 2025",
            };
            // need to redefine __DATE__ and __TIME__ for a reproducible build
            exe.root_module.addCMacro("__DATE__", b.fmt("\"{s}\"", .{release_date}));
            exe.root_module.addCMacro("__TIME__", "\"00:00:00\"");
        },
    }
    exe.root_module.addCMacro("PLATFORM", switch (target.result.os.tag) {
        .linux => "\"linux\"",
        .macos => "\"darwin\"",
        .windows => "\"win32\"",
        else => std.debug.panic("todo: populate PLATFORM for os '{s}'", .{@tagName(target.result.os.tag)}),
    });
    switch (args.pyconfig.header) {
        .path => |path| exe.root_module.addIncludePath(path.dirname()),
        .config_header => |h| exe.root_module.addConfigHeader(h),
    }
    exe.root_module.addIncludePath(upstream.path("."));
    exe.root_module.addIncludePath(upstream.path("Include"));
    exe.root_module.addIncludePath(upstream.path("Include/internal"));
    if (args.stage.stage2FrozenMods()) |mods| {
        exe.root_module.addIncludePath(mods.getpath_h.dirname().dirname());
        exe.root_module.addIncludePath(mods.importlib_bootstrap_h.dirname().dirname().dirname());
        exe.root_module.addIncludePath(mods.importlib_bootstrap_external_h.dirname().dirname().dirname());
        exe.root_module.addIncludePath(mods.zipimport_h.dirname().dirname().dirname());
    }

    switch (args.stage) {
        .freeze_module, .bootstrap => {},
        .final => |final| switch (args.pyconfig.version) {
            .@"3.11.13" => {},
            else => for (final.frozen_headers) |h| {
                exe.root_module.addIncludePath(h.dirname().dirname());
            },
        },
    }

    const flags_common = [_][]const u8{
        "-fwrapv",
        "-std=c11",
        "-fvisibility=hidden",
        "-DVPATH=\"\"",
    };

    {
        const AddModules = struct {
            step: std.Build.Step,
            upstream: *std.Build.Dependency,
            exe: *std.Build.Step.Compile,
            module_compile_args_file: std.Build.LazyPath,
        };
        const add_modules_make = struct {
            fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
                _ = options;
                const io = step.owner.graph.io;
                const self: *AddModules = @fieldParentPtr("step", step);
                const file_path = self.module_compile_args_file.getPath2(step.owner, step);

                const module_compile_args = try std.Io.Dir.cwd().readFileAlloc(io, file_path, step.owner.allocator, .unlimited);
                defer step.owner.allocator.free(module_compile_args);

                var files: std.ArrayList([]const u8) = .empty;
                defer files.deinit(step.owner.allocator);

                var line_it = std.mem.splitScalar(u8, module_compile_args, '\n');
                while (line_it.next()) |line| {
                    if (line.len == 0) continue;
                    if (std.mem.startsWith(u8, line, "# ")) continue;
                    if (std.mem.endsWith(u8, line, ".c")) {
                        try files.append(step.owner.allocator, line);
                    } else if (std.mem.startsWith(u8, line, "-I")) {
                        const path = line[2..];
                        const prefix = "$(srcdir)/";
                        if (!std.mem.startsWith(u8, path, prefix)) std.debug.panic(
                            "expected include path to start with '-I{s}' but got: '{s}'",
                            .{ prefix, line },
                        );
                        const inc_sub_path = step.owner.dupe(path[prefix.len..]);
                        self.exe.root_module.addIncludePath(self.upstream.path(inc_sub_path));
                    } else std.debug.panic("todo: parse module-compile-args line '{s}'", .{line});
                }

                self.exe.root_module.addCSourceFiles(.{
                    .root = self.upstream.path("."),
                    .files = files.items,
                    .flags = &flags_common,
                });
            }
        }.make;
        const add_modules = b.allocator.create(AddModules) catch @panic("OOM");
        add_modules.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("add module sources/includes to {s} exe", .{exe.name}),
                .owner = b,
                .makeFn = &add_modules_make,
            }),
            .upstream = upstream,
            .exe = exe,
            .module_compile_args_file = args.makesetup_out.path(b, "module-compile-args.txt"),
        };
        add_modules.module_compile_args_file.addStepDependencies(&add_modules.step);
        exe.step.dependOn(&add_modules.step);
    }

    exe.root_module.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = switch (args.stage) {
            .freeze_module => concat(b.allocator, &.{
                &.{
                    "Programs/_freeze_module.c",
                    "Modules/getbuildinfo.c",
                    "Modules/getpath_noop.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
            .bootstrap => concat(b.allocator, &.{
                &.{
                    "Programs/_bootstrap_python.c",
                    "Modules/getbuildinfo.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
            .final => concat(b.allocator, &.{
                &.{
                    "Programs/python.c",
                    "Modules/getbuildinfo.c",
                    "Python/frozen.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
        },
        .flags = concat(b.allocator, &.{
            &flags_common,
            switch (args.pyconfig.version) {
                // workaround dictobject.c memcpy alignment issue
                .@"3.11.13" => &.{"-fno-sanitize=alignment"},
                // tokenizer.c uses pointer overflow in restore_fstring_buffers
                .@"3.12.11" => &.{"-fno-sanitize=pointer-overflow"},
            },
        }),
    });

    exe.root_module.addCSourceFile(.{
        .file = args.makesetup_out.path(b, "config.c"),
        .flags = &flags_common,
    });

    switch (args.stage) {
        .freeze_module => {},
        .bootstrap, .final => exe.root_module.addCSourceFile(.{
            .file = upstream.path("Modules/getpath.c"),
            .flags = &(flags_common ++ [_][]const u8{
                "-DPREFIX=\"\"",
                "-DEXEC_PREFIX=\"\"",
                b.fmt("-DVERSION=\"{s}\"", .{args.pyconfig.version.libName()}),
                "-DPLATLIBDIR=\"lib\"",
            }),
        }),
    }
    switch (args.stage) {
        .freeze_module, .bootstrap => {},
        .final => |final| {
            exe.root_module.addCSourceFile(.{ .file = final.deepfreeze_c, .flags = &flags_common });
        },
    }

    if (target.result.os.tag == .windows) {
        exe.root_module.addCSourceFile(.{
            .file = upstream.path("Python/dynload_win.c"),
            .flags = &flags_common,
        });
    } else {
        exe.root_module.addCSourceFile(.{
            .file = upstream.path("Python/dynload_shlib.c"),
            .flags = &(flags_common ++ .{
                "-DSOABI=\"cpython-311-x86_64-linux-gnu\"",
            }),
        });
    }

    if (args.pyconfig.libs.zlib) |zlib| exe.root_module.linkLibrary(zlib);
    if (args.pyconfig.libs.openssl) |openssl| exe.root_module.linkLibrary(openssl);

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
        exe.root_module.linkSystemLibrary("api-ms-win-core-path-l1-1-0", .{});
    }

    // TODO: do we need this
    // exe.rdynamic = true;

    return exe;
}

const Pyconfig = struct {
    version: Version,
    libs: Libs,
    header: union(enum) {
        path: std.Build.LazyPath,
        config_header: *std.Build.Step.ConfigHeader,
    },
};

const Libs = struct {
    zlib: ?*std.Build.Step.Compile,
    openssl: ?*std.Build.Step.Compile,
};

fn addPyconfig(
    b: *std.Build,
    version: Version,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    libs: Libs,
    configquery_exe: *std.Build.Step.Compile,
) !Pyconfig {
    const t = target.result;
    if (t.os.tag == .windows) return .{
        .version = version,
        .libs = libs,
        .header = .{ .path = upstream.path("PC/pyconfig.h") },
    };

    const config_header = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = upstream.path("pyconfig.h.in") },
        .include_path = "pyconfig.h",
    }, .{
        .ALIGNOF_LONG = 8,
        .ALIGNOF_SIZE_T = 8,
        .DOUBLE_IS_LITTLE_ENDIAN_IEEE754 = 1,
        .ENABLE_IPV6 = 1,
        .MAJOR_IN_SYSMACROS = have(t.os.tag == .linux),
        .PTHREAD_KEY_T_IS_COMPATIBLE_WITH_INT = 1,
        .PTHREAD_SYSTEM_SCHED_SUPPORTED = 1,
        .PY_BUILTIN_HASHLIB_HASHES = "md5,sha1,sha256,sha512,sha3,blake2",
        .PY_COERCE_C_LOCALE = 1,
        .PY_SSL_DEFAULT_CIPHERS = 1,
        .PY_SUPPORT_TIER = 2,
        .RETSIGTYPE = .void,
        .SIZEOF_DOUBLE = 8,
        .SIZEOF_FLOAT = 4,
        .SIZEOF_FPOS_T = 16,
        .SIZEOF_INT = 4,
        .SIZEOF_LONG = 8,
        .SIZEOF_LONG_DOUBLE = 16,
        .SIZEOF_LONG_LONG = 8,
        .SIZEOF_OFF_T = 8,
        .SIZEOF_PID_T = 4,
        .SIZEOF_PTHREAD_KEY_T = 4,
        .SIZEOF_PTHREAD_T = 8,
        .SIZEOF_SHORT = 2,
        .SIZEOF_SIZE_T = 8,
        .SIZEOF_TIME_T = 8,
        .SIZEOF_UINTPTR_T = 8,
        .SIZEOF_VOID_P = 8,
        .SIZEOF_WCHAR_T = 4,
        .SIZEOF__BOOL = 1,
        .STDC_HEADERS = 1,
        .SYS_SELECT_WITH_SYS_TIME = 1,
        .WITH_DECIMAL_CONTEXTVAR = 1,
        .WITH_DOC_STRINGS = 1,
        .WITH_FREELISTS = 1,
        .WITH_PYMALLOC = 1,
        ._DARWIN_C_SOURCE = 1,
        ._FILE_OFFSET_BITS = 64,
        ._LARGEFILE_SOURCE = 1,
        ._NETBSD_SOURCE = 1,
        ._POSIX_C_SOURCE = .@"200809L",
        ._PYTHONFRAMEWORK = "",
        ._REENTRANT = 1,
        ._XOPEN_SOURCE = 700,
        ._XOPEN_SOURCE_EXTENDED = 1,
        .__BSD_VISIBLE = 1,
        ._ALL_SOURCE = 1,
        ._GNU_SOURCE = 1,
        ._POSIX_PTHREAD_SEMANTICS = 1,
        ._TANDEM_SOURCE = 1,
        .__EXTENSIONS__ = 1,

        .AC_APPLE_UNIVERSAL_BUILD = null,
        .AIX_BUILDDATE = null,
        .AIX_GENUINE_CPLUSPLUS = null,
        .ALT_SOABI = null,
        .ANDROID_API_LEVEL = null,
        .DOUBLE_IS_ARM_MIXED_ENDIAN_IEEE754 = null,
        .DOUBLE_IS_BIG_ENDIAN_IEEE754 = null,
        .GETPGRP_HAVE_ARG = null,
        .MAJOR_IN_MKDEV = null,
        .MVWDELCH_IS_EXPRESSION = null,
        .PACKAGE_BUGREPORT = null,
        .PACKAGE_NAME = null,
        .PACKAGE_STRING = null,
        .PACKAGE_TARNAME = null,
        .PACKAGE_URL = null,
        .PACKAGE_VERSION = null,
        .POSIX_SEMAPHORES_NOT_ENABLED = null,
        .PYLONG_BITS_IN_DIGIT = null,
        .PY_SQLITE_ENABLE_LOAD_EXTENSION = null,
        .PY_SQLITE_HAVE_SERIALIZE = null,
        .PY_SSL_DEFAULT_CIPHER_STRING = null,
        .Py_DEBUG = null,
        .Py_ENABLE_SHARED = null,
        .Py_HASH_ALGORITHM = null,
        .Py_STATS = null,
        .Py_SUNOS_VERSION = null,
        .Py_TRACE_REFS = null,
        .SETPGRP_HAVE_ARG = null,
        .SIGNED_RIGHT_SHIFT_ZERO_FILLS = null,
        .THREAD_STACK_SIZE = null,
        .TIMEMODULE_LIB = null,
        .TM_IN_SYS_TIME = null,
        .USE_COMPUTED_GOTOS = null,
        .WINDOW_HAS_FLAGS = null,
        .WITH_DTRACE = null,
        .WITH_DYLD = null,
        .WITH_EDITLINE = null,
        .WITH_LIBINTL = null,
        .WITH_NEXT_FRAMEWORK = null,
        .WITH_VALGRIND = null,
        .X87_DOUBLE_ROUNDING = null,
        ._BSD_SOURCE = null,
        ._INCLUDE__STDC_A1_SOURCE = null,
        ._LARGE_FILES = null,
        ._MINIX = null,
        ._POSIX_1_SOURCE = null,
        ._POSIX_SOURCE = null,
        ._POSIX_THREADS = null,
        ._WASI_EMULATED_GETPID = null,
        ._WASI_EMULATED_PROCESS_CLOCKS = null,
        ._WASI_EMULATED_SIGNAL = null,
        .clock_t = null,
        .@"const" = null,
        .gid_t = null,
        .mode_t = null,
        .off_t = null,
        .pid_t = null,
        .signed = null,
        .size_t = null,
        .socklen_t = null,
        .uid_t = null,
        .WORDS_BIGENDIAN = null,

        .HAVE_BROKEN_MBSTOWCS = null,
        .HAVE_BROKEN_NICE = null,
        .HAVE_BROKEN_PIPE_BUF = null,
        .HAVE_BROKEN_POLL = null,
        .HAVE_BROKEN_POSIX_SEMAPHORES = null,
        .HAVE_BROKEN_PTHREAD_SIGMASK = null,
        .HAVE_BROKEN_SEM_GETVALUE = null,
        .HAVE_BROKEN_UNSETENV = null,

        .HAVE_PTHREAD_STUBS = null,
        .HAVE_USABLE_WCHAR_T = null,
        .HAVE_NON_UNICODE_WCHAR_T_REPRESENTATION = null,
        .HAVE_CHROOT = have(t.os.tag == .linux),
        .HAVE_GCC_ASM_FOR_MC68881 = have(t.cpu.arch == .m68k),
        .HAVE_GCC_ASM_FOR_X64 = have(t.cpu.arch == .x86_64),
        .HAVE_GCC_ASM_FOR_X87 = have(t.cpu.arch == .x86_64 or t.cpu.arch == .x86),
        // Readline type (static configuration, not function test)
        .HAVE_RL_COMPDISP_FUNC_T = null,
    });
    switch (version) {
        .@"3.11.13" => config_header.addValues(.{
            .PY_FORMAT_SIZE_T = "z",
            .TIME_WITH_SYS_TIME = 1,
            .FLOAT_WORDS_BIGENDIAN = null,
        }),
        .@"3.12.11" => config_header.addValues(.{
            .ALIGNOF_MAX_ALIGN_T = @as(u32, switch (t.cpu.arch) {
                .x86_64, .aarch64 => 16,
                .x86, .arm => 8,
                else => 8,
            }),

            // ncurses library (static configuration, not function test)
            .HAVE_NCURSESW = null,

            // Performance trampoline feature
            .PY_HAVE_PERF_TRAMPOLINE = null,

            ._HPUX_ALT_XOPEN_SOCKET_API = null,
            ._OPENBSD_SOURCE = null,

            // C standard feature test macros (all set to null as they're optional)
            .__STDC_WANT_IEC_60559_ATTRIBS_EXT__ = null,
            .__STDC_WANT_IEC_60559_BFP_EXT__ = null,
            .__STDC_WANT_IEC_60559_DFP_EXT__ = null,
            .__STDC_WANT_IEC_60559_FUNCS_EXT__ = null,
            .__STDC_WANT_IEC_60559_TYPES_EXT__ = null,
            .__STDC_WANT_LIB_EXT2__ = null,
            .__STDC_WANT_MATH_SPEC_FUNCS__ = null,
        }),
    }

    {
        const run = b.addRunArtifact(configquery_exe);
        run.addArg("--zig-exe");
        run.addArg(b.graph.zig_exe);
        if (b.cache_root.path) |cache_root| {
            run.addArg("--cache-dir");
            run.addArg(cache_root);
        }
        run.addArg("-target");
        run.addArg(try target.query.zigTriple(b.allocator));
        run.addArg("-mcpu");
        run.addArg(try target.query.serializeCpuAlloc(b.allocator));
        if (libs.zlib) |zlib| run.addPrefixedDirectoryArg("-I", zlib.getEmittedIncludeTree());
        if (libs.openssl) |openssl| run.addPrefixedDirectoryArg("-I", openssl.getEmittedIncludeTree());
        run.addFileArg(b.path("config-common"));
        run.addFileArg(switch (version) {
            .@"3.11.13" => b.path("config-3.11.13"),
            .@"3.12.11" => b.path("config-3.12.11"),
        });
        run.addArg("-o");
        ConfigHeaderExt.addFile(config_header, run.addOutputFileArg("config"));
    }

    return .{
        .version = version,
        .libs = libs,
        .header = .{ .config_header = config_header },
    };
}

fn have(x: bool) ?u1 {
    return if (x) 1 else null;
}

const Config = struct { name: []const u8, string: []const u8 };
fn concatConfigs(comptime first: anytype, comptime second: anytype) [std.meta.fields(@TypeOf(first)).len + std.meta.fields(@TypeOf(second)).len]Config {
    const first_len = std.meta.fields(@TypeOf(first)).len;
    var result: [first_len + std.meta.fields(@TypeOf(second)).len]Config = undefined;
    inline for (std.meta.fields(@TypeOf(first)), result[0..first_len]) |field, *config| {
        config.* = .{ .name = @tagName(@field(first, field.name)[0]), .string = @field(first, field.name)[1] };
    }
    inline for (std.meta.fields(@TypeOf(second)), result[first_len..]) |field, *config| {
        config.* = .{ .name = @tagName(@field(second, field.name)[0]), .string = @field(second, field.name)[1] };
    }
    return result;
}

const python_src = struct {
    const common = [_][]const u8{
        "Python/_warnings.c",
        "Python/Python-ast.c",
        "Python/Python-tokenize.c",
        "Python/asdl.c",
        "Python/ast.c",
        "Python/ast_opt.c",
        "Python/ast_unparse.c",
        "Python/bltinmodule.c",
        "Python/ceval.c",
        "Python/codecs.c",
        "Python/compile.c",
        "Python/context.c",
        "Python/dynamic_annotations.c",
        "Python/errors.c",
        "Python/frame.c",
        "Python/frozenmain.c",
        "Python/future.c",
        "Python/getargs.c",
        "Python/getcompiler.c",
        "Python/getcopyright.c",
        "Python/getplatform.c",
        "Python/getversion.c",
        "Python/hamt.c",
        "Python/hashtable.c",
        "Python/import.c",
        "Python/importdl.c",
        "Python/initconfig.c",
        "Python/marshal.c",
        "Python/modsupport.c",
        "Python/mysnprintf.c",
        "Python/mystrtoul.c",
        "Python/pathconfig.c",
        "Python/preconfig.c",
        "Python/pyarena.c",
        "Python/pyctype.c",
        "Python/pyfpe.c",
        "Python/pyhash.c",
        "Python/pylifecycle.c",
        "Python/pymath.c",
        "Python/pystate.c",
        "Python/pythonrun.c",
        "Python/pytime.c",
        "Python/bootstrap_hash.c",
        "Python/specialize.c",
        "Python/structmember.c",
        "Python/symtable.c",
        "Python/sysmodule.c",
        "Python/thread.c",
        "Python/traceback.c",
        "Python/getopt.c",
        "Python/pystrcmp.c",
        "Python/pystrtod.c",
        "Python/pystrhex.c",
        "Python/dtoa.c",
        "Python/formatter_unicode.c",
        "Python/fileutils.c",
        "Python/suggestions.c",
    };
    pub const @"3.11.13" = common;
    pub const @"3.12.11" = common ++ .{
        "Python/assemble.c",
        "Python/flowgraph.c",
        "Python/ceval_gil.c",
        "Python/instrumentation.c",
        "Python/intrinsics.c",
        "Python/legacy_tracing.c",
        "Python/tracemalloc.c",
        "Python/perf_trampoline.c",
    };
};

const object_src = struct {
    const common = [_][]const u8{
        "Objects/abstract.c",
        "Objects/boolobject.c",
        "Objects/bytes_methods.c",
        "Objects/bytearrayobject.c",
        "Objects/bytesobject.c",
        "Objects/call.c",
        "Objects/capsule.c",
        "Objects/cellobject.c",
        "Objects/classobject.c",
        "Objects/codeobject.c",
        "Objects/complexobject.c",
        "Objects/descrobject.c",
        "Objects/enumobject.c",
        "Objects/exceptions.c",
        "Objects/genericaliasobject.c",
        "Objects/genobject.c",
        "Objects/fileobject.c",
        "Objects/floatobject.c",
        "Objects/frameobject.c",
        "Objects/funcobject.c",
        "Objects/interpreteridobject.c",
        "Objects/iterobject.c",
        "Objects/listobject.c",
        "Objects/longobject.c",
        "Objects/dictobject.c",
        "Objects/odictobject.c",
        "Objects/memoryobject.c",
        "Objects/methodobject.c",
        "Objects/moduleobject.c",
        "Objects/namespaceobject.c",
        "Objects/object.c",
        "Objects/obmalloc.c",
        "Objects/picklebufobject.c",
        "Objects/rangeobject.c",
        "Objects/setobject.c",
        "Objects/sliceobject.c",
        "Objects/structseq.c",
        "Objects/tupleobject.c",
        "Objects/typeobject.c",
        "Objects/unicodeobject.c",
        "Objects/unicodectype.c",
        "Objects/unionobject.c",
        "Objects/weakrefobject.c",
    };
    pub const @"3.11.13" = common ++ .{
        "Objects/accu.c",
    };
    pub const @"3.12.11" = common ++ .{
        "Objects/typevarobject.c",
    };
};

const parser_src = [_][]const u8{
    // PEGEN_OBJS
    "Parser/pegen.c",
    "Parser/pegen_errors.c",
    "Parser/action_helpers.c",
    "Parser/parser.c",
    "Parser/string_parser.c",
    "Parser/peg_api.c",

    // POBJS
    "Parser/token.c",

    //
    "Parser/myreadline.c",
    "Parser/tokenizer.c",
};

const module_src = [_][]const u8{
    "Modules/main.c",
    "Modules/gcmodule.c",
};

const extra_src = struct {
    // Setup.stdlib is commented out regardless of ctypes module config, so we
    // need to copy the sources it adds here
    pub const @"3.11.13" = [_][]const u8{
        "Modules/_ctypes/_ctypes.c",
        "Modules/_ctypes/callbacks.c",
        "Modules/_ctypes/callproc.c",
        "Modules/_ctypes/stgdict.c",
        "Modules/_ctypes/cfield.c",
    };
    pub const @"3.12.11" = [_][]const u8{};
};

const library_src_omit_frozen = struct {
    pub const @"3.11.13" = parser_src ++ object_src.@"3.11.13" ++ python_src.@"3.11.13" ++ module_src ++ extra_src.@"3.11.13";
    pub const @"3.12.11" = parser_src ++ object_src.@"3.12.11" ++ python_src.@"3.12.11" ++ module_src ++ extra_src.@"3.12.11";
};

const frozen_modules = [_][]const u8{
    "Lib/importlib/_bootstrap.py",
    "Lib/importlib/_bootstrap_external.py",
    "Lib/zipimport.py",
    "Lib/abc.py",
    "Lib/codecs.py",
    "Lib/io.py",
    "Lib/_collections_abc.py",
    "Lib/_sitebuiltins.py",
    "Lib/genericpath.py",
    "Lib/ntpath.py",
    "Lib/posixpath.py",
    "Lib/os.py",
    "Lib/site.py",
    "Lib/stat.py",
    "Lib/importlib/util.py",
    "Lib/importlib/machinery.py",
    "Lib/runpy.py",
    "Lib/__hello__.py",
    "Lib/__phello__/__init__.py",
    "Lib/__phello__/ham/__init__.py",
    "Lib/__phello__/ham/eggs.py",
    "Lib/__phello__/spam.py",
    "Tools/freeze/flag.py",
};

fn frozenModuleNames(version: Version) *const [frozen_modules.len][]const u8 {
    return switch (version) {
        .@"3.11.13" => &frozen_module_name_sets.@"3.11",
        else => &frozen_module_name_sets.@"after_3.11",
    };
}
const frozen_module_name_sets = struct {
    pub const @"3.11" = makeNames(.@"3.11");
    pub const @"after_3.11" = makeNames(.@"after_3.11");
    fn makeNames(when: enum { @"3.11", @"after_3.11" }) [frozen_modules.len][]const u8 {
        var names: [frozen_modules.len][]const u8 = undefined;
        for (&names, frozen_modules) |*name_ref, path| {
            if (std.mem.eql(u8, "Tools/freeze/flag.py", path)) {
                name_ref.* = "frozen_only";
                continue;
            }

            const name = blk_name: {
                const path_prefix = "Lib/";
                const path_suffix = blk: {
                    const init_suffix = "/__init__.py";
                    if (std.mem.endsWith(u8, path, init_suffix)) break :blk init_suffix;
                    break :blk ".py";
                };
                var name_buf: [path.len - path_prefix.len - path_suffix.len]u8 = undefined;
                for (&name_buf, path[path_prefix.len..][0..name_buf.len]) |*name_char, path_char| {
                    name_char.* = switch (path_char) {
                        '/' => switch (when) {
                            .@"3.11" => '_',
                            .@"after_3.11" => '.',
                        },
                        else => |c| c,
                    };
                }
                break :blk_name name_buf;
            };
            name_ref.* = &name;
        }
        return names;
    }
};

fn ci(
    b: *std.Build,
    version: Version,
    ssl_enabled: bool,
    upstream: *std.Build.Dependency,
    ci_step: *std.Build.Step,
    args: struct {
        replace_exe: *std.Build.Step.Compile,
        makesetup_exe: *std.Build.Step.Compile,
        configquery_exe: *std.Build.Step.Compile,
        stage2_frozen_mods: Stage2FrozenMods,
        frozen_headers: []const std.Build.LazyPath,
        deepfreeze_c: std.Build.LazyPath,
    },
) !void {
    const CiTarget = struct { triple: []const u8, ssl: bool };
    const ci_targets = [_]CiTarget{
        // .{ .triple = "x86_64-windows", .ssl = false },
        // .{ .triple = "aarch64-windows", .ssl = true },
        // .{ .triple = "x86-windows", .ssl = true },

        .{ .triple = "x86_64-macos", .ssl = false },
        .{ .triple = "aarch64-macos", .ssl = false },

        .{ .triple = "x86_64-linux-musl", .ssl = true },
        .{ .triple = "x86_64-linux-gnu", .ssl = true },
        .{ .triple = "aarch64-linux-musl", .ssl = false },
        .{ .triple = "aarch64-linux-gnu", .ssl = false },
        // .{ .triple = "arm-linux-musl", .ssl = true }, // zlib doesn't build
        .{ .triple = "riscv64-linux-musl", .ssl = false },
        .{ .triple = "powerpc64le-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-gnu", .ssl = false },
        .{ .triple = "s390x-linux-musl", .ssl = false },
    };

    for (ci_targets) |ci_target| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target.triple },
        ));
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;
        const target_dest_dir: std.Build.InstallDir = .{ .custom = ci_target.triple };
        const install = b.step(b.fmt("install-{s}", .{ci_target.triple}), "");
        ci_step.dependOn(install);

        const libs: Libs = .{
            .zlib = (b.dependency("zlib", .{
                .target = target,
                .optimize = optimize,
            })).artifact("z"),
            .openssl = if (ssl_enabled and ci_target.ssl) (if (b.lazyDependency("openssl", .{
                .target = target,
                .optimize = optimize,
            })) |dep| dep.artifact("openssl") else null) else null,
        };
        const makesetup = addMakesetup(b, version, upstream, libs, .{
            .os_tag = target.result.os.tag,
            .replace_exe = args.replace_exe,
            .makesetup_exe = args.makesetup_exe,
        });
        const exe = addPythonExe(b, upstream, target, optimize, .{
            .name = "python",
            .makesetup_out = makesetup,
            .pyconfig = try addPyconfig(b, version, upstream, target, libs, args.configquery_exe),
            .stage = .{ .final = .{
                .stage2 = args.stage2_frozen_mods,
                .frozen_headers = args.frozen_headers,
                .deepfreeze_c = args.deepfreeze_c,
            } },
        });

        install.dependOn(
            &b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );
    }
}

fn concat(allocator: std.mem.Allocator, lists: []const []const []const u8) []const []const u8 {
    var total: usize = 0;
    for (lists) |list| {
        total += list.len;
    }
    const result = allocator.alloc([]const u8, total) catch @panic("OOM");
    var index: usize = 0;
    for (lists) |list| {
        for (list) |s| {
            result[index] = s;
            index += 1;
        }
    }
    std.debug.assert(index == total);
    return result;
}

const std = @import("std");
const ConfigHeaderExt = @import("ConfigHeaderExt.zig");
