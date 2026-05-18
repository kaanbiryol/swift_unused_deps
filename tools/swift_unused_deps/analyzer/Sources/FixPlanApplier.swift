import ArgumentParser
import Foundation

public enum FixPlanApplier {
    public struct Result {
        public let applied: Bool
        public let buildFixCount: Int
        public let sourceImportRemovalCount: Int
    }

    public static func apply(
        _ plan: FixPlan,
        workspaceDirectory: URL? = nil
    ) throws -> Result {
        guard !plan.isEmpty else {
            printErr("No fixes to apply.")
            return Result(applied: false, buildFixCount: 0, sourceImportRemovalCount: 0)
        }
        try plan.validate()

        let sourceImportEdits = try SourceImportEditor.plan(
            removals: plan.sourceImportRemovals,
            workspaceDirectory: workspaceDirectory,
            skipMissingImports: true
        )
        let effectiveSourceImportRemovals = sourceImportEdits.flatMap { edit in
            edit.removedModuleNames.sorted().map {
                SourceImportRemoval(filePath: edit.displayFilePath, moduleName: $0)
            }
        }
        let effectiveBuildEdits = plan.buildEdits.filter {
            BuildEditApplicability(edit: $0, workspaceDirectory: workspaceDirectory).shouldApply
        }
        let effectivePlan = FixPlan(
            sourceImportRemovals: effectiveSourceImportRemovals,
            buildEdits: effectiveBuildEdits
        )

        guard !effectivePlan.isEmpty else {
            printErr("No fixes to apply. The fix plan is already applied.")
            return Result(applied: false, buildFixCount: 0, sourceImportRemovalCount: 0)
        }

        printErr(FixPlan.formatSummary(effectivePlan))
        printErr("Applying \(effectiveBuildEdits.count) BUILD fix(es) and \(effectiveSourceImportRemovals.count) source import removal(s)...")

        if effectivePlan.buildozerCommands.isEmpty {
            try SourceImportEditor.apply(edits: sourceImportEdits)
            return Result(
                applied: !sourceImportEdits.isEmpty,
                buildFixCount: 0,
                sourceImportRemovalCount: effectiveSourceImportRemovals.count
            )
        }

        let result = Buildozer.runBatch(
            commands: effectivePlan.buildozerCommands,
            workingDirectory: workspaceDirectory
        )
        if result.success {
            try SourceImportEditor.apply(edits: sourceImportEdits)
            return Result(
                applied: true,
                buildFixCount: effectiveBuildEdits.count,
                sourceImportRemovalCount: effectiveSourceImportRemovals.count
            )
        } else if result.noChanges {
            printErr("WARNING: buildozer made no changes (\(effectiveBuildEdits.count) command(s) attempted).")
            printErr("The labels in the commands may not match the label format in BUILD files.")
            return Result(applied: false, buildFixCount: 0, sourceImportRemovalCount: 0)
        } else {
            printErr("FAILED: \(result.output)")
            throw ExitCode(1)
        }
    }
}

private struct BuildEditApplicability {
    let edit: BuildEdit
    let workspaceDirectory: URL?

    var shouldApply: Bool {
        guard let workspaceDirectory, let target = ParsedTargetLabel(edit.target) else {
            return true
        }
        guard let buildFile = buildFileURL(forPackage: target.package, workspaceDirectory: workspaceDirectory) else {
            return true
        }
        guard
            let content = try? String(contentsOf: buildFile, encoding: .utf8),
            let targetBlock = extractTargetBlock(named: target.name, from: content)
        else {
            return true
        }

        let sourceContainsLabel = attribute(edit.attribute, in: targetBlock, contains: edit.label, targetPackage: target.package)
        switch edit.operation {
        case .add:
            return !sourceContainsLabel
        case .remove:
            return sourceContainsLabel
        case .move:
            return sourceContainsLabel
        }
    }

    private func buildFileURL(forPackage package: String, workspaceDirectory: URL) -> URL? {
        let packageDirectory = package.isEmpty
            ? workspaceDirectory
            : workspaceDirectory.appendingPathComponent(package, isDirectory: true)
        let buildBazel = packageDirectory.appendingPathComponent("BUILD.bazel")
        if FileManager.default.fileExists(atPath: buildBazel.path) {
            return buildBazel
        }
        let build = packageDirectory.appendingPathComponent("BUILD")
        if FileManager.default.fileExists(atPath: build.path) {
            return build
        }
        return nil
    }

    private func attribute(
        _ attribute: String,
        in targetBlock: String,
        contains label: String,
        targetPackage: String
    ) -> Bool {
        guard let value = attributeValue(attribute, in: targetBlock) else {
            return false
        }
        return labelRepresentations(label, targetPackage: targetPackage).contains { representation in
            value.contains("\"\(representation)\"") || value.contains("'\(representation)'")
        }
    }

