import 'dart:math';

/// LinkPair 表示连边的轻量级映射，用于解耦图聚类算法与 UI 节点定义
class LinkPair {
  final String source;
  final String target;
  final double weight;

  LinkPair({
    required this.source,
    required this.target,
    this.weight = 1.0,
  });
}

/// GraphClustering 提供基于拓扑连边的个人脑网图谱快速社区聚类工具
class GraphClustering {
  /// detectCommunities 基于标签传播算法 (Label Propagation Algorithm) 对图进行划分
  /// 返回节点 ID 到社区 ID (Community ID) 的映射 Map
  static Map<String, String> detectCommunities(
    List<String> nodeIds,
    List<LinkPair> links, {
    int maxIterations = 10,
  }) {
    final Map<String, String> communities = {};
    if (nodeIds.isEmpty) return communities;

    // 1. 初始化：每个节点初始为各自独立的社区 (Label = NodeID)
    for (final id in nodeIds) {
      communities[id] = id;
    }

    // 构建邻接表以加速邻居查找，key 为 node_id，value 为其关联邻居列表（包含权重）
    final Map<String, List<_Neighbor>> adjacencyList = {};
    for (final id in nodeIds) {
      adjacencyList[id] = [];
    }

    for (final link in links) {
      // 容错：防止连边指向了不存在于 nodeIds 中的幽灵节点
      if (!adjacencyList.containsKey(link.source) || !adjacencyList.containsKey(link.target)) {
        continue;
      }
      adjacencyList[link.source]!.add(_Neighbor(link.target, link.weight));
      adjacencyList[link.target]!.add(_Neighbor(link.source, link.weight));
    }

    final random = Random();
    final List<String> shuffledNodes = List.from(nodeIds);

    // 2. 迭代传播标签
    for (int iter = 0; iter < maxIterations; iter++) {
      bool changed = false;
      shuffledNodes.shuffle(random);

      for (final nodeId in shuffledNodes) {
        final neighbors = adjacencyList[nodeId] ?? [];
        if (neighbors.isEmpty) continue;

        // 统计邻居节点的社区标签及其权重累加值
        final Map<String, double> labelWeights = {};
        for (final nb in neighbors) {
          final nbLabel = communities[nb.id] ?? nb.id;
          labelWeights[nbLabel] = (labelWeights[nbLabel] ?? 0.0) + nb.weight;
        }

        // 找出累加权重最大的标签
        String bestLabel = communities[nodeId]!;
        double maxWeight = -1.0;
        final List<String> candidateLabels = [];

        labelWeights.forEach((label, weight) {
          if (weight > maxWeight) {
            maxWeight = weight;
            candidateLabels.clear();
            candidateLabels.add(label);
          } else if (weight == maxWeight) {
            candidateLabels.add(label);
          }
        });

        // 若有多个标签权重相同，随机选择一个
        if (candidateLabels.isNotEmpty) {
          final selectedLabel = candidateLabels[random.nextInt(candidateLabels.length)];
          if (selectedNodeLabel(communities[nodeId], selectedLabel)) {
            communities[nodeId] = selectedLabel;
            changed = true;
          }
        }
      }

      // 如果标签不再变化，提前退出迭代
      if (!changed) {
        break;
      }
    }

    return communities;
  }

  // 辅助比较标签是否需要变更，容空安全
  static bool selectedNodeLabel(String? current, String next) {
    if (current == null) return true;
    return current != next;
  }
}

class _Neighbor {
  final String id;
  final double weight;
  _Neighbor(this.id, this.weight);
}
