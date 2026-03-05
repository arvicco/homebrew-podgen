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
    BRIGHT_RED    = "\e[91m"
    BRIGHT_YELLOW = "\e[93m"

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

    # Gloss token patterns — combined agram|plain in single regex to avoid
    # second-pass gsub re-matching ANSI escape codes from the first pass.
    # Agram branch (groups 1-4/5): *wrong*correct[ph](grammar)[translation]
    # Plain branch (groups 5-7/6-9): word[ph](grammar)[translation]
    GLOSS_TOKEN_RE           = /\*(\S+?)\*(\S+?)(?:\s?\[([^\]]+)\])?\(([^)]+)\)|(\S+?)(?:\s?\[([^\]]+)\])?\(([^)]+)\)/
    GLOSS_TRANSLATE_TOKEN_RE = /\*(\S+?)\*(\S+?)(?:\s?\[([^\]]+)\])?\(([^)]+)\)([^\s\[]*)|(\S+?)(?:\s?\[([^\]]+)\])?\(([^)]+)\)([^\s\[]*)/

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

      def phonetic(text)
        wrap(text, BRIGHT_GREEN)
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
      # Single-pass gsub: agram branch matched first (groups 1-4), plain branch
      # as fallback (groups 5-7). Avoids chained gsub where ANSI codes from the
      # first pass get re-matched by the second.

      def colorize_gloss(line)
        return line unless enabled?

        line.gsub(GLOSS_TOKEN_RE) do
          if $1 # agram: wrong=$1, correct=$2, ph=$3, grammar=$4
            color = pos_color($4)
            result = "#{BRIGHT_YELLOW}#{BOLD}*#{$1}*#{RESET}#{color}#{BOLD}#{$2}#{RESET}"
            result += "#{BRIGHT_GREEN}[#{$3}]#{RESET}" if $3
            result += "#{color}#{DIM}(#{$4})#{RESET}"
            result
          else # plain: word=$5, ph=$6, grammar=$7
            color = pos_color($7)
            result = "#{color}#{BOLD}#{$5}#{RESET}"
            result += "#{BRIGHT_GREEN}[#{$6}]#{RESET}" if $6
            result += "#{color}#{DIM}(#{$7})#{RESET}"
            result
          end
        end
      end

      def colorize_gloss_translate(line)
        return line unless enabled?

        line.gsub(GLOSS_TRANSLATE_TOKEN_RE) do
          if $1 # agram: wrong=$1, correct=$2, ph=$3, grammar=$4, translation=$5
            color = pos_color($4)
            result = "#{BRIGHT_YELLOW}#{BOLD}*#{$1}*#{RESET}#{color}#{BOLD}#{$2}#{RESET}"
            result += "#{BRIGHT_GREEN}[#{$3}]#{RESET}" if $3
            result += "#{color}#{DIM}(#{$4})#{RESET}"
            result += "#{ITALIC}#{$5}#{RESET}" unless $5.empty?
            result
          else # plain: word=$6, ph=$7, grammar=$8, translation=$9
            color = pos_color($8)
            result = "#{color}#{BOLD}#{$6}#{RESET}"
            result += "#{BRIGHT_GREEN}[#{$7}]#{RESET}" if $7
            result += "#{color}#{DIM}(#{$8})#{RESET}"
            result += "#{ITALIC}#{$9}#{RESET}" unless $9.empty?
            result
          end
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
