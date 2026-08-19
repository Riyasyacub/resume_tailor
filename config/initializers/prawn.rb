require "prawn"

# We transliterate to Windows-1252 in Renderers::PdfRenderer before drawing text,
# so the built-in AFM font warning is expected and not actionable.
Prawn::Fonts::AFM.hide_m17n_warning = true
