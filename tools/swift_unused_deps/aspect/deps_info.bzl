"""Bazel aspect for detecting unused Swift dependencies.

Propagates through dependency-like attributes of Swift and test aggregation
targets and emits per-target metadata for analysis.

The public swift_unused_deps macro wires this aspect into Bazel-native report,
test, and fix targets.
"""

load("@build_bazel_rules_swift//swift:providers.bzl", "SwiftInfo")
load(":providers.bzl", "SwiftDepsInfo")

_DEPS_ATTR_TAG_PREFIX = "swift_unused_deps.deps_attr="
_FIX_TARGET_TAG_PREFIX = "swift_unused_deps.fix_target="
_NON_REMOVABLE_DEP_TAG_PREFIX = "swift_unused_deps.non_removable_dep="
_IDENTIFIER_START_CHARS = "_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
_IDENTIFIER_CHARS = _IDENTIFIER_START_CHARS + "0123456789"
_SIMPLE_TARGET_NAME_CHARS = _IDENTIFIER_CHARS + ".+-"

def _label_string(label):
    value = str(label)
    if value.startswith("@@//"):
        return value[2:]
    return value

def _tag_value(tags, prefix):
    result = None
    for tag in tags:
        if not tag.startswith(prefix):
            continue
        value = tag[len(prefix):]
        if not value:
            fail("Tag '{}' must include a value.".format(prefix[:-1]))
        if result != None and result != value:
            fail("Conflicting '{}' tags: '{}' and '{}'.".format(prefix[:-1], result, value))
        result = value
    return result

def _tag_values(tags, prefix):
    result = []
    for tag in tags:
        if not tag.startswith(prefix):
            continue
        value = tag[len(prefix):]
        if not value:
            fail("Tag '{}' must include a value.".format(prefix[:-1]))
        if value not in result:
            result.append(value)
    return result

def _is_valid_identifier(value):
    if not value or value[0] not in _IDENTIFIER_START_CHARS:
        return False
    for i in range(len(value)):
        if value[i] not in _IDENTIFIER_CHARS:
            return False
    return True

def _is_simple_target_name(value):
    if not value:
        return False
    for i in range(len(value)):
        if value[i] not in _SIMPLE_TARGET_NAME_CHARS:
            return False
    return True

def _same_package_label(analyzed_label, target_name):
    package_label = analyzed_label.split(":")[0]
    return "{}:{}".format(package_label, target_name)

def _dependency_label(analyzed_label, value):
    if value.startswith(":"):
        return analyzed_label.split(":")[0] + value
    if _is_simple_target_name(value):
        return _same_package_label(analyzed_label, value)
    if value.startswith("//") or (value.startswith("@") and "//" in value):
        return value
    fail(
        "Invalid swift_unused_deps.non_removable_dep value '{}' on {}. Use a same-package target name or a Bazel label.".format(
            value,
            analyzed_label,
        ),
    )

def _build_edit_metadata(ctx):
    analyzed_label = _label_string(ctx.label)
    tags = ctx.rule.attr.tags if hasattr(ctx.rule.attr, "tags") else []

    fix_target_name = _tag_value(tags, _FIX_TARGET_TAG_PREFIX)
    if fix_target_name != None:
        if not _is_simple_target_name(fix_target_name):
            fail(
                "Invalid swift_unused_deps.fix_target value '{}' on {}. Use a simple same-package target name.".format(
                    fix_target_name,
                    analyzed_label,
                ),
            )
        fix_target = _same_package_label(analyzed_label, fix_target_name)
    else:
        fix_target = analyzed_label

    deps_attr = _tag_value(tags, _DEPS_ATTR_TAG_PREFIX) or "deps"
    if not _is_valid_identifier(deps_attr):
        fail(
            "Invalid swift_unused_deps.deps_attr value '{}' on {}. Use a valid Bazel attribute identifier.".format(
                deps_attr,
                analyzed_label,
            ),
        )

    non_removable_deps = [
        _dependency_label(analyzed_label, value)
        for value in _tag_values(tags, _NON_REMOVABLE_DEP_TAG_PREFIX)
    ]

    return {
        "target": fix_target,
        "deps_attr": deps_attr,
        "non_removable_deps": sorted(non_removable_deps),
    }

