require "prawn"

module Renderers
  # Single-column, selectable-text PDF. Same reasoning as the DOCX renderer:
  # no tables or columns, so a parser reads it top to bottom in the right order.
  class PdfRenderer
    def self.call(resume) = new(resume).call

    def initialize(resume)
      @r = resume
    end

    def call
      pdf = Prawn::Document.new(page_size: "LETTER", margin: [ 40, 45, 40, 45 ])
      pdf.font "Helvetica"

      header(pdf)
      summary(pdf)
      Array(@r["sections"]).each { |s| render_section(pdf, s) }

      pdf.render
    end

    private

    def header(pdf)
      pdf.text esc(@r["name"]), size: 19, style: :bold, align: :center
      pdf.text esc(@r["headline"]), size: 12, align: :center, color: "444444" if @r["headline"].present?

      contact = Array(@r["contact"]).compact_blank
      pdf.move_down 3
      pdf.text esc(contact.join("  |  ")), size: 8.5, align: :center, color: "555555" if contact.any?
      pdf.move_down 10
    end

    def summary(pdf)
      return if @r["summary"].blank?
      section_heading(pdf, "Summary")
      pdf.text esc(@r["summary"]), size: 10, leading: 2
      pdf.move_down 4
    end

    def render_section(pdf, section)
      section_heading(pdf, section["heading"])

      if section["type"] == "grouped"
        Array(section["groups"]).each do |g|
          items = Array(g["items"]).compact_blank.join(", ")
          next if items.blank?
          label = g["label"].present? ? "<b>#{esc(g['label'])}:</b> " : ""
          pdf.text "#{label}#{esc(items)}", size: 10, leading: 2, inline_format: true
          pdf.move_down 2
        end
        pdf.move_down 4
      else
        Array(section["entries"]).each { |e| render_entry(pdf, e) }
      end
    end

    def render_entry(pdf, entry)
      left  = [ entry["title"], entry["org"] ].compact_blank.join(" — ")
      right = [ entry["location"], entry["dates"] ].compact_blank.join(" | ")

      pdf.text esc(left), size: 10.5, style: :bold if left.present?
      pdf.text esc(right), size: 9, style: :italic, color: "555555" if right.present?
      pdf.move_down 2

      Array(entry["bullets"]).compact_blank.each do |b|
        pdf.indent(11) do
          pdf.text "• #{esc(b)}", size: 10, leading: 1.5
        end
        pdf.move_down 1.5
      end

      pdf.move_down 6
    end

    def section_heading(pdf, text)
      return if text.blank?
      pdf.move_down 4
      pdf.text esc(text.to_s.upcase), size: 10.5, style: :bold, character_spacing: 0.4
      pdf.stroke_color "AAAAAA"
      pdf.stroke_horizontal_rule
      pdf.stroke_color "000000"
      pdf.move_down 5
    end

    # Prawn's built-in AFM fonts cover Windows-1252 only. Anything outside it was
    # being silently deleted, which turned "JSON↔XML" into "JSONXML" — a real word
    # in the resume quietly mangled. Map the symbols that actually show up in
    # engineering resumes to ASCII rather than dropping them.
    TRANSLITERATIONS = {
      "‘" => "'", "’" => "'", "‚" => ",", "“" => '"', "”" => '"', "„" => '"',
      "–" => "-", "−" => "-", "‒" => "-", "―" => "-",
      "…" => "...", "•" => "-", "▪" => "-", "‣" => "-", "·" => "-",
      "↔" => "<->", "⇄" => "<->", "⟷" => "<->",
      "→" => "->", "⇒" => "=>", "⟶" => "->",
      "←" => "<-", "⇐" => "<=", "⟵" => "<-",
      "≤" => "<=", "≥" => ">=", "≈" => "~", "≠" => "!=",
      "×" => "x", "÷" => "/", "±" => "+/-",
      "™" => "(TM)", "€" => "EUR", "₹" => "Rs.", "∞" => "infinity",
      " " => " ", "​" => "", " " => " ", " " => " "
    }.freeze

    TRANSLITERATION_PATTERN = Regexp.union(TRANSLITERATIONS.keys).freeze

    def esc(text)
      text.to_s
          .gsub(TRANSLITERATION_PATTERN) { |c| TRANSLITERATIONS[c] }
          .encode("Windows-1252", invalid: :replace, undef: :replace, replace: "")
          .encode("UTF-8")
    end
  end
end
