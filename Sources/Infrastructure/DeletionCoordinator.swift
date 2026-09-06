// MARK: - DeletionCoordinator
// 删除前的最后一道复核：重新读取 PhotoKit 元数据、keep 保护和当前特征，
// 再把用户选择与算法建议分开校验。协调器不执行静默删除，实际请求仍由
// PhotoLibraryServiceProtocol 交给系统确认框。

import Foundation

final class DeletionCoordinator {
    private let photoLibrary: PhotoLibraryServiceProtocol
    private let database: PhotoLibraryDatabase

    init(photoLibrary: PhotoLibraryServiceProtocol, database: PhotoLibraryDatabase) {
        self.photoLibrary = photoLibrary
        self.database = database
    }

    func preflight(
        selections: [DeletionSelection],
        groups: [ScoredGroup]
    ) -> DeletionPreflightResult {
        let normalized = normalizedSelections(selections)
        guard !normalized.isEmpty else {
            return DeletionPreflightResult(approvedIDs: [], blocked: [], safetyDataAvailable: true)
        }

        guard case .success(let keepIDs) = database.assetIDsResult(withVerdict: .keep) else {
            return DeletionPreflightResult(
                approvedIDs: [],
                blocked: normalized.map {
                    DeletionPreflightIssue(
                        assetID: $0.assetID,
                        source: $0.source,
                        reason: .safetyDataUnavailable
                    )
                },
                safetyDataAvailable: false
            )
        }

        let requestedIDs = normalized.map(\.assetID)
        let latestRecords = Dictionary(
            photoLibrary.fetchAssets(matching: requestedIDs).map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let hashes = database.allFeatureprintHashes(featureVersion: ScanStateMachine.featureVersion)
        let embeddings = database.allFeatureprintEmbeddings(featureVersion: ScanStateMachine.featureVersion)
        let selectedIDs = Set(requestedIDs)

        var groupByID: [String: [ScoredMember]] = [:]
        for group in groups {
            for member in group.members {
                groupByID[member.record.localIdentifier] = group.members
            }
        }

        var approved: [String] = []
        var blocked: [DeletionPreflightIssue] = []
        for selection in normalized {
            guard let record = latestRecords[selection.assetID] else {
                blocked.append(issue(selection, reason: .unavailable))
                continue
            }
            guard SafetyRules.canUserRequestDelete(
                asset: record,
                userKept: keepIDs.contains(record.localIdentifier)
            ) else {
                let reason: SuggestionBlockReason
                if keepIDs.contains(record.localIdentifier) {
                    reason = .userKept
                } else if record.favorite {
                    reason = .favorite
                } else {
                    reason = .edited
                }
                blocked.append(issue(selection, reason: reason))
                continue
            }

            guard selection.source == .suggestion else {
                approved.append(selection.assetID)
                continue
            }

            guard record.mediaType == .image, !record.isLivePhoto else {
                blocked.append(issue(selection, reason: .unsupportedDynamicMedia))
                continue
            }
            guard let rawMembers = groupByID[selection.assetID], !rawMembers.isEmpty else {
                blocked.append(issue(selection, reason: .noDirectReplacement))
                continue
            }
            // A persisted group can outlive one of its members.  Do not fall
            // back to the stale record: a missing replacement invalidates the
            // suggestion until the group is rescanned.
            guard rawMembers.allSatisfy({ latestRecords[$0.record.localIdentifier] != nil }) else {
                blocked.append(issue(selection, reason: .noDirectReplacement))
                continue
            }
            let members = rawMembers.map { member in
                ScoredMember(
                    record: latestRecords[member.record.localIdentifier]!,
                    score: member.score,
                    isBestShot: member.isBestShot
                )
            }
            let hasFeature = members.contains { member in
                hashes[member.record.localIdentifier] != nil
                    || embeddings[member.record.localIdentifier] != nil
            }
            guard hasFeature else {
                blocked.append(issue(selection, reason: .missingFeature))
                continue
            }
            let currentSuggestions = GroupScoring.preselectableIDs(
                for: members,
                hashByID: hashes,
                embeddingByID: embeddings,
                protectedIDs: keepIDs,
                selectedIDs: selectedIDs
            )
            guard currentSuggestions.contains(selection.assetID) else {
                blocked.append(issue(selection, reason: .noDirectReplacement))
                continue
            }
            approved.append(selection.assetID)
        }

        return DeletionPreflightResult(
            approvedIDs: approved,
            blocked: blocked,
            safetyDataAvailable: true
        )
    }

    func execute(
        selections: [DeletionSelection],
        groups: [ScoredGroup],
        completion: @escaping (DeletionPreflightResult, DeletionRequestResult?) -> Void
    ) {
        let preflight = preflight(selections: selections, groups: groups)
        guard !preflight.approvedIDs.isEmpty else {
            completion(preflight, nil)
            return
        }
        photoLibrary.requestDeleteDetailed(of: preflight.approvedIDs) { result in
            completion(preflight, result)
        }
    }

    private func normalizedSelections(_ selections: [DeletionSelection]) -> [DeletionSelection] {
        var sourceByID: [String: DeletionSelectionSource] = [:]
        var order: [String] = []
        for selection in selections where !selection.assetID.isEmpty {
            if sourceByID[selection.assetID] == nil {
                order.append(selection.assetID)
                sourceByID[selection.assetID] = selection.source
            } else if selection.source == .user {
                // 明确逐张选择优先于“全选建议”来源，但仍经过相同的
                // 收藏/编辑/keep 最终校验。
                sourceByID[selection.assetID] = .user
            }
        }
        return order.compactMap { id in
            sourceByID[id].map { DeletionSelection(assetID: id, source: $0) }
        }
    }

    private func issue(
        _ selection: DeletionSelection,
        reason: SuggestionBlockReason
    ) -> DeletionPreflightIssue {
        DeletionPreflightIssue(assetID: selection.assetID, source: selection.source, reason: reason)
    }
}
