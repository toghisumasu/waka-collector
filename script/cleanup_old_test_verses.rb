# 実行:
#   ドライラン: bin/rails runner script/cleanup_old_test_verses.rb
#   実   行:   DRY_RUN=false bin/rails runner script/cleanup_old_test_verses.rb

DRY_RUN = ENV.fetch('DRY_RUN', 'true') != 'false'

sep = "─" * 60

puts sep
puts DRY_RUN ? "【ドライラン】削除はしません" : "【実行モード】対象を destroy します"
puts sep

before_count = Renga.count
targets = Renga.where("tsugeku LIKE ?", "%ゆかりのままで%")

puts "削除前 Renga 総件数: #{before_count}"
puts "削除対象: #{targets.size} 件\n\n"

targets.each do |r|
  puts "  ID=#{r.id}  作成: #{r.created_at.strftime('%Y-%m-%d %H:%M')}"
  puts "    maeku  : #{r.maeku.inspect}"
  puts "    tsugeku: #{r.tsugeku.inspect}"

  unless DRY_RUN
    r.destroy
    puts "    → 削除済み"
  end
end

if DRY_RUN
  puts "\n上記 #{targets.size} 件が削除対象です。"
  puts "実際に削除するには DRY_RUN=false を指定して実行してください。"
else
  after_count = Renga.count
  puts "\n#{sep}"
  puts "削除前: #{before_count} 件  →  削除後: #{after_count} 件  （#{before_count - after_count} 件削除）"
end

puts sep
