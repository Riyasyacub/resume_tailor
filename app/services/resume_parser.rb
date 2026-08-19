require "pdf-reader"
require "zip"

# Turns an uploaded resume into plain text. PDF, DOCX, TXT, MD.
# Nothing is written to disk — the file is read from the upload tempfile and discarded.
class ResumeParser
  class Error < StandardError; end

  MAX_BYTES = 10.megabytes

  def self.call(uploaded_file)
    new(uploaded_file).call
  end

  def initialize(uploaded_file)
    @file = uploaded_file
  end

  def call
    raise Error, "Please attach your resume." if @file.blank?
    raise Error, "That file is larger than 10MB." if @file.size > MAX_BYTES

    text =
      case File.extname(@file.original_filename).downcase
      when ".pdf"           then from_pdf
      when ".docx"          then from_docx
      when ".txt", ".md"    then @file.read.to_s
      when ".doc"
        raise Error, "Legacy .doc isn't supported. Save it as .docx or PDF and try again."
      else
        raise Error, "Unsupported file type. Use PDF, DOCX, or TXT."
      end

    cleaned = normalise(text)

    if cleaned.length < 100
      raise Error, "We could only read #{cleaned.length} characters from that file. " \
                   "If it's a scanned image, export a text-based PDF or paste the content into a .txt file."
    end

    cleaned
  end

  private

  def from_pdf
    io = StringIO.new(@file.read)
    PDF::Reader.new(io).pages.map(&:text).join("\n")
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
    raise Error, "Could not read that PDF (#{e.class.name.demodulize}). Try re-exporting it."
  end

  # A .docx is a zip; the body text lives in word/document.xml.
  def from_docx
    xml = nil

    Zip::File.open_buffer(@file.read) do |zip|
      entry = zip.find_entry("word/document.xml")
      raise Error, "That .docx looks corrupted — no document body found." if entry.nil?
      xml = entry.get_input_stream.read
    end

    xml
      .dup
      .force_encoding(Encoding::UTF_8)  # zip entries come back as binary
      .scrub("")
      .gsub(/<w:p[ >]/, "\n\\0")        # paragraph breaks
      .gsub(/<w:br\s*\/>/, "\n")        # explicit line breaks
      .gsub(/<w:tab\s*\/>/, "  ")       # tabs
      .gsub(/<[^>]+>/, "")              # strip remaining tags
      .then { |s| unescape_xml(s) }
  rescue Zip::Error
    raise Error, "Could not open that .docx file."
  end

  def unescape_xml(str)
    str.gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">")
       .gsub("&quot;", '"').gsub("&apos;", "'")
  end

  # Uploaded files arrive as ASCII-8BIT. unicode_normalize refuses to touch binary,
  # so tag the bytes as UTF-8 and scrub anything invalid before normalising.
  def normalise(text)
    text.to_s
        .dup
        .force_encoding(Encoding::UTF_8)
        .scrub("")
        .unicode_normalize(:nfkc)
        .gsub("\r\n", "\n")
        .gsub(/[ \t]+/, " ")
        .gsub(/\n{3,}/, "\n\n")
        .strip
  end
end
