#!/usr/bin/env ruby
# log_to_html.rb — 独吟百韻ログ → 縦書き鑑賞用HTML
#
# 使用法:
#   bundle exec ruby script/log_to_html.rb
#   bundle exec ruby script/log_to_html.rb log/other.log log/out.html

INPUT  = ARGV[0] || File.expand_path("../log/dryrun_final_100.log",  __dir__)
OUTPUT = ARGV[1] || File.expand_path("../log/hyakuin_20260630.html", __dir__)

# ── 折区切り定義 ─────────────────────────────────────────────
FOLDS = [
  { name: "初折表", range:  1..8   },
  { name: "初折裏", range:  9..22  },
  { name: "二の折表", range: 23..36  },
  { name: "二の折裏", range: 37..50  },
  { name: "三の折表", range: 51..64  },
  { name: "三の折裏", range: 65..78  },
  { name: "名残表",  range: 79..92  },
  { name: "名残裏",  range: 93..100 },
].freeze

SEASON_BG = {
  "春" => "#fdf2f5",
  "夏" => "#f0f7ec",
  "秋" => "#fbf0e4",
  "冬" => "#eef5f8",
  "雑" => "#f5f5f0",
}.freeze

# ── ログ解析 ─────────────────────────────────────────────────
# フォーマット: [timestamp] 001 | word | 長/短 | season | bui | status
Line = Struct.new(:no, :word, :length, :season, :bui, :status, :forced, :note)

def parse_log(path)
  File.readlines(path, chomp: true).filter_map do |raw|
    m = raw.match(/\]\s*(\d+)\s*\|\s*(.+?)\s*\|\s*([長短])\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+)$/)
    next unless m
    no     = m[1].to_i
    word   = m[2]
    len    = m[3]
    season = m[4].strip
    bui    = m[5].strip
    status = m[6].strip
    forced = status.start_with?("FORCED")
    note   = forced ? status.sub(/^FORCED:\s*/, "") : nil
    Line.new(no, word, len, season, bui, status, forced, note)
  end
end

# ── HTML生成ヘルパー ─────────────────────────────────────────

def h(str)
  str.to_s
     .gsub("&", "&amp;")
     .gsub("<", "&lt;")
     .gsub(">", "&gt;")
     .gsub('"', "&quot;")
end

def fold_for(no)
  FOLDS.find { |f| f[:range].include?(no) }
end

# ── 短冊HTML ────────────────────────────────────────────────

def tanzaku_html(line)
  bg      = SEASON_BG[line.season] || SEASON_BG["雑"]
  border  = line.forced ? "border: 1.5px solid #e8a0a0;" : "border: 1px solid #c8b89a;"
  forced_mark = line.forced ? '<span class="forced-mark">※</span>' : ""
  forced_title = line.forced ? " title=\"#{h(line.note)}\"" : ""

  <<~HTML
    <div class="tanzaku" style="background:#{bg};#{border}"#{forced_title}>
      #{forced_mark}
      <span class="verse-no">#{format('%03d', line.no)}</span>
      <span class="verse-text">#{h(line.word)}</span>
      <span class="verse-meta">#{h(line.season)}・#{h(line.length)}</span>
    </div>
  HTML
end

# ── メイン ──────────────────────────────────────────────────

verses = parse_log(INPUT)
abort "ログが読み込めません: #{INPUT}" if verses.empty?

# 折ごとにグループ化
fold_groups = FOLDS.map do |fold|
  lines = verses.select { |v| fold[:range].include?(v.no) }
  [fold[:name], lines]
end

