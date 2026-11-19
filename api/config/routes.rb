Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :v1 do
    get "health", to: "health#show"
  end

  # Keep last: every other path, the root included, answers 404 in the JSON
  # error shape. "*path" needs at least one segment, so "/" has its own route.
  root to: "application#route_not_found", via: :all
  match "*path", to: "application#route_not_found", via: :all
end
