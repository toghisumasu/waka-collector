#!/usr/bin/env bash
# run_observe_and_summarize.sh — 其の四十八：100句run自動化＋結果サマリー
#
# run_observe_production.sh（其の四十六、D-46-1）と同じくobserve_production_hyakuin.rb
# 本体は無変更のまま、rails runnerの起動をラップする。追加で、実行完了後に
# jsonlログ・stderrログを自動集計してサマリーファイル（log/observation_<tag>_summary.txt）
# に書き出す。完走したかクラッシュしたか、クラッシュした場合はD-47-1（其の四十七）の
# rescueが記録したstage/verse_noをそのまま抜き出して報告する。
#
# 放置運用を想定（tmux起動→本スクリプト実行→デタッチ→完全放置）。set -e は
# 意図的に使わない。rails runnerが非0で終了しても、その後の集計・サマリー書き出しを
# 必ず実行するため（クラッシュ時こそサマリーが必要）。
#
# 使用法:
#   script/run_observe_and_summarize.sh <RUN_TAG> [TOTAL_VERSES]
#   例: script/run_observe_and_summarize.sh sono48_run1        # 100句（デフォルト）
#       script/run_observe_and_summarize.sh sono48_smoke 5     # 5句スモーク
#
# observe_production_hyakuin.rb・RengasController・RengaGenerator・
# ShikimokuChecker本体は無変更（D-33-1対象外の新規スクリプトのため今回は
# 承認ゲート不要と判断。詳細はdocs/依頼書_其の四十八_D-47-1実戦検証.md参照）。

set -uo pipefail

PROJECT_DIR="/Volumes/externalHDD/projects/waka-collector"
cd "$PROJECT_DIR"

if [ -z "${1:-}" ]; then
  echo "使用法: $0 <RUN_TAG> [TOTAL_VERSES]" >&2
  exit 2
fi
RUN_TAG="$1"
TOTAL_VERSES="${2:-100}"
RUN_DATE=$(date +%Y%m%d)

STDERR_LOG="$PROJECT_DIR/log/observation_stderr_${RUN_TAG}_${RUN_DATE}.log"
JSONL_LOG="$PROJECT_DIR/log/observation_sono39_${RUN_TAG}_${RUN_DATE}.jsonl"
SUMMARY_PATH="$PROJECT_DIR/log/observation_${RUN_TAG}_summary.txt"

echo "stderrログ: $STDERR_LOG"
echo "jsonlログ: $JSONL_LOG"
echo "サマリー出力先: $SUMMARY_PATH"

bundle exec rails runner script/observe_production_hyakuin.rb "$TOTAL_VERSES" "$RUN_TAG" \
  2>&1 | tee "$STDERR_LOG"
EXIT_CODE="${PIPESTATUS[0]}"

