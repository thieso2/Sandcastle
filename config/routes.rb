Rails.application.routes.draw do
  root "dashboard#index"

  resource :session
  resources :passwords, param: :token

  namespace :api do
    resources :sandboxes do
      member do
        post :start
        post :stop
        post :connect
      end
    end
    resources :users
    resource :status, only: :show
    resources :tokens, only: [ :index, :create, :destroy ]
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
