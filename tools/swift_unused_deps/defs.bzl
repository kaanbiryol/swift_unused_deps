"""Public Bazel API for swift_unused_deps."""

load("//tools/swift_unused_deps/aspect:deps_info.bzl", _swift_deps_aspect = "swift_deps_aspect")

swift_unused_deps_aspect = _swift_deps_aspect
