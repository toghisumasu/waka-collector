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
end

