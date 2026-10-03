require "csv"
rows = CSV.read("db/data/renga/minase_sangin_verses.csv", headers: true, encoding: "bom|utf-8")
ARGV.map(&:to_i).each do |pos|
  puts "=== #{pos}句 ==="
  ([pos - 8, 1].max..pos).each do |n|
    r = rows[n - 1]
    puts format("%3d %s [%s]", n, r["text"], r["kyoken_tokens"])
  end
end
