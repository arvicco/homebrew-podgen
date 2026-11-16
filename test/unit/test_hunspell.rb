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

  # --- missing_for / missing_message (P25-2) ---

  def test_missing_for_names_both_files_when_no_dir_holds_them
    Dir.mktmpdir do |dir|
      Tell::Hunspell.stub(:dict_dirs, [dir]) do
        assert_equal %w[es_ES.dic es_ES.aff], Tell::Hunspell.missing_for("es")
      end
    end
  end

  def test_missing_for_installed_pair_is_empty
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "es_ES.dic"), "1\nx\n")
      File.write(File.join(dir, "es_ES.aff"), "SET UTF-8\n")
      Tell::Hunspell.stub(:dict_dirs, ["/nonexistent", dir]) do
        assert_equal [], Tell::Hunspell.missing_for("es")
        assert_nil Tell::Hunspell.missing_message("es")
      end
    end
  end

  def test_missing_for_dic_without_aff_is_missing
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "es_ES.dic"), "1\nx\n")
      Tell::Hunspell.stub(:dict_dirs, [dir]) do
        assert_equal %w[es_ES.dic es_ES.aff], Tell::Hunspell.missing_for("es")
      end
    end
  end

  def test_missing_for_unmapped_language_is_nil_with_mapping_message
    assert_nil Tell::Hunspell.missing_for("xx")
    assert_equal "no dictionary mapping for 'xx': inflections are not expanded", Tell::Hunspell.missing_message("xx")
  end

  def test_missing_message_names_dictionary_and_install_command
    Dir.mktmpdir do |dir|
      Tell::Hunspell.stub(:dict_dirs, [dir]) do
        assert_equal "no hunspell dictionary for 'es' (es_ES): inflections are not expanded — run scripts/install_hunspell_dicts.rb es",
          Tell::Hunspell.missing_message("es")
      end
    end
  end

  def test_expansion_problem_installed_files_without_tools_names_the_tools
    Dir.mktmpdir do |dir|
      %w[es_ES.dic es_ES.aff].each { File.write(File.join(dir, it), "") }
      Tell::Hunspell.stub(:dict_dirs, [dir]) do
        Tell::Hunspell.stub(:available?, false) do
          assert_match(/hunspell or unmunch not installed/, Tell::Hunspell.expansion_problem("es"))
        end
        Tell::Hunspell.stub(:available?, true) do
          assert_nil Tell::Hunspell.expansion_problem("es")
        end
      end
    end
  end

  def test_check_report_lists_installed_and_missing_languages
    Dir.mktmpdir do |dir|
      %w[sl_SI.dic sl_SI.aff].each { File.write(File.join(dir, it), "") }
      Tell::Hunspell.stub(:dict_dirs, [dir]) do
        lines, ok = Tell::Hunspell.check_report(%w[sl es xx])
        refute ok
        assert_equal "sl: installed (sl_SI)", lines[0]
        assert_match(/\Aes: MISSING — no hunspell dictionary for 'es' \(es_ES\)/, lines[1])
        assert_match(/\Axx: MISSING — no dictionary mapping for 'xx'/, lines[2])
        assert_equal [["sl: installed (sl_SI)"], true], Tell::Hunspell.check_report(%w[sl])
      end
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
    stems = lambda do |*|
      stems_called = true
      {}
    end
    forms = expand_stubbed("lupina", roots: %w[lupin], unmunched: %w[lupina lupino lupini], stems: stems)
    assert_equal %w[lupina lupino lupini], forms
    refute stems_called
  end

  # --- P24-1 (Q-168): a non-verb lemma whose root is a different word ---

  # Recorded from `hunspell -d it_IT -s`: "nuovamente nuovo",
  # "farcela fare", "moltissimo molto", "casa caso". unmunch of the root's
  # entry prints the root's forms, which the prefix filter narrows to the
  # root itself, so the lemma never appears in its own expansion.
  def test_expand_non_verb_lemma_whose_root_differs_excludes_root_forms
    forms = expand_stubbed("nuovamente", roots: %w[nuovo],
      unmunched: %w[nuovo nuova nuovi nuove nuovamente], stems: {})
    refute_includes forms, "nuovo"
    assert_equal [], forms
  end

  def test_expand_non_verb_clitic_lemma_excludes_the_bare_verb
    forms = expand_stubbed("farcela", roots: %w[fare],
      unmunched: %w[fare farei faremo fatto], stems: {})
    assert_equal [], forms
  end

  def test_expand_non_verb_lemma_among_its_root_forms_keeps_them
    forms = expand_stubbed("lupina", roots: %w[lupin], unmunched: %w[lupina lupino lupini], stems: {})
    assert_equal %w[lupina lupino lupini], forms
  end

  # --- P24-1 (Q-168): the .aff SET line decides the dictionary encoding ---

  # it_IT.aff carries `SET UTF-8` on line 36, after a comment block.
  def test_utf8_paths_set_line_after_100_bytes_uses_original_files
    in_dict_dir("#{"# comment line of the licence header\n" * 5}SET UTF-8\n") do |dic, aff, cache|
      assert_equal [dic, aff], Tell::Hunspell.send(:utf8_paths, "xx_XX")
      assert_empty Dir.children(cache)
    end
  end

  def test_utf8_paths_converts_legacy_encoding_into_versioned_cache
    in_dict_dir("# header\nSET ISO8859-1\nTRY abc\n", dic_body: "1\ncitt\xE0/A\n".b) do |_dic, _aff, cache|
      utf8_dic, utf8_aff = Tell::Hunspell.send(:utf8_paths, "xx_XX")
      assert_equal File.join(cache, "hunspell_xx_XX_utf8_v#{Tell::Hunspell::CACHE_VERSION}.dic"), utf8_dic
      assert_includes File.read(utf8_dic, encoding: "UTF-8"), "città"
      assert_includes File.read(utf8_aff), "SET UTF-8"
      assert_equal 2, Dir.children(cache).length, "no temp files left behind"
    end
  end

  def test_utf8_paths_rewrites_the_set_directive_not_a_comment_that_contains_set
    aff = "# RESET note\n# SET ISO8859-1 (old header)\nSET ISO8859-1\nTRY abc\n"
    in_dict_dir(aff, dic_body: "1\ncitt\xE0/A\n".b) do |_dic, _aff, _cache|
      _utf8_dic, utf8_aff = Tell::Hunspell.send(:utf8_paths, "xx_XX")
      converted = File.read(utf8_aff, encoding: "UTF-8")
      assert_match(/^SET UTF-8$/, converted, "the SET directive line is rewritten")
      refute_match(/^SET ISO8859-1/, converted, "the old directive must not survive")
      assert_includes converted, "# RESET note", "comment text is untouched"
    end
  end

  def test_utf8_paths_ignores_cache_written_by_the_old_path
    in_dict_dir("SET ISO8859-1\n", dic_body: "1\ncitt\xE0/A\n".b) do |_dic, _aff, cache|
      File.write(File.join(cache, "hunspell_xx_XX_utf8.dic"), "1\ncittĂ /A\n")
      File.write(File.join(cache, "hunspell_xx_XX_utf8.aff"), "SET UTF-8\n")
      utf8_dic, _ = Tell::Hunspell.send(:utf8_paths, "xx_XX")
      refute_equal File.join(cache, "hunspell_xx_XX_utf8.dic"), utf8_dic
      assert_includes File.read(utf8_dic, encoding: "UTF-8"), "città"
    end
  end

  def test_utf8_paths_failed_iconv_writes_no_cache_and_returns_nil
    in_dict_dir("SET ISO8859-1\n") do |_dic, _aff, cache|
      paths = nil
      _out, err = capture_io do
        paths = Open3.stub(:capture3, ["partial", "iconv: bad", Status.new(false)]) do
          Tell::Hunspell.send(:utf8_paths, "xx_XX")
        end
      end
      assert_equal [nil, nil], paths
      assert_empty Dir.children(cache)
      assert_includes err, "iconv"
    end
  end

  # --- P18-8 (5): the batch `hunspell -s` parser ---

  # Recorded from `printf 'letim\nleta\nburkla\n' | hunspell -d sl_SI -s`
  # (hunspell 1.7, macOS): one "word root" line per root, a blank line
  # per word, an unknown word echoed alone.
  STEMS_SAMPLE = "letim letim\n\nleta leta\nleta letam\nleta let\nleta le\n\nburkla\n\n"

  def test_stems_of_parses_batch_output_into_roots_per_word
    stems = Open3.stub(:capture3, [STEMS_SAMPLE, "", Status.new(true)]) do
      Tell::Hunspell.send(:stems_of, %w[letim leta burkla], "sl_SI")
    end
    assert_equal({"letim" => %w[letim], "leta" => %w[leta letam let le]}, stems)
    refute stems.key?("burkla")
  end

  def test_stems_of_failed_run_warns_and_returns_empty
    stems = nil
    _out, err = capture_io do
      stems = Open3.stub(:capture3, ["", "boom", Status.new(false)]) do
        Tell::Hunspell.send(:stems_of, %w[letim], "sl_SI")
      end
    end
    assert_equal({}, stems)
    assert_includes err, "hunspell -s failed"
    assert_includes err, "sl_SI"
  end

  def test_expand_unknown_word_returns_empty
    skip "hunspell + sl_SI dictionary required" unless Tell::Hunspell.supports?("sl")

    forms = Tell::Hunspell.expand("burkla", lang: "sl")
    assert_equal [], forms
  end

  private

  # A dictionary dir holding xx_XX.aff (aff_body) and xx_XX.dic, plus an
  # empty conversion cache dir; yields [dic_path, aff_path, cache_dir].
  def in_dict_dir(aff_body, dic_body: "1\nparola/A\n")
    Dir.mktmpdir("hunspell_test") do |dir|
      dic = File.join(dir, "xx_XX.dic")
      aff = File.join(dir, "xx_XX.aff")
      File.binwrite(dic, dic_body)
      File.binwrite(aff, aff_body)
      cache = File.join(dir, "cache")
      Dir.mkdir(cache)
      Tell::Hunspell.stub(:find_dic_path, dic) do
        Tell::Hunspell.stub(:cache_dir, cache) { yield dic, aff, cache }
      end
    end
  end

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
