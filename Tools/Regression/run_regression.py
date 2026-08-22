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

阈值没有数据支撑不许合入：把选定值 + 报告摘要写进 threshold-log.md。
"""

import csv
import sys
from collections import defaultdict
from pathlib import Path

DISTRACTORS = "_distractors"


def load_ground_truth(dataset: Path) -> dict[str, int]:
    """asset 文件名（去扩展名）→ 真实组 id。"""
    truth: dict[str, int] = {}
    group_id = 0
    for folder in sorted(dataset.iterdir()):
        if not folder.is_dir() or folder.name == DISTRACTORS:
            continue
        group_id += 1
        for image in folder.glob("*"):
            truth[image.stem] = group_id
    return truth


def load_embeddings(path: Path) -> dict[str, list[float]]:
    vectors: dict[str, list[float]] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.reader(handle):
            if not row or row[0] == "asset_id":
                continue
            vectors[row[0]] = [float(value) for value in row[1:]]
    return vectors


def l2_normalize(vector: list[float]) -> list[float]:
    norm = sum(v * v for v in vector) ** 0.5
    if norm == 0:
        return vector
    return [v / norm for v in vector]


def cluster(assets: dict[str, list[float]], threshold: float) -> dict[str, int]:
    """union-find 连通分量（与 ios Core/Grouping/EmbeddingClusterer 同语义）。"""
    ids = sorted(assets)
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


def evaluate(truth: dict[str, int], labels: dict[str, int]) -> tuple[float, float]:
    """返回 (组级 purity, 应拆组误并率)。"""
    by_output: dict[int, list[str]] = defaultdict(list)
    for asset, label in labels.items():
        by_output[label].append(asset)

    total = len(labels)
    if not total:
        return 1.0, 0.0

    purity = sum(
        max(
            sum(1 for a in members if truth.get(a) == gid)
            for gid in set(truth.get(a) for a in members)
        )
        for members in by_output.values()
    ) / total

    cross_pairs = wrongly_merged = 0
    ids = sorted(labels)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            ta, tb = truth.get(a), truth.get(b)
            if ta is None or tb is None or ta == tb:
                continue
            cross_pairs += 1
            if labels[a] == labels[b]:
                wrongly_merged += 1

    mis_merge = wrongly_merged / cross_pairs if cross_pairs else 0.0
    return purity, mis_merge


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    dataset = Path(sys.argv[1])
    truth = load_ground_truth(dataset)
    embeddings = load_embeddings(dataset / "embeddings.csv")
    assets = {
        asset: l2_normalize(vector)
        for asset, vector in embeddings.items()
        if asset in truth
    }
    print(f"标注资产 {len(truth)} 个，有向量的 {len(assets)} 个")

    print(f"{'阈值':>6} {'purity':>8} {'误并率':>8}  达标(purity>=0.9 且 误并<=0.10)")
    qualified: list[float] = []
    for step in range(4, 21):
        threshold = step * 0.05
        labels = cluster(assets, threshold)
        purity, mis_merge = evaluate(truth, labels)
        ok = purity >= 0.9 and mis_merge <= 0.10
        if ok:
            qualified.append(threshold)
        print(f"{threshold:>6.2f} {purity:>8.3f} {mis_merge:>8.3f}  {'✓' if ok else ''}")

    if qualified:
        print(f"\n达标区间：{min(qualified):.2f} ~ {max(qualified):.2f}")
        print("选定后追加 Tools/Regression/threshold-log.md 并同步 AppConfig。")
    else:
        print("\n无达标阈值——检查向量质量或扩充标注集。")


if __name__ == "__main__":
    main()
