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

