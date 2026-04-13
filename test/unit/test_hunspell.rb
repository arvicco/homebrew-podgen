# frozen_string_literal: true

require_relative "../test_helper"
require "tell/hunspell"

class TestHunspell < Minitest::Test
  def setup
    Tell::Hunspell.instance_variable_set(:@available, nil)
    Tell::Hunspell.instance_variable_set(:@utf8_cache, nil)
  end

  # --- dict_for ---

  def test_dict_for_slovenian
    assert_equal "sl_SI", Tell::Hunspell.dict_for("sl")
  end

  def test_dict_for_unknown_language
    assert_nil Tell::Hunspell.dict_for("xx")
  end

  # --- available? ---

  def test_available_when_binaries_exist
    Tell::Hunspell.stub(:available?, true) do
      assert Tell::Hunspell.available?
    end
  end

  def test_not_available_when_binaries_missing
    Tell::Hunspell.stub(:available?, false) do
      refute Tell::Hunspell.available?
    end
  end

  # --- supports? ---

  def test_supports_returns_false_when_not_available
    Tell::Hunspell.stub(:available?, false) do
      refute Tell::Hunspell.supports?("sl")
    end
  end

  def test_supports_returns_false_for_unknown_language
    Tell::Hunspell.stub(:available?, true) do
      refute Tell::Hunspell.supports?("xx")
    end
  end

  # --- expand ---

  def test_expand_returns_empty_when_unsupported
    Tell::Hunspell.stub(:supports?, false) do
      assert_equal [], Tell::Hunspell.expand("test", lang: "xx")
    end
  end

  def test_expand_returns_empty_for_unknown_word
    skip "hunspell + sl_SI dictionary required" unless Tell::Hunspell.supports?("sl")

    result = Tell::Hunspell.expand("xyzzyplugh", lang: "sl")
    assert_equal [], result
  end

  def test_expand_noun_includes_declensions
    skip "hunspell + sl_SI dictionary required" unless Tell::Hunspell.supports?("sl")

    forms = Tell::Hunspell.expand("lupina", lang: "sl")
    assert_includes forms, "lupina"
    assert_includes forms, "lupino"
    assert_includes forms, "lupini"
    assert_includes forms, "lupine"
    refute forms.any? { |f| f.start_with?("lupinar") }, "should not include derived words"
  end

  def test_expand_verb_includes_conjugations
    skip "hunspell + sl_SI dictionary required" unless Tell::Hunspell.supports?("sl")

    forms = Tell::Hunspell.expand("zlekniti", lang: "sl")
    assert_includes forms, "zlekniti"   # infinitive
    assert_includes forms, "zleknemo"   # 1st person plural present
    assert_includes forms, "zleknil"    # past participle masc
    assert_includes forms, "zleknila"   # past participle fem
  end

  def test_expand_adjective_includes_forms
    skip "hunspell + sl_SI dictionary required" unless Tell::Hunspell.supports?("sl")

    forms = Tell::Hunspell.expand("meden", lang: "sl")
    assert_includes forms, "meden"
    assert_includes forms, "medeno"
    assert_includes forms, "medeni"
    assert_includes forms, "medena"
  end

  def test_expand_unknown_word_returns_empty
    skip "hunspell + sl_SI dictionary required" unless Tell::Hunspell.supports?("sl")

    forms = Tell::Hunspell.expand("burkla", lang: "sl")
    assert_equal [], forms
  end
end
