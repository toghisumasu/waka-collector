require_relative '../config/environment'

dict = BuiDictionary.new

tests = {
  "旅"  => "旅",
  "旅衣" => "旅",
  "草枕" => "旅",
  "仏"  => "釈教",
  "無常" => "釈教",
  "菩提" => "釈教",
  "社"  => "神祇",
  "祓"  => "神祇",
  "神代" => "神祇",
  "花"  => "植物",   # 既存エントリの確認
  "時雨" => "降物",   # 既存エントリの確認
  "春"  => nil,       # 非部立語
}

puts "=== bui_dictionary 人間界 検出テスト ==="
ok = fail_ = 0
tests.each do |word, expected|
  result = dict.primary_bui(word)
  status = result == expected ? "OK" : "FAIL"
  status == "OK" ? ok += 1 : fail_ += 1
  puts "#{status}  #{word.ljust(6)} → #{result.inspect} (期待: #{expected.inspect})"
end
puts "\n結果: #{ok} OK / #{fail_} FAIL"