def _get_module_name(target):
    """Get the Swift module name from SwiftInfo."""
    for module in target[SwiftInfo].direct_modules:
        if module.swift:
            return module.name
    return None

def _get_swiftmodule_file(target):
    """Get the .swiftmodule File from SwiftInfo."""
    for module in target[SwiftInfo].direct_modules:
        if module.swift:
            return module.swift.swiftmodule
    return None

def _get_indexstore_directory(target):
    """Get the declared indexstore directory from SwiftInfo if available."""
    for module in target[SwiftInfo].direct_modules:
        if module.swift:
            return getattr(module.swift, "indexstore", None)
    return None

def _has_mixed_sources(ctx):
    has_swift = False
    has_other = False
    if hasattr(ctx.rule.attr, "srcs"):
        for src in ctx.rule.attr.srcs:
            for f in src.files.to_list():
                if f.extension == "swift":
                    has_swift = True
                elif f.extension in ["m", "mm", "c", "cc", "cpp"]:
                    has_other = True
    return has_swift and has_other

def _get_dep_module_name(dep):
    if SwiftInfo not in dep:
        return None
    for module in dep[SwiftInfo].direct_modules:
        if module.swift:
            return module.name
    return None

def _dep_info_entries(dep, kind):
    """Return declared dep info entries from a dependency.

    Returns a list of dep info dicts. For normal swift_library targets this
    is a single-element list. For aggregation targets like swift_library_group
    (which have SwiftInfo but no direct module), the direct child modules
    are used with the group's own label.
    """
    module_name = _get_dep_module_name(dep)
    if module_name:
        return [{"label": _label_string(dep.label), "module_name": module_name, "kind": kind}]

    # Target has no direct Swift module (e.g. swift_library_group).
    # Use the group's direct child modules with the group's own label.
    if SwiftDepsInfo in dep and dep[SwiftDepsInfo].direct_dep_modules:
        result = []
        for mod_name in dep[SwiftDepsInfo].direct_dep_modules:
            result.append({"label": _label_string(dep.label), "module_name": mod_name, "kind": kind})
        return result

    return []

def _transitive_modules(deps, private_deps, plugins = []):
    modules = {}
    for dep in list(deps) + list(private_deps) + list(plugins):
        dep_module_name = _get_dep_module_name(dep)
        if dep_module_name:
            modules[dep_module_name] = _label_string(dep.label)
        if SwiftDepsInfo in dep:
            for module_tuple in dep[SwiftDepsInfo].transitive_modules.to_list():
                mod_name, mod_label = module_tuple.split("=", 1)
                if mod_name not in modules:
                    modules[mod_name] = mod_label
    return modules

def _add_reachable_via(module_reachable_via, module_name, direct_dep_label):
    if module_name not in module_reachable_via:
        module_reachable_via[module_name] = []
    if direct_dep_label not in module_reachable_via[module_name]:
        module_reachable_via[module_name].append(direct_dep_label)

def _module_reachable_via(deps, private_deps):
    """Return module name -> direct dep labels that expose that module."""
    module_reachable_via = {}
    for dep in list(deps) + list(private_deps):
        direct_dep_label = _label_string(dep.label)
        dep_module_name = _get_dep_module_name(dep)
        if dep_module_name:
            _add_reachable_via(module_reachable_via, dep_module_name, direct_dep_label)
        if SwiftDepsInfo in dep:
            for module_tuple in dep[SwiftDepsInfo].transitive_modules.to_list():
                mod_name, _ = module_tuple.split("=", 1)
                _add_reachable_via(module_reachable_via, mod_name, direct_dep_label)
    return module_reachable_via

