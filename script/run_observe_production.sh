#!/usr/bin/env bash
# observe_production_hyakuin.rb 起動用ラッパー — 其の四十六バックログ②
#
# rails runner呼び出しに `2>&1 | tee` を追加し、Rubyの未捕捉例外バックトレース
# を確実にファイル保存する。run5では、プロセスが無言で終了した際にどの例外が
# 投げられたかが復元不可能だった（tmuxスクロールバックが空、stderr保存設定
# なし）。バックログ①（rescue範囲見直し）とは独立だが、合わせて対応すると
# 次回同様の停止が起きた際の原因究明が容易になる（docs/handover_20260717_
# 其の四十.md バックログ①②参照）。
#
# 使用法（tmux等、長時間実行はユーザー自身のターミナルから直接起動すること。
# Claude Code経由のtmux起動はセッションが消失することがある）:
#   script/run_observe_production.sh              # 100句
#   script/run_observe_production.sh 5             # スモークテスト（5句）
#   script/run_observe_production.sh 100 run7       # ログ/observation_batchにrun7タグを付与

set -euo pipefail

PROJECT_DIR="/Volumes/externalHDD/projects/waka-collector"
cd "$PROJECT_DIR"

TOTAL_VERSES="${1:-100}"
RUN_TAG="${2:-}"
TAG_SUFFIX="${RUN_TAG:+${RUN_TAG}_}"
RUN_DATE=$(date +%Y%m%d)
STDERR_LOG="$PROJECT_DIR/log/observation_stderr_${TAG_SUFFIX}${RUN_DATE}.log"

echo "stderrログ: $STDERR_LOG"

bundle exec rails runner script/observe_production_hyakuin.rb "$TOTAL_VERSES" "$RUN_TAG" \
  2>&1 | tee "$STDERR_LOG"
