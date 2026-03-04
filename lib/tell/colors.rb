# frozen_string_literal: true

module Tell
  module Colors
    # ANSI escape codes
    RESET     = "\e[0m"
    BOLD      = "\e[1m"
    DIM       = "\e[2m"
    ITALIC    = "\e[3m"
    RED       = "\e[31m"
    GREEN     = "\e[32m"
    YELLOW    = "\e[33m"
    BLUE      = "\e[34m"
    MAGENTA   = "\e[35m"
    CYAN      = "\e[36m"
    DARK_GRAY = "\e[90m"
    BRIGHT_GREEN = "\e[92m"
    BRIGHT_BLUE  = "\e[94m"
    BRIGHT_RED   = "\e[91m"

    # POS → color mapping for gloss tokens
    POS_COLORS = {
      "n"      => RED,
      "v"      => CYAN,
      "aux"    => CYAN,
      "adj"    => GREEN,
      "adv"    => BLUE,
      "pron"   => MAGENTA,
      "pr"     => DARK_GRAY,
      "conj"   => DARK_GRAY,
      "det"    => DARK_GRAY,
      "part"   => DARK_GRAY,
      "num"    => YELLOW,
      "interj" => BRIGHT_RED
    }.freeze

    # Gloss token patterns
    GLOSS_RE           = /(\S+?)\(([^)]+)\)/
    GLOSS_TRANSLATE_RE = /(\S+?)\(([^)]+)\)(\S*)/

    class << self
      def enabled?
        $stderr.tty?
      end

      # Core wrap — returns plain text when colors disabled
      def wrap(text, *codes)
        return text unless enabled?
        "#{codes.join}#{text}#{RESET}"
      end

      # --- Semantic helpers ---

      def tag(label)
        wrap(label, BOLD)
      end

      def forward(text)
        wrap(text, CYAN)
      end

      def reverse(text)
        wrap(text, YELLOW)
      end

      def error(text)
        wrap(text, RED)
      end

      def status(text)
        wrap(text, DARK_GRAY)
      end

      def warning(text)
        wrap(text, YELLOW)
      end

      # --- Gloss colorizers ---

      # Colorize plain gloss: word(grammar) word(grammar) ...
      def colorize_gloss(line)
        return line unless enabled?

        line.gsub(GLOSS_RE) do
          word, grammar = $1, $2
          color = pos_color(grammar)
          "#{color}#{BOLD}#{word}#{RESET}#{color}\e[2m(#{grammar})#{RESET}"
        end
      end

      # Colorize gloss+translate: word(grammar)translation ...
      def colorize_gloss_translate(line)
        return line unless enabled?

        line.gsub(GLOSS_TRANSLATE_RE) do
          word, grammar, translation = $1, $2, $3
          color = pos_color(grammar)
          result = "#{color}#{BOLD}#{word}#{RESET}#{color}\e[2m(#{grammar})#{RESET}"
          result += "#{ITALIC}#{translation}#{RESET}" unless translation.empty?
          result
        end
      end

      # Extract POS color from dot-separated grammar string
      def extract_pos(grammar)
        grammar.split(".").each do |part|
          return part if POS_COLORS.key?(part)
        end
        nil
      end

      private

      def pos_color(grammar)
        pos = extract_pos(grammar)
        pos ? POS_COLORS[pos] : ""
      end
    end
  end
end
