#!/usr/bin/env python3
"""T05 阈值回归脚本：扫描 embedding 聚类距离阈值，输出 purity / 误并率报告。

用法：
    python3 run_regression.py <dataset_dir>

dataset_dir 结构见同目录 README.md：每个 album-* 文件夹是一个正例组，
_distractors/ 是干扰负例；embeddings.csv 每行 asset_id, v0, v1, ...

指标定义（与任务卡 T05 验收线对齐）：
  组级 purity   = 各输出组内最大真实组占比之和 / 资产总数
  应拆组误并率  = 被"并进同一输出组但来自不同真实组"的资产对数
                  / 全部跨真实组资产对数（越低越好，验收 ≤ 10%）
  应并组漏拆率  = 同一真实组被拆进不同输出组的比例（辅助观察）

三项指标都达到门槛且结果不是全部单例/全部合并才算通过；没有达标阈值时
脚本以失败状态退出。阈值没有数据支撑不许合入：把选定值 + 报告摘要写进
threshold-log.md。
"""

import csv
import sys
from collections import defaultdict
from pathlib import Path

DISTRACTORS = "_distractors"
MAX_PURITY = 0.90
MAX_MIS_MERGE = 0.10
MAX_SPLIT = 0.10


def load_ground_truth(dataset: Path) -> dict[str, int]:
    """asset 文件名（去扩展名）→ 真实组 id。"""
    truth: dict[str, int] = {}
    duplicate_ids: set[str] = set()
    group_id = 0
    for folder in sorted(dataset.iterdir()):
        if not folder.is_dir() or folder.name == DISTRACTORS:
            continue
        group_id += 1
        for image in folder.glob("*"):
            if image.stem in truth:
                duplicate_ids.add(image.stem)
            truth[image.stem] = group_id

    # 干扰样本也是负例，不能从评测数据里排除。每个干扰图视为一个
    # 独立真实组，这样它与任意正例/其它干扰图被合并都会计入误并率。
    distractor_folder = dataset / DISTRACTORS
    if distractor_folder.is_dir():
        for image in sorted(distractor_folder.glob("*")):
            group_id += 1
            if image.stem in truth:
                duplicate_ids.add(image.stem)
            truth[image.stem] = group_id
    if duplicate_ids:
        raise ValueError(
            "ground-truth asset ids must be unique; duplicates: "
            + ", ".join(sorted(duplicate_ids)[:5])
        )
    return truth


def load_embeddings(path: Path) -> dict[str, list[float]]:
    vectors: dict[str, list[float]] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.reader(handle):
            if not row or row[0] == "asset_id":
                continue
            try:
                vector = [float(value) for value in row[1:]]
            except ValueError as error:
                raise ValueError(f"{row[0]} contains a non-numeric embedding") from error
            if not vector or not all(value == value and abs(value) != float("inf") for value in vector):
                raise ValueError(f"{row[0]} contains an empty or non-finite embedding")
            if row[0] in vectors:
                raise ValueError(f"{row[0]} appears more than once in embeddings.csv")
            vectors[row[0]] = vector
    if not vectors:
        raise ValueError("embeddings.csv contains no labelled vectors")
    dimensions = {len(vector) for vector in vectors.values()}
    if len(dimensions) != 1:
        raise ValueError(f"embedding dimensions are inconsistent: {sorted(dimensions)}")
    return vectors


def l2_normalize(vector: list[float]) -> list[float]:
    norm = sum(v * v for v in vector) ** 0.5
    if not norm or not norm == norm or norm == float("inf"):
        raise ValueError("zero or non-finite embedding cannot be normalized")
    return [v / norm for v in vector]


def cluster(assets: dict[str, list[float]], threshold: float) -> dict[str, int]:
    """union-find 连通分量（与 ios Core/Grouping/EmbeddingClusterer 同语义）。"""
    ids = sorted(assets)
    dimensions = {len(assets[asset]) for asset in ids}
    if len(dimensions) > 1:
        raise ValueError(f"embedding dimensions are inconsistent: {sorted(dimensions)}")
    parent = {asset: asset for asset in ids}

    def find(node: str) -> str:
        while parent[node] != node:
            node = parent[node]
        return node

    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            va, vb = assets[a], assets[b]
            distance = sum((x - y) ** 2 for x, y in zip(va, vb)) ** 0.5
            if distance <= threshold:
                ra, rb = find(a), find(b)
                if ra != rb:
                    parent[rb] = ra

    labels: dict[str, int] = {}
    for asset in ids:
        root = find(asset)
        labels.setdefault(root, len(labels))
    return {asset: labels[find(asset)] for asset in ids}


