"""Bazel-native rules for swift_unused_deps."""

load("//tools/swift_unused_deps/aspect:deps_info.bzl", "swift_deps_aspect")
load("//tools/swift_unused_deps/aspect:providers.bzl", "SwiftDepsInfo")

_CONFIDENCE_VALUES = ["low", "high"]

SwiftUnusedDepsReportInfo = provider(
    doc = "Merged swift_unused_deps report and fix artifacts.",
    fields = {
        "report_json": "Merged JSON report file.",
        "report_text": "Merged text report file.",
        "fix_json": "Merged fix plan file.",
        "exit_code": "File containing the report exit code.",
    },
)

def _collect_swift_unused_deps_outputs(targets):
    report_sets = []
    fix_high_sets = []
    fix_low_sets = []
    metadata_sets = []

    for target in targets:
        if SwiftDepsInfo not in target:
            continue

        info = target[SwiftDepsInfo]
        report_sets.append(info.transitive_report_files)
        fix_high_sets.append(info.transitive_fix_high_files)
        fix_low_sets.append(info.transitive_fix_low_files)
        metadata_sets.append(info.transitive_metadata_files)

    return struct(
        reports = depset(transitive = report_sets),
        fix_high = depset(transitive = fix_high_sets),
        fix_low = depset(transitive = fix_low_sets),
        metadata = depset(transitive = metadata_sets),
    )

def _merged_outputs(ctx):
    return struct(
        report_json = ctx.actions.declare_file(ctx.label.name + ".swift_unused_deps.report.json"),
        report_text = ctx.actions.declare_file(ctx.label.name + ".swift_unused_deps.report.txt"),
        fix_json = ctx.actions.declare_file(ctx.label.name + ".swift_unused_deps.fix.json"),
        exit_code = ctx.actions.declare_file(ctx.label.name + ".swift_unused_deps.exit_code"),
    )

def _run_merge_action(ctx, outputs, collected):
    fix_files = collected.fix_low if ctx.attr.include_low_confidence_fixes else collected.fix_high

    args = ctx.actions.args()
    args.add("merge-reports")
    args.add("--min-report-confidence")
    args.add(ctx.attr.min_report_confidence)
    args.add_all(collected.reports, before_each = "--report-input")
    args.add_all(fix_files, before_each = "--fix-input")
    args.add("--report-output")
    args.add(outputs.report_json)
    args.add("--text-output")
    args.add(outputs.report_text)
    args.add("--fix-output")
    args.add(outputs.fix_json)
    args.add("--exit-code-output")
    args.add(outputs.exit_code)

    ctx.actions.run(
        executable = ctx.executable._swift_unused_deps,
        arguments = [args],
        inputs = depset(transitive = [collected.reports, fix_files]),
        outputs = [
            outputs.report_json,
            outputs.report_text,
            outputs.fix_json,
            outputs.exit_code,
        ],
        mnemonic = "SwiftUnusedDepsMergeReports",
        progress_message = "Merging swift_unused_deps reports for %s" % ctx.label,
    )

def _output_groups(outputs, collected):
    return OutputGroupInfo(
        swift_unused_deps_merged_report = depset([
            outputs.report_json,
            outputs.report_text,
        ]),
        swift_unused_deps_merged_fix = depset([outputs.fix_json]),
        swift_unused_deps_merged_exit_code = depset([outputs.exit_code]),
        swift_unused_deps_reports = collected.reports,
        swift_unused_deps_fix_high = collected.fix_high,
        swift_unused_deps_fix_low = collected.fix_low,
        swift_unused_deps_metadata = collected.metadata,
    )

def _report_info(outputs):
    return SwiftUnusedDepsReportInfo(
        report_json = outputs.report_json,
        report_text = outputs.report_text,
        fix_json = outputs.fix_json,
        exit_code = outputs.exit_code,
    )

