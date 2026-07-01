#!/usr/bin/env ruby
# frozen_string_literal: true

# analyze_generation_failures.rb — 生成失敗(:generation_failed) 原因分析（其の二十六・叩き台）
#
# dryrun_hyakuin.rb / dryrun_repeat.sh が残した log/*.log を横断的に読み、
# best_candidate が5回のリトライ全てで得られず :generation_failed
# （プレースホルダ「(生成失敗)」または旧バグによるクラッシュ）に至った
# 箇所を抽出・集計し、log/generation_failure_analysis.md に出力する。
#
# 使用法:
#   bundle exec ruby script/analyze_generation_failures.rb

require "time"
require "json"

LOG_DIR      = File.expand_path("../log", __dir__)
REPO_ROOT    = File.expand_path("..", __dir__)
OUTPUT_MD    = File.join(LOG_DIR, "generation_failure_analysis.md")
ATTEMPTS_LOG = File.join(LOG_DIR, "generation_attempts.log")
TOTAL_VERSES = 100
MAX_RETRY    = 5

# describe() の nilクラッシュ修正コミット。このコミット以前のログは
# 旧バグ由来のクラッシュ（真の生成失敗原因ではなくログ基盤側の問題）が
# 混入するため、次回以降の集計では除外する。
FIX_COMMIT = "8e08b48"

def fix_commit_time
  raw = Dir.chdir(REPO_ROOT) { `git log -1 --format=%aI #{FIX_COMMIT} 2>/dev/null`.strip }
  return nil if raw.empty?

  Time.iso8601(raw)
rescue ArgumentError
  nil
end

FIX_COMMIT_TIME = fix_commit_time

EXCLUDE_BASENAMES = %w[development.log server.log test.log].freeze

LINE_RE = /\A\[(?<ts>[^\]]+)\]\s+(?<no>\d{3})\s+\|\s+(?<word>.*?)\s+\|\s+(?<vt>長|短)\s+\|\s+(?<season>\S+)\s+\|\s*(?<bui>[^|]*)\|\s+(?<status>.*)\z/

# 直前句の違反理由を種類別に分類するためのパターン
# （ShikimokuChecker.describe が生成する自由文字列を正規表現で判別する。
#   describe 自体は変更していないので、文言が変わればここも追従要）
CATEGORY_PATTERNS = {
  ichiza:      /一座一句物/,
  kigo_streak: /季「.+?」が\d+句(?:連続|で転換)/,
  teiza:       /(?:面|折)「.+?」に(?:月|花)なし/,
  chotan:      /(?:長句|短句)が連続/,
  kuzari:      /部立「.+?」が\d+句目から間\d+句で再出/,
  generation_failed: /句生成に失敗しました/,
}.freeze

CrashInfo = Struct.new(:signature, :raw, keyword_init: true)

def classify_status(status)
  return :ok if status == "OK"
  return :none if status.nil? || status.empty?

  CATEGORY_PATTERNS.each { |key, re| return key if status.match?(re) }
  :other
end

def category_label(key)
  {
    ichiza: "一座一句物",
    kigo_streak: "季の連続/転換",
    teiza: "定座（月・花）",
    chotan: "長短句違い",
    kuzari: "句去（部立の再出間隔）",
    generation_failed: "生成失敗（連鎖）",
    ok: "OK（直前は正常）",
    none: "履歴なし（先頭句）",
    other: "分類不能",
  }.fetch(key, key.to_s)
end

# ── ログファイル走査 ──────────────────────────────────────────

def target_log_files
  Dir.glob(File.join(LOG_DIR, "*.log"))
     .reject { |f| File.basename(f).end_with?("_stderr.log") }
     .reject { |f| EXCLUDE_BASENAMES.include?(File.basename(f)) }
     .sort_by { |f| File.mtime(f) }
end

def parse_lines(path)
  File.readlines(path, chomp: true).filter_map do |raw|
    m = LINE_RE.match(raw)
    next unless m

    {
      ts: m[:ts], no: m[:no].to_i, word: m[:word], vt: m[:vt],
      season: m[:season], bui: m[:bui].to_s.strip, status: m[:status],
      source: path,
    }
  end
