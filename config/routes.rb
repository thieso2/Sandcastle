Rails.application.routes.draw do
  root "dashboard#index"

  resource :session
  resources :passwords, param: :token

  resources :sandboxes, only: :destroy do
    member do
      post :start
      post :stop
      get :stats, controller: "dashboard", action: "stats"
    end
  end

  resource :tailscale, only: [], controller: "tailscale" do
    get :show
    post :enable
    delete :disable
  end

  namespace :admin do
    resources :users
  end

  namespace :api do
    resources :sandboxes do
      member do
        post :start
        post :stop
        post :connect
        post :snapshot
        post :restore
      end
    end
    resources :snapshots, only: [ :index, :destroy ], param: :name
    resources :users
    resource :status, only: :show
    resources :tokens, only: [ :index, :create, :destroy ]
    resource :tailscale, only: [], controller: "tailscale" do
      post :enable
      delete :disable
      get :status
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