def _runfiles_prelude(strict):
    strict_line = "set -euo pipefail" if strict else "set -u"
    return """#!/usr/bin/env bash
%s

if [[ -z "${RUNFILES_DIR:-}" && -d "$0.runfiles" ]]; then
  export RUNFILES_DIR="$0.runfiles"
fi

resolve_runfile() {
  local path="$1"
  if [[ -n "${RUNFILES_DIR:-}" && -n "${TEST_WORKSPACE:-}" && -e "${RUNFILES_DIR}/${TEST_WORKSPACE}/${path}" ]]; then
    printf '%%s\\n' "${RUNFILES_DIR}/${TEST_WORKSPACE}/${path}"
    return 0
  fi
  if [[ -n "${RUNFILES_DIR:-}" && -e "${RUNFILES_DIR}/_main/${path}" ]]; then
    printf '%%s\\n' "${RUNFILES_DIR}/_main/${path}"
    return 0
  fi
  if [[ -n "${RUNFILES_DIR:-}" && -e "${RUNFILES_DIR}/${path}" ]]; then
    printf '%%s\\n' "${RUNFILES_DIR}/${path}"
    return 0
  fi
  if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" && -e "${TEST_SRCDIR}/${TEST_WORKSPACE}/${path}" ]]; then
    printf '%%s\\n' "${TEST_SRCDIR}/${TEST_WORKSPACE}/${path}"
    return 0
  fi
  if [[ -n "${TEST_WORKSPACE:-}" && -e "$0.runfiles/${TEST_WORKSPACE}/${path}" ]]; then
    printf '%%s\\n' "$0.runfiles/${TEST_WORKSPACE}/${path}"
    return 0
  fi
  if [[ -e "$0.runfiles/_main/${path}" ]]; then
    printf '%%s\\n' "$0.runfiles/_main/${path}"
    return 0
  fi
  if [[ -e "${path}" ]]; then
    printf '%%s\\n' "${path}"
    return 0
  fi
  printf '%%s\\n' "${path}"
}
""" % strict_line

def _swift_unused_deps_report_impl(ctx):
    collected = _collect_swift_unused_deps_outputs(ctx.attr.targets)
    outputs = _merged_outputs(ctx)
    _run_merge_action(ctx, outputs, collected)

    return [
        DefaultInfo(files = depset([
            outputs.report_json,
            outputs.report_text,
            outputs.fix_json,
            outputs.exit_code,
        ])),
        _report_info(outputs),
        _output_groups(outputs, collected),
    ]

def _swift_unused_deps_test_impl(ctx):
    collected = _collect_swift_unused_deps_outputs(ctx.attr.targets)
    outputs = _merged_outputs(ctx)
    _run_merge_action(ctx, outputs, collected)

    executable = ctx.actions.declare_file(ctx.label.name + "_test.sh")
    ctx.actions.write(
        output = executable,
        is_executable = True,
        content = _runfiles_prelude(strict = False) + """
report="$(resolve_runfile "%s")"
exit_code_file="$(resolve_runfile "%s")"

cat "${report}"
exit "$(cat "${exit_code_file}")"
""" % (outputs.report_text.short_path, outputs.exit_code.short_path),
    )

    runfiles = ctx.runfiles(files = [
        outputs.report_json,
        outputs.report_text,
        outputs.fix_json,
        outputs.exit_code,
    ])

    return [
        DefaultInfo(
            executable = executable,
            files = depset([
                outputs.report_json,
                outputs.report_text,
                outputs.fix_json,
                outputs.exit_code,
            ]),
            runfiles = runfiles,
        ),
        _report_info(outputs),
        _output_groups(outputs, collected),
    ]

