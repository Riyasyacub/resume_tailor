require "test_helper"

class ResumeParserTest < ActiveSupport::TestCase
  # Stands in for ActionDispatch::Http::UploadedFile.
  Upload = Struct.new(:original_filename, :bytes) do
    def size = bytes.bytesize
    def read = bytes
    def blank? = false
  end

  SAMPLE = <<~TXT.freeze
    Riyas Yacub
    SUMMARY
    Backend engineer with 5+ years building production FinTech systems.
    SKILLS
    Ruby, Go, PostgreSQL, Docker, AWS, Sidekiq, Redis, ActionCable, Minitest
  TXT

  # Regression: uploads arrive as ASCII-8BIT and unicode_normalize refuses binary,
  # so every .txt and .docx upload used to raise Encoding::CompatibilityError.
  test "parses a binary-encoded txt upload into valid UTF-8" do
    upload = Upload.new("resume.txt", SAMPLE.dup.force_encoding(Encoding::ASCII_8BIT))

    text = ResumeParser.call(upload)

    assert_equal Encoding::UTF_8, text.encoding
    assert text.valid_encoding?
    assert_includes text, "Riyas Yacub"
  end

  test "parses a docx built by our own renderer" do
    docx = Renderers::DocxRenderer.call(
      "name" => "Riyas Yacub",
      "summary" => "Backend engineer with five years of production experience shipping systems.",
      "sections" => [ { "heading" => "Skills", "type" => "grouped",
                        "groups" => [ { "label" => "Tech", "items" => %w[Ruby Go PostgreSQL Docker] } ] } ]
    )

    text = ResumeParser.call(Upload.new("resume.docx", docx))

    assert_equal Encoding::UTF_8, text.encoding
    assert text.valid_encoding?
    assert_includes text, "Riyas Yacub"
    assert_includes text, "PostgreSQL"
  end

  test "parses a pdf built by our own renderer" do
    pdf = Renderers::PdfRenderer.call(
      "name" => "Riyas Yacub",
      "summary" => "Backend engineer with five years of production experience shipping systems.",
      "sections" => [ { "heading" => "Skills", "type" => "grouped",
                        "groups" => [ { "label" => "Tech", "items" => %w[Ruby Go PostgreSQL Docker] } ] } ]
    )

    text = ResumeParser.call(Upload.new("resume.pdf", pdf))

    assert_equal Encoding::UTF_8, text.encoding
    assert_includes text, "Riyas Yacub"
  end

  test "keeps non-ascii characters intact" do
    text = ResumeParser.call(Upload.new("resume.txt", "Rîyas — café résumé, naïve. #{SAMPLE}"))

    assert_includes text, "café"
    assert_includes text, "—"
  end

  test "rejects a file too short to be a resume" do
    error = assert_raises(ResumeParser::Error) { ResumeParser.call(Upload.new("r.txt", "too short")) }
    assert_match(/could only read/i, error.message)
  end

  test "rejects binary junk rather than emitting mojibake" do
    assert_raises(ResumeParser::Error) do
      ResumeParser.call(Upload.new("r.txt", "\xFF\xFE\x00\x01 junk".b))
    end
  end

  test "rejects unsupported extensions" do
    error = assert_raises(ResumeParser::Error) { ResumeParser.call(Upload.new("r.rtf", SAMPLE)) }
    assert_match(/unsupported file type/i, error.message)
  end

  test "points legacy .doc users at a format we can read" do
    error = assert_raises(ResumeParser::Error) { ResumeParser.call(Upload.new("r.doc", SAMPLE)) }
    assert_match(/\.docx or PDF/i, error.message)
  end

  test "requires a file at all" do
    assert_raises(ResumeParser::Error) { ResumeParser.call(nil) }
  end
end
