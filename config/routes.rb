Rails.application.routes.draw do
  root "tailor#new"

  post "analyze",    to: "tailor#analyze",    as: :analyze
  delete "api_key",  to: "tailor#forget_key", as: :forget_key

  get  "sessions/:id",          to: "tailor#review",   as: :review
  post "sessions/:id/generate", to: "tailor#generate", as: :generate
  get  "sessions/:id/result",   to: "tailor#result",   as: :result
  get  "sessions/:id/download/:format", to: "tailor#download", as: :download, constraints: { format: /docx|pdf|md/ }

  get "up" => "rails/health#show", as: :rails_health_check
end