def _passthrough_transitive_modules(ctx):
    """Return transitive modules from deps of a non-Swift target.

    This ensures the transitive module map is not broken when a non-Swift
    target (e.g. objc_library, swift_library_group) sits between two Swift
    targets. Also records which modules are directly provided by this
    target's deps (vs deeply transitive ones).
    """
    transitive_sets = []
    transitive_metadata_sets = []
    transitive_source_sets = []
    transitive_report_sets = []
    transitive_fix_high_sets = []
    transitive_fix_low_sets = []
    direct_dep_modules = []
    direct_indexstore_sets = []
    for attr_name in ["deps", "private_deps", "plugins", "tests"]:
        if hasattr(ctx.rule.attr, attr_name):
            for dep in getattr(ctx.rule.attr, attr_name):
                if SwiftDepsInfo in dep:
                    transitive_sets.append(dep[SwiftDepsInfo].transitive_modules)
                    transitive_metadata_sets.append(dep[SwiftDepsInfo].transitive_metadata_files)
                    transitive_source_sets.append(dep[SwiftDepsInfo].transitive_source_files)
                    transitive_report_sets.append(dep[SwiftDepsInfo].transitive_report_files)
                    transitive_fix_high_sets.append(dep[SwiftDepsInfo].transitive_fix_high_files)
                    transitive_fix_low_sets.append(dep[SwiftDepsInfo].transitive_fix_low_files)
                    direct_indexstore_sets.append(dep[SwiftDepsInfo].direct_indexstore_files)

                # Record direct module names from deps that have SwiftInfo.
                if SwiftInfo in dep:
                    for module in dep[SwiftInfo].direct_modules:
                        if module.swift:
                            direct_dep_modules.append(module.name)
    if transitive_sets or transitive_metadata_sets or transitive_report_sets:
        transitive_metadata_files = depset(transitive = transitive_metadata_sets)
        transitive_source_files = depset(transitive = transitive_source_sets)
        transitive_report_files = depset(transitive = transitive_report_sets)
        transitive_fix_high_files = depset(transitive = transitive_fix_high_sets)
        transitive_fix_low_files = depset(transitive = transitive_fix_low_sets)
        return [
            SwiftDepsInfo(
                transitive_metadata_files = transitive_metadata_files,
                transitive_source_files = transitive_source_files,
                transitive_report_files = transitive_report_files,
                transitive_fix_high_files = transitive_fix_high_files,
                transitive_fix_low_files = transitive_fix_low_files,
                transitive_modules = depset(transitive = transitive_sets),
                direct_dep_modules = direct_dep_modules,
                direct_indexstore_files = depset(transitive = direct_indexstore_sets),
            ),
            OutputGroupInfo(
                swift_unused_deps_metadata = transitive_metadata_files,
                swift_unused_deps_reports = transitive_report_files,
                swift_unused_deps_fix_high = transitive_fix_high_files,
                swift_unused_deps_fix_low = transitive_fix_low_files,
            ),
        ]
    return []