def evaluate(truth: dict[str, int], labels: dict[str, int]) -> tuple[float, float, float]:
    """返回 (组级 purity, 应拆组误并率, 应并组漏拆率)。"""
    by_output: dict[int, list[str]] = defaultdict(list)
    for asset, label in labels.items():
        by_output[label].append(asset)

    total = len(labels)
    if not total:
        return 0.0, 1.0, 1.0

    purity = sum(
        max(
            sum(1 for a in members if truth.get(a) == gid)
            for gid in set(truth[a] for a in members)
        )
        for members in by_output.values()
    ) / total

    cross_pairs = wrongly_merged = 0
    ids = sorted(labels)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            ta, tb = truth[a], truth[b]
            if ta == tb:
                continue
            cross_pairs += 1
            if labels[a] == labels[b]:
                wrongly_merged += 1

    mis_merge = wrongly_merged / cross_pairs if cross_pairs else 0.0
    return purity, mis_merge, split_rate(truth, labels)


def has_positive_and_negative_pairs(truth: dict[str, int]) -> bool:
    """评测集必须同时包含应合并正例对和应拆分负例对。"""
    counts = defaultdict(int)
    for group_id in truth.values():
        counts[group_id] += 1
    has_positive = any(count >= 2 for count in counts.values())
    has_negative = len(counts) >= 2
    return has_positive and has_negative


def degenerate_labels(labels: dict[str, int]) -> str | None:
    """固定拒绝“全部单例”和“全部合并”两种无意义结果。"""
    unique_labels = set(labels.values())
    if len(unique_labels) == len(labels):
        return "全部单例"
    if len(unique_labels) == 1:
        return "全部合并"
    return None


def split_rate(truth: dict[str, int], labels: dict[str, int]) -> float:
    """同一真实组被拆到不同输出组的资产对比例（越低越好）。"""
    by_truth: dict[int, list[str]] = defaultdict(list)
    for asset, group_id in truth.items():
        if asset in labels:
            by_truth[group_id].append(asset)
    total_pairs = split_pairs = 0
    for members in by_truth.values():
        for index, asset in enumerate(members):
            for other in members[index + 1:]:
                total_pairs += 1
                if labels[asset] != labels[other]:
                    split_pairs += 1
    return split_pairs / total_pairs if total_pairs else 0.0


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    dataset = Path(sys.argv[1])
    truth = load_ground_truth(dataset)
    embeddings = load_embeddings(dataset / "embeddings.csv")
    if not has_positive_and_negative_pairs(truth):
        raise ValueError("dataset must contain both positive pairs and negative pairs")
    missing = sorted(set(truth) - set(embeddings))
    if missing:
        raise ValueError(
            f"{len(missing)} ground-truth assets have no embedding; first few: {missing[:5]}"
        )
    extra = sorted(set(embeddings) - set(truth))
    if extra:
        raise ValueError(
            f"{len(extra)} embeddings have no ground-truth asset; first few: {extra[:5]}"
        )
    assets = {
        asset: l2_normalize(vector)
        for asset, vector in embeddings.items()
        if asset in truth
    }
    if len(assets) < 2:
        raise ValueError("at least two labelled assets with embeddings are required")
    print(f"标注资产 {len(truth)} 个，有向量的 {len(assets)} 个")

    print(f"{'阈值':>6} {'purity':>8} {'误并率':>8} {'漏拆率':>8}  达标(三项均≤门槛)")
    qualified: list[float] = []
    for step in range(4, 21):
        threshold = step * 0.05
        labels = cluster(assets, threshold)
        purity, mis_merge, split = evaluate(truth, labels)
        degenerate = degenerate_labels(labels)
        ok = (
            purity >= MAX_PURITY
            and mis_merge <= MAX_MIS_MERGE
            and split <= MAX_SPLIT
            and degenerate is None
        )
        if ok:
            qualified.append(threshold)
        reason = f"（拒绝：{degenerate}）" if degenerate else ""
        print(f"{threshold:>6.2f} {purity:>8.3f} {mis_merge:>8.3f} {split:>8.3f}  {'PASS' if ok else 'FAIL'}{reason}")

    if qualified:
        print(f"\n达标区间：{min(qualified):.2f} ~ {max(qualified):.2f}")
        print("选定后追加 Tools/Regression/threshold-log.md 并同步 AppConfig。")
    else:
        print("\n无达标阈值——检查向量质量或扩充标注集。")
        sys.exit(1)


if __name__ == "__main__":
    main()
