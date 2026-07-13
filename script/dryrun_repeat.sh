#!/usr/bin/env bash
# dryrun_hyakuin.rb をN回連続実行し不安定性を検証する
#
# 使用法:
#   script/dryrun_repeat.sh [RUNS] [START_RUN]
#     RUNS      = 実行回数（デフォルト5）
#     START_RUN = 開始回数ラベル（デフォルト1。中断からの再開時に指定）
#
#   例: 9回連続実行
#     script/dryrun_repeat.sh 9
#   例: Ollama停止で4回目まで完了・5回目で中断した場合の再開
#     script/dryrun_repeat.sh 5 5   # 残り5回を「5回目」からのラベルで実行

PROJECT_DIR="/Volumes/externalHDD/projects/waka-collector"
LOG_DIR="$PROJECT_DIR/log"
SUMMARY_MD="$LOG_DIR/dryrun_repeat_summary.md"
RUNS="${1:-5}"
START_RUN="${2:-1}"
END_RUN=$((START_RUN + RUNS - 1))

cd "$PROJECT_DIR"

# ─── 生存確認 ─────────────────────────────────────────────────────
# Ollama（メンタムさん）が落ちていると全attemptがollama_errorで
# 埋まり、以降の実行が無駄になる。実行前に必ず確認し、
# 落ちていれば処理を中断してどの回で止まったかを記録する。
check_ollama() {
  if ! pgrep -f "ollama serve" > /dev/null 2>&1; then
    return 1
  fi
  curl -s -o /dev/null -m 5 http://localhost:11434/api/tags
}

# Rails server (:3000) はこのスクリプト自体の実行には必須ではない
# （dryrun_hyakuin.rb は app/services を直接requireするため）が、
# 環境健全性の記録として毎回ログに残す（教訓継続）。
check_rails_status() {
  if lsof -i :3000 > /dev/null 2>&1; then
    echo "稼働中"
  else
    echo "停止中"
  fi
}

# ─── サマリーファイル初期化 ───────────────────────────────────────
# START_RUN > 1（中断からの再開）の場合は既存サマリーに追記し、
# 通常実行（START_RUN=1）の場合のみ新規に初期化する。
if [ "$START_RUN" -gt 1 ] && [ -f "$SUMMARY_MD" ]; then
  {
    echo ""
    echo "---"
    echo ""
    echo "## 再開: $(date '+%Y-%m-%d %H:%M')（${START_RUN}〜${END_RUN}回目）"
    echo ""
    echo "| 回 | 開始 | 終了 | 完走 | 最終句 | FORCED数 | FORCED字数ng | FORCED式目違反 | ichiza違反 | 句去違反 | generation_failed | 救済発動(雑転換) | Rails | 47句通過 | 70句通過 |"
    echo "|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|"
  } >> "$SUMMARY_MD"
else
  {
    echo "# dryrun_repeat 結果サマリー"
    echo ""
    echo "実行日時: $(date '+%Y-%m-%d %H:%M')（${START_RUN}〜${END_RUN}回目）"
    echo ""
    echo "| 回 | 開始 | 終了 | 完走 | 最終句 | FORCED数 | FORCED字数ng | FORCED式目違反 | ichiza違反 | 句去違反 | generation_failed | 救済発動(雑転換) | Rails | 47句通過 | 70句通過 |"
    echo "|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|"
  } > "$SUMMARY_MD"
fi

echo "========================================"
echo "dryrun_repeat 開始: $(date '+%Y-%m-%d %H:%M:%S')（${RUNS}回、ラベル${START_RUN}〜${END_RUN}）"
echo "サマリー出力先: $SUMMARY_MD"
echo "========================================"

