require "net/http"
require "json"

# Thin adapter over Claude / OpenAI / Gemini.
#
# All three are asked for JSON and given their provider's native JSON mode,
# so we never have to scrape prose for a payload. Returns a parsed Hash.
class LlmClient
  class Error < StandardError; end

  PROVIDERS = {
    "claude" => { label: "Claude (Anthropic)", default_model: "claude-sonnet-5",  key_hint: "sk-ant-..." },
    "openai" => { label: "ChatGPT (OpenAI)",   default_model: "gpt-4o",            key_hint: "sk-..." },
    "gemini" => { label: "Gemini (Google)",    default_model: "gemini-2.5-flash",  key_hint: "AIza..." }
  }.freeze

  TIMEOUT = 180 # resume rewrites are slow; do not cut them off

  def initialize(provider:, api_key:, model: nil)
    @provider = provider.to_s
    @api_key  = api_key.to_s.strip
    @model    = model.presence || PROVIDERS.dig(@provider, :default_model)

    raise Error, "Unknown provider: #{@provider}" unless PROVIDERS.key?(@provider)
    raise Error, "API key is required." if @api_key.empty?
  end

  # Returns a parsed Hash. Raises LlmClient::Error with a readable message.
  def complete_json(system:, user:)
    body = send(:"#{@provider}_body", system, user)
    raw  = post(send(:"#{@provider}_uri"), send(:"#{@provider}_headers"), body)
    text = send(:"#{@provider}_extract", raw)

    parse_json(text)
  end

  def self.label_for(provider) = PROVIDERS.dig(provider.to_s, :label) || provider.to_s

  private

  def post(uri, headers, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = TIMEOUT
    http.open_timeout = 30

    request = Net::HTTP::Post.new(uri, headers)
    request.body = body.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "#{LlmClient.label_for(@provider)} returned #{response.code}: #{api_error_message(response.body)}"
    end

    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, "#{LlmClient.label_for(@provider)} timed out after #{TIMEOUT}s. Try a smaller resume or a faster model."
  rescue JSON::ParserError
    raise Error, "#{LlmClient.label_for(@provider)} returned a response we could not read."
  end

  # Pull the human-readable bit out of a provider error payload.
  def api_error_message(body)
    parsed = JSON.parse(body)
    parsed.dig("error", "message") || parsed.dig("error", "type") || body.to_s.truncate(300)
  rescue JSON::ParserError
    body.to_s.truncate(300)
  end

  def parse_json(text)
    cleaned = text.to_s.strip
      .sub(/\A```(?:json)?\s*/m, "")
      .sub(/```\z/m, "")
      .strip

    JSON.parse(cleaned)
  rescue JSON::ParserError
    raise Error, "#{LlmClient.label_for(@provider)} did not return valid JSON. Try again, or switch models."
  end

  # --- Claude ---------------------------------------------------------------

  def claude_uri = URI("https://api.anthropic.com/v1/messages")

  def claude_headers
    {
      "x-api-key" => @api_key,
      "anthropic-version" => "2023-06-01",
      "content-type" => "application/json"
    }
  end

  def claude_body(system, user)
    {
      model: @model,
      max_tokens: 8192,
      system: "#{system}\n\nRespond with a single valid JSON object and nothing else.",
      messages: [ { role: "user", content: user } ]
    }
  end

  def claude_extract(raw)
    raw.dig("content", 0, "text")
  end

  # --- OpenAI ---------------------------------------------------------------

  def openai_uri = URI("https://api.openai.com/v1/chat/completions")

  def openai_headers
    { "Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json" }
  end

  def openai_body(system, user)
    {
      model: @model,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "#{system}\n\nRespond with a single valid JSON object." },
        { role: "user", content: user }
      ]
    }
  end

  def openai_extract(raw)
    raw.dig("choices", 0, "message", "content")
  end

  # --- Gemini ---------------------------------------------------------------

  def gemini_uri
    URI("https://generativelanguage.googleapis.com/v1beta/models/#{@model}:generateContent?key=#{@api_key}")
  end

  def gemini_headers = { "Content-Type" => "application/json" }

  def gemini_body(system, user)
    {
      systemInstruction: { parts: [ { text: system } ] },
      contents: [ { role: "user", parts: [ { text: user } ] } ],
      generationConfig: { responseMimeType: "application/json", maxOutputTokens: 8192 }
    }
  end

  def gemini_extract(raw)
    raw.dig("candidates", 0, "content", "parts", 0, "text")
  end
end