    private func labelRepresentations(_ label: String, targetPackage: String) -> [String] {
        var representations = [stripMainRepoPrefix(label)]
        let normalized = representations[0]
        let packagePrefix = "//\(targetPackage):"
        if normalized.hasPrefix(packagePrefix) {
            representations.append(":" + String(normalized.dropFirst(packagePrefix.count)))
        }
        if let packageShorthand = packageShorthandLabel(normalized) {
            representations.append(packageShorthand)
        }
        return Array(Set(representations))
    }

    private func packageShorthandLabel(_ label: String) -> String? {
        guard
            let slashSlashRange = label.range(of: "//"),
            let colonIndex = label.lastIndex(of: ":"),
            colonIndex > slashSlashRange.upperBound
        else {
            return nil
        }

        let package = label[slashSlashRange.upperBound..<colonIndex]
        guard package.split(separator: "/").last.map(String.init) == String(label[label.index(after: colonIndex)...]) else {
            return nil
        }

        return String(label[..<colonIndex])
    }

    private func stripMainRepoPrefix(_ label: String) -> String {
        if label.hasPrefix("@@//") {
            return "//" + String(label.dropFirst(4))
        }
        return label
    }

    private func extractTargetBlock(named name: String, from content: String) -> String? {
        let nameAssignment = #"name\s*=\s*""# + NSRegularExpression.escapedPattern(for: name) + #"""#
        guard
            let regex = try? NSRegularExpression(pattern: nameAssignment),
            let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
            let nameRange = Range(match.range, in: content),
            let openParen = content[..<nameRange.lowerBound].lastIndex(of: "(")
        else {
            return nil
        }

        guard let closeParen = matchingDelimiter(in: content, openingAt: openParen, open: "(", close: ")") else {
            return nil
        }
        return String(content[openParen...closeParen])
    }

    private func attributeValue(_ attribute: String, in targetBlock: String) -> String? {
        let assignment = #"\b\#(NSRegularExpression.escapedPattern(for: attribute))\s*="#
        guard
            let regex = try? NSRegularExpression(pattern: assignment),
            let match = regex.firstMatch(in: targetBlock, range: NSRange(targetBlock.startIndex..<targetBlock.endIndex, in: targetBlock)),
            let assignmentRange = Range(match.range, in: targetBlock)
        else {
            return nil
        }

        var valueStart = assignmentRange.upperBound
        while valueStart < targetBlock.endIndex, targetBlock[valueStart].isWhitespace {
            valueStart = targetBlock.index(after: valueStart)
        }

        var index = valueStart
        var bracketDepth = 0
        var braceDepth = 0
        var parenDepth = 0
        var stringDelimiter: Character?
        var previous: Character?

        while index < targetBlock.endIndex {
            let character = targetBlock[index]
            if let delimiter = stringDelimiter {
                if character == delimiter, previous != "\\" {
                    stringDelimiter = nil
                }
            } else {
                switch character {
                case "\"", "'":
                    stringDelimiter = character
                case "[":
                    bracketDepth += 1
                case "]":
                    bracketDepth = max(0, bracketDepth - 1)
                case "{":
                    braceDepth += 1
                case "}":
                    braceDepth = max(0, braceDepth - 1)
                case "(":
                    parenDepth += 1
                case ")":
                    if bracketDepth == 0, braceDepth == 0, parenDepth == 0 {
                        return String(targetBlock[valueStart..<index])
                    }
                    parenDepth = max(0, parenDepth - 1)
                case ",":
                    if bracketDepth == 0, braceDepth == 0, parenDepth == 0 {
                        return String(targetBlock[valueStart..<index])
                    }
                default:
                    break
                }
            }
            previous = character
            index = targetBlock.index(after: index)
        }

        return String(targetBlock[valueStart..<targetBlock.endIndex])
    }

    private func matchingDelimiter(
        in text: String,
        openingAt openIndex: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var index = openIndex
        var depth = 0
        var stringDelimiter: Character?
        var previous: Character?

        while index < text.endIndex {
            let character = text[index]
            if let delimiter = stringDelimiter {
                if character == delimiter, previous != "\\" {
                    stringDelimiter = nil
                }
            } else if character == "\"" || character == "'" {
                stringDelimiter = character
            } else if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            previous = character
            index = text.index(after: index)
        }

        return nil
    }
}

private struct ParsedTargetLabel {
    let package: String
    let name: String

    init?(_ label: String) {
        var normalized = label
        if normalized.hasPrefix("@@//") {
            normalized = "//" + String(normalized.dropFirst(4))
        }
        guard normalized.hasPrefix("//") else {
            return nil
        }

        let withoutPrefix = String(normalized.dropFirst(2))
        if let colonIndex = withoutPrefix.firstIndex(of: ":") {
            package = String(withoutPrefix[..<colonIndex])
            name = String(withoutPrefix[withoutPrefix.index(after: colonIndex)...])
        } else {
            package = withoutPrefix
            name = withoutPrefix.split(separator: "/").last.map(String.init) ?? ""
        }

        guard !name.isEmpty else {
            return nil
        }
    }
}
