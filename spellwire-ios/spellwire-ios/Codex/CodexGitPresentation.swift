import Foundation

enum CodexGitPresentation {
    static func relevantPaths(timeline: [CodexTimelineItem]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for item in timeline where item.kind == "fileChange" {
            for path in item.changedPaths ?? [] where !path.isEmpty {
                if seen.insert(path).inserted {
                    paths.append(path)
                }
            }
        }

        return paths
    }

    static func inlineActionAnchorItemID(
        timeline: [CodexTimelineItem],
        hasChanges: Bool,
        isThreadIdle: Bool
    ) -> String? {
        guard hasChanges, isThreadIdle else { return nil }
        guard let latestAgentIndex = timeline.lastIndex(where: { $0.kind == "agentMessage" }) else {
            return nil
        }
        let trailingItems = timeline.suffix(from: timeline.index(after: latestAgentIndex))
        guard trailingItems.contains(where: { $0.kind == "userMessage" }) == false else {
            return nil
        }
        return timeline[latestAgentIndex].id
    }

    static func branchWarning(preview: GitCommitPreview?) -> String? {
        preview?.warnings.first
    }
}
