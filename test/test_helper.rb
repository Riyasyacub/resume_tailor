ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  parallelize(workers: 1)

  # Every LLM call goes through LlmClient#complete_json, so stubbing that one
  # method keeps the whole suite offline. The constructor is bypassed too: it
  # validates the API key, which lives in the browser session and is not present
  # on requests that do not go through the analyse form.
  def stub_llm(response, &block)
    with_stubbed_client(-> (*) { response }, &block)
  end

  def stub_llm_error(message = "boom", &block)
    with_stubbed_client(-> (*) { raise LlmClient::Error, message }, &block)
  end

  private

  def with_stubbed_client(behaviour)
    original_new  = LlmClient.instance_method(:initialize)
    original_call = LlmClient.instance_method(:complete_json)

    LlmClient.define_method(:initialize) { |**| }
    LlmClient.define_method(:complete_json) { |**| behaviour.call }
    yield
  ensure
    # Put the real methods back rather than removing ours, which would warn
    # about removing initialize and leave the class subtly different.
    LlmClient.define_method(:initialize, original_new)
    LlmClient.define_method(:complete_json, original_call)
  end
end
