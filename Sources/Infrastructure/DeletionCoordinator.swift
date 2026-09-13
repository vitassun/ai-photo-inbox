// MARK: - DeletionCoordinator
// 删除前的最后一道复核：重新读取 PhotoKit 元数据、keep 保护和当前特征，
// 再把用户选择与算法建议分开校验。协调器不执行静默删除，实际请求仍由
// PhotoLibraryServiceProtocol 交给系统确认框。
//
// 分批职责（T10 补充验收）：**协调器**掌握分批顺序，服务只负责提交"当前这一批"
// 并回传系统结果。这样每一批提交前都能重新做一次安全复核——用户可能在两批之间
// 收藏/编辑/保留某项，或删掉了某组的替代品，这些变化必须在下一批生效前被拦住。

import Foundation

/// 一批在提交前重新复核后的结果。
struct DeletionBatchPlan {
    /// 本批最终可提交的 id（已通过重新复核）。
    let approvedIDs: [String]
    /// 复核后移出本批的项目及原因。
    let blocked: [DeletionPreflightIssue]
}

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

        // 全量复核时，整批选择本身构成"计划删除集合"：校验某项的替代关系时，
        // 同批的其他选择不能被当作最终保留项（因为它们也会被删掉）。
        let plannedDeletionIDs = Set(normalized.map(\.assetID))
        return validate(
            normalized: normalized,
            groups: groups,
            keepIDs: keepIDs,
            plannedDeletionIDs: plannedDeletionIDs,
            previouslyApprovedIDs: []
        )
    }

    /// 核心复核。参数语义（T10 补充验收的关键）：
    /// - `plannedDeletionIDs`：**后续仍计划删除**的资产。校验替代关系时，
    ///   这些 id 不能算作候选的替代品——它们同样会被删除。
    /// - `previouslyApprovedIDs`：**本次已批准删除**的资产。它们已从相册消失，
    ///   既不能再当替代品，也不该因为"组内成员没了"就让后续批次整组失效。
    private func validate(
        normalized: [DeletionSelection],
        groups: [ScoredGroup],
        keepIDs: Set<String>,
        plannedDeletionIDs: Set<String>,
        previouslyApprovedIDs: Set<String>
    ) -> DeletionPreflightResult {
        let requestedIDs = normalized.map(\.assetID)
        // 需要刷新的 id：本批选择 + 组内成员。已批准删除的成员不必再查
        // （它们已经不在相册里，查了也只会缺席，从而误判成"替代品消失"）。
        let groupMemberIDs = groups.flatMap { $0.members.map { $0.record.localIdentifier } }
        let idsToRefresh = Set(requestedIDs + groupMemberIDs)
            .subtracting(previouslyApprovedIDs)
        let latestRecords = Dictionary(
            photoLibrary.fetchAssets(matching: Array(idsToRefresh)).map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let validAssetVersions = Dictionary(
            uniqueKeysWithValues: latestRecords.map {
                ($0.key, $0.value.modificationDate)
            }
        )
        let hashes = database.allFeatureprintHashes(
            featureVersion: ScanStateMachine.featureVersion,
            validAssetVersions: validAssetVersions
        )
        let embeddings = database.allFeatureprintEmbeddings(
            featureVersion: ScanStateMachine.featureVersion,
            validAssetVersions: validAssetVersions
        )
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
                // 本批里查不到：可能是「本次已批准删除」（属预期，静默跳过而非报错），
                // 也可能是外部变更导致真的消失了（必须让用户知道）。
                if previouslyApprovedIDs.contains(selection.assetID) { continue }
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
            // A persisted group can outlive one of its members. Do not fall
            // back to the stale record: a missing replacement invalidates the
            // suggestion until the group is rescanned.
            //
            // 例外：本批之前已批准删除的成员不算"缺失"——那是我们自己的删除
            // 造成的，不能因此把后续批次整组判死。只有**外部变更**导致的缺席
            // 才阻止提交。
            let missingMembers = rawMembers.filter { member in
                let id = member.record.localIdentifier
                if previouslyApprovedIDs.contains(id) { return false }
                return latestRecords[id] == nil
            }
            guard missingMembers.isEmpty else {
                blocked.append(issue(selection, reason: .noDirectReplacement))
                continue
            }
            // 用最新元数据重建成员；已批准删除的成员直接排除（它们不再是替代品）。
            let members = rawMembers.compactMap { member -> ScoredMember? in
                let id = member.record.localIdentifier
                if previouslyApprovedIDs.contains(id) { return nil }
                guard let latest = latestRecords[id] else { return nil }
                return ScoredMember(record: latest, score: member.score, isBestShot: member.isBestShot)
            }
            let hasFeature = members.contains { member in
                hashes[member.record.localIdentifier] != nil
                    || embeddings[member.record.localIdentifier] != nil
            }
            guard hasFeature else {
                blocked.append(issue(selection, reason: .missingFeature))
                continue
            }
            // Validate this candidate against the final selection set while
            // leaving the candidate itself out of that set. Otherwise the
            // safety helper quite correctly excludes every selected id and
            // the preflight would reject the very suggestions the user chose.
            //
            // 同时排除"后续计划删除"的 id：它们不会留下来当替代品。
            let otherSelectedIDs = plannedDeletionIDs
                .subtracting([selection.assetID])
                .union(previouslyApprovedIDs)
            let currentSuggestions = GroupScoring.preselectableIDs(
                for: members,
                hashByID: hashes,
                embeddingByID: embeddings,
                protectedIDs: keepIDs,
                selectedIDs: otherSelectedIDs
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

    /// 分批执行删除。**协调器掌握分批顺序**，服务只提交当前这一批。
    ///
    /// 逐批协议（T10 补充验收）：
    /// 1. 提交前重新读取收藏/编辑/保留决定/资产修改版本/替代资产；
    /// 2. 已被保护或失去替代品的项目移出本批并回报具体原因；
    /// 3. 安全数据读取失败 → **停止提交**（不降级、不猜测）；
    /// 4. 当前批取消或失败 → 停止后续批次，已成功的批次结果照常保留。
    func execute(
        selections: [DeletionSelection],
        groups: [ScoredGroup],
        completion: @escaping (DeletionPreflightResult, DeletionRequestResult?) -> Void
    ) {
        let normalized = normalizedSelections(selections)
        guard !normalized.isEmpty else {
            completion(
                DeletionPreflightResult(approvedIDs: [], blocked: [], safetyDataAvailable: true),
                nil
            )
            return
        }

        let plannedDeletionIDs = Set(normalized.map(\.assetID))
        let orderedIDs = normalized.map(\.assetID)
        let sourceByID = Dictionary(
            normalized.map { ($0.assetID, $0.source) },
            uniquingKeysWith: { first, _ in first }
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var batchResults: [DeletionBatchResult] = []
            var allApproved: [String] = []
            var allBlocked: [DeletionPreflightIssue] = []
            var safetyDataAvailable = true
            var stopped = false

            // 每批提交前重新复核。批的大小沿用 DeletionFlow.maxBatchSize，
            // 但切批与推进由协调器决定。
            let batches = DeletionFlow.batches(of: orderedIDs)
            for (index, batchIDs) in batches.enumerated() {
                if stopped {
                    batchResults.append(DeletionBatchResult(
                        batchIndex: index,
                        requestedIDs: batchIDs,
                        approvedIDs: [],
                        status: .skipped,
                        reason: "前一批次未完成"
                    ))
                    continue
                }

                let batchSelections = batchIDs.map { id in
                    DeletionSelection(assetID: id, source: sourceByID[id] ?? .user)
                }
                // 本批复核：已批准删除的 id 传入 previouslyApprovedIDs，
                // 避免它们被当成"消失的替代品"而误伤后续批次。
                let batchPreflight = self.validate(
                    normalized: batchSelections,
                    groups: groups,
                    keepIDs: self.currentKeepIDs() ?? [],
                    plannedDeletionIDs: plannedDeletionIDs,
                    previouslyApprovedIDs: Set(allApproved)
                )
                allBlocked.append(contentsOf: batchPreflight.blocked)

                guard batchPreflight.safetyDataAvailable else {
                    // 安全数据读不到就停止提交，绝不带病继续后续批次。
                    safetyDataAvailable = false
                    stopped = true
                    continue
                }
                guard !batchPreflight.approvedIDs.isEmpty else {
                    // 本批全部被拦下（保护或失去替代品）：记录原因但继续下一批，
                    // 因为后续批次的其他组可能仍然安全。
                    continue
                }

                let result = self.submitBatch(
                    batchPreflight.approvedIDs,
                    batchIndex: index,
                    requestedIDs: batchIDs
                )
                batchResults.append(result)
                allApproved.append(contentsOf: result.approvedIDs)
                if result.status != .approved {
                    // 取消或失败：保留已成功批次，停止后续提交。
                    stopped = true
                }
            }

            let preflight = DeletionPreflightResult(
                approvedIDs: allApproved,
                blocked: allBlocked,
                safetyDataAvailable: safetyDataAvailable
            )
            let requestResult = batchResults.isEmpty
                ? nil
                : DeletionRequestResult(batches: batchResults)
            DispatchQueue.main.async {
                completion(preflight, requestResult)
            }
        }
    }

    /// 读取当前 keep 记录。读取失败返回 nil，调用方据此停止提交。
    private func currentKeepIDs() -> Set<String>? {
        guard case .success(let keepIDs) = database.assetIDsResult(withVerdict: .keep) else {
            return nil
        }
        return keepIDs
    }

    /// 提交**单批**给服务层，同步等待系统确认框结果。
    /// 分批与推进逻辑不在这里——服务只负责这一批。
    private func submitBatch(
        _ approvedIDs: [String],
        batchIndex: Int,
        requestedIDs: [String]
    ) -> DeletionBatchResult {
        guard !approvedIDs.isEmpty else {
            return DeletionBatchResult(
                batchIndex: batchIndex,
                requestedIDs: requestedIDs,
                approvedIDs: [],
                status: .skipped,
                reason: "本批无可提交项目"
            )
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: DeletionBatchResult?
        photoLibrary.requestDeleteDetailed(of: approvedIDs) { result in
            // 服务层对单批只应回一个批次结果；取首个匹配项。
            if let first = result.batches.first {
                outcome = DeletionBatchResult(
                    batchIndex: batchIndex,
                    requestedIDs: requestedIDs,
                    approvedIDs: first.approvedIDs,
                    status: first.status,
                    reason: first.reason
                )
            } else {
                outcome = DeletionBatchResult(
                    batchIndex: batchIndex,
                    requestedIDs: requestedIDs,
                    approvedIDs: [],
                    status: .failed,
                    reason: "系统删除结果缺失"
                )
            }
            semaphore.signal()
        }
        semaphore.wait()
        return outcome ?? DeletionBatchResult(
            batchIndex: batchIndex,
            requestedIDs: requestedIDs,
            approvedIDs: [],
            status: .failed,
            reason: "系统删除结果缺失"
        )
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
