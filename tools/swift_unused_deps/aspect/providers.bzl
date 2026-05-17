"""Provider definitions for swift_unused_deps aspect."""

SwiftDepsInfo = provider(
    doc = """Collected dependency metadata for a swift_library target.

    This provider carries the module-name-to-label mapping that SwiftInfo
    does not provide. Module names are read from SwiftInfo.direct_modules,
    but the Bazel label association is tracked here.
    """,
    fields = {
        "transitive_metadata_files": "Depset of metadata JSON files for this target and its transitive Swift deps.",
        "transitive_report_files": "Depset of JSON report files for this target and its transitive Swift deps.",
        "transitive_fix_high_files": "Depset of high-confidence fix JSON files for this target and its transitive Swift deps.",
        "transitive_fix_low_files": "Depset of all fix JSON files for this target and its transitive Swift deps.",
        "transitive_modules": "Depset of 'module_name=label' strings for all transitive Swift deps.",
        "direct_dep_modules": "List of module names directly provided by this target's deps (for passthrough targets like swift_library_group).",
    },
)