html = <<~HTML
  <!DOCTYPE html>
  <html lang="ja">
  <head>
  <meta charset="UTF-8">
  <title>独吟百韻　水無瀬の風</title>
  <style>
  /* ── リセット ── */
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: #ede8df;
    font-family: "Hiragino Mincho ProN", "游明朝", "Yu Mincho", "ＭＳ 明朝", serif;
    color: #2a1f14;
    padding: 40px 20px;
  }

  /* ── タイトル ── */
  .title-block {
    writing-mode: vertical-rl;
    text-orientation: mixed;
    margin: 0 auto 50px;
    text-align: center;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 24px;
  }
  .title-main {
    font-size: 2.2rem;
    letter-spacing: 0.25em;
    color: #3d2b1a;
    border-right: 3px double #9a7a5a;
    padding-right: 16px;
  }
  .title-date {
    font-size: 0.95rem;
    color: #7a6a5a;
    letter-spacing: 0.15em;
  }
  .title-subtitle {
    font-size: 1.1rem;
    color: #5a4a3a;
    letter-spacing: 0.2em;
  }

  /* ── 凡例 ── */
  .legend {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    justify-content: center;
    margin-bottom: 40px;
    font-size: 0.8rem;
  }
  .legend-item {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .legend-swatch {
    width: 16px;
    height: 16px;
    border: 1px solid #b0a090;
    border-radius: 2px;
  }

  /* ── 折コンテナ ── */
  .fold-section {
    margin-bottom: 48px;
  }
  .fold-header {
    writing-mode: horizontal-tb;
    font-size: 0.85rem;
    letter-spacing: 0.2em;
    color: #7a5a3a;
    border-bottom: 1px solid #b0946e;
    padding-bottom: 6px;
    margin-bottom: 20px;
  }
  .fold-count {
    font-size: 0.75rem;
    color: #9a8a7a;
    margin-left: 12px;
  }

  /* ── 短冊列（右→左、縦書き） ── */
  .tanzaku-row {
    display: flex;
    flex-direction: row-reverse;   /* 右から左へ並ぶ */
    flex-wrap: nowrap;
    gap: 8px;
    overflow-x: auto;
    padding-bottom: 12px;
  }

  /* ── 短冊 ── */
  .tanzaku {
    writing-mode: vertical-rl;
    text-orientation: mixed;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 16px 8px;
    min-width: 52px;
    min-height: 280px;
    border-radius: 3px;
    position: relative;
    flex-shrink: 0;
    box-shadow: 1px 1px 4px rgba(0,0,0,0.08);
    cursor: default;
    transition: box-shadow 0.15s;
  }
  .tanzaku:hover {
    box-shadow: 2px 2px 8px rgba(0,0,0,0.18);
  }

  /* 句番号 */
  .verse-no {
    font-size: 0.62rem;
    color: #9a8270;
    letter-spacing: 0.05em;
    margin-bottom: 4px;
  }

  /* 句本文 */
  .verse-text {
    font-size: 1.0rem;
    line-height: 1.9;
    letter-spacing: 0.12em;
    color: #1e130a;
    flex: 1;
  }

  /* 季・長短 */
  .verse-meta {
    font-size: 0.62rem;
    color: #8a7060;
    margin-top: 4px;
    letter-spacing: 0.05em;
  }

  /* FORCED マーク */
  .forced-mark {
    position: absolute;
    top: 4px;
    left: 4px;
    font-size: 0.65rem;
    color: #c05050;
    writing-mode: horizontal-tb;
    line-height: 1;
  }

  /* ── フッター ── */
  .footer {
    text-align: center;
    font-size: 0.75rem;
    color: #9a8a7a;
    margin-top: 48px;
    padding-top: 16px;
    border-top: 1px solid #c0b0a0;
    letter-spacing: 0.1em;
  }

  /* ── 統計バー ── */
  .stats {
    display: flex;
    gap: 20px;
    justify-content: center;
    flex-wrap: wrap;
    margin-bottom: 32px;
    font-size: 0.8rem;
    color: #6a5a4a;
  }
  .stat-item { letter-spacing: 0.08em; }
  </style>
  </head>
  <body>

  <div style="text-align:center; margin-bottom: 40px;">
    <div class="title-block">
      <div class="title-main">独吟百韻</div>
      <div class="title-subtitle">水無瀬の風</div>
      <div class="title-date">令和八年六月三十日</div>
    </div>
  </div>

HTML

# 統計
total   = verses.size
forced  = verses.count(&:forced)
seasons = verses.group_by(&:season).transform_values(&:size).sort_by { |_, c| -c }

html << '<div class="stats">' + "\n"
html << "  <span class=\"stat-item\">全#{total}句</span>\n"
html << "  <span class=\"stat-item\">FORCED #{forced}句</span>\n"
seasons.each do |s, c|
  html << "  <span class=\"stat-item\">#{h(s)}#{c}句</span>\n"
end
html << "</div>\n\n"

# 凡例
html << '<div class="legend">' + "\n"
SEASON_BG.each do |s, bg|
  html << "  <div class=\"legend-item\">" \
          "<div class=\"legend-swatch\" style=\"background:#{bg}\"></div>#{h(s)}</div>\n"
end
html << "  <div class=\"legend-item\"><span style=\"color:#c05050;font-size:0.85rem\">※</span> FORCED句</div>\n"
html << "</div>\n\n"

# 折ごとに出力
fold_groups.each do |fold_name, lines|
  next if lines.empty?
  r = FOLDS.find { |f| f[:name] == fold_name }[:range]
  html << "<div class=\"fold-section\">\n"
  html << "  <div class=\"fold-header\">#{h(fold_name)}" \
          "<span class=\"fold-count\">（#{r.min}〜#{r.max}句）</span></div>\n"
  html << "  <div class=\"tanzaku-row\">\n"
  lines.each { |v| html << tanzaku_html(v).gsub(/^/, "    ") }
  html << "  </div>\n"
  html << "</div>\n\n"
end

html << <<~HTML
  <div class="footer">
    独吟百韻「水無瀬の風」&ensp;|&ensp;生成: qwen3:8b via Ollama&ensp;|&ensp;検証: ShikimokuChecker
  </div>

  </body>
  </html>
HTML

File.write(OUTPUT, html, encoding: "UTF-8")
puts "生成完了: #{OUTPUT}"
puts "  #{verses.size}句 / FORCED #{verses.count(&:forced)}句"