def _swift_deps_aspect_impl(target, ctx):
    if SwiftInfo not in target:
        return _passthrough_transitive_modules(ctx)

    module_name = _get_module_name(target)
    if module_name == None:
        # Target has SwiftInfo but no direct Swift module (e.g. swift_library_group).
        # Still propagate transitive modules from deps.
        return _passthrough_transitive_modules(ctx)

    swiftmodule_file = _get_swiftmodule_file(target)
    indexstore_directory = _get_indexstore_directory(target)

    # Build transitive module tuples.
    self_module_tuple = "{}={}".format(module_name, _label_string(ctx.label))
    transitive_sets = [depset([self_module_tuple])]
    transitive_metadata_sets = []
    transitive_source_sets = []
    transitive_report_sets = []
    transitive_fix_high_sets = []
    transitive_fix_low_sets = []
    dependency_indexstore_sets = []
    for attr_name in ["deps", "private_deps", "plugins"]:
        if hasattr(ctx.rule.attr, attr_name):
            for dep in getattr(ctx.rule.attr, attr_name):
                if SwiftDepsInfo in dep:
                    transitive_sets.append(dep[SwiftDepsInfo].transitive_modules)
                    transitive_metadata_sets.append(dep[SwiftDepsInfo].transitive_metadata_files)
                    transitive_source_sets.append(dep[SwiftDepsInfo].transitive_source_files)
                    transitive_report_sets.append(dep[SwiftDepsInfo].transitive_report_files)
                    transitive_fix_high_sets.append(dep[SwiftDepsInfo].transitive_fix_high_files)
                    transitive_fix_low_sets.append(dep[SwiftDepsInfo].transitive_fix_low_files)
                    dependency_indexstore_sets.append(dep[SwiftDepsInfo].direct_indexstore_files)
    transitive_modules = depset(transitive = transitive_sets)
    dependency_metadata_files = depset(transitive = transitive_metadata_sets).to_list()
    dependency_source_files = depset(transitive = transitive_source_sets).to_list()
    dependency_indexstore_files = depset(transitive = dependency_indexstore_sets).to_list()

    # Record declared deps, deduplicating by module name (a module can
    # appear through multiple swift_library_group expansions).
    seen_modules = {}
    declared_deps = []
    if hasattr(ctx.rule.attr, "deps"):
        for dep in ctx.rule.attr.deps:
            for info in _dep_info_entries(dep, "dep"):
                if info["module_name"] not in seen_modules:
                    seen_modules[info["module_name"]] = True
                    declared_deps.append(info)

    declared_private_deps = []
    if hasattr(ctx.rule.attr, "private_deps"):
        for dep in ctx.rule.attr.private_deps:
            for info in _dep_info_entries(dep, "private_dep"):
                if info["module_name"] not in seen_modules:
                    seen_modules[info["module_name"]] = True
                    declared_private_deps.append(info)

    plugin_deps = []
    seen_plugin_modules = {}
    if hasattr(ctx.rule.attr, "plugins"):
        for dep in ctx.rule.attr.plugins:
            for info in _dep_info_entries(dep, "plugin"):
                if info["module_name"] not in seen_plugin_modules:
                    seen_plugin_modules[info["module_name"]] = True
                    plugin_deps.append(info)

    # Build transitive module map.
    transitive_map = _transitive_modules(
        ctx.rule.attr.deps if hasattr(ctx.rule.attr, "deps") else [],
        ctx.rule.attr.private_deps if hasattr(ctx.rule.attr, "private_deps") else [],
        ctx.rule.attr.plugins if hasattr(ctx.rule.attr, "plugins") else [],
    )
    module_reachable_via = _module_reachable_via(
        ctx.rule.attr.deps if hasattr(ctx.rule.attr, "deps") else [],
        ctx.rule.attr.private_deps if hasattr(ctx.rule.attr, "private_deps") else [],
    )

    # Record declared source paths so the analyzer action can read inputs through
    # Bazel's declared inputs instead of relying on absolute paths captured in
    # the index store.
    source_files = []
    source_inputs = []
    if hasattr(ctx.rule.attr, "srcs"):
        for src in ctx.rule.attr.srcs:
            for f in src.files.to_list():
                if f.extension == "swift":
                    source_files.append({
                        "basename": f.basename,
                        "path": f.path,
                        "short_path": f.short_path,
                        "is_generated": not f.is_source,
                    })
                    source_inputs.append(f)

    # Write metadata JSON.
    metadata = {
        "schema_version": 1,
        "target": {
            "label": _label_string(ctx.label),
            "module_name": module_name,
            "source_files": source_files,
            "is_mixed_source": _has_mixed_sources(ctx),
            "rule_kind": ctx.rule.kind,
            "build_edit": _build_edit_metadata(ctx),
        },
        "declared_deps": declared_deps + declared_private_deps,
        "plugin_deps": plugin_deps,
        "transitive_module_map": transitive_map,
        "module_reachable_via": module_reachable_via,
        "indexstore_path": indexstore_directory.short_path if indexstore_directory else "",
    }

    metadata_file = ctx.actions.declare_file(
        "{}.swift_deps_info.json".format(ctx.label.name),
    )
    report_file = ctx.actions.declare_file(
        "{}.swift_unused_deps.report.json".format(ctx.label.name),
    )
    fix_high_file = ctx.actions.declare_file(
        "{}.swift_unused_deps.fix_high.json".format(ctx.label.name),
    )
    fix_low_file = ctx.actions.declare_file(
        "{}.swift_unused_deps.fix_low.json".format(ctx.label.name),
    )
    metadata_json = json.encode(metadata)

    # Use run_shell with swiftmodule as input to ensure compilation runs
    # (needed so the index store gets populated as a side effect).
    if swiftmodule_file:
        ctx.actions.run_shell(
            inputs = [swiftmodule_file],
            outputs = [metadata_file],
            command = "cat > '{}' << 'METADATA_EOF'\n{}\nMETADATA_EOF".format(
                metadata_file.path,
                metadata_json,
            ),
            mnemonic = "SwiftDepsMetadata",
            progress_message = "Emitting deps metadata for %s" % module_name,
        )
    else:
        ctx.actions.write(
            output = metadata_file,
            content = metadata_json,
        )

    analyzer_args = ctx.actions.args()
    analyzer_args.add("analyze-target")
    analyzer_args.add("--metadata-file")
    analyzer_args.add(metadata_file)
    analyzer_args.add_all(dependency_metadata_files, before_each = "--dependency-metadata-file")
    analyzer_args.add("--bazel-bin")
    analyzer_args.add(".")
    if indexstore_directory:
        analyzer_args.add("--index-store-path")
        analyzer_args.add(indexstore_directory.path)
    for dependency_indexstore in dependency_indexstore_files:
        analyzer_args.add("--dependency-index-store-path")
        analyzer_args.add(dependency_indexstore.path)
    analyzer_args.add("--report-output")
    analyzer_args.add(report_file)
    analyzer_args.add("--fix-output")
    analyzer_args.add(fix_high_file)
    analyzer_args.add("--fix-low-output")
    analyzer_args.add(fix_low_file)

    analyzer_inputs = [metadata_file] + source_inputs + dependency_metadata_files + dependency_source_files
    if indexstore_directory:
        analyzer_inputs.append(indexstore_directory)
    analyzer_inputs.extend(dependency_indexstore_files)

    ctx.actions.run(
        executable = ctx.executable._analyzer,
        arguments = [analyzer_args],
        inputs = analyzer_inputs,
        outputs = [report_file, fix_high_file, fix_low_file],
        mnemonic = "SwiftUnusedDepsAnalyzeTarget",
        progress_message = "Analyzing unused deps for %s" % module_name,
    )

    transitive_metadata_files = depset([metadata_file], transitive = transitive_metadata_sets)
    transitive_source_files = depset(source_inputs, transitive = transitive_source_sets)
    transitive_report_files = depset([report_file], transitive = transitive_report_sets)
    transitive_fix_high_files = depset([fix_high_file], transitive = transitive_fix_high_sets)
    transitive_fix_low_files = depset([fix_low_file], transitive = transitive_fix_low_sets)
    direct_indexstore_files = depset([indexstore_directory] if indexstore_directory else [])

    return [
        SwiftDepsInfo(
            transitive_metadata_files = transitive_metadata_files,
            transitive_source_files = transitive_source_files,
            transitive_report_files = transitive_report_files,
            transitive_fix_high_files = transitive_fix_high_files,
            transitive_fix_low_files = transitive_fix_low_files,
            transitive_modules = transitive_modules,
            direct_dep_modules = [],
            direct_indexstore_files = direct_indexstore_files,
        ),
        OutputGroupInfo(
            swift_unused_deps_metadata = transitive_metadata_files,
            swift_unused_deps_reports = transitive_report_files,
            swift_unused_deps_fix_high = transitive_fix_high_files,
            swift_unused_deps_fix_low = transitive_fix_low_files,
        ),
    ]

swift_deps_aspect = aspect(
    implementation = _swift_deps_aspect_impl,
    doc = """Detects unused Swift dependencies.

    Produces per-target metadata files as Bazel outputs.

    For Bazel-first analysis workflows, request swift_unused_deps_metadata.
    """,
    attr_aspects = ["deps", "private_deps", "plugins", "tests"],
    attrs = {
        "_analyzer": attr.label(
            default = Label("//tools/swift_unused_deps/analyzer:swift_unused_deps"),
            executable = True,
            cfg = "exec",
        ),
    },
)
