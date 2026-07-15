require 'yaml'

class BuiDictionary
  DICT_PATH = File.join(__dir__, '../data/bui_dictionary.yml')

  def initialize(path = DICT_PATH)
    @data = YAML.load_file(path) || {}
  end

  def fetch(word)
    @data[word]
  end

  def primary_bui(word)
    @data.dig(word, 'primary_bui')
  end

  def taiyo(word)
    @data.dig(word, 'taiyo') || '体'
  end

  def tai?(word)
    taiyo(word) == '体'
  end

  def yo?(word)
    taiyo(word) == '用'
  end

  # 植物細分化: "flower" / "grass" / "tree" / nil（未登録）
  def plant_type(word)
    @data.dig(word, 'plant_type')
  end

  # 部立の集合検出（D-38-3：MeCab形態素解析を標準手段とする）。
  # 形態素ごとの表層形をprimary_buiに照会し、見つかった部立を重複排除して返す。
  # nmは呼び出し側で構築済みのNatto::MeCabインスタンス（辞書ロードの重複を避けるため注入）。
  # 情報源はこの辞書（B層確定値）に限定する（D-36-1）。KIGO_BUI等の補完は行わない。
  # ひらがな表記語は未登録なら検出しない（D-22-2と同じ既知の限定、実害観測まで温存）。
  def detect_all(text, nm)
    return [] if text.nil? || text.strip.empty?

    found = []
    nm.parse(text.gsub(/[\s　]+/, "")) do |node|
      next if node.is_eos?
      bui = primary_bui(node.surface)
      found << bui if bui
    end
    found.uniq
  end

  # bui自己申告タグの正規化（其の二十八の季語所属ng調査で判明した①②対策）。
  # tagが既にvalid_categoriesに含まれればそのまま返す。
  # 含まれない場合、辞書上のprimary_bui（例: 「花」「木」「草」「紅葉」→「植物」、
  # 「虫」「鳥」「獣」→「動物」）で置き換えられればそれを返す。
  # 辞書にも未登録の場合は tag をそのまま返す（真に未知＝其の二十八の③、
  # ShikimokuChecker側で従来通り無視される）。
  def normalize_bui(tag, valid_categories)
    return tag if valid_categories.include?(tag)

    mapped = primary_bui(tag)
    valid_categories.include?(mapped) ? mapped : tag
  end
end

