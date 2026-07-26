# Prometheus Stack Deploy — Prometheus 监控栈部署模块（规划中）

## 概述

自动化部署 Prometheus + Grafana + Alertmanager 监控体系到 K8s 集群。

## 状态

**规划中** — 目录结构将完全复用 `k8s_cluster_deploy` 模板。

## 计划支持

- Prometheus Server（含持久化存储）
- Grafana（含预置 Dashboard）
- Alertmanager（告警路由）
- Node Exporter / kube-state-metrics
- Loki 日志聚合（可选）
