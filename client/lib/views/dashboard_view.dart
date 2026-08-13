import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/assistant_provider.dart';
import '../models/memory.dart';
import '../utils/graph_clustering.dart';
import 'command_center_view.dart';
import 'settings_view.dart';
import 'voice_cabin_view.dart';

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key});

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView>
    with TickerProviderStateMixin {
  final TextEditingController _quickCaptureController = TextEditingController();
  int _homeSection = 0; // 0: 收件箱, 1: 分析
  bool _isQuickCapturing = false;
  int _activeTab = 0; // 0: Flow (瀑布), 1: Timeline (时光轴)
  bool _isMultiSelectMode = false;
  final List<String> _selectedIds = [];

  // 脑图网状态
  List<GraphNode> _graphNodes = [];
  List<GraphLink> _graphLinks = [];
  Map<String, GraphNode> _graphNodeMap = {};
  bool _isLoadingGraph = false;
  String? _graphError;

  // 缓存完整的原始图谱数据，用于折叠筛选
  List<GraphNode> _rawNodes = [];
  List<GraphLink> _rawLinks = [];
  bool _showSecondaryEntities = false;

  // Phase 7.0 图聚类与折叠状态
  Map<String, String> _nodeCommunities = {};
  Map<String, String> _communityLeaders = {};
  final Set<String> _expandedCommunities = {};

  // 物理引擎与视口手势状态
  late AnimationController _physicsController;
  double _graphScale = 1.0;
  Offset _graphOffset = Offset.zero;
  double _baseScale = 1.0;
  Offset _baseOffset = Offset.zero;
  GraphNode? _draggedNode;
  GraphNode? _selectedNode;
  double _temperature = 1.0;

  // 判定点击手势
  Offset _panStartLocalPoint = Offset.zero;
  DateTime _panStartTime = DateTime.now();
  Offset _lastLocalFocalPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    _physicsController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _physicsController.addListener(() {
      if (_activeTab == 2) {
        _updatePhysics();
      }
    });
  }

  @override
  void dispose() {
    _quickCaptureController.dispose();
    _physicsController.dispose();
    super.dispose();
  }

  // 物理模拟力导向计算
  void _updatePhysics() {
    if (_graphNodes.isEmpty) return;

    // Fruchterman-Reingold 经典布局力算法（已优化：加大斥力与弹簧长度防止节点密集重叠）
    const double kRepel = 6000.0; // 斥力强度（↑ 原2200，防止节点挤压成一坨）
    const double kSpring = 0.04; // 弹簧系数（↓ 微降，允许连线更松弛）
    const double springLength = 220.0; // 理想连线弹簧长度（↑ 原150，确保连接节点间留有明确间距）
    const double gravity = 0.010; // 指向中心引力强度（↓ 微降，防止过度向心聚拢）
    const double damping = 0.85; // 阻尼

    final size = MediaQuery.of(context).size;
    final double centerX = size.width / 2;
    const double centerY = 270.0;

    // 1. 所有节点两两计算排斥力
    for (int i = 0; i < _graphNodes.length; i++) {
      final nodeA = _graphNodes[i];
      for (int j = i + 1; j < _graphNodes.length; j++) {
        final nodeB = _graphNodes[j];

        final dx = nodeB.x - nodeA.x;
        final dy = nodeB.y - nodeA.y;
        final distSq = dx * dx + dy * dy + 0.1;
        final dist = sqrt(distSq);

        if (dist < 450.0) {
          final force = kRepel / distSq;
          final fx = (dx / dist) * force;
          final fy = (dy / dist) * force;

          if (!nodeA.isDragging) {
            nodeA.vx -= fx * _temperature;
            nodeA.vy -= fy * _temperature;
          }
          if (!nodeB.isDragging) {
            nodeB.vx += fx * _temperature;
            nodeB.vy += fy * _temperature;
          }
        }

        // 刚性排斥力，当距离小于 100 像素时强力推开以防重叠（↑ 原60，保证每两个节点之间有足够视觉间隙）
        if (dist < 100.0) {
          final rigidForce = (100.0 - dist) * 3.5;
          final rfx = (dx / dist) * rigidForce;
          final rfy = (dy / dist) * rigidForce;
          if (!nodeA.isDragging) {
            nodeA.vx -= rfx * _temperature;
            nodeA.vy -= rfy * _temperature;
          }
          if (!nodeB.isDragging) {
            nodeB.vx += rfx * _temperature;
            nodeB.vy += rfy * _temperature;
          }
        }
      }
    }

    // 2. 连接线弹簧拉力计算
    for (final link in _graphLinks) {
      final nodeA = _graphNodeMap[link.source];
      final nodeB = _graphNodeMap[link.target];
      if (nodeA == null || nodeB == null) continue;

      final dx = nodeB.x - nodeA.x;
      final dy = nodeB.y - nodeA.y;
      final dist = sqrt(dx * dx + dy * dy) + 0.1;

      final force = kSpring * (dist - springLength);
      final fx = (dx / dist) * force;
      final fy = (dy / dist) * force;

      if (!nodeA.isDragging) {
        nodeA.vx += fx * _temperature;
        nodeA.vy += fy * _temperature;
      }
      if (!nodeB.isDragging) {
        nodeB.vx -= fx * _temperature;
        nodeB.vy -= fy * _temperature;
      }
    }

    // 3. 计算中心引力，应用速度并进行阻尼衰减
    for (final node in _graphNodes) {
      if (node.isDragging) continue;

      final dx = centerX - node.x;
      final dy = centerY - node.y;
      node.vx += dx * gravity;
      node.vy += dy * gravity;

      node.x += node.vx;
      node.y += node.vy;
      node.vx *= damping;
      node.vy *= damping;
    }

    // 3.5 刚性位置碰撞约束解算器：强力推开距离过近的节点，绝对保证圆圈之间的最小安全距离
    const double minSafeDistance = 140.0;
    // 使用 3 次碰撞解算迭代，能够很好地将链式挤压成团的节点扩散开
    for (int iter = 0; iter < 3; iter++) {
      for (int i = 0; i < _graphNodes.length; i++) {
        final nodeA = _graphNodes[i];
        for (int j = i + 1; j < _graphNodes.length; j++) {
          final nodeB = _graphNodes[j];
          final dx = nodeB.x - nodeA.x;
          final dy = nodeB.y - nodeA.y;
          final distSq = dx * dx + dy * dy + 0.1;
          final dist = sqrt(distSq);
          if (dist < minSafeDistance) {
            final overlap = minSafeDistance - dist;
            // 将重叠距离沿连线方向平分并强制推开
            final pushX = (dx / dist) * (overlap / 2.0);
            final pushY = (dy / dist) * (overlap / 2.0);

            if (!nodeA.isDragging && !nodeB.isDragging) {
              nodeA.x -= pushX;
              nodeA.y -= pushY;
              nodeB.x += pushX;
              nodeB.y += pushY;
            } else if (nodeA.isDragging) {
              nodeB.x += pushX * 2.0;
              nodeB.y += pushY * 2.0;
            } else if (nodeB.isDragging) {
              nodeA.x -= pushX * 2.0;
              nodeA.y -= pushY * 2.0;
            }
          }
        }
      }
    }

    // 4. 模拟退火控制
    setState(() {
      _temperature *= 0.985; // 退火速率降低（原0.975），让物理引擎有更充裕的时间将重叠节点展开
      if (_temperature < 0.005) {
        _physicsController.stop(); // 能量过低，物理引擎自动降温停机以节省 CPU 占用
      }
    });
  }

  void _wakeUpPhysics() {
    setState(() {
      _temperature = 1.0;
    });
    if (!_physicsController.isAnimating) {
      _physicsController.repeat();
    }
  }

  // 异步获取图谱拓扑数据并初始化物理排布
  Future<void> _loadMindGraph() async {
    setState(() {
      _isLoadingGraph = true;
      _graphError = null;
      _graphNodes.clear();
      _graphLinks.clear();
      _graphNodeMap.clear();
      _rawNodes.clear();
      _rawLinks.clear();
    });

    try {
      final apiService = ref.read(apiServiceProvider);
      final data = await apiService.fetchMindGraph();

      final List<dynamic> jsonNodes = data['nodes'] ?? [];
      final List<dynamic> jsonLinks = data['links'] ?? [];

      final size = MediaQuery.of(context).size;
      final double centerX = size.width / 2;
      const double centerY = 270.0;
      final r = Random();

      final List<GraphNode> tempNodes = [];
      for (final n in jsonNodes) {
        final angle = r.nextDouble() * 2 * pi;
        final radius = 80.0 +
            r.nextDouble() *
                280.0; // 初始散布半径扩大（原50~170 → 80~360），给物理引擎一个更合理的起始布局
        tempNodes.add(GraphNode(
          id: n['id'] ?? '',
          label: n['label'] ?? '',
          type: n['type'] ?? 'memory',
          entityType: n['entity_type'],
          x: centerX + radius * cos(angle),
          y: centerY + radius * sin(angle),
        ));
      }

      final List<GraphLink> tempLinks = [];
      for (final l in jsonLinks) {
        tempLinks.add(GraphLink(
          source: l['source'] ?? '',
          target: l['target'] ?? '',
          type: l['type'] ?? 'tag',
          label: l['label'],
        ));
      }

      // 运行社区聚类分析 (GraphRAG 与标签相关性)
      final List<String> nodeIds = tempNodes.map((n) => n.id).toList();
      final List<LinkPair> clusteringLinks = tempLinks
          .map((l) => LinkPair(
                source: l.source,
                target: l.target,
                weight: l.type == 'graph_rag'
                    ? 1.5
                    : (l.type == 'similar' ? 0.5 : 1.0),
              ))
          .toList();

      final communities =
          GraphClustering.detectCommunities(nodeIds, clusteringLinks);

      // 计算每个社区的领头节点 (Degree 最大者)
      final Map<String, List<String>> communityGroups = {};
      communities.forEach((nodeId, commId) {
        communityGroups.putIfAbsent(commId, () => []).add(nodeId);
      });

      final Map<String, String> leaders = {};
      final Map<String, int> degrees = {};
      for (final link in tempLinks) {
        degrees[link.source] = (degrees[link.source] ?? 0) + 1;
        degrees[link.target] = (degrees[link.target] ?? 0) + 1;
      }

      communityGroups.forEach((commId, memberIds) {
        String leaderId = memberIds.first;
        int maxDeg = -1;
        for (final mId in memberIds) {
          final deg = degrees[mId] ?? 0;
          if (deg > maxDeg) {
            maxDeg = deg;
            leaderId = mId;
          }
        }
        leaders[commId] = leaderId;
      });

      // 更新节点的社区属性
      for (final node in tempNodes) {
        final cId = communities[node.id];
        if (cId != null) {
          node.communityId = cId;
          node.isClusterLeader = (node.id == leaders[cId]);
        }
      }

      setState(() {
        _rawNodes = tempNodes;
        _rawLinks = tempLinks;
        _nodeCommunities = communities;
        _communityLeaders = leaders;
        _expandedCommunities.clear();
        _isLoadingGraph = false;
        _temperature = 1.0;
      });

      // 应用折叠过滤，生成当前渲染集
      _applyGraphFilter();
      _autoFitGraph();

      _physicsController.repeat();
    } catch (e) {
      setState(() {
        _isLoadingGraph = false;
        _graphError = e.toString();
      });
    }
  }

  // 过滤图谱节点与连线，防范毛线球效应
  void _applyGraphFilter() {
    if (_rawNodes.isEmpty) return;

    // 1. 计算每个节点在实体网中的度数 (除 similar 虚连线外)
    final Map<String, int> degrees = {};
    for (final link in _rawLinks) {
      if (link.type == 'similar') continue;
      degrees[link.source] = (degrees[link.source] ?? 0) + 1;
      degrees[link.target] = (degrees[link.target] ?? 0) + 1;
    }

    // 计算每个社区所包含的原始节点总数
    final Map<String, int> commSizes = {};
    for (final node in _rawNodes) {
      final cId = node.communityId;
      if (cId != null) {
        commSizes[cId] = (commSizes[cId] ?? 0) + 1;
      }
    }

    // 2. 筛选节点：如果关闭了“展现二级关联实体”开关，过滤掉度数 <= 1 且类型为 entity 的节点
    final List<GraphNode> filteredNodes = [];
    final Set<String> activeNodeIds = {};

    for (final node in _rawNodes) {
      if (!_showSecondaryEntities &&
          (node.type == 'entity' || node.type == 'tag')) {
        final deg = degrees[node.id] ?? 0;
        if (deg <= 1) {
          // 折叠隐藏二级关联实体和叶子标签
          continue;
        }
      }

      // 社区关联折叠逻辑
      final commId = node.communityId;
      if (commId != null) {
        final size = commSizes[commId] ?? 1;
        node.communitySize = size;
        node.isCommunityExpanded = _expandedCommunities.contains(commId);

        // 如果社区节点总数 >= 3，且社区未被用户展开，且该节点不是 Leader 节点，则不参与渲染与物理迭代
        if (size >= 3 && !node.isCommunityExpanded && !node.isClusterLeader) {
          continue;
        }
      }

      filteredNodes.add(node);
      activeNodeIds.add(node.id);
    }

    // 3. 筛选连边：只保留两端节点均处于激活状态的连边
    final List<GraphLink> filteredLinks = [];
    for (final link in _rawLinks) {
      if (activeNodeIds.contains(link.source) &&
          activeNodeIds.contains(link.target)) {
        filteredLinks.add(link);
      }
    }

    setState(() {
      _graphNodes = filteredNodes;
      _graphLinks = filteredLinks;
      _graphNodeMap = {for (var n in filteredNodes) n.id: n};
    });
  }

  void _autoFitGraph() {
    if (_graphNodes.isEmpty) return;
    double minX = double.infinity;
    double maxX = -double.infinity;
    double minY = double.infinity;
    double maxY = -double.infinity;
    for (final node in _graphNodes) {
      if (node.x < minX) minX = node.x;
      if (node.x > maxX) maxX = node.x;
      if (node.y < minY) minY = node.y;
      if (node.y > maxY) maxY = node.y;
    }
    final size = MediaQuery.of(context).size;
    final canvasWidth = size.width - 40;
    const double canvasHeight = 540.0;
    final graphWidth = maxX - minX + 100.0;
    final graphHeight = maxY - minY + 100.0;
    double scale = min(canvasWidth / graphWidth, canvasHeight / graphHeight);
    scale = scale.clamp(0.4, 1.4);
    final graphCenterX = (minX + maxX) / 2;
    final graphCenterY = (minY + maxY) / 2;
    final canvasCenterX = canvasWidth / 2;
    const double canvasCenterY = canvasHeight / 2;
    final offsetX = canvasCenterX - graphCenterX * scale;
    final offsetY = canvasCenterY - graphCenterY * scale;
    setState(() {
      _graphScale = scale;
      _graphOffset = Offset(offsetX, offsetY);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(assistantProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0E17),
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: state.isOfflineMode
                    ? const Color(0xFFFF8906)
                    : Colors.green,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: state.isOfflineMode
                        ? const Color(0xFFFF8906)
                        : Colors.green,
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              state.isOfflineMode ? '记忆收件箱 · 离线' : '记忆收件箱',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 19,
              ),
            ),
          ],
        ),
        actions: [
          if (_isMultiSelectMode)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.redAccent),
              onPressed: () {
                setState(() {
                  _isMultiSelectMode = false;
                  _selectedIds.clear();
                });
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.grey),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const SettingsView()),
                );
              },
            ),
        ],
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () async {
              await ref.read(assistantProvider.notifier).refreshAll();
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHomeSectionSwitcher(),
                  const SizedBox(height: 16),
                  _buildQuickCapture(state),

                  // 离线状态指示条
                  if (state.isOfflineMode || state.offlineQueue.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF8906).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: const Color(0xFFFF8906).withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.wifi_off,
                              color: Color(0xFFFF8906), size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              state.offlineQueue.isNotEmpty
                                  ? '当前处于离线模式，有 ${state.offlineQueue.length} 条数据等待同步。'
                                  : '检测到网络连接失败。当前以离线模式运行。',
                              style: GoogleFonts.outfit(
                                  color: Colors.white70, fontSize: 13),
                            ),
                          ),
                          if (state.offlineQueue.isNotEmpty)
                            GestureDetector(
                              onTap: () {
                                ref
                                    .read(assistantProvider.notifier)
                                    .flushOfflineQueue();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFF8906),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.sync,
                                        size: 14, color: Colors.black),
                                    const SizedBox(width: 4),
                                    Text(
                                      '立即对账',
                                      style: GoogleFonts.outfit(
                                        color: Colors.black,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 20),

                  // 2. 快捷操作栏 (Quick Actions)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1E29),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildQuickAction(
                          icon: Icons.manage_search,
                          label: '智能检索',
                          color: const Color(0xFFFF8906),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (context) =>
                                      const CommandCenterView()),
                            );
                            ref.read(assistantProvider.notifier).refreshAll();
                          },
                        ),
                        Container(width: 1, height: 36, color: Colors.white10),
                        _buildQuickAction(
                          icon: Icons.camera_alt,
                          label: '拍照识别',
                          color: const Color(0xFF8B5CF6),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (context) => const CommandCenterView(
                                      initialMode: 'camera')),
                            );
                            ref.read(assistantProvider.notifier).refreshAll();
                          },
                        ),
                        Container(width: 1, height: 36, color: Colors.white10),
                        _buildQuickAction(
                          icon: Icons.mic,
                          label: '语音速记',
                          color: const Color(0xFF10B981),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (context) => const CommandCenterView(
                                      initialMode: 'voice')),
                            );
                            ref.read(assistantProvider.notifier).refreshAll();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  if (_homeSection == 0) ...[
                    _buildInboxSummary(state),
                    const SizedBox(height: 22),
                    if ((state.stats['confirmation_tasks'] as List?)
                            ?.isNotEmpty ??
                        false) ...[
                      _buildInboxSectionHeader(
                        '待确认',
                        '${state.stats['confirmation_task_count'] ?? 0} 项',
                      ),
                      const SizedBox(height: 10),
                      _buildTaskConfirmationsCard(state.stats),
                      const SizedBox(height: 22),
                    ],
                    _buildInboxSectionHeader(
                      '最近记忆',
                      '${state.memories.length} 条',
                    ),
                    const SizedBox(height: 10),
                    _buildRecentInbox(state.memories),
                    const SizedBox(height: 22),
                    _buildInboxSectionHeader('即将提醒', '未来日程'),
                    const SizedBox(height: 10),
                    _buildUpcomingTasksCard(state.stats),
                    const SizedBox(height: 80),
                  ],

                  if (_homeSection == 1) ...[
                    // 3. 核心指标卡片 (有意义的用户指标)
                    Row(
                      children: [
                        Expanded(
                          child: _buildMetricCard(
                            title: '今日录入',
                            value: '${state.stats['today_count'] ?? 0}',
                            subtitle: '条记忆',
                            color: const Color(0xFFFF8906),
                            icon: Icons.today,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildMetricCard(
                            title: '待处理提醒',
                            value: '${state.stats['pending_task_count'] ?? 0}',
                            subtitle: '项任务',
                            color: Colors.redAccent,
                            icon: Icons.notifications_active,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildMetricCard(
                            title: '连续记录',
                            value: '${state.stats['streak_days'] ?? 0}',
                            subtitle: '天 🔥',
                            color: const Color(0xFF10B981),
                            icon: Icons.local_fire_department,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildMetricCard(
                            title: '知识总量',
                            value: '${state.stats['total_memories'] ?? 0}',
                            subtitle: '条存档',
                            color: const Color(0xFF8B5CF6),
                            icon: Icons.memory,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // 4. 7日活跃趋势柱状图
                    _buildSectionTitle('📊 7日活跃趋势'),
                    const SizedBox(height: 12),
                    _buildActivityChart(state.stats),
                    const SizedBox(height: 24),

                    // 5. 等待用户确认的 AI 提取任务
                    if ((state.stats['confirmation_tasks'] as List?)
                            ?.isNotEmpty ??
                        false) ...[
                      _buildSectionTitle('待确认提醒'),
                      const SizedBox(height: 12),
                      _buildTaskConfirmationsCard(state.stats),
                      const SizedBox(height: 24),
                    ],

                    // 6. 即将到来的待办
                    _buildSectionTitle('⏰ 即将到来'),
                    const SizedBox(height: 12),
                    _buildUpcomingTasksCard(state.stats),
                    const SizedBox(height: 24),

                    // 6. AI 画像洞察
                    _buildSectionTitle('🧠 AI 画像洞察'),
                    const SizedBox(height: 12),
                    _buildUserProfileCard(state.stats),
                    const SizedBox(height: 24),

                    // 7. 热门标签排行
                    _buildSectionTitle('🏷️ 热门标签'),
                    const SizedBox(height: 12),
                    _buildTopTagsCard(state.stats),
                    const SizedBox(height: 24),

                    // 4. Tab 切换选择器与标题
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            _buildTabButton(0, '脑图瀑布'),
                            const SizedBox(width: 14),
                            _buildTabButton(1, '时光轨迹'),
                            const SizedBox(width: 14),
                            _buildTabButton(2, '脑图网'),
                          ],
                        ),
                        if (state.isLoading)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFFFF8906)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    if (state.memories.isEmpty && _activeTab != 2)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40.0),
                          child: Text(
                            '目前没有任何记忆输入。请在上方指令舱输入！',
                            style: GoogleFonts.outfit(color: Colors.grey),
                          ),
                        ),
                      )
                    else if (_activeTab == 0)
                      _buildFlowGrid(state.memories)
                    else if (_activeTab == 1)
                      _buildTimelineList(state.memories)
                    else
                      _buildMindGraphCanvas(),
                  ],

                  const SizedBox(height: 80), // 留出底部浮动操作抽屉的空隙
                ],
              ),
            ),
          ),

          // 悬浮警报横幅列表 (iOS大厂交互范式)
          if (state.activeAlarms.isNotEmpty)
            Positioned(
              top: 10,
              left: 20,
              right: 20,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: state.activeAlarms.map((alarm) {
                    final id = alarm['id'] ?? '';
                    final title = alarm['title'] ?? '提醒/待办时间已到';
                    final desc = alarm['description'] ?? '';
                    return Container(
                      key: ValueKey(id),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1E29),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.redAccent, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.redAccent.withOpacity(0.35),
                            blurRadius: 16,
                            spreadRadius: 2,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withOpacity(0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.alarm_on,
                                    color: Colors.redAccent, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  title,
                                  style: GoogleFonts.outfit(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  ref
                                      .read(assistantProvider.notifier)
                                      .dismissAlarm(id);
                                },
                                child: const Icon(Icons.close,
                                    color: Colors.grey, size: 20),
                              ),
                            ],
                          ),
                          if (desc.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              desc,
                              style: GoogleFonts.outfit(
                                  color: Colors.white70, fontSize: 13),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () {
                                  ref
                                      .read(assistantProvider.notifier)
                                      .dismissAlarm(id);
                                },
                                child: Text(
                                  '稍后提醒',
                                  style: GoogleFonts.outfit(
                                      color: Colors.grey, fontSize: 13),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8)),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                ),
                                onPressed: () {
                                  ref
                                      .read(assistantProvider.notifier)
                                      .completeTask(id);
                                },
                                child: Text(
                                  '标记完成',
                                  style: GoogleFonts.outfit(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
      floatingActionButtonLocation:
          _isMultiSelectMode && _selectedIds.isNotEmpty
              ? FloatingActionButtonLocation.centerFloat
              : FloatingActionButtonLocation.endFloat,
      floatingActionButton: _isMultiSelectMode && _selectedIds.isNotEmpty
          ? _buildFloatingActionBar(state)
          : _buildVoiceCabinFloatingButton(context),
    );
  }

  Widget _buildHomeSectionSwitcher() {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF191822),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          _buildHomeSectionTab(0, Icons.inbox_outlined, '收件箱'),
          _buildHomeSectionTab(1, Icons.analytics_outlined, '分析'),
        ],
      ),
    );
  }

  Widget _buildHomeSectionTab(int index, IconData icon, String label) {
    final selected = _homeSection == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _homeSection = index),
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2A2835) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? const Color(0xFFFF8906) : Colors.white38,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: GoogleFonts.outfit(
                  color: selected ? Colors.white : Colors.white54,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickCapture(AssistantState state) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF8906).withOpacity(0.28)),
      ),
      child: Column(
        children: [
          TextField(
            key: const ValueKey('quick-capture-input'),
            controller: _quickCaptureController,
            minLines: 2,
            maxLines: 5,
            enabled: !_isQuickCapturing,
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 15,
              height: 1.4,
            ),
            decoration: InputDecoration(
              hintText: '把通知、想法或待办放进来...',
              hintStyle: GoogleFonts.outfit(color: Colors.white30),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(15, 14, 15, 10),
            ),
          ),
          Divider(color: Colors.white.withOpacity(0.06), height: 1),
          SizedBox(
            height: 46,
            child: Row(
              children: [
                IconButton(
                  tooltip: '打开智能检索',
                  onPressed:
                      _isQuickCapturing ? null : () => _openCommandCenter(),
                  icon: const Icon(
                    Icons.manage_search,
                    color: Colors.white54,
                    size: 20,
                  ),
                ),
                IconButton(
                  tooltip: '拍照录入',
                  onPressed: _isQuickCapturing
                      ? null
                      : () => _openCommandCenter(initialMode: 'camera'),
                  icon: const Icon(
                    Icons.camera_alt_outlined,
                    color: Colors.white54,
                    size: 19,
                  ),
                ),
                IconButton(
                  tooltip: '语音录入',
                  onPressed: _isQuickCapturing
                      ? null
                      : () => _openCommandCenter(initialMode: 'voice'),
                  icon: const Icon(
                    Icons.mic_none,
                    color: Colors.white54,
                    size: 20,
                  ),
                ),
                const Spacer(),
                if (state.isOfflineMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '离线可保存',
                      style: GoogleFonts.outfit(
                        color: const Color(0xFFFF8906),
                        fontSize: 10,
                      ),
                    ),
                  ),
                IconButton(
                  key: const ValueKey('quick-capture-submit'),
                  tooltip: '保存到收件箱',
                  onPressed: _isQuickCapturing ? null : _submitQuickCapture,
                  icon: _isQuickCapturing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFFF8906),
                          ),
                        )
                      : const Icon(
                          Icons.arrow_upward,
                          color: Color(0xFFFF8906),
                          size: 21,
                        ),
                ),
                const SizedBox(width: 3),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submitQuickCapture() async {
    final content = _quickCaptureController.text.trim();
    if (content.isEmpty || _isQuickCapturing) return;
    setState(() => _isQuickCapturing = true);
    try {
      await ref
          .read(assistantProvider.notifier)
          .addMemory(content, 'text', 'App 快速录入');
      if (!mounted) return;
      _quickCaptureController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已放入记忆收件箱')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('录入失败: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isQuickCapturing = false);
      }
    }
  }

  Future<void> _openCommandCenter({String initialMode = 'text'}) async {
    if (_isMultiSelectMode) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CommandCenterView(initialMode: initialMode),
      ),
    );
    if (mounted) {
      ref.read(assistantProvider.notifier).refreshAll();
    }
  }

  Widget _buildInboxSummary(AssistantState state) {
    final activeProcessing = state.memories
        .where((memory) =>
            memory.processingStatus == 'pending' ||
            memory.processingStatus == 'processing')
        .length;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF17161F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
      ),
      child: Row(
        children: [
          _buildInboxSummaryItem(
            '${state.stats['today_count'] ?? 0}',
            '今日录入',
            const Color(0xFFFF8906),
          ),
          Container(width: 1, height: 28, color: Colors.white10),
          _buildInboxSummaryItem(
            '${state.stats['confirmation_task_count'] ?? 0}',
            '待确认',
            const Color(0xFFF2C94C),
          ),
          Container(width: 1, height: 28, color: Colors.white10),
          _buildInboxSummaryItem(
            '$activeProcessing',
            '处理中',
            const Color(0xFF56CCF2),
          ),
        ],
      ),
    );
  }

  Widget _buildInboxSummaryItem(String value, String label, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: GoogleFonts.shareTechMono(
              color: color,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.outfit(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildInboxSectionHeader(String title, String trailing) {
    return Row(
      children: [
        Text(
          title,
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Text(
          trailing,
          style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildRecentInbox(List<Memory> memories) {
    if (memories.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF17161F),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.04)),
        ),
        child: Column(
          children: [
            const Icon(Icons.inbox_outlined, color: Colors.white24, size: 30),
            const SizedBox(height: 8),
            Text(
              '收件箱还是空的',
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      );
    }

    final recent = memories.take(8).toList();
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF17161F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
      ),
      child: Column(
        children: recent.asMap().entries.map((entry) {
          final memory = entry.value;
          return Column(
            children: [
              InkWell(
                onTap: () => _showDetailDialog(context, ref, memory),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: _memoryStatusColor(memory.processingStatus)
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          _sourceTypeIcon(memory.sourceType),
                          color: _memoryStatusColor(memory.processingStatus),
                          size: 17,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    memory.title.isNotEmpty
                                        ? memory.title
                                        : _memoryFallbackTitle(memory),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.outfit(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _formatInboxTime(memory.createdAt),
                                  style: GoogleFonts.shareTechMono(
                                    color: Colors.white30,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              memory.rawContent,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.outfit(
                                color: Colors.white54,
                                fontSize: 11.5,
                                height: 1.3,
                              ),
                            ),
                            if (memory.processingStatus != 'completed') ...[
                              const SizedBox(height: 5),
                              Text(
                                _memoryStatusLabel(memory.processingStatus),
                                style: GoogleFonts.outfit(
                                  color: _memoryStatusColor(
                                      memory.processingStatus),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.chevron_right,
                        color: Colors.white24,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
              if (entry.key < recent.length - 1)
                const Divider(color: Colors.white10, height: 1, indent: 56),
            ],
          );
        }).toList(),
      ),
    );
  }

  String _memoryFallbackTitle(Memory memory) {
    final content = memory.rawContent.trim();
    if (content.isEmpty) return '未命名记忆';
    final runes = content.runes.toList();
    return String.fromCharCodes(runes.take(18));
  }

  String _formatInboxTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return DateFormat('HH:mm').format(date);
    }
    return DateFormat('MM/dd').format(date);
  }

  IconData _sourceTypeIcon(String sourceType) {
    switch (sourceType) {
      case 'image':
        return Icons.image_outlined;
      case 'audio':
        return Icons.graphic_eq;
      case 'file':
        return Icons.description_outlined;
      case 'link':
        return Icons.link;
      default:
        return Icons.notes;
    }
  }

  Color _memoryStatusColor(String status) {
    switch (status) {
      case 'failed':
        return const Color(0xFFEB5757);
      case 'needs_confirmation':
        return const Color(0xFFFF8906);
      case 'pending':
        return const Color(0xFFF2C94C);
      case 'processing':
        return const Color(0xFF56CCF2);
      default:
        return const Color(0xFF10B981);
    }
  }

  String _memoryStatusLabel(String status) {
    switch (status) {
      case 'failed':
        return '解析失败';
      case 'needs_confirmation':
        return '等待确认';
      case 'pending':
        return '等待解析';
      case 'processing':
        return '正在解析';
      default:
        return '已解析';
    }
  }

  // 渲染脑图瀑布 (GridView)
  Widget _buildFlowGrid(List<Memory> memories) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.65,
      ),
      itemCount: memories.length,
      itemBuilder: (context, index) {
        final memory = memories[index];
        final isSelected = _selectedIds.contains(memory.id);
        return _buildMemoryItemCard(memory, isSelected);
      },
    );
  }

  // 渲染时光轨迹 (按日期分组时间轴)
  Widget _buildTimelineList(List<Memory> memories) {
    final grouped = _groupMemoriesByDate(memories);
    final groupKeys = grouped.keys.toList();

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: groupKeys.length,
      itemBuilder: (context, gIndex) {
        final groupTitle = groupKeys[gIndex];
        final groupItems = grouped[groupTitle]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFF8906),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    groupTitle,
                    style: GoogleFonts.shareTechMono(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4.0), // 轴线偏移
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 左侧垂直轴线
                    Container(
                      width: 2,
                      color: Colors.white10,
                    ),
                    const SizedBox(width: 16),
                    // 右侧当天的全部卡片
                    Expanded(
                      child: Column(
                        children: groupItems.map((memory) {
                          final isSelected = _selectedIds.contains(memory.id);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12.0),
                            child: _buildMemoryItemCard(memory, isSelected,
                                isTimeline: true),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // 单张卡片渲染（Flow 与 Timeline 复用，做尺寸及多选适配）
  Widget _buildMemoryItemCard(Memory memory, bool isSelected,
      {bool isTimeline = false}) {
    final date = DateTime.fromMillisecondsSinceEpoch(memory.createdAt * 1000);
    final formattedDate = DateFormat('MM-dd HH:mm').format(date);

    return GestureDetector(
      onLongPress: () {
        if (!_isMultiSelectMode) {
          setState(() {
            _isMultiSelectMode = true;
            _selectedIds.add(memory.id);
          });
        }
      },
      onTap: () {
        if (_isMultiSelectMode) {
          setState(() {
            if (isSelected) {
              _selectedIds.remove(memory.id);
              if (_selectedIds.isEmpty) {
                _isMultiSelectMode = false;
              }
            } else {
              _selectedIds.add(memory.id);
            }
          });
        } else {
          _showDetailDialog(context, ref, memory);
        }
      },
      child: Container(
        height: isTimeline ? 140 : null, // 微调高到 140，保证时间轴卡片高度足够
        decoration: BoxDecoration(
          color: const Color(0xFF1F1E29),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFFFF8906)
                : Colors.deepPurple.withOpacity(0.15),
            width: isSelected ? 2.0 : 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFFFF8906).withOpacity(0.2),
                    blurRadius: 8,
                    spreadRadius: 1,
                  )
                ]
              : null,
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        formattedDate,
                        style: GoogleFonts.shareTechMono(
                            color: Colors.grey, fontSize: 11),
                      ),
                      const Spacer(),
                      if (memory.sourceType != 'text')
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            memory.sourceType.toUpperCase(),
                            style: GoogleFonts.outfit(
                              color: Colors.deepPurpleAccent,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _getPriorityColor(memory.priority)
                              .withOpacity(0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: _getPriorityColor(memory.priority)
                                  .withOpacity(0.4)),
                        ),
                        child: Text(
                          _getPriorityName(memory.priority),
                          style: GoogleFonts.outfit(
                            color: _getPriorityColor(memory.priority),
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (memory.processingStatus != 'completed')
                        _buildProcessingStatus(memory),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (memory.title.isNotEmpty) ...[
                          Text(
                            memory.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              color: const Color(0xFFFF8906), // 高亮深橙色标题
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Expanded(
                            child: Text(
                              memory.rawContent,
                              maxLines: isTimeline ? 3 : 5,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.outfit(
                                color:
                                    Colors.white.withOpacity(0.75), // 增强亮度和对比度
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ] else ...[
                          Expanded(
                            child: Text(
                              memory.rawContent,
                              maxLines: isTimeline ? 4 : 6,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.outfit(
                                color: Colors.white, // 无标题时直接展示标准正文
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (memory.tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: memory.tags.take(2).map((tag) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '#$tag',
                            style: GoogleFonts.outfit(
                                color: Colors.deepPurpleAccent, fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
            // 多选状态 Checkbox
            if (_isMultiSelectMode)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color:
                        isSelected ? const Color(0xFFFF8906) : Colors.black45,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          isSelected ? const Color(0xFFFF8906) : Colors.white24,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, size: 14, color: Colors.black)
                      : null,
                ),
              )
            else
              Positioned(
                top: 2,
                right: 2,
                child: IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _confirmDelete(context, ref, memory.id),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingStatus(Memory memory) {
    late final Color color;
    late final IconData icon;
    late final String label;

    switch (memory.processingStatus) {
      case 'pending':
        color = const Color(0xFFF2C94C);
        icon = Icons.schedule;
        label = '待解析';
        break;
      case 'processing':
        color = const Color(0xFF56CCF2);
        icon = Icons.sync;
        label = '解析中';
        break;
      case 'failed':
        color = const Color(0xFFEB5757);
        icon = Icons.refresh;
        label = '重试';
        break;
      case 'needs_confirmation':
        color = const Color(0xFFFF8906);
        icon = Icons.fact_check_outlined;
        label = '待确认';
        break;
      case 'completed':
        color = const Color(0xFF10B981);
        icon = Icons.check_circle_outline;
        label = '已解析';
        break;
      default:
        color = Colors.grey;
        icon = Icons.help_outline;
        label = '未知';
    }

    final message = memory.processingStatus == 'failed'
        ? (memory.processingError.isEmpty
            ? '解析失败，点按重试'
            : '${memory.processingError}\n点按重试')
        : label;

    return Tooltip(
      message: message,
      child: InkWell(
        onTap: memory.processingStatus == 'failed'
            ? () => _retryMemoryProcessing(memory)
            : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 12),
              const SizedBox(width: 3),
              Text(
                label,
                style: GoogleFonts.outfit(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _retryMemoryProcessing(Memory memory) async {
    try {
      await ref
          .read(assistantProvider.notifier)
          .retryMemoryProcessing(memory.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已重新提交解析')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重试失败：$e')),
      );
    }
  }

  // 底部多选浮动控制栏
  Widget _buildFloatingActionBar(AssistantState state) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF8906).withOpacity(0.4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 20,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Row(
        children: [
          Text(
            '已选择 ${_selectedIds.length} 项',
            style: GoogleFonts.outfit(
                color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              setState(() {
                _isMultiSelectMode = false;
                _selectedIds.clear();
              });
            },
            child: Text('取消', style: GoogleFonts.outfit(color: Colors.grey)),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF8906),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.auto_awesome, size: 16, color: Colors.black),
            label: Text(
              '融合生成长文',
              style: GoogleFonts.outfit(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            onPressed: () async {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFF8906)),
                ),
              );

              try {
                final summary = await ref
                    .read(assistantProvider.notifier)
                    .summarizeSelectedMemories(_selectedIds);

                Navigator.pop(context); // 关掉 Loading
                setState(() {
                  _isMultiSelectMode = false;
                  _selectedIds.clear();
                });

                _showMarkdownPreviewCabin(context, summary);
              } catch (e) {
                Navigator.pop(context); // 关掉 Loading
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('智能总结失败: $e'),
                      backgroundColor: Colors.redAccent),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  // 融合总结预览与本地导出舱
  void _showMarkdownPreviewCabin(BuildContext context, String markdownText) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final nameController = TextEditingController(
          text:
              'JARVIS_知识融合_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}',
        );
        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog.fullscreen(
              backgroundColor: const Color(0xFF0F0E17),
              child: Scaffold(
                backgroundColor: const Color(0xFF0F0E17),
                appBar: AppBar(
                  backgroundColor: const Color(0xFF1F1E29),
                  elevation: 0,
                  title: Text(
                    'JARVIS 知识融合总结',
                    style: GoogleFonts.shareTechMono(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  leading: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.copy, color: Color(0xFFFF8906)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: markdownText));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Markdown 已复制到剪贴板！'),
                              backgroundColor: Colors.green),
                        );
                      },
                    ),
                  ],
                ),
                body: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导出文件名',
                        style: GoogleFonts.outfit(
                            color: Colors.grey, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F1E29),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: TextField(
                          controller: nameController,
                          style: GoogleFonts.shareTechMono(
                              color: Colors.white, fontSize: 14),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: '文件名',
                            hintStyle: TextStyle(color: Colors.grey),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1E29),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: SingleChildScrollView(
                            child: SelectionArea(
                              child: Text(
                                markdownText,
                                style: GoogleFonts.shareTechMono(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF8906),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: const Icon(Icons.save, color: Colors.black),
                              label: Text(
                                '保存到本地 Document 文件夹',
                                style: GoogleFonts.outfit(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              onPressed: () async {
                                final fname = nameController.text.trim();
                                if (fname.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('请输入有效的文件名！'),
                                        backgroundColor: Colors.redAccent),
                                  );
                                  return;
                                }

                                try {
                                  final directory =
                                      await getApplicationDocumentsDirectory();
                                  final file =
                                      io.File('${directory.path}/$fname.md');
                                  await file.writeAsString(markdownText);

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('已成功保存至:\n${file.path}'),
                                      backgroundColor: Colors.green,
                                      duration: const Duration(seconds: 6),
                                    ),
                                  );
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text('保存失败: $e'),
                                        backgroundColor: Colors.redAccent),
                                  );
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // 辅助分组方法
  Map<String, List<Memory>> _groupMemoriesByDate(List<Memory> memories) {
    final Map<String, List<Memory>> groups = {};
    for (final memory in memories) {
      final date = DateTime.fromMillisecondsSinceEpoch(memory.createdAt * 1000);
      final today = DateTime.now();
      final yesterday = today.subtract(const Duration(days: 1));

      String groupKey = '更早';
      if (date.year == today.year &&
          date.month == today.month &&
          date.day == today.day) {
        groupKey = '今天';
      } else if (date.year == yesterday.year &&
          date.month == yesterday.month &&
          date.day == yesterday.day) {
        groupKey = '昨天';
      } else {
        groupKey = DateFormat('yyyy-MM-dd').format(date);
      }

      groups.putIfAbsent(groupKey, () => []).add(memory);
    }
    return groups;
  }

  Widget _buildTabButton(int index, String label) {
    final isActive = _activeTab == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _activeTab = index;
        });
        if (index == 2 && _graphNodes.isEmpty) {
          _loadMindGraph();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFFFF8906) : const Color(0xFF1F1E29),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? const Color(0xFFFF8906) : Colors.white10,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.outfit(
            color: isActive ? Colors.black : Colors.white70,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.15)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 8),
              ] else ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.outfit(fontSize: 12, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: GoogleFonts.shareTechMono(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: GoogleFonts.outfit(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // ────────────── 新增仪表盘组件 ──────────────

  Widget _buildQuickAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: GoogleFonts.outfit(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: GoogleFonts.outfit(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
  }

  // 7 日活跃趋势柱状图
  Widget _buildActivityChart(Map<String, dynamic> stats) {
    final List<dynamic> rawCounts = stats['daily_counts'] ?? [];

    // 构建最近 7 天的数据，填充空缺日期
    final now = DateTime.now();
    final Map<String, int> countMap = {};
    for (final item in rawCounts) {
      if (item is Map<String, dynamic>) {
        countMap[item['date'] ?? ''] = (item['count'] ?? 0) as int;
      }
    }

    final List<BarChartGroupData> barGroups = [];
    final List<String> dayLabels = [];
    double maxY = 5;

    for (int i = 6; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final dateStr = DateFormat('yyyy-MM-dd').format(date);
      final count = countMap[dateStr] ?? 0;
      if (count > maxY) maxY = count.toDouble();

      final weekday = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      dayLabels.add(weekday[date.weekday - 1]);

      barGroups.add(
        BarChartGroupData(
          x: 6 - i,
          barRods: [
            BarChartRodData(
              toY: count.toDouble(),
              color: i == 0 ? const Color(0xFFFF8906) : const Color(0xFF8B5CF6),
              width: 18,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(6)),
              backDrawRodData: BackgroundBarChartRodData(
                show: true,
                toY: maxY + 2,
                color: Colors.white.withOpacity(0.03),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 180,
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: BarChart(
        BarChartData(
          maxY: maxY + 2,
          barGroups: barGroups,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: (maxY / 3).ceilToDouble().clamp(1, 100),
                getTitlesWidget: (value, meta) {
                  return Text(
                    value.toInt().toString(),
                    style: GoogleFonts.shareTechMono(
                        color: Colors.white24, fontSize: 10),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final idx = value.toInt();
                  if (idx >= 0 && idx < dayLabels.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        dayLabels[idx],
                        style: GoogleFonts.outfit(
                            color: Colors.white38, fontSize: 10),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              tooltipBgColor: const Color(0xFF2A2940),
              getTooltipItem: (group, gIdx, rod, rIdx) {
                return BarTooltipItem(
                  '${rod.toY.toInt()} 条',
                  GoogleFonts.outfit(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTaskConfirmationsCard(Map<String, dynamic> stats) {
    final List<dynamic> rawTasks = stats['confirmation_tasks'] ?? [];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF8906).withOpacity(0.25)),
      ),
      child: Column(
        children: rawTasks.asMap().entries.map((entry) {
          final rawTask = entry.value;
          final task = Map<String, dynamic>.from(rawTask as Map);
          final dueSeconds =
              task['due_time'] is int ? task['due_time'] as int : 0;
          final dueDate =
              DateTime.fromMillisecondsSinceEpoch(dueSeconds * 1000);
          final originalDueText = task['original_due_text'] ?? '';
          final sourceContent = task['source_content'] ?? '';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.notifications_none,
                    color: Color(0xFFFF8906),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      task['title'] ?? '未命名提醒',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF8906).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'AI 提取',
                      style: GoogleFonts.outfit(
                        color: const Color(0xFFFF8906),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.schedule, color: Colors.white38, size: 15),
                  const SizedBox(width: 6),
                  Text(
                    DateFormat('yyyy/MM/dd HH:mm').format(dueDate),
                    style: GoogleFonts.shareTechMono(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  if (originalDueText.toString().isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '原文：$originalDueText',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (sourceContent.toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  sourceContent,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                    color: Colors.white54,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: '忽略这条提醒',
                    onPressed: () => _rejectTaskConfirmation(task),
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white38,
                      size: 19,
                    ),
                    constraints:
                        const BoxConstraints.tightFor(width: 36, height: 36),
                  ),
                  IconButton(
                    tooltip: '编辑后确认',
                    onPressed: () => _showTaskConfirmationDialog(task),
                    icon: const Icon(
                      Icons.edit_outlined,
                      color: Colors.white70,
                      size: 18,
                    ),
                    constraints:
                        const BoxConstraints.tightFor(width: 36, height: 36),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    onPressed: () => _confirmTask(task),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('确认'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF8906),
                      foregroundColor: Colors.black,
                      minimumSize: const Size(82, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (entry.key < rawTasks.length - 1)
                Divider(color: Colors.white.withOpacity(0.07), height: 1),
            ],
          );
        }).toList(),
      ),
    );
  }

  Future<void> _confirmTask(Map<String, dynamic> task) async {
    try {
      await ref.read(assistantProvider.notifier).confirmTask(task);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('提醒已确认并启用')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('确认失败：$e')),
      );
    }
  }

  Future<void> _rejectTaskConfirmation(Map<String, dynamic> task) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1F1E29),
        title: const Text('忽略这条提醒？', style: TextStyle(color: Colors.white)),
        content: const Text(
          '忽略后不会创建提醒，原始记忆仍会保留。',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('忽略', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await ref
        .read(assistantProvider.notifier)
        .removeTask(task['id'].toString());
  }

  Future<void> _showTaskConfirmationDialog(Map<String, dynamic> task) async {
    final titleController =
        TextEditingController(text: task['title']?.toString() ?? '');
    final descriptionController =
        TextEditingController(text: task['description']?.toString() ?? '');
    var actionType = task['action_type']?.toString() ?? 'reminder';
    final dueSeconds = task['due_time'] is int ? task['due_time'] as int : 0;
    var dueDate = dueSeconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(dueSeconds * 1000)
        : DateTime.now().add(const Duration(hours: 1));

    final updatedTask = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF1F1E29),
          title: Text(
            '核对提醒',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '标题',
                    labelStyle: TextStyle(color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    labelStyle: TextStyle(color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: actionType,
                  dropdownColor: const Color(0xFF2A2935),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '提醒方式',
                    labelStyle: TextStyle(color: Colors.white54),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'reminder', child: Text('普通提醒')),
                    DropdownMenuItem(value: 'alarm', child: Text('强提醒')),
                    DropdownMenuItem(value: 'api_call', child: Text('自动动作')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setModalState(() => actionType = value);
                    }
                  },
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () async {
                    final pickedDate = await showDatePicker(
                      context: dialogContext,
                      initialDate: dueDate,
                      firstDate:
                          DateTime.now().subtract(const Duration(days: 1)),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (pickedDate == null || !dialogContext.mounted) return;
                    final pickedTime = await showTimePicker(
                      context: dialogContext,
                      initialTime: TimeOfDay.fromDateTime(dueDate),
                    );
                    if (pickedTime == null) return;
                    setModalState(() {
                      dueDate = DateTime(
                        pickedDate.year,
                        pickedDate.month,
                        pickedDate.day,
                        pickedTime.hour,
                        pickedTime.minute,
                      );
                    });
                  },
                  icon: const Icon(Icons.event, size: 18),
                  label: Text(
                    DateFormat('yyyy/MM/dd HH:mm').format(dueDate),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                if (titleController.text.trim().isEmpty) return;
                Navigator.of(dialogContext).pop({
                  ...task,
                  'title': titleController.text.trim(),
                  'description': descriptionController.text.trim(),
                  'action_type': actionType,
                  'due_time': dueDate.millisecondsSinceEpoch ~/ 1000,
                });
              },
              icon: const Icon(Icons.check, size: 16),
              label: const Text('确认'),
            ),
          ],
        ),
      ),
    );

    titleController.dispose();
    descriptionController.dispose();
    if (updatedTask != null && mounted) {
      await _confirmTask(updatedTask);
    }
  }

  // 即将到来的待办任务卡片
  Widget _buildUpcomingTasksCard(Map<String, dynamic> stats) {
    final List<dynamic> rawTasks = stats['upcoming_tasks'] ?? [];

    if (rawTasks.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1E29),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.check_circle,
                  color: Color(0xFF10B981), size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '一切就绪',
                    style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '暂无待处理的提醒或任务',
                    style:
                        GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: rawTasks.take(5).map((task) {
          final title = task['title'] ?? '未命名任务';
          final dueTime = task['due_time'] ?? 0;
          final actionType = task['action_type'] ?? 'reminder';
          final dueDate = DateTime.fromMillisecondsSinceEpoch(
            (dueTime is int ? dueTime : 0) * 1000,
          );
          final formattedTime = DateFormat('MM/dd HH:mm').format(dueDate);

          IconData taskIcon;
          Color taskColor;
          switch (actionType) {
            case 'alarm':
              taskIcon = Icons.alarm;
              taskColor = Colors.redAccent;
              break;
            case 'api_call':
              taskIcon = Icons.api;
              taskColor = Colors.blueAccent;
              break;
            default:
              taskIcon = Icons.notifications_active;
              taskColor = const Color(0xFFFF8906);
          }

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: taskColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(taskIcon, color: taskColor, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formattedTime,
                        style: GoogleFonts.shareTechMono(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: taskColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    actionType,
                    style: GoogleFonts.outfit(
                        color: taskColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () async {
                    final taskId = task['id'];
                    if (taskId != null) {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: const Color(0xFF1F1E29),
                          title: Text('确认删除',
                              style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                          content: Text('确认要永久删除这个待办事项吗？',
                              style: GoogleFonts.outfit(color: Colors.white70)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(false),
                              child: Text('取消',
                                  style: GoogleFonts.outfit(
                                      color: Colors.white38)),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(true),
                              child: Text('删除',
                                  style: GoogleFonts.outfit(
                                      color: Colors.redAccent,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        ref.read(assistantProvider.notifier).removeTask(taskId);
                      }
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                      size: 16,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // AI 画像洞察卡片
  Widget _buildUserProfileCard(Map<String, dynamic> stats) {
    final profileStr = stats['user_profile'] ?? '';

    if (profileStr.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1E29),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF8B5CF6).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.psychology,
                  color: Color(0xFF8B5CF6), size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI 正在学习认识你',
                    style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '多录入一些记忆，AI 将逐步构建你的画像',
                    style:
                        GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 尝试解析 JSON 格式的画像
    Map<String, dynamic>? profileMap;
    try {
      profileMap = jsonDecode(profileStr) as Map<String, dynamic>?;
    } catch (_) {
      profileMap = null;
    }

    if (profileMap != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1E29),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: profileMap.entries.take(5).map((entry) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(top: 6),
                    decoration: const BoxDecoration(
                      color: Color(0xFF8B5CF6),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: '${entry.key}: ',
                            style: GoogleFonts.outfit(
                              color: const Color(0xFF8B5CF6),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          TextSpan(
                            text: '${entry.value}',
                            style: GoogleFonts.outfit(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      );
    }

    // Fallback: 纯文本显示
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.15)),
      ),
      child: Text(
        profileStr.length > 300
            ? '${profileStr.substring(0, 300)}...'
            : profileStr,
        style: GoogleFonts.outfit(
            color: Colors.white70, fontSize: 13, height: 1.5),
      ),
    );
  }

  // 热门标签排行条状图
  Widget _buildTopTagsCard(Map<String, dynamic> stats) {
    final List<dynamic> rawTags = stats['top_tags'] ?? [];

    if (rawTags.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1E29),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFF8906).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.label_off,
                  color: Color(0xFFFF8906), size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '暂无标签数据',
                    style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '录入记忆时 AI 会自动提取标签',
                    style:
                        GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final maxCount = rawTags
        .map((t) => (t['count'] ?? 0) as int)
        .reduce((a, b) => a > b ? a : b);

    final colors = [
      const Color(0xFFFF8906),
      const Color(0xFF8B5CF6),
      const Color(0xFF10B981),
      Colors.blueAccent,
      Colors.pinkAccent,
      Colors.tealAccent,
      Colors.amberAccent,
      Colors.cyanAccent,
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1E29),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: rawTags.asMap().entries.map((entry) {
          final idx = entry.key;
          final tag = entry.value;
          final name = tag['name'] ?? '';
          final count = (tag['count'] ?? 0) as int;
          final ratio = maxCount > 0 ? count / maxCount : 0.0;
          final color = colors[idx % colors.length];

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    '#$name',
                    style: GoogleFonts.outfit(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio,
                      backgroundColor: Colors.white.withOpacity(0.05),
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                      minHeight: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 28,
                  child: Text(
                    '$count',
                    style: GoogleFonts.shareTechMono(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Color _getPriorityColor(int priority) {
    switch (priority) {
      case 3:
        return Colors.redAccent;
      case 2:
        return Colors.orangeAccent;
      case 1:
        return Colors.blueAccent;
      default:
        return Colors.grey;
    }
  }

  String _getPriorityName(int priority) {
    switch (priority) {
      case 3:
        return '紧急';
      case 2:
        return '高';
      case 1:
        return '普通';
      default:
        return '低';
    }
  }

  Widget _buildMemoryMetaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoryOriginalContent(Memory memory) {
    final content = memory.originalContent.isNotEmpty
        ? memory.originalContent
        : memory.rawContent;
    if (memory.sourceType == 'image' && content.startsWith('data:image')) {
      try {
        final encoded = content.substring(content.indexOf(',') + 1);
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(
            base64Decode(encoded),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text(
              '原始图片无法显示',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        );
      } catch (_) {
        return const Text(
          '原始图片无法显示',
          style: TextStyle(color: Colors.redAccent),
        );
      }
    }
    return SelectableText(
      content,
      style: GoogleFonts.outfit(
        color: Colors.white70,
        fontSize: 14,
        height: 1.45,
      ),
    );
  }

  String _sourceTypeLabel(String sourceType) {
    switch (sourceType) {
      case 'image':
        return '图片';
      case 'audio':
        return '语音';
      case 'file':
        return '文件';
      case 'link':
        return '链接';
      case 'note':
        return '笔记';
      case 'contact':
        return '联系人';
      case 'location':
        return '位置';
      default:
        return '文本';
    }
  }

  void _showDetailDialog(BuildContext context, WidgetRef ref, Memory memory) {
    showDialog(
      context: context,
      builder: (context) {
        bool isEditing = false;
        final titleController = TextEditingController(text: memory.title);
        final contentController =
            TextEditingController(text: memory.rawContent);
        final timeController =
            TextEditingController(text: memory.extractedTime);
        final tagsController =
            TextEditingController(text: memory.tags.join(', '));
        int selectedPriority = memory.priority;

        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              backgroundColor: const Color(0xFF1F1E29),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isEditing ? '编辑事实记忆' : '记忆体详情',
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isEditing ? Icons.close : Icons.edit,
                              color: const Color(0xFFFF8906),
                            ),
                            onPressed: () {
                              setState(() {
                                isEditing = !isEditing;
                              });
                            },
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white10),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildProcessingStatus(memory),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8B5CF6).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _sourceTypeLabel(memory.sourceType),
                              style: GoogleFonts.outfit(
                                color: const Color(0xFFB69CFF),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildMemoryMetaRow(
                        '录入时间',
                        DateFormat('yyyy/MM/dd HH:mm').format(
                          DateTime.fromMillisecondsSinceEpoch(
                              memory.createdAt * 1000),
                        ),
                      ),
                      _buildMemoryMetaRow(
                        '最近处理',
                        DateFormat('yyyy/MM/dd HH:mm').format(
                          DateTime.fromMillisecondsSinceEpoch(
                              memory.updatedAt * 1000),
                        ),
                      ),
                      if (memory.sourceMeta.isNotEmpty)
                        _buildMemoryMetaRow('来源信息', memory.sourceMeta),
                      if (memory.processingError.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: Colors.redAccent.withOpacity(0.25)),
                          ),
                          child: Text(
                            memory.processingError,
                            style: GoogleFonts.outfit(
                              color: Colors.redAccent,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text('标题',
                          style: GoogleFonts.outfit(
                              color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 6),
                      isEditing
                          ? TextField(
                              controller: titleController,
                              style: GoogleFonts.outfit(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Colors.black12,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                              ),
                            )
                          : Text(
                              memory.title.isNotEmpty ? memory.title : '（暂无标题）',
                              style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold),
                            ),
                      const SizedBox(height: 16),
                      Text('原始内容',
                          style: GoogleFonts.outfit(
                              color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 6),
                      _buildMemoryOriginalContent(memory),
                      if (isEditing ||
                          memory.rawContent.trim() !=
                              (memory.originalContent.isNotEmpty
                                      ? memory.originalContent
                                      : memory.rawContent)
                                  .trim()) ...[
                        const SizedBox(height: 16),
                        Text('解析内容',
                            style: GoogleFonts.outfit(
                                color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 6),
                        isEditing
                            ? TextField(
                                controller: contentController,
                                maxLines: 5,
                                style: GoogleFonts.outfit(color: Colors.white),
                                decoration: const InputDecoration(
                                  filled: true,
                                  fillColor: Colors.black12,
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.all(10),
                                ),
                              )
                            : SelectableText(
                                memory.rawContent,
                                style: GoogleFonts.outfit(
                                    color: Colors.white70, fontSize: 14),
                              ),
                      ],
                      const SizedBox(height: 16),
                      Text('关联发生时间',
                          style: GoogleFonts.outfit(
                              color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 6),
                      isEditing
                          ? TextField(
                              controller: timeController,
                              style: GoogleFonts.outfit(color: Colors.white),
                              decoration: const InputDecoration(
                                hintText: 'YYYY-MM-DDTHH:mm:SSZ',
                                filled: true,
                                fillColor: Colors.black12,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                              ),
                            )
                          : Text(
                              memory.extractedTime.isNotEmpty
                                  ? memory.extractedTime
                                  : '（未绑定关联时间）',
                              style: GoogleFonts.shareTechMono(
                                  color: Colors.white70, fontSize: 14),
                            ),
                      const SizedBox(height: 16),
                      Text('优先级',
                          style: GoogleFonts.outfit(
                              color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 6),
                      isEditing
                          ? DropdownButtonFormField<int>(
                              value: selectedPriority,
                              dropdownColor: const Color(0xFF1F1E29),
                              style: GoogleFonts.outfit(color: Colors.white),
                              decoration: const InputDecoration(
                                filled: true,
                                fillColor: Colors.black12,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                              ),
                              items: const [
                                DropdownMenuItem(
                                    value: 3,
                                    child: Text('紧急 (P3)',
                                        style: TextStyle(
                                            color: Colors.redAccent))),
                                DropdownMenuItem(
                                    value: 2,
                                    child: Text('高 (P2)',
                                        style: TextStyle(
                                            color: Colors.orangeAccent))),
                                DropdownMenuItem(
                                    value: 1,
                                    child: Text('普通 (P1)',
                                        style: TextStyle(
                                            color: Colors.blueAccent))),
                                DropdownMenuItem(
                                    value: 0,
                                    child: Text('低 (P0)',
                                        style: TextStyle(color: Colors.grey))),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    selectedPriority = val;
                                  });
                                }
                              },
                            )
                          : Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _getPriorityColor(memory.priority)
                                    .withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: _getPriorityColor(memory.priority)),
                              ),
                              child: Text(
                                _getPriorityName(memory.priority),
                                style: GoogleFonts.outfit(
                                    color: _getPriorityColor(memory.priority),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                      const SizedBox(height: 16),
                      Text('关联标签',
                          style: GoogleFonts.outfit(
                              color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 6),
                      isEditing
                          ? TextField(
                              controller: tagsController,
                              style: GoogleFonts.outfit(color: Colors.white),
                              decoration: const InputDecoration(
                                hintText: '用英文逗号分隔，例如: 工作, 账单, 重要',
                                filled: true,
                                fillColor: Colors.black12,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                              ),
                            )
                          : Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: memory.tags.isEmpty
                                  ? [
                                      Text('（暂无标签）',
                                          style: GoogleFonts.outfit(
                                              color: Colors.white38,
                                              fontSize: 13))
                                    ]
                                  : memory.tags.map((tag) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: Colors.deepPurple
                                              .withOpacity(0.15),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          '# $tag',
                                          style: GoogleFonts.outfit(
                                              color: Colors.deepPurpleAccent,
                                              fontSize: 12),
                                        ),
                                      );
                                    }).toList(),
                            ),
                      const SizedBox(height: 24),
                      if (isEditing)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  isEditing = false;
                                  titleController.text = memory.title;
                                  contentController.text = memory.rawContent;
                                  timeController.text = memory.extractedTime;
                                  tagsController.text = memory.tags.join(', ');
                                  selectedPriority = memory.priority;
                                });
                              },
                              child: Text('取消',
                                  style:
                                      GoogleFonts.outfit(color: Colors.grey)),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF8906),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () async {
                                final updatedTags = tagsController.text
                                    .split(',')
                                    .map((t) => t.trim())
                                    .where((t) => t.isNotEmpty)
                                    .toList();

                                final updatedMemory = memory.copyWith(
                                  title: titleController.text.trim(),
                                  rawContent: contentController.text.trim(),
                                  extractedTime: timeController.text.trim(),
                                  priority: selectedPriority,
                                  tags: updatedTags,
                                );

                                Navigator.pop(context);

                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('正在保存更新中...')),
                                );

                                try {
                                  await ref
                                      .read(assistantProvider.notifier)
                                      .updateMemory(updatedMemory);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('记忆更新已保存！'),
                                        backgroundColor: Colors.green),
                                  );
                                } catch (e) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text('保存更新失败: $e'),
                                        backgroundColor: Colors.redAccent),
                                  );
                                }
                              },
                              child: Text('保存',
                                  style: GoogleFonts.outfit(
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, String id) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1E29),
          title: Text('删除记忆',
              style: GoogleFonts.outfit(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          content: Text('确认要从 SQLite 数据库和 Qdrant 向量存储中删除该条神经事实吗？此操作无法撤销。',
              style: GoogleFonts.outfit(color: Colors.grey)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消', style: GoogleFonts.outfit(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
              ),
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await ref.read(assistantProvider.notifier).removeMemory(id);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('事实记忆已成功清除。'),
                        backgroundColor: Colors.green),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text('删除失败: $e'),
                        backgroundColor: Colors.redAccent),
                  );
                }
              },
              child: Text('清除',
                  style: GoogleFonts.outfit(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  // 渲染思维脑图网核心交互画布
  Widget _buildMindGraphCanvas() {
    if (_isLoadingGraph) {
      return const SizedBox(
        height: 500,
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFFFF8906)),
        ),
      );
    }

    if (_graphError != null) {
      return SizedBox(
        height: 500,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('载入脑图网失败',
                  style: GoogleFonts.outfit(
                      color: Colors.redAccent, fontSize: 16)),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _loadMindGraph,
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF8906)),
                child:
                    Text('重试', style: GoogleFonts.outfit(color: Colors.black)),
              ),
            ],
          ),
        ),
      );
    }

    if (_graphNodes.isEmpty) {
      return SizedBox(
        height: 500,
        child: Center(
          child: Column(
            // 脑图为空在 API 返回时可能是空数据
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('目前还没有脑图网络节点数据',
                  style: GoogleFonts.outfit(color: Colors.grey)),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _loadMindGraph,
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF8906)),
                child: Text('加载数据',
                    style: GoogleFonts.outfit(color: Colors.black)),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      height: 540,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF0C0B12), // 星空网络深色背景
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
      ),
      child: Stack(
        children: [
          // 手势捕捉区
          GestureDetector(
            onScaleStart: (details) {
              final touchPoint = details.localFocalPoint;
              // 将屏幕物理坐标系转换为 Canvas 缩放平移后的逻辑坐标系
              final logicalX = (touchPoint.dx - _graphOffset.dx) / _graphScale;
              final logicalY = (touchPoint.dy - _graphOffset.dy) / _graphScale;

              _panStartLocalPoint = touchPoint;
              _panStartTime = DateTime.now();

              // 检测是否触碰到某个节点的几何碰撞域
              GraphNode? hitNode;
              for (final node in _graphNodes) {
                final double dx = node.x - logicalX;
                final double dy = node.y - logicalY;
                final double distance = sqrt(dx * dx + dy * dy);
                // 默认判定碰撞半径为 25
                if (distance < 25.0) {
                  hitNode = node;
                  break;
                }
              }

              if (hitNode != null) {
                _draggedNode = hitNode;
                _draggedNode!.isDragging = true;
                _draggedNode!.vx = 0;
                _draggedNode!.vy = 0;
              } else {
                _draggedNode = null;
                _baseOffset = _graphOffset;
                _baseScale = _graphScale;
              }
              _wakeUpPhysics();
            },
            onScaleUpdate: (details) {
              _lastLocalFocalPoint = details.localFocalPoint;
              if (_draggedNode != null) {
                setState(() {
                  _draggedNode!.x =
                      (details.localFocalPoint.dx - _graphOffset.dx) /
                          _graphScale;
                  _draggedNode!.y =
                      (details.localFocalPoint.dy - _graphOffset.dy) /
                          _graphScale;
                  _draggedNode!.vx = 0;
                  _draggedNode!.vy = 0;
                });
              } else {
                setState(() {
                  if (details.pointerCount > 1) {
                    _graphScale = (_baseScale * details.scale).clamp(0.4, 3.0);
                  }
                  _graphOffset = _baseOffset + details.focalPointDelta;
                });
              }
              _wakeUpPhysics();
            },
            onScaleEnd: (details) {
              if (_draggedNode != null) {
                final duration = DateTime.now().difference(_panStartTime);
                final distance =
                    (_lastLocalFocalPoint - _panStartLocalPoint).distance;

                // 判断为点击而非拖动
                if (duration.inMilliseconds < 250 && distance < 6.0) {
                  // Phase 7.0: 拦截并处理社区折叠/展开点击
                  final commId = _draggedNode!.communityId;
                  final commSize = _draggedNode!.communitySize;
                  if (commId != null &&
                      commSize >= 3 &&
                      _draggedNode!.isClusterLeader) {
                    setState(() {
                      if (_expandedCommunities.contains(commId)) {
                        _expandedCommunities.remove(commId);
                      } else {
                        _expandedCommunities.add(commId);
                        // 物理弹射爆炸动效：初始化节点到 leader 附近并给予随机向外的强初速度
                        final leaderNode = _draggedNode!;
                        final r = Random();
                        for (final member in _rawNodes) {
                          if (member.communityId == commId &&
                              member.id != leaderNode.id) {
                            member.x =
                                leaderNode.x + (r.nextDouble() - 0.5) * 35.0;
                            member.y =
                                leaderNode.y + (r.nextDouble() - 0.5) * 35.0;
                            final double angle = r.nextDouble() * 2 * pi;
                            const double speed = 360.0;
                            member.vx = cos(angle) * speed;
                            member.vy = sin(angle) * speed;
                          }
                        }
                      }
                      _applyGraphFilter();
                    });
                    _wakeUpPhysics();
                    _draggedNode!.isDragging = false;
                    _draggedNode = null;
                    return; // 结束执行，阻止弹出详情抽屉
                  }

                  setState(() {
                    if (_selectedNode?.id == _draggedNode!.id) {
                      _selectedNode = null;
                    } else {
                      _selectedNode = _draggedNode;
                    }
                  });

                  if (_selectedNode != null &&
                      _selectedNode!.type == 'memory') {
                    final state = ref.read(assistantProvider);
                    final mem = state.memories.firstWhere(
                      (m) => m.id == _selectedNode!.id,
                      orElse: () => Memory(
                        id: _selectedNode!.id,
                        rawContent: _selectedNode!.label,
                        extractedTime: '',
                        priority: 1,
                        sourceType: 'text',
                        sourceMeta: '',
                        createdAt:
                            DateTime.now().millisecondsSinceEpoch ~/ 1000,
                        updatedAt:
                            DateTime.now().millisecondsSinceEpoch ~/ 1000,
                        tags: [],
                        title: _selectedNode!.label,
                      ),
                    );
                    _showDetailDialog(context, ref, mem);
                  }
                }

                _draggedNode!.isDragging = false;
                _draggedNode = null;
              }
              _wakeUpPhysics();
            },
            child: CustomPaint(
              size: Size.infinite,
              painter: MindGraphPainter(
                nodes: _graphNodes,
                links: _graphLinks,
                selectedNode: _selectedNode,
                scale: _graphScale,
                offset: _graphOffset,
              ),
            ),
          ),

          // 展现隐藏关联实体控制开关（顶部偏右）
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1E29).withOpacity(0.85),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '展现二级实体',
                    style:
                        GoogleFonts.outfit(color: Colors.white70, fontSize: 11),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 20,
                    width: 35,
                    child: Switch(
                      value: _showSecondaryEntities,
                      activeColor: const Color(0xFFFF8906),
                      onChanged: (val) {
                        setState(() {
                          _showSecondaryEntities = val;
                        });
                        _applyGraphFilter();
                        _wakeUpPhysics();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 浮动控制工具按钮
          Positioned(
            bottom: 12,
            right: 12,
            child: Row(
              children: [
                _buildCanvasControlButton(
                  icon: Icons.refresh,
                  onPressed: _loadMindGraph,
                  tooltip: '刷新拓扑脑图',
                ),
                const SizedBox(width: 8),
                _buildCanvasControlButton(
                  icon: Icons.center_focus_strong,
                  onPressed: () {
                    setState(() {
                      _selectedNode = null;
                    });
                    _autoFitGraph();
                    _wakeUpPhysics();
                  },
                  tooltip: '自适应居中',
                ),
              ],
            ),
          ),

          // 顶部显示选中的神经卡片详情
          if (_selectedNode != null)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1E29).withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _selectedNode!.type == 'tag'
                        ? const Color(0xFF8B5CF6)
                        : const Color(0xFFFF8906),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _selectedNode!.type == 'tag'
                          ? Icons.label
                          : Icons.psychology,
                      color: _selectedNode!.type == 'tag'
                          ? const Color(0xFF8B5CF6)
                          : const Color(0xFFFF8906),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _selectedNode!.type == 'tag'
                            ? '当前选中标签: #${_selectedNode!.label}'
                            : '当前选中记忆: ${_selectedNode!.label}',
                        style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedNode = null;
                        });
                      },
                      child:
                          const Icon(Icons.close, color: Colors.grey, size: 18),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCanvasControlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1F1E29).withOpacity(0.85),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white10),
          ),
          child: Icon(icon, color: Colors.white70, size: 18),
        ),
      ),
    );
  }

  Widget _buildVoiceCabinFloatingButton(BuildContext context) {
    return FloatingActionButton(
      heroTag: 'voice_cabin_btn',
      backgroundColor: const Color(0xFF030914),
      elevation: 6,
      shape: const CircleBorder(
        side: BorderSide(color: Color(0xFF00F0FF), width: 1.5),
      ),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const VoiceCabinView()),
        );
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00F0FF).withOpacity(0.35),
                  blurRadius: 10,
                  spreadRadius: 1,
                )
              ],
            ),
          ),
          const Icon(Icons.mic, color: Color(0xFF00F0FF), size: 28),
        ],
      ),
    );
  }
}

// ────────────── 思维脑图图谱辅助实体与 CustomPainter ──────────────

class GraphNode {
  final String id;
  final String label;
  final String type; // "memory", "tag", "entity"
  final String?
      entityType; // "person", "location", "organization", "event", etc.
  double x;
  double y;
  double vx = 0;
  double vy = 0;
  bool isDragging = false;

  // New fields for GraphRAG community detection and clustering
  String? communityId;
  bool isClusterLeader;
  int communitySize;
  bool isCommunityExpanded;

  GraphNode({
    required this.id,
    required this.label,
    required this.type,
    this.entityType,
    required this.x,
    required this.y,
    this.communityId,
    this.isClusterLeader = false,
    this.communitySize = 1,
    this.isCommunityExpanded = false,
  });
}

class GraphLink {
  final String source;
  final String target;
  final String type; // "tag", "similar", "graph_rag", "memory_entity"
  final String? label; // 关系描述，如 "开发了"

  GraphLink({
    required this.source,
    required this.target,
    required this.type,
    this.label,
  });
}

class MindGraphPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphLink> links;
  final GraphNode? selectedNode;
  final double scale;
  final Offset offset;

  MindGraphPainter({
    required this.nodes,
    required this.links,
    required this.selectedNode,
    required this.scale,
    required this.offset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);

    // 建立高亮集
    final Set<String> connectedNodeIds = {};
    if (selectedNode != null) {
      connectedNodeIds.add(selectedNode!.id);
      for (final link in links) {
        if (link.source == selectedNode!.id) {
          connectedNodeIds.add(link.target);
        } else if (link.target == selectedNode!.id) {
          connectedNodeIds.add(link.source);
        }
      }
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    // 1. 绘制连边
    for (final link in links) {
      final sourceNode = _findNode(link.source);
      final targetNode = _findNode(link.target);
      if (sourceNode == null || targetNode == null) continue;

      bool isHighlighted = true;
      double opacityFactor = 1.0;
      if (selectedNode != null) {
        if (link.source == selectedNode!.id ||
            link.target == selectedNode!.id) {
          isHighlighted = true;
          opacityFactor = 1.0;
        } else {
          isHighlighted = false;
          opacityFactor = 0.08;
        }
      }

      final double strokeWidth = isHighlighted ? 1.6 : 0.8;
      Color color;
      if (link.type == 'similar') {
        color = const Color(0xFFFF8906)
            .withOpacity(isHighlighted ? 0.7 : 0.2 * opacityFactor);
      } else if (link.type == 'graph_rag') {
        color = const Color(0xFF00E5FF)
            .withOpacity(isHighlighted ? 0.6 : 0.15 * opacityFactor);
      } else if (link.type == 'memory_entity') {
        color = Colors.cyanAccent
            .withOpacity(isHighlighted ? 0.4 : 0.1 * opacityFactor);
      } else {
        color = const Color(0xFF8B5CF6)
            .withOpacity(isHighlighted ? 0.5 : 0.12 * opacityFactor);
      }

      final paint = Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke;

      canvas.drawLine(
        Offset(sourceNode.x, sourceNode.y),
        Offset(targetNode.x, targetNode.y),
        paint,
      );

      // 如果是 GraphRAG 语义连边，并在连线中点位置使用 TextPainter 绘制关系描述
      if (link.type == 'graph_rag' &&
          link.label != null &&
          link.label!.isNotEmpty) {
        final double midX = (sourceNode.x + targetNode.x) / 2;
        final double midY = (sourceNode.y + targetNode.y) / 2;

        final labelPainter = TextPainter(
          textDirection: ui.TextDirection.ltr,
          textAlign: TextAlign.center,
        );

        labelPainter.text = TextSpan(
          text: link.label,
          style: TextStyle(
            color: const Color(0xFF00E5FF)
                .withOpacity(isHighlighted ? 1.0 : 0.3 * opacityFactor),
            fontSize: 7.5,
            fontWeight: FontWeight.bold,
          ),
        );
        labelPainter.layout();

        // 绘制半透明气泡背景，防止直线直接穿透文字导致无法看清
        final rectPaint = Paint()
          ..color = const Color(0xFF0C0B12)
              .withOpacity(isHighlighted ? 0.9 : 0.25 * opacityFactor)
          ..style = PaintingStyle.fill;

        final rect = Rect.fromLTWH(
          midX - labelPainter.width / 2 - 4,
          midY - labelPainter.height / 2 - 2,
          labelPainter.width + 8,
          labelPainter.height + 4,
        );

        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)),
          rectPaint,
        );

        // 绘制微弱发光边框，强化科技感
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)),
          Paint()
            ..color = const Color(0xFF00E5FF)
                .withOpacity(isHighlighted ? 0.35 : 0.08 * opacityFactor)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5,
        );

        labelPainter.paint(
          canvas,
          Offset(midX - labelPainter.width / 2, midY - labelPainter.height / 2),
        );
      }
    }

    // 2. 绘制节点
    for (final node in nodes) {
      bool isDimmed = false;
      if (selectedNode != null && !connectedNodeIds.contains(node.id)) {
        isDimmed = true;
      }

      final double opacity = isDimmed ? 0.22 : 1.0;
      final bool isSelected = selectedNode?.id == node.id;

      // Memory: 19.0, Tag: 15.0, Entity: 14.0
      final double radius = node.type == 'tag'
          ? 15.0
          : node.type == 'entity'
              ? 14.0
              : 19.0;
      final Color nodeColor = node.type == 'tag'
          ? const Color(0xFF8B5CF6)
          : node.type == 'entity'
              ? const Color(0xFF00E5FF) // 语义实体采用青色霓虹发光
              : const Color(0xFFFF8906);

      // A. 发光霓虹阴影
      final shadowPaint = Paint()
        ..color =
            nodeColor.withOpacity(isSelected ? 0.55 * opacity : 0.18 * opacity)
        ..maskFilter =
            MaskFilter.blur(BlurStyle.normal, isSelected ? 10.0 : 5.0);
      canvas.drawCircle(Offset(node.x, node.y),
          radius + (isSelected ? 5.0 : 2.5), shadowPaint);

      // B. 实体节点
      final bodyPaint = Paint()
        ..color = nodeColor.withOpacity(0.9 * opacity)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(node.x, node.y), radius, bodyPaint);

      // E. 绘制折叠状态下的社区外环与计数角标 (Cluster Indicator & Badge)
      if (node.isClusterLeader &&
          node.communitySize >= 3 &&
          !node.isCommunityExpanded) {
        final ringPaint = Paint()
          ..color = const Color(0xFF00FFCC).withOpacity(0.55 * opacity)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(Offset(node.x, node.y), radius + 6.0, ringPaint);

        // 绘制计数角标
        final badgePainter = TextPainter(textDirection: ui.TextDirection.ltr);
        badgePainter.text = TextSpan(
          text: '+${node.communitySize - 1}',
          style: const TextStyle(
            color: Color(0xFF00FFCC),
            fontSize: 7.5,
            fontWeight: FontWeight.bold,
          ),
        );
        badgePainter.layout();

        final double badgeX = node.x + radius + 1.0;
        final double badgeY = node.y - radius - 5.0;

        final badgeBg = Paint()
          ..color = const Color(0xFF0C0B12)
          ..style = PaintingStyle.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(badgeX - 2, badgeY - 1, badgePainter.width + 4,
                badgePainter.height + 2),
            const Radius.circular(3),
          ),
          badgeBg,
        );

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(badgeX - 2, badgeY - 1, badgePainter.width + 4,
                badgePainter.height + 2),
            const Radius.circular(3),
          ),
          Paint()
            ..color = const Color(0xFF00FFCC).withOpacity(0.4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5,
        );

        badgePainter.paint(canvas, Offset(badgeX, badgeY));
      }

      // C. 绘制中心标识
      final textPainter = TextPainter(
        textDirection: ui.TextDirection.ltr,
      );

      String centerSymbol = '🧠';
      if (node.type == 'tag') {
        centerSymbol = '#';
      } else if (node.type == 'entity') {
        final et = node.entityType?.toLowerCase() ?? '';
        if (et.contains('person') || et.contains('user')) {
          centerSymbol = '👤';
        } else if (et.contains('loc') ||
            et.contains('place') ||
            et.contains('address')) {
          centerSymbol = '📍';
        } else if (et.contains('org') ||
            et.contains('comp') ||
            et.contains('group')) {
          centerSymbol = '🏢';
        } else if (et.contains('event') ||
            et.contains('time') ||
            et.contains('date')) {
          centerSymbol = '📅';
        } else {
          centerSymbol = '🔹';
        }
      }

      textPainter.text = TextSpan(
        text: centerSymbol,
        style: TextStyle(
          color: Colors.white.withOpacity(opacity),
          fontSize: node.type == 'tag' ? 11.0 : 12.0,
          fontWeight: FontWeight.bold,
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(node.x - textPainter.width / 2, node.y - textPainter.height / 2),
      );

      // D. 绘制文字描述
      final labelPainter = TextPainter(
        textDirection: ui.TextDirection.ltr,
        textAlign: TextAlign.center,
      );
      String displayLabel = node.label;
      if (displayLabel.length > 6) {
        displayLabel = displayLabel.substring(0, 6) + '...';
      }

      labelPainter.text = TextSpan(
        text: node.type == 'tag' ? '#$displayLabel' : displayLabel,
        style: TextStyle(
          color: (isSelected ? const Color(0xFFFF8906) : Colors.white70)
              .withOpacity(opacity),
          fontSize: 9.5,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      );
      labelPainter.layout();
      labelPainter.paint(
        canvas,
        Offset(node.x - labelPainter.width / 2, node.y + radius + 5.0),
      );
    }

    canvas.restore();
  }

  GraphNode? _findNode(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant MindGraphPainter oldDelegate) {
    return true;
  }
}
