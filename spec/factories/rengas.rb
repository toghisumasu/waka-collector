FactoryBot.define do
  factory :renga do
    maeku { "MyText" }
    tsugeku { "MyText" }
    maeku_author { "MyString" }
    tsugeku_author { "MyString" }
    generated_by_model { "MyString" }
    style_check_result { "" }
    honka_reference { "" }
  end
end
