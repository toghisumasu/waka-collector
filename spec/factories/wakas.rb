FactoryBot.define do
  factory :waka do
    upper_phrase { '春はあけぼの やうやう白く なりゆく山ぎは' }
    lower_phrase { 'すこしあかりて 紫だちたる雲の' }
    author { '清少納言' }
    source { '枕草子' }
    era { '平安' }
    notes { 'テストデータ' }
  end
end
