# 実行: bin/rails runner script/diagnose_renga_data.rb
require 'natto'

USER_DIC = Rails.root.join("dict", "user.dic").to_s
YOUON    = %w[ゃ ゅ ょ].freeze

def mora_from_yomi(yomi)
  yomi.tr('ァ-ヴー', 'ぁ-ゔー').chars.reject { |c| YOUON.include?(c) }.size
end

def morphemes_of(text, nm)
  result = []
  nm.parse(text.gsub(/[\s　]+/, '')) do |node|
    next if node.is_eos?
    f    = node.feature.split(',')
    yomi = f[7] || node.surface
    result << { surface: node.surface, yomi: yomi.tr('ァ-ヴー', 'ぁ-ゔー'), mora: mora_from_yomi(yomi) }
  end
  result
end

def abnormal?(text)
  return false if text.nil?
  text.match?(/[a-zA-Z]/) || text.include?('**')
end

nm = begin
  Natto::MeCab.new(userdic: USER_DIC)
rescue => e
  puts "ユーザー辞書なし (#{e.message})、標準辞書で続行"
  Natto::MeCab.new
end

all    = Renga.order(created_at: :desc)
total  = all.count
latest = all.limit(5).to_a

sep = "─" * 60

puts sep
puts "Renga 総件数: #{total}"
puts sep

# ---- 最新5件の詳細表示 ----
puts "\n【最新5件の詳細】\n\n"

latest.each do |r|
  puts sep
  puts "ID: #{r.id}  作成: #{r.created_at.strftime('%Y-%m-%d %H:%M')}"
  puts "  maeku      : #{r.maeku.inspect}"
  puts "  tsugeku    : #{r.tsugeku.inspect}"
  puts "  maeku_author  : #{r.maeku_author.inspect}"
  puts "  tsugeku_author: #{r.tsugeku_author.inspect}"
  puts "  model         : #{r.generated_by_model.inspect}"

  if r.tsugeku.present?
    ms   = morphemes_of(r.tsugeku, nm)
    mora = ms.sum { |m| m[:mora] }
    puts "  --- MeCab 解析 ---"
    ms.each do |m|
      puts "    surface=#{m[:surface].ljust(8)} yomi=#{m[:yomi].ljust(10)} mora=#{m[:mora]}"
    end
    puts "  合計音数: #{mora}"
    puts "  ★ 異常データ検知" if abnormal?(r.tsugeku)
  else
    puts "  tsugeku: (空)"
  end
  puts
end

# ---- 全件の異常データ集計 ----
puts sep
puts "\n【異常データ集計（全#{total}件）】\n\n"

english_ids = []
asterisk_ids = []

Renga.where.not(tsugeku: [nil, '']).find_each do |r|
  t = r.tsugeku
  english_ids  << r.id if t.match?(/[a-zA-Z]/)
  asterisk_ids << r.id if t.include?('**')
end

puts "  英語を含む tsugeku  : #{english_ids.size} 件"
puts "  「**」を含む tsugeku: #{asterisk_ids.size} 件"

if english_ids.any?
  puts "\n  英語含みの ID: #{english_ids.first(10).join(', ')}#{english_ids.size > 10 ? ' ...' : ''}"
  english_ids.first(3).each do |id|
    r = Renga.find(id)
    puts "    [#{id}] #{r.tsugeku.inspect}"
  end
end

if asterisk_ids.any?
  puts "\n  「**」含みの ID: #{asterisk_ids.first(10).join(', ')}#{asterisk_ids.size > 10 ? ' ...' : ''}"
  asterisk_ids.first(3).each do |id|
    r = Renga.find(id)
    puts "    [#{id}] #{r.tsugeku.inspect}"
  end
end

puts "\n#{sep}"
puts "診断完了"