{
  echo "===================================================="
  echo "其の四十八 D-47-1実戦検証 実行サマリー"
  echo "実行日時: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "タグ: ${RUN_TAG}　目標句数: ${TOTAL_VERSES}"
  echo "stderrログ: ${STDERR_LOG}"
  echo "jsonlログ: ${JSONL_LOG}"
  echo "rails runner終了コード: ${EXIT_CODE}"
  echo "===================================================="
  echo

  if [ ! -f "$JSONL_LOG" ]; then
    echo "【異常】jsonlログが見つかりません（${JSONL_LOG}）。プロセス起動自体に失敗した可能性があります。stderrログを直接確認してください。"
  else
    STATS_JSON=$(jq -s --argjson v "$TOTAL_VERSES" '
      {
        total_attempts: ([.[] | select(.action as $a | ["retry","exhausted","forced_zatsu","forced_zatsu_mora_ng","forced_zatsu_create","create"] | index($a))] | length),
        total_ng: ([.[] | select(.action as $a | ["retry","exhausted","forced_zatsu","forced_zatsu_mora_ng"] | index($a))] | length),
        forced_zatsu_creates: ([.[] | select(.action == "forced_zatsu_create")] | length),
        forced_zatsu_mora_ng: ([.[] | select(.action == "forced_zatsu_mora_ng")] | length),
        error_count: ([.[] | select(.action == "error")] | length),
        max_verse_no: (map(.verse_no) | max),
        reached_target: (any(.[]; .verse_no == $v))
      } as $r
      | $r + { ng_rate: (if $r.total_attempts > 0 then ((($r.total_ng * 1000 / $r.total_attempts) | round) / 10) else 0 end) }
    ' "$JSONL_LOG")

    MAX_VERSE=$(jq -r '.max_verse_no' <<< "$STATS_JSON")
    REACHED=$(jq -r '.reached_target' <<< "$STATS_JSON")
    TOTAL_ATTEMPTS=$(jq -r '.total_attempts' <<< "$STATS_JSON")
    TOTAL_NG=$(jq -r '.total_ng' <<< "$STATS_JSON")
    NG_RATE=$(jq -r '.ng_rate' <<< "$STATS_JSON")
    FZ_CREATE=$(jq -r '.forced_zatsu_creates' <<< "$STATS_JSON")
    FZ_MORA_NG=$(jq -r '.forced_zatsu_mora_ng' <<< "$STATS_JSON")
    ERROR_COUNT=$(jq -r '.error_count' <<< "$STATS_JSON")

    echo "--- 1. 完走判定 ---"
    if [ "$EXIT_CODE" = "0" ] && [ "$REACHED" = "true" ]; then
      echo "完走（verse_no:${TOTAL_VERSES}到達、終了コード0）"
    elif [ "$REACHED" = "true" ]; then
      echo "verse_no:${TOTAL_VERSES}の行は存在するが終了コードが非0（${EXIT_CODE}）→ 要確認"
    else
      echo "未完走（最大到達verse_no: ${MAX_VERSE}、終了コード: ${EXIT_CODE}）"
    fi
    echo

    echo "--- 2. クラッシュ時のstage/verse_no（D-47-1由来のstderrログ） ---"
    LAST_STAGE_BLOCK=$(grep -a -A1 '^\[observe_production_hyakuin\]' "$STDERR_LOG" | tail -2)
    if [ -n "$LAST_STAGE_BLOCK" ]; then
      echo "$LAST_STAGE_BLOCK"
    elif [ "$EXIT_CODE" != "0" ]; then
      echo "D-47-1のrescue経由のログなし（ループ外、または既存3rescue[RuntimeError/Net::ReadTimeout/RetryExhausted]の経路でクラッシュした可能性）。stderrログ全文（${STDERR_LOG}）を確認してください。"
    else
      echo "該当なし（クラッシュしていません）"
    fi
    echo

    echo "--- 3. 集計値（jsonlログから再集計、観測スクリプト自身のカウンタと同じロジック） ---"
    echo "総試行回数: ${TOTAL_ATTEMPTS}"
    echo "総ng回数:   ${TOTAL_NG}"
    echo "ng率:       ${NG_RATE}%"
    echo "forced_zatsu採用: ${FZ_CREATE}句（うちモーラng許容: ${FZ_MORA_NG}句）"
    echo

    echo "--- 4. action:\"error\"（D-47-1由来ログ）の有無 ---"
    echo "件数: ${ERROR_COUNT}"
    if [ "$ERROR_COUNT" != "0" ]; then
      echo "【強調】action:\"error\"エントリ詳細:"
      jq -c 'select(.action == "error")' "$JSONL_LOG"
    fi
    echo

    echo "--- 5. 其の四十五までのRun1〜4との比較参考値 ---"
    echo "其の四十五 Run1〜4のng率レンジ: 31.7%〜40.2%（docs/architecture_decisions.md該当箇所参照）"
    if (( $(echo "$NG_RATE >= 31.7 && $NG_RATE <= 40.2" | bc -l) )); then
      echo "今回のng率（${NG_RATE}%）はこのレンジ内。"
    else
      echo "今回のng率（${NG_RATE}%）はこのレンジ外（要確認。ただしn数が少ないため即座に異常とは断定しない）。"
    fi
  fi
} > "$SUMMARY_PATH"

cat "$SUMMARY_PATH"

exit "$EXIT_CODE"
