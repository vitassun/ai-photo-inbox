# T05 阈值回归集工具

职责：为 embedding 聚类距离阈值（`AppConfig.embeddingClusterDistanceThreshold`）
提供数据支撑——没有回归数据不许改阈值（任务卡 T05 边界）。

## 目录约定

```
Tools/Regression/
├── run_regression.py     # 一键回归脚本（本文件同级，入库）
├── threshold-log.md      # 阈值调参记录（入库，每次调整必须追加一行）
└── dataset/              # ★ gitignore：手工标注相册原图与导出向量，绝不提交
    ├── album-001/        # 每个文件夹 = 一个应聚成一组的正例组
    │   └── *.jpg
    ├── album-002/
    ├── _distractors/     # 干扰负例：不属于任何组的散片
    │   └── *.jpg
    └── embeddings.csv    # 由调试导出钩子生成：asset_id,dim0,dim1,...
```

## 用法

```bash
python3 Tools/Regression/run_regression.py Tools/Regression/dataset
```

脚本读取 `embeddings.csv` 与目录结构，对候选阈值扫描并输出每个阈值下的
**组级 purity**、**应拆组误并率**、**应并组漏拆率**，给出达标区间。
三项都必须达到门槛（purity ≥ 0.90、误并率 ≤ 10%、漏拆率 ≤ 10%）；
全部单例和全部合并会被固定判为失败。脚本还会拒绝重复标注 ID、缺向量、
额外向量和维度不一致的数据。没有达标阈值时以失败状态退出。把选定值连同
本次报告摘要追加进 `threshold-log.md`，再同步改 `AppConfig`。

## embeddings.csv 从哪来

调试导出钩子（后续卡的设置页调试入口）遍历全库，把每张已算好 embedding
的资产按 `localIdentifier, v0, v1, ...` 逐行写出；标注时人工把
localIdentifier 对应的原图放进对应 album 文件夹。CSV 同样在 gitignore 内。

## 铁律

- dataset/ 下任何内容（原图、向量、报告原文）不进公开仓库。
- 阈值变更没有对应的 log 行 + 报告 = 违规改动，review 直接拒。
