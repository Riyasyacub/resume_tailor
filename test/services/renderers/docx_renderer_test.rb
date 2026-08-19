require "test_helper"
require "zip"

class DocxRendererTest < ActiveSupport::TestCase
  RESUME = {
    "name" => "Riyas Yacub",
    "headline" => "Backend Engineer | FinTech & Payments",
    "contact" => [ "riyasyacub@gmail.com", "+91 9944706071", "Chennai, India" ],
    "summary" => "Backend Engineer with 5+ years building production FinTech systems.",
    "sections" => [
      { "heading" => "Technical Skills", "type" => "grouped",
        "groups" => [ { "label" => "Languages", "items" => [ "Ruby", "SQL", "C++" ] } ] },
      { "heading" => "Professional Experience", "type" => "entries",
        "entries" => [ { "title" => "Backend Engineer", "org" => "Effortless", "location" => "Chennai",
                         "dates" => "June 2022 - Present",
                         "bullets" => [ "Bidirectional JSON<->XML transformation",
                                        'Handled <tags>, "quotes" & ampersands' ] } ] }
    ]
  }.freeze

  def render(resume = RESUME) = Renderers::DocxRenderer.call(resume)

  def document_xml(bytes)
    Zip::File.open_buffer(bytes) { |zip| return zip.read("word/document.xml") }
  end

  test "produces a zip whose first entry is the content types part" do
    names = []
    Zip::File.open_buffer(render) { |zip| names = zip.map(&:name) }

    assert_equal "[Content_Types].xml", names.first
    assert_includes names, "_rels/.rels"
    assert_includes names, "word/_rels/document.xml.rels"
    assert_includes names, "word/document.xml"
  end

  # Regression: rubyzip 3.x defaults write_zip64_support to true, which writes
  # 0xFFFFFFFF size sentinels into every local header. Word and macOS both then
  # reject the file as corrupt, while `file` still reports it as a Word document.
  test "writes no zip64 sentinels into local file headers" do
    bytes = render
    offset = 0
    entries = 0

    while bytes.byteslice(offset, 4) == "PK\x03\x04".b
      _sig, _ver, _flag, _meth, _t, _dt, _crc, csize, usize, name_len, extra_len =
        bytes.byteslice(offset, 30).unpack("VvvvvvVVVvv")

      refute_equal 0xFFFFFFFF, csize, "compressed size is a ZIP64 sentinel"
      refute_equal 0xFFFFFFFF, usize, "uncompressed size is a ZIP64 sentinel"

      offset += 30 + name_len + extra_len + csize
      entries += 1
    end

    assert_equal 4, entries, "expected to walk all four entries via their local headers"
  end

  # Regression: CT_PPrBase fixes the order of w:pPr children. Emitting spacing
  # before pBdr yields well-formed XML that Word refuses to open.
  test "orders w:pPr children to match the OOXML schema sequence" do
    schema_order = %w[pBdr spacing ind jc]

    document_xml(render).scan(%r{<w:pPr>(.*?)</w:pPr>}m).flatten.each do |block|
      found = block.scan(%r{<w:(#{schema_order.join('|')})[ /><]}).flatten
      assert_equal found.sort_by { |e| schema_order.index(e) }, found,
                   "w:pPr children out of schema order: #{found.inspect}"
    end
  end

  # Regression: heredoc indentation put whitespace text nodes inside w:body,
  # which its content model does not allow.
  test "puts no stray text nodes between block elements in w:body" do
    body = document_xml(render)[%r{<w:body>(.*)</w:body>}m, 1]

    refute_match(/>\s+</, body, "found whitespace between elements in w:body")
  end

  test "escapes xml metacharacters in resume content" do
    xml = document_xml(render)

    assert_includes xml, "&lt;tags&gt;"
    assert_includes xml, "&amp;"
    refute_includes xml, "<tags>"
  end

  test "sectPr is the final child of the body" do
    assert_match %r{<w:sectPr>.*</w:sectPr></w:body>}m, document_xml(render)
  end

  # The only check that would actually have caught the corruption: hand the file
  # to a real OOXML reader. `file` and XML well-formedness both said "fine".
  test "opens in a real ooxml reader" do
    skip "textutil is macOS only" unless RUBY_PLATFORM.include?("darwin") && File.executable?("/usr/bin/textutil")

    Tempfile.create([ "resume", ".docx" ]) do |f|
      f.binmode
      f.write(render)
      f.flush

      output = `/usr/bin/textutil -convert txt -stdout #{f.path.shellescape} 2>&1`

      refute_match(/isn.t in the correct format|Error reading/, output,
                   "a real OOXML reader rejected the generated file")
      assert_includes output, "Riyas Yacub"
      assert_includes output, "C++"
    end
  end

  test "handles a minimal resume with no contact or summary" do
    bytes = render("name" => "X", "contact" => [],
                   "sections" => [ { "heading" => "Experience", "type" => "entries",
                                     "entries" => [ { "title" => "Dev", "org" => "Y", "bullets" => [ "did work" ] } ] } ])

    assert_operator bytes.bytesize, :>, 0
    assert_includes document_xml(bytes), "did work"
  end
end
