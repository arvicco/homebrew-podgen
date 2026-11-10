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

  # --- P17-5 (Q-115): verb-stem expansion keeps only forms of the lemma ---

  def test_expand_verb_excludes_words_that_only_share_the_stem
    forms = expand_stubbed("leteti", roots: %w[leteti letim],
      unmunched: %w[leteti letim letel letela leta leto letom],
      stems: {"leteti" => %w[leteti letim], "letim" => %w[letim], "letel" => %w[letel leteti],
              "letela" => %w[leteti], "leta" => %w[leta letam let le], "leto" => %w[leto],
              "letom" => %w[leto]})
    assert_equal %w[leteti letim letel letela], forms
  end

  def test_expand_verb_without_dictionary_roots_returns_empty
    forms = expand_stubbed("xyzzeti", roots: [], unmunched: %w[xyzzam xyzzati], stems: {})
    assert_equal [], forms
  end

  def test_expand_noun_does_not_stem_the_forms_again
    stems_called = false
    forms = expand_stubbed("lupina", roots: %w[lupin], unmunched: %w[lupina lupino lupini],
      stems: ->(*) { stems_called = true; {} })
    assert_equal %w[lupina lupino lupini], forms
    refute stems_called
  end

  def test_expand_unknown_word_returns_empty
    skip "hunspell + sl_SI dictionary required" unless Tell::Hunspell.supports?("sl")

    forms = Tell::Hunspell.expand("burkla", lang: "sl")
    assert_equal [], forms
  end

  private

  Status = Struct.new(:success?)

  # expand with every external seam stubbed: the .dic index holds the
  # unmunched words, `hunspell -s` of the lemma gives roots, unmunch prints
  # unmunched, and stems (a hash or a callable) answers the batch stemmer.
  def expand_stubbed(lemma, roots:, unmunched:, stems:)
    index = Hash.new { |h, k| h[k] = [] }
    (unmunched + roots + [lemma]).uniq.each { |w| index[w] << "#{w}/A\n" }
    stems_impl = stems.respond_to?(:call) ? stems : ->(*) { stems }
    Tell::Hunspell.stub(:supports?, true) do
      Tell::Hunspell.stub(:utf8_paths, ["/x.dic", "/x.aff"]) do
        Tell::Hunspell.stub(:dic_word_index, index) do
          Tell::Hunspell.stub(:stem, roots) do
            Tell::Hunspell.stub(:stems_of, stems_impl) do
              Open3.stub(:capture3, ["#{unmunched.join("\n")}\n", "", Status.new(true)]) do
                Tell::Hunspell.expand(lemma, lang: "sl")
              end
            end
          end
        end
      end
    end
  end
end
