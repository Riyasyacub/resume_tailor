module Renderers
  class MarkdownRenderer
    def self.call(resume) = new(resume).call

    def initialize(resume)
      @r = resume
    end

    def call
      out = []
      out << "# #{@r['name']}"
      out << "**#{@r['headline']}**" if @r["headline"].present?
      out << Array(@r["contact"]).compact_blank.join(" | ") if @r["contact"].present?

      if @r["summary"].present?
        out << "\n## Summary\n"
        out << @r["summary"]
      end

      Array(@r["sections"]).each do |section|
        out << "\n## #{section['heading']}\n"

        if section["type"] == "grouped"
          Array(section["groups"]).each do |g|
            label = g["label"].present? ? "**#{g['label']}:** " : ""
            out << "#{label}#{Array(g['items']).join(', ')}"
          end
        else
          Array(section["entries"]).each do |e|
            heading = [ e["title"], e["org"] ].compact_blank.join(" — ")
            meta    = [ e["location"], e["dates"] ].compact_blank.join(" | ")
            out << "### #{heading}"
            out << "*#{meta}*" if meta.present?
            Array(e["bullets"]).each { |b| out << "- #{b}" }
            out << ""
          end
        end
      end

      out.join("\n").gsub(/\n{3,}/, "\n\n").strip + "\n"
    end
  end
end
