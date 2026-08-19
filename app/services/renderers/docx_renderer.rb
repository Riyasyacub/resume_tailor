require "zip"

module Renderers
  # Writes a minimal, deliberately plain .docx.
  #
  # No tables, no columns, no text boxes, no headers or footers. Those are exactly
  # what breaks ATS parsers, so the document is a flat run of paragraphs. Bullets are
  # literal characters rather than Word list numbering for the same reason.
  class DocxRenderer
    FONT = "Calibri".freeze

    def self.call(resume) = new(resume).call

    def initialize(resume)
      @r = resume
      @body = +""
    end

    def call
      heading_name
      contact_line
      summary

      Array(@r["sections"]).each { |section| render_section(section) }

      package(document_xml)
    end

    private

    # --- content ------------------------------------------------------------

    def heading_name
      para(@r["name"], size: 32, bold: true, align: "center", after: 40)
      para(@r["headline"], size: 24, align: "center", after: 40) if @r["headline"].present?
    end

    def contact_line
      contact = Array(@r["contact"]).compact_blank
      return if contact.empty?
      para(contact.join("  |  "), size: 18, align: "center", after: 200)
    end

    def summary
      return if @r["summary"].blank?
      section_heading("Summary")
      para(@r["summary"], size: 21, after: 160)
    end

    def render_section(section)
      section_heading(section["heading"])

      if section["type"] == "grouped"
        Array(section["groups"]).each do |g|
          items = Array(g["items"]).compact_blank.join(", ")
          next if items.blank?
          runs = []
          runs << run("#{g['label']}: ", size: 21, bold: true) if g["label"].present?
          runs << run(items, size: 21)
          paragraph(runs.join, after: 60)
        end
        spacer
      else
        Array(section["entries"]).each { |e| render_entry(e) }
      end
    end

    def render_entry(entry)
      left  = [ entry["title"], entry["org"] ].compact_blank.join(" — ")
      right = [ entry["location"], entry["dates"] ].compact_blank.join(" | ")

      paragraph(run(left, size: 22, bold: true), after: 0) if left.present?
      paragraph(run(right, size: 19, italic: true), after: 60) if right.present?

      Array(entry["bullets"]).compact_blank.each do |b|
        paragraph(run("• #{b}", size: 21), after: 40, indent: 260)
      end

      spacer
    end

    def section_heading(text)
      return if text.blank?
      paragraph(run(text.to_s.upcase, size: 22, bold: true), after: 60, before: 160, border: true)
    end

    def spacer = @body << %(<w:p><w:pPr><w:spacing w:after="80"/></w:pPr></w:p>)

    # --- primitives ---------------------------------------------------------

    def para(text, size:, bold: false, italic: false, align: nil, after: 80)
      return if text.blank?
      paragraph(run(text, size:, bold:, italic:), align:, after:)
    end

    def run(text, size:, bold: false, italic: false)
      props = +"<w:rFonts w:ascii=\"#{FONT}\" w:hAnsi=\"#{FONT}\"/>"
      props << "<w:b/>" if bold
      props << "<w:i/>" if italic
      props << %(<w:sz w:val="#{size}"/><w:szCs w:val="#{size}"/>)

      %(<w:r><w:rPr>#{props}</w:rPr><w:t xml:space="preserve">#{esc(text)}</w:t></w:r>)
    end

    # CT_PPrBase defines a fixed sequence for the children of w:pPr. Emitting them
    # out of order produces a file Word refuses to open as corrupt, even though the
    # XML is perfectly well-formed. The schema order used here is:
    #   pBdr -> spacing -> ind -> jc
    def paragraph(runs, align: nil, after: 80, before: 0, indent: nil, border: false)
      props = +""
      props << %(<w:pBdr><w:bottom w:val="single" w:sz="4" w:space="2" w:color="999999"/></w:pBdr>) if border
      props << %(<w:spacing w:before="#{before}" w:after="#{after}"/>)
      props << %(<w:ind w:left="#{indent}" w:hanging="180"/>) if indent
      props << %(<w:jc w:val="#{align}"/>) if align

      @body << "<w:p><w:pPr>#{props}</w:pPr>#{runs}</w:p>"
    end

    def esc(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
          .gsub('"', "&quot;").gsub("'", "&apos;")
          .gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "") # control chars are invalid in OOXML
    end

    # --- packaging ----------------------------------------------------------

    # The content model of w:body admits block elements only, so indentation between
    # them is a whitespace text node the schema does not allow. Word forgives it;
    # stricter readers reject the whole file. Emit it flat, no pretty-printing.
    NAMESPACES = [
      'xmlns:ve="http://schemas.openxmlformats.org/markup-compatibility/2006"',
      'xmlns:o="urn:schemas-microsoft-com:office:office"',
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"',
      'xmlns:v="urn:schemas-microsoft-com:vml"',
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
      'xmlns:w10="urn:schemas-microsoft-com:office:word"',
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    ].join(" ").freeze

    SECT_PR = '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>' \
              '<w:pgMar w:top="720" w:right="900" w:bottom="720" w:left="900" ' \
              'w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>'.freeze

    def document_xml
      %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>) +
        %(<w:document #{NAMESPACES}><w:body>#{@body}#{SECT_PR}</w:body></w:document>)
    end

    CONTENT_TYPES = <<~XML.freeze
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      </Types>
    XML

    RELS = <<~XML.freeze
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
      </Relationships>
    XML

    # document.xml has no outbound relationships, but Word expects the part to exist.
    DOCUMENT_RELS = <<~XML.freeze
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
    XML

    def package(document)
      # rubyzip 3.x defaults write_zip64_support to true (2.x defaulted to false).
      # In streaming mode that writes 0xFFFFFFFF size sentinels into every local file
      # header, even for a 2KB archive. Word and macOS both reject the result as
      # corrupt while `file` still happily reports "Microsoft Word 2007+".
      # Set here rather than in an initializer so nothing can load after us and
      # silently flip it back.
      Zip.write_zip64_support = false

      # [Content_Types].xml must be the first entry in the archive.
      buffer = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry("[Content_Types].xml");        zip.write CONTENT_TYPES
        zip.put_next_entry("_rels/.rels");                zip.write RELS
        zip.put_next_entry("word/_rels/document.xml.rels"); zip.write DOCUMENT_RELS
        zip.put_next_entry("word/document.xml");          zip.write document
      end

      buffer.string
    end
  end
end