# ─── Nループ ────────────────────────────────────────────────────
for N in $(seq $START_RUN $END_RUN); do
  # 実行前チェック：Ollamaが落ちていたら中断
  if ! check_ollama; then
    STOP_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "Ollama応答なし。${N}回目の開始前に処理を中断します: ${STOP_TIME}"
    echo "再開方法: script/dryrun_repeat.sh <残り回数> ${N}"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    {
      echo ""
      echo "---"
      echo ""
      echo "**中断:** ${N}回目の開始前に Ollama 応答なしを検知。${STOP_TIME}"
      echo ""
      echo "再開コマンド: \`script/dryrun_repeat.sh <残り回数> ${N}\`"
    } >> "$SUMMARY_MD"
    exit 1
  fi

  RAILS_STATUS=$(check_rails_status)

  TIMESTAMP=$(date +%H%M)
  STDOUT_LOG="$LOG_DIR/dryrun_repeat_run${N}_${TIMESTAMP}.log"
  STDERR_LOG="$LOG_DIR/dryrun_repeat_run${N}_${TIMESTAMP}_stderr.log"

  START_TIME=$(date '+%H:%M:%S')
  echo ""
  echo "--- Run ${N}/${END_RUN} 開始: ${START_TIME}（Rails:${RAILS_STATUS}） ---"
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
  FORCED_MORA_NG="0"
  FORCED_SHIKIMOKU="0"
  ICHIZA_COUNT="0"
  KUZARI_COUNT="0"
  GEN_FAILED_COUNT="0"
  RESCUE_COUNT="0"
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

    # FORCED 句数（字数ng＋式目違反の合算値。其の三十三で判明した通り
    # 基準値との単純比較には使えないため、以下の内訳と併せて参照する）
    FORCED_COUNT=$(grep -c "FORCED" "$STDOUT_LOG" || echo "0")

    # FORCED内訳：字数ng（ShikimokuChecker.describeの:mora_error文言に
    # 一意に含まれる「に合致しません」で判別。式目違反側の文言には
    # 出現しないことを確認済み）
    FORCED_LINES_TMP=$(grep "FORCED" "$STDOUT_LOG")
    if [ -z "$FORCED_LINES_TMP" ]; then
      # FORCED行が0件のとき、echoが空行を1行生成してしまい後続grep -vの
      # 反転一致で式目違反側が誤って1になるため、ここで明示的に0を確定する
      FORCED_MORA_NG="0"
      FORCED_SHIKIMOKU="0"
    else
      FORCED_MORA_NG=$(echo "$FORCED_LINES_TMP" | grep -c "に合致しません")
      # FORCED内訳：式目違反（字数ng以外。generation_failed行は既存の
      # GEN_FAILED_COUNTで別途カウント済みのため二重計上を避けて除外）
      FORCED_SHIKIMOKU=$(echo "$FORCED_LINES_TMP" | grep -v "に合致しません" | grep -vc "句生成に失敗しました")
    fi

    # ichiza 違反数（一座一句物検出）
    ICHIZA_COUNT=$(grep -c "一座一句物" "$STDOUT_LOG" || echo "0")

    # 句去違反数（kuzari_violations 由来の "句去" 文字列）
    KUZARI_COUNT=$(grep -c "句去" "$STDOUT_LOG" || echo "0")

    # generation_failed 件数（5attempt全滅でbest_candidateがnilのまま確定）
    GEN_FAILED_COUNT=$(grep -c "句生成に失敗しました" "$STDOUT_LOG" || echo "0")

    # duplicate_verse固着への機械的救済（雑への転換）発動回数
    RESCUE_COUNT=$(grep -c "詠み直しを指示" "$STDOUT_LOG" || echo "0")

    # 47句目・70句目の通過確認
    grep -qE '\] 047 \|' "$STDOUT_LOG" && PASS_47="通過" || true
    grep -qE '\] 070 \|' "$STDOUT_LOG" && PASS_70="通過" || true
  fi

  echo "  => 完走:${COMPLETED} / 最終句:${LAST_VERSE}句 / FORCED:${FORCED_COUNT}句（字数ng:${FORCED_MORA_NG} / 式目違反:${FORCED_SHIKIMOKU}） / ichiza:${ICHIZA_COUNT} / 句去:${KUZARI_COUNT} / gen_failed:${GEN_FAILED_COUNT} / 救済発動:${RESCUE_COUNT} / 47句:${PASS_47} / 70句:${PASS_70}"

  # サマリー表に1行追記
  echo "| ${N} | ${START_TIME} | ${END_TIME} | ${COMPLETED} | ${LAST_VERSE}句 | ${FORCED_COUNT} | ${FORCED_MORA_NG} | ${FORCED_SHIKIMOKU} | ${ICHIZA_COUNT} | ${KUZARI_COUNT} | ${GEN_FAILED_COUNT} | ${RESCUE_COUNT} | ${RAILS_STATUS} | ${PASS_47} | ${PASS_70} |" \
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
