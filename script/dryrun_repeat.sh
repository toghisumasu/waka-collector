#!/usr/bin/env bash
# dryrun_hyakuin.rb を5回連続実行し不安定性を検証する

PROJECT_DIR="/Volumes/externalHDD/projects/waka-collector"
LOG_DIR="$PROJECT_DIR/log"
SUMMARY_MD="$LOG_DIR/dryrun_repeat_summary.md"
RUNS=5

cd "$PROJECT_DIR"

# ─── サマリーファイル初期化 ───────────────────────────────────────
{
  echo "# dryrun_repeat 結果サマリー"
  echo ""
  echo "実行日時: $(date '+%Y-%m-%d %H:%M')"
  echo ""
  echo "| 回 | 開始 | 終了 | 完走 | 最終句 | FORCED数 | ichiza違反 | 句去違反 | 47句通過 | 70句通過 |"
  echo "|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|"
} > "$SUMMARY_MD"

echo "========================================"
echo "dryrun_repeat 開始: $(date '+%Y-%m-%d %H:%M:%S')"
echo "サマリー出力先: $SUMMARY_MD"
echo "========================================"

# ─── 5回ループ ────────────────────────────────────────────────────
for N in $(seq 1 $RUNS); do
  TIMESTAMP=$(date +%H%M)
  STDOUT_LOG="$LOG_DIR/dryrun_repeat_run${N}_${TIMESTAMP}.log"
  STDERR_LOG="$LOG_DIR/dryrun_repeat_run${N}_${TIMESTAMP}_stderr.log"

  START_TIME=$(date '+%H:%M:%S')
  echo ""
  echo "--- Run ${N}/${RUNS} 開始: ${START_TIME} ---"
  echo "  stdout: $STDOUT_LOG"
  echo "  stderr: $STDERR_LOG"

  # 実行（クラッシュしても継続するため exit code は捨てる）
  bundle exec ruby script/dryrun_hyakuin.rb \
    > "$STDOUT_LOG" \
    2> "$STDERR_LOG" \
    || true

  END_TIME=$(date '+%H:%M:%S')

  # ─── 結果集計 ───────────────────────────────────────────────────
  COMPLETED="否"
  LAST_VERSE="0"
  FORCED_COUNT="0"
  ICHIZA_COUNT="0"
  KUZARI_COUNT="0"
  PASS_47="否"
  PASS_70="否"

  if [ -f "$STDOUT_LOG" ]; then
    # 完走確認（完了メッセージ有無）
    if grep -q "独吟百韻ドライラン完了" "$STDOUT_LOG"; then
      COMPLETED="完走"
    fi

    # 到達した最終句番号
    RAW_LAST=$(grep -oE '\] [0-9]{3} \|' "$STDOUT_LOG" \
                 | grep -oE '[0-9]{3}' \
                 | sort -n \
                 | tail -1 \
                 | sed 's/^0*//')
    LAST_VERSE="${RAW_LAST:-0}"

    # FORCED 句数
    FORCED_COUNT=$(grep -c "FORCED" "$STDOUT_LOG" || echo "0")

    # ichiza 違反数（一座一句物検出）
    ICHIZA_COUNT=$(grep -c "一座一句物" "$STDOUT_LOG" || echo "0")

    # 句去違反数（kuzari_violations 由来の "句去" 文字列）
    KUZARI_COUNT=$(grep -c "句去" "$STDOUT_LOG" || echo "0")

    # 47句目・70句目の通過確認
    grep -qE '\] 047 \|' "$STDOUT_LOG" && PASS_47="通過" || true
    grep -qE '\] 070 \|' "$STDOUT_LOG" && PASS_70="通過" || true
  fi

  echo "  => 完走:${COMPLETED} / 最終句:${LAST_VERSE}句 / FORCED:${FORCED_COUNT} / ichiza:${ICHIZA_COUNT} / 句去:${KUZARI_COUNT} / 47句:${PASS_47} / 70句:${PASS_70}"

  # サマリー表に1行追記
  echo "| ${N} | ${START_TIME} | ${END_TIME} | ${COMPLETED} | ${LAST_VERSE}句 | ${FORCED_COUNT} | ${ICHIZA_COUNT} | ${KUZARI_COUNT} | ${PASS_47} | ${PASS_70} |" \
    >> "$SUMMARY_MD"
done

# ─── フッター ─────────────────────────────────────────────────────
{
  echo ""
  echo "---"
  echo ""
  echo "_自動生成: $(date '+%Y-%m-%d %H:%M:%S')_"
} >> "$SUMMARY_MD"

echo ""
echo "========================================"
echo "dryrun_repeat 全${RUNS}回完了: $(date '+%Y-%m-%d %H:%M:%S')"
echo "サマリー: $SUMMARY_MD"
echo "========================================"