end

# 同一ファイル内で句番号が巻き戻る箇所を「別ラン」として分割する
# （dryrun_hyakuin_YYYYMMDD.log は同日中の全実行がappendされる）
def split_into_runs(lines)
  runs = []
  current = []
  lines.each do |line|
    if current.any? && line[:no] <= current.last[:no]
      runs << current
      current = []
    end
    current << line
  end
  runs << current if current.any?
  runs
end

def read_stderr_signature(source_path)
  stderr_path = source_path.sub(/\.log\z/, "_stderr.log")
  return nil unless File.exist?(stderr_path)

  content = File.read(stderr_path)
  return nil unless content.include?(":generation_failed")

  crash_line = content[/^.*NoMethodError.*$/]
  CrashInfo.new(signature: crash_line || "(NoMethodError行なし)", raw: stderr_path)
end

# ── ラン単位の解析 ────────────────────────────────────────────

FailureEvent = Struct.new(
  :source, :run_start_ts, :verse_no, :history_size,
  :prev_status, :prev_category, :crash, :crash_signature,
  keyword_init: true
)

def analyze_run(run)
  events = []
  run.each_with_index do |line, i|
    next unless line[:word] == "(生成失敗)"

    prev = run[i - 1] if i.positive?
    events << FailureEvent.new(
      source: line[:source], run_start_ts: run.first[:ts], verse_no: line[:no],
      history_size: line[:no] - 1, prev_status: prev&.dig(:status),
      prev_category: classify_status(prev&.dig(:status)), crash: false,
      crash_signature: nil
    )
  end

  last = run.last
  if last[:no] < TOTAL_VERSES && events.empty?
    crash = read_stderr_signature(last[:source])
    if crash
      events << FailureEvent.new(
        source: last[:source], run_start_ts: run.first[:ts], verse_no: last[:no] + 1,
        history_size: last[:no], prev_status: last[:status],
        prev_category: classify_status(last[:status]), crash: true,
        crash_signature: crash.signature
      )
    end
  end

  { lines: run, events: events, completed: last[:no] == TOTAL_VERSES }
end

# ── 同一candidateの複数attempt繰り返し検出（generation_attempts.log由来） ──
#
# 15句目・17句目で観測された「文言は同一のまま bui 判定だけが揺れて
# kuzari_violation で却下され続ける」パターンを機械的に検出する。
# generation_attempts.log は日付ローテーションなしで追記され続けるため、
# dryrun_hyakuin.log と同様に verse_no の巻き戻りでラン境界を判定する。

RepeatedCandidateEvent = Struct.new(
  :run_index, :verse_no, :word, :attempts, :reasons, :bui_variants, :history_size,
  keyword_init: true
)

