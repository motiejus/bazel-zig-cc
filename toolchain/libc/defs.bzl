# Copyright 2023 Uber Technologies, Inc.
# Licensed under the Apache License, Version 2.0

load("@bazel-zig-cc//toolchain/private:defs.bzl", "LIBCS")

def declare_libcs(macos_sdk_versions):
    for libc in LIBCS + ["macos." + v for v in macos_sdk_versions]:
        native.constraint_value(
            name = libc,
            constraint_setting = "variant",
        )