def _swift_unused_deps_fix_impl(ctx):
    report = ctx.attr.report[SwiftUnusedDepsReportInfo]
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    apply_executable = ctx.executable._swift_unused_deps_apply

    ctx.actions.write(
        output = executable,
        is_executable = True,
        content = _runfiles_prelude(strict = True) + """
apply_bin="$(resolve_runfile "%s")"
fix_plan="$(resolve_runfile "%s")"

exec "${apply_bin}" "${fix_plan}"
""" % (apply_executable.short_path, report.fix_json.short_path),
    )

    runfiles = ctx.runfiles(files = [
        apply_executable,
        report.fix_json,
    ]).merge(ctx.attr._swift_unused_deps_apply[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
    ]

_COMMON_ATTRS = {
    "targets": attr.label_list(
        aspects = [swift_deps_aspect],
        doc = "Top-level targets whose Swift dependency closure should be analyzed.",
    ),
    "min_report_confidence": attr.string(
        default = "low",
        values = _CONFIDENCE_VALUES,
        doc = "Minimum confidence level that is reported and causes tests to fail.",
    ),
    "include_low_confidence_fixes": attr.bool(
        default = False,
        doc = "Include low-confidence fixes in the merged fix plan.",
    ),
    "_swift_unused_deps": attr.label(
        default = Label("//tools/swift_unused_deps/analyzer:swift_unused_deps"),
        executable = True,
        cfg = "exec",
    ),
}

swift_unused_deps_report = rule(
    implementation = _swift_unused_deps_report_impl,
    attrs = _COMMON_ATTRS,
    doc = "Merges swift_unused_deps aspect outputs into report and fix-plan artifacts.",
)

swift_unused_deps_test = rule(
    implementation = _swift_unused_deps_test_impl,
    attrs = _COMMON_ATTRS,
    doc = "Fails when swift_unused_deps reports issues at or above the configured confidence.",
    test = True,
)

swift_unused_deps_fix = rule(
    implementation = _swift_unused_deps_fix_impl,
    attrs = {
        "report": attr.label(
            providers = [SwiftUnusedDepsReportInfo],
            doc = "A swift_unused_deps_report target whose fix plan should be applied.",
        ),
        "_swift_unused_deps_apply": attr.label(
            default = Label("//tools/swift_unused_deps/analyzer:swift_unused_deps_apply"),
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Applies a merged swift_unused_deps fix plan via bazel run.",
    executable = True,
)

def _target_kwargs(visibility = None, tags = None):
    kwargs = {}
    if visibility != None:
        kwargs["visibility"] = visibility
    if tags != None:
        kwargs["tags"] = tags
    return kwargs

def swift_unused_deps(
        name,
        targets,
        min_report_confidence = "low",
        include_low_confidence_fixes = False,
        visibility = None,
        tags = None,
        test_tags = None,
        report_tags = None,
        fix_tags = None):
    """Creates check, report, and fix targets for Swift unused dependency analysis.

    Given name = "swift_unused_deps", this macro creates:
      - :swift_unused_deps, a bazel test target
      - :swift_unused_deps_report, a bazel build target that emits merged artifacts
      - :swift_unused_deps_fix, a bazel run target that applies the merged fix plan

    Args:
      name: Name of the generated test target.
      targets: Top-level Bazel targets whose Swift dependency closure should be analyzed.
      min_report_confidence: Minimum confidence level to report and fail the test on.
      include_low_confidence_fixes: Include low-confidence fixes in the generated fix plan.
      visibility: Optional visibility applied to all generated targets.
      tags: Optional tags applied to all generated targets unless target-specific tags are set.
      test_tags: Optional tags for the generated test target.
      report_tags: Optional tags for the generated report target.
      fix_tags: Optional tags for the generated fix target.
    """
    report_name = name + "_report"

    swift_unused_deps_report(
        name = report_name,
        targets = targets,
        min_report_confidence = min_report_confidence,
        include_low_confidence_fixes = include_low_confidence_fixes,
        **_target_kwargs(
            visibility = visibility,
            tags = report_tags if report_tags != None else tags,
        )
    )

    swift_unused_deps_test(
        name = name,
        targets = targets,
        min_report_confidence = min_report_confidence,
        include_low_confidence_fixes = include_low_confidence_fixes,
        **_target_kwargs(
            visibility = visibility,
            tags = test_tags if test_tags != None else tags,
        )
    )

    swift_unused_deps_fix(
        name = name + "_fix",
        report = ":" + report_name,
        **_target_kwargs(
            visibility = visibility,
            tags = fix_tags if fix_tags != None else tags,
        )
    )
