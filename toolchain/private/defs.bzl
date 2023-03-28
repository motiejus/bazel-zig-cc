_ZIG_TOOL_PATH = "tools/{zigtarget}/{zig_tool}"

# Zig supports even older glibcs than defined below, but we have tested only
# down to 2.17.
# $ zig targets | jq -r '.glibc[]' | sort -V
_GLIBCS = [
    "2.17",
    "2.18",
    "2.19",
    "2.22",
    "2.23",
    "2.24",
    "2.25",
    "2.26",
    "2.27",
    "2.28",
    "2.29",
    "2.30",
    "2.31",
    "2.32",
    "2.33",
    "2.34",
]

_INCLUDE_TAIL = [
    "libcxx/include",
    "libcxxabi/include",
    "include",
]

LIBCS = ["musl"] + ["gnu.{}".format(glibc) for glibc in _GLIBCS]

def zig_tool_path(os):
    if os == "windows":
        return _ZIG_TOOL_PATH + ".exe"
    else:
        return _ZIG_TOOL_PATH

def target_structs(macos_sdk_versions):
    ret = []
    for zigcpu, gocpu in (("x86_64", "amd64"), ("aarch64", "arm64")):
        ret.append(_target_windows(gocpu, zigcpu))
        ret.append(_target_linux_musl(gocpu, zigcpu))
        for glibc in _GLIBCS:
            ret.append(_target_linux_gnu(gocpu, zigcpu, glibc))
        for macos_sdk_version in macos_sdk_versions:
            ret.append(_target_macos(gocpu, zigcpu, macos_sdk_version))
    return ret

def _target_macos(gocpu, zigcpu, macos_sdk_version):
    macos_sdk_opts = [
        "--sysroot",
        "external/macos_sdk_{}".format(macos_sdk_version),
        "-F",
        "/System/Library/Frameworks",
    ]

    copts = macos_sdk_opts

    if zigcpu == "aarch64":
        copts.append("-mcpu=apple_m1")

    return struct(
        gotarget = "darwin_{}_sdk.{}".format(gocpu, macos_sdk_version),
        zigtarget = "{}-macos-sdk.{}".format(zigcpu, macos_sdk_version),
        includes = [],
        linkopts = macos_sdk_opts,
        dynamic_library_linkopts = ["-Wl,-undefined=dynamic_lookup"],
        cxx_builtin_include_directories = ["external/macos_sdk_{}/usr/include".format(macos_sdk_version)],
        sdk_include_files = ["@macos_sdk_{}//:usr_include".format(macos_sdk_version)],
        sdk_lib_files = ["@macos_sdk_{}//:usr_lib".format(macos_sdk_version)],
        copts = copts,
        libc = "macos",
        bazel_target_cpu = "darwin",
        constraint_values = [
            "@platforms//os:macos",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld64.lld"},
        artifact_name_patterns = [
            {
                "category_name": "dynamic_library",
                "prefix": "lib",
                "extension": ".dylib",
            },
        ],
        libc_constraint = "@zig_sdk//libc:macos.{}".format(macos_sdk_version),
    )

def _target_windows(gocpu, zigcpu):
    return struct(
        gotarget = "windows_{}".format(gocpu),
        zigtarget = "{}-windows-gnu".format(zigcpu),
        includes = [
            "libc/mingw",
            "libunwind/include",
            "libc/include/any-windows-any",
        ] + _INCLUDE_TAIL,
        linkopts = [],
        dynamic_library_linkopts = [],
        copts = [],
        libc = "mingw",
        bazel_target_cpu = "x64_windows",
        constraint_values = [
            "@platforms//os:windows",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld64.lld"},
        artifact_name_patterns = [
            {
                "category_name": "static_library",
                "prefix": "",
                "extension": ".lib",
            },
            {
                "category_name": "dynamic_library",
                "prefix": "",
                "extension": ".dll",
            },
            {
                "category_name": "executable",
                "prefix": "",
                "extension": ".exe",
            },
        ],
    )

def _target_linux_gnu(gocpu, zigcpu, glibc_version):
    glibc_suffix = "gnu.{}".format(glibc_version)

    compiler_extra_includes = []
    linker_version_scripts = []
    if glibc_version < "2.28":
        # https://github.com/ziglang/zig/issues/5882#issuecomment-888250676
        compiler_extra_includes.append("glibc-hacks/fcntl.h")
        linker_version_scripts.append("glibc-hacks/fcntl.map")
    if glibc_version < "2.34":
        compiler_extra_includes.append("glibc-hacks/res_search-{}.h".format(gocpu))
        linker_version_scripts.append("glibc-hacks/res_search-{}.map".format(gocpu))

    return struct(
        gotarget = "linux_{}_{}".format(gocpu, glibc_suffix),
        zigtarget = "{}-linux-{}".format(zigcpu, glibc_suffix),
        includes = [
                       "libc/include/{}-linux-gnu".format(zigcpu),
                       "libc/include/generic-glibc",
                   ] +
                   # x86_64-linux-any is x86_64-linux and x86-linux combined.
                   (["libc/include/x86-linux-any"] if zigcpu == "x86_64" else []) +
                   (["libc/include/{}-linux-any".format(zigcpu)] if zigcpu != "x86_64" else []) + [
            "libc/include/any-linux-any",
        ] + _INCLUDE_TAIL,
        compiler_extra_includes = compiler_extra_includes,
        linker_version_scripts = linker_version_scripts,
        linkopts = [],
        dynamic_library_linkopts = [],
        copts = [],
        libc = "glibc",
        bazel_target_cpu = "k8",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        libc_constraint = "@zig_sdk//libc:{}".format(glibc_suffix),
        tool_paths = {"ld": "ld.lld"},
        artifact_name_patterns = [],
    )

def _target_linux_musl(gocpu, zigcpu):
    return struct(
        gotarget = "linux_{}_musl".format(gocpu),
        zigtarget = "{}-linux-musl".format(zigcpu),
        includes = [
                       "libc/include/{}-linux-musl".format(zigcpu),
                       "libc/include/generic-musl",
                   ] +
                   # x86_64-linux-any is x86_64-linux and x86-linux combined.
                   (["libc/include/x86-linux-any"] if zigcpu == "x86_64" else []) +
                   (["libc/include/{}-linux-any".format(zigcpu)] if zigcpu != "x86_64" else []) + [
            "libc/include/any-linux-any",
        ] + _INCLUDE_TAIL,
        linkopts = [],
        dynamic_library_linkopts = [],
        copts = ["-D_LIBCPP_HAS_MUSL_LIBC", "-D_LIBCPP_HAS_THREAD_API_PTHREAD"],
        libc = "musl",
        bazel_target_cpu = "k8",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        libc_constraint = "@zig_sdk//libc:musl",
        tool_paths = {"ld": "ld.lld"},
        artifact_name_patterns = [],
    )