def parse_attempts_log
  return [] unless File.exist?(ATTEMPTS_LOG)

  File.readlines(ATTEMPTS_LOG, chomp: true).filter_map do |raw|
    next if raw.strip.empty?

    JSON.parse(raw, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end

# verse_no が直前までの最大値を下回ったら新しいランとみなす
# （同一verse_no内でattemptが複数行続くのは正常なので "<=" ではなく "<" で判定する）
def split_attempts_into_runs(entries)
  runs = []
  current = []
  running_max = -1
  entries.each do |e|
    if current.any? && e[:verse_no] < running_max
      runs << current
      current = []
      running_max = -1
    end
    current << e
    running_max = [running_max, e[:verse_no]].max
  end
  runs << current if current.any?
  runs
end

def find_repeated_candidates(run, run_index)
  events = []
  run.group_by { |e| e[:verse_no] }.each do |verse_no, group|
    with_candidate = group.select { |e| e[:candidate] }
    with_candidate.group_by { |e| e.dig(:candidate, :word) }.each do |word, same_word|
      next if same_word.size < 2

      events << RepeatedCandidateEvent.new(
        run_index:    run_index,
        verse_no:     verse_no,
        word:         word,
        attempts:     same_word.map { |e| e[:attempt] },
        reasons:      same_word.map { |e| e[:reason] },
        bui_variants: same_word.map { |e| Array(e.dig(:candidate, :bui)).sort }.uniq,
        history_size: same_word.first[:history_size]
      )
    end
  end
  events
end

attempts_entries    = parse_attempts_log
attempts_runs        = split_attempts_into_runs(attempts_entries)
repeated_candidate_events = attempts_runs.each_with_index.flat_map { |run, i| find_repeated_candidates(run, i + 1) }

# ── メイン ────────────────────────────────────────────────────

files = target_log_files
all_runs = []
files.each do |path|
  lines = parse_lines(path)
  next if lines.empty?

  split_into_runs(lines).each { |run| all_runs << run }
end

# 同一ランが複数ファイル（dryrun_hyakuin_YYYYMMDD.log と
# dryrun_repeat_run*_HHMM.log）に重複記録されるためdedupする
seen = {}
deduped_runs = all_runs.select do |run|
  key = [run.first[:ts], run.last[:ts], run.last[:no]]
  if seen[key]
    false
  else
    seen[key] = true
    true
  end
end

# describe() nilクラッシュ修正（FIX_COMMIT）より前に実行されたランは
# 旧バグ由来のクラッシュが混入するため除外する
pre_fix_runs, unique_runs = if FIX_COMMIT_TIME
  deduped_runs.partition { |run| Time.parse(run.first[:ts]) < FIX_COMMIT_TIME }
else
  [[], deduped_runs]
end

analyzed = unique_runs.map { |run| analyze_run(run) }
all_events = analyzed.flat_map { |a| a[:events] }

# ── 集計 ──────────────────────────────────────────────────────

def bucket(verse_no)
  case verse_no
  when 1..33  then "前半(1-33)"
  when 34..66 then "中盤(34-66)"
  else             "終盤(67-100)"
  end
end

bucket_counts = Hash.new(0)
all_events.each { |e| bucket_counts[bucket(e.verse_no)] += 1 }

category_counts = Hash.new(0)
all_events.each { |e| category_counts[e.prev_category] += 1 }

# ── レポート出力 ──────────────────────────────────────────────

md = +""
md << "# generation_failed 原因分析（其の二十六・叩き台）\n\n"
md << "生成日時: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
md << "対象ログファイル数: #{files.size} / 検出したラン数（dedup後）: #{unique_runs.size}\n"
md << "うち完走: #{analyzed.count { |a| a[:completed] }} / 未完走: #{analyzed.count { |a| !a[:completed] }}\n"
md << "検出した generation_failed 件数（クラッシュ由来含む）: #{all_events.size}\n\n"

md << "## 除外したログ（旧バグ由来）\n\n"
if FIX_COMMIT_TIME
  md << "修正コミット #{FIX_COMMIT}（#{FIX_COMMIT_TIME.strftime('%Y-%m-%d %H:%M:%S %z')}）より前に開始されたランは"
  md << "describe() nilクラッシュの旧バグが混入するため除外した。除外ラン数: #{pre_fix_runs.size}\n\n"
else
  md << "修正コミット #{FIX_COMMIT} がこのリポジトリの履歴から見つからなかったため、フィルタなしで集計した。\n\n"
end

md << "## サンプル数について\n\n"
md << "現時点でのサンプル数は **N=#{all_events.size}** と非常に小さい。"
md << "以下の集計・仮説は参考値であり、統計的に有意な傾向とはみなせない。"
md << "script/dryrun_repeat.sh を追加実行してサンプルを増やしてから再解釈すること。\n\n"

md << "## 検出した generation_failed 一覧\n\n"
if all_events.empty?
  md << "（該当なし）\n\n"
else
  md << "| # | 発生元ファイル | ラン開始 | 句番号 | history.size | 種別 | 直前句の違反理由（分類） | リトライ回数 | プロンプト目安 |\n"
  md << "|:-:|:--|:--|:-:|:-:|:--|:--|:--|:--|\n"
  all_events.each_with_index do |e, i|
    kind = e.crash ? "クラッシュ（旧バグ）" : "プレースホルダ記録"
    md << "| #{i + 1} | #{File.basename(e.source)} | #{e.run_start_ts} | #{e.verse_no} | #{e.history_size} | #{kind} | #{category_label(e.prev_category)} | #{MAX_RETRY}/#{MAX_RETRY}固定（attempt別ログなし） | N/A（Ollamaリクエスト自体がログに残っていないため算出不能） |\n"
  end
  md << "\n"
  crashed = all_events.select(&:crash)
  if crashed.any?
    md << "### クラッシュ由来イベントの詳細\n\n"
    crashed.each do |e|
      md << "- #{File.basename(e.source)} #{e.verse_no}句目: `#{e.crash_signature}`\n"
    end
    md << "\n"
  end
end

md << "## 句番号の分布\n\n"
md << "| 区間 | 件数 |\n|:--|:-:|\n"
%w[前半(1-33) 中盤(34-66) 終盤(67-100)].each do |b|
  md << "| #{b} | #{bucket_counts[b]} |\n"
end
md << "\n"

md << "## history.size との相関\n\n"
md << "本スクリプトの実装上 `history.size == 句番号 - 1` のため、句番号分布と完全に同一の傾向になる"
md << "（history.size 自体を独立変数として動かした比較データが現状のログには存在しない）。\n\n"
if all_events.any?
  sizes = all_events.map(&:history_size)
  md << "history.size の範囲: #{sizes.min} 〜 #{sizes.max} / 平均: #{(sizes.sum.to_f / sizes.size).round(1)}\n\n"
end

md << "## 直前句の違反理由（種類別頻度）\n\n"
md << "| 分類 | 件数 |\n|:--|:-:|\n"
category_counts.sort_by { |_, v| -v }.each do |k, v|
  md << "| #{category_label(k)} | #{v} |\n"
end
md << "\n"

md << "## 同一candidateが複数attemptで繰り返されるケース（generation_attempts.log由来）\n\n"
if attempts_entries.empty?
  md << "log/generation_attempts.log が存在しないか空のため、集計不能。\n\n"
else
  md << "generation_attempts.log を検出した#{attempts_runs.size}ラン分走査。"
  md << "同一句番号内で候補文言（word）が変わらないまま複数attemptにわたって記録された"
  md << "ケースは **#{repeated_candidate_events.size}件**。\n\n"
  if repeated_candidate_events.any?
    bui_flicker = repeated_candidate_events.select { |e| e.bui_variants.size > 1 }
    md << "うち、文言は同一なのに bui 判定が attempt ごとに揺れているケース: "
    md << "**#{bui_flicker.size}件**（15句目・17句目で観測された現象と同型）。\n\n"
    md << "| # | ラン | 句番目 | history.size | 候補文言 | 出現attempt | 各attemptのreason | bui判定のバリエーション |\n"
    md << "|:-:|:-:|:-:|:-:|:--|:--|:--|:--|\n"
    repeated_candidate_events.each_with_index do |e, i|
      md << "| #{i + 1} | #{e.run_index} | #{e.verse_no} | #{e.history_size} | #{e.word} | " \
            "#{e.attempts.join('→')} | #{e.reasons.join('→')} | #{e.bui_variants.map { |b| b.join('・') }.join(' / ')} |\n"
    end
    md << "\n"
    if bui_flicker.any?
      md << "`dryrun_hyakuin.rb` では bui は `BuiDictionary`/`detect_bui` による決定論的推定ではなく、" \
            "LLMが出力するJSONの `\"bui\"` フィールドをそのまま採用している（`parse_candidate` 参照）。" \
            "よってこのブレはB層側の非決定性ではなく、**同一の句本文に対してLLM自身が" \
            "毎回異なる部立を自己申告している**＝C層（生成）側のサンプリング不安定性である。" \
            "句去チェックはこの自己申告bui にそのまま依存しているため、句本文が良くても" \
            "bui申告がぶれるだけでkuzari_violationとして却下され続ける構造的リスクがある。\n\n"
    end
  end
end

md << "## プロンプト長・トークン数目安\n\n"
md << "現行の `OllamaClient.generate` と `dryrun_hyakuin.rb` は送信プロンプトの内容・"
md << "各attemptのfeedback文言をログに残していない。そのためリトライ毎のプロンプト肥大化を"
md << "実測することはできない。計測したい場合は `build_prompt` の戻り値をログ出力する"
md << "変更が別途必要（本スクリプトの範囲外）。\n\n"

md << "## リトライ回数について\n\n"
md << "`MAX_RETRY = #{MAX_RETRY}` は固定値であり、attempt単位のログ（何回目にどの理由で"
md << "却下されたか）は現状記録されていない。Ollama接続エラー時のみ `puts` されるが、"
md << "確認した全ログ中で発生0件だった。したがって今回検出した generation_failed は"
md << "「JSON解析失敗」「重複句」「禁止季」のいずれか（またはその組み合わせ）が5回連続した"
md << "結果と推測されるが、ログからは3つを区別できない。\n\n"

md << "## 仮説（未検証・断定ではない）\n\n"
md << "以下はあくまで叩き台の仮説であり、今回のサンプル数（N=#{all_events.size}）では"
md << "検証も反証もできない。サンプルを増やしたうえで再検討すること。\n\n"

hypotheses = []
if all_events.size >= 2
  max_bucket, max_count = bucket_counts.max_by { |_, v| v }
  dist_str = bucket_counts.map { |k, v| "#{k}=#{v}" }.join("・")
  if max_count > all_events.size / 2.0
    hypotheses << "「#{max_bucket}」に発生が偏っている（#{max_count}/#{all_events.size}件、内訳: #{dist_str}）。" \
                   "履歴が長くなるほどprompt内の禁止季語・部立制約が積み上がり、LLMが制約を満たすJSONを" \
                   "安定して出力できなくなっている可能性（プロンプト肥大化仮説）。" \
                   "ただしプロンプト内容自体はログに残っていないため未検証。"
  else
    hypotheses << "句番号の分布に明確な偏りは見られない（内訳: #{dist_str}）。単発の運" \
                   "（LLMのサンプリングのばらつき）による失敗である可能性があり、履歴長そのものが" \
                   "主要因ではないかもしれない。"
  end
end

if category_counts[:ok].to_i == all_events.size && all_events.size >= 2
  hypotheses << "検出した#{all_events.size}件は全て直前句が式目違反していない（OK）状態から" \
                 "generation_failed に至っている。制約フィードバックの蓄積による劣化というより、" \
                 "LLM自体のサンプリング不安定性（JSON整形ミス・重複句の偶発・季語選択のブレなど）が" \
                 "主要因である可能性を示唆する。"
elsif category_counts[:ichiza] >= category_counts.values.max.to_i && category_counts[:ichiza] > 0
  hypotheses << "直前句が一座一句物違反だったケースが目立つ場合、一座一句物のfeedback文言" \
                 "（「以下は一座一句物につき再使用不可: ...。別の語で詠め」）がLLMにとって" \
                 "誤解を招きやすい可能性（feedback文言仮説）。"
end

if all_events.count(&:crash) > 0
  hypotheses << "検出#{all_events.count(&:crash)}件はいずれも旧バグ（describeのnilクラッシュ、" \
                 "8e08b48で修正済み）由来であり、真の生成失敗原因ではなく"     \
                 "ログ基盤側の問題だった。修正後は少なくともクラッシュせず placeholder 記録に" \
                 "フォールバックすることは確認できたが、根本原因（なぜ5回とも失敗したか）は" \
                 "この修正では未解明。"
end

hypotheses << "サンプル数が少なすぎる（N=#{all_events.size}）ため、上記のいずれも現時点では" \
              "仮説の域を出ない。dryrun_repeat.sh を追加実行し、generation_failed の発生率を" \
              "10件以上のサンプルで再集計するまでは結論を出すべきではない。"

hypotheses.each { |h| md << "- #{h}\n" }
md << "\n"

File.write(OUTPUT_MD, md)
puts "書き出し完了: #{OUTPUT_MD}"
puts "検出イベント数: #{all_events.size}"
