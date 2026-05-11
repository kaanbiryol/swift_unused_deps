"""Public Bazel API for swift_unused_deps."""

load(
    "//tools/swift_unused_deps:rules.bzl",
    _swift_unused_deps = "swift_unused_deps",
    _swift_unused_deps_fix = "swift_unused_deps_fix",
    _swift_unused_deps_report = "swift_unused_deps_report",
    _swift_unused_deps_test = "swift_unused_deps_test",
)
load("//tools/swift_unused_deps/aspect:deps_info.bzl", _swift_deps_aspect = "swift_deps_aspect")

swift_unused_deps_aspect = _swift_deps_aspect
swift_unused_deps = _swift_unused_deps
swift_unused_deps_fix = _swift_unused_deps_fix
swift_unused_deps_report = _swift_unused_deps_report
swift_unused_deps_test = _swift_unused_deps_test
