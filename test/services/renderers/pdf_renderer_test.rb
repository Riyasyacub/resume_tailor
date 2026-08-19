require "test_helper"
require "pdf-reader"

class PdfRendererTest < ActiveSupport::TestCase
  def text_of(resume)
    pdf = Renderers::PdfRenderer.call(resume)
    PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")
  end

  test "renders a valid pdf" do
    pdf = Renderers::PdfRenderer.call("name" => "Riyas Yacub", "contact" => [], "sections" => [])

    assert_equal "%PDF-", pdf.byteslice(0, 5)
  end

  # Regression: Prawn's built-in fonts are Windows-1252 only, and unmapped
  # characters were replaced with "" — silently turning JSON<->XML into JSONXML.
  test "transliterates symbols instead of deleting them" do
    text = text_of(
      "name" => "Riyas Yacub", "contact" => [],
      "sections" => [ { "heading" => "Experience", "type" => "entries", "entries" => [
        { "title" => "Engineer", "org" => "Effortless", "bullets" => [
          "Bidirectional JSON↔XML transformation",
          "Cut load time to <1s (>90% reduction) across ≥5 services",
          "Handled 20–25 instances → zero incidents, ±2% variance",
          "Saved ₹50,000/month"
        ] } ] } ]
    )

    { "JSON<->XML" => "↔ arrow", "<1s" => "less-than", ">90%" => "greater-than",
      ">=5 services" => "≥", "20-25" => "en dash", "->" => "→",
      "+/-2%" => "±", "Rs.50,000" => "₹" }.each do |probe, why|
      assert_includes text, probe, "#{why} was lost"
    end
  end

  test "keeps smart quotes readable" do
    text = text_of("name" => "X", "contact" => [], "summary" => "“Quoted” and ‘single’ and ellipsis…",
                   "sections" => [])

    assert_includes text, '"Quoted"'
    assert_includes text, "'single'"
    assert_includes text, "..."
  end

  test "renders grouped and entry sections in the order given" do
    text = text_of(
      "name" => "Riyas", "contact" => [],
      "sections" => [
        { "heading" => "Skills", "type" => "grouped", "groups" => [ { "label" => "Tech", "items" => %w[Ruby Go] } ] },
        { "heading" => "Experience", "type" => "entries",
          "entries" => [ { "title" => "Engineer", "org" => "Effortless", "bullets" => [ "shipped things" ] } ] }
      ]
    )

    assert_operator text.index("SKILLS"), :<, text.index("EXPERIENCE")
    assert_includes text, "shipped things"
  end

  test "survives a long resume without raising" do
    entries = (1..25).map { |i| { "title" => "Role #{i}", "org" => "Org #{i}", "dates" => "20#{i}",
                                  "bullets" => [ "bullet number #{i} " * 8 ] } }

    text = text_of("name" => "Long", "contact" => [],
                   "sections" => [ { "heading" => "Experience", "type" => "entries", "entries" => entries } ])

    assert_includes text, "Role 25"
  end
end
