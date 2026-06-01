load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

def macro_module(name, srcs, test_srcs, test_deps = [], visibility = None, tags = []):
    swift_library(
        name = name,
        module_name = name,
        srcs = srcs,
        visibility = visibility,
    )

    swift_library(
        name = name + "TestsLib",
        module_name = name + "TestsLib",
        testonly = True,
        srcs = test_srcs,
        deps = [":" + name] + test_deps,
        tags = tags + [
            "swift_unused_deps.fix_target=%s" % name,
            "swift_unused_deps.deps_attr=test_deps",
        ],
        visibility = visibility,
    )
