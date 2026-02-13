Rails.application.routes.draw do
  root "dashboard#index"

  resource :session
  resources :passwords, param: :token
  resource :invite, only: [ :edit, :update ], path_names: { edit: "" }

  get  "auth/:provider/callback", to: "oauth_callbacks#create"
  post "auth/:provider/callback", to: "oauth_callbacks#create"
  get  "auth/failure",            to: "oauth_callbacks#failure"
  resource :change_password, only: [ :show, :update ]

  get  "auth/device",              to: "device_auth#show",     as: :auth_device
  post "auth/device/verify",       to: "device_auth#verify",   as: :auth_device_verify
  get  "auth/device/approve/:id",  to: "device_auth#confirm",  as: :auth_device_confirm
  post "auth/device/approve",      to: "device_auth#approve",  as: :auth_device_approve

  resources :sandboxes, only: :destroy do
    member do
      post :start
      post :stop
      get :stats, controller: "dashboard", action: "stats"
      post :terminal, controller: "terminal", action: "open"
      delete :terminal, controller: "terminal", action: "close"
    end
  end

  get "terminal/auth", to: "terminal#auth"

  resource :tailscale, only: [], controller: "tailscale" do
    get :show
    post :login
    get :login_status
    patch :update_settings
    delete :disable
  end

  namespace :admin do
    get "/", to: "dashboard#index", as: :dashboard
    get "system_status", to: "dashboard#system_status"
    resource :settings, only: [ :edit, :update ]
    resources :users do
      post :invite, on: :collection
    end
    resources :sandboxes, only: :destroy do
      member do
        post :start
        post :stop
        get :stats
      end
    end
  end

  namespace :api do
    resources :sandboxes do
      member do
        post :start
        post :stop
        post :connect
        post :snapshot
        post :restore
        post :tailscale_connect
        delete :tailscale_disconnect
      end
      resources :routes, only: [ :index, :create, :destroy ], param: :domain, constraints: { domain: %r{[^/]+} }
    end
    resources :snapshots, only: [ :index, :destroy ], param: :name
    resources :users
    resource :status, only: :show
    resources :tokens, only: [ :index, :create, :destroy ]
    namespace :auth do
      post :device_code
      post :device_token
    end
    resource :tailscale, only: [], controller: "tailscale" do
      post :enable
      post :login
      get :login_status
      patch :update_settings
      delete :disable
      get :status
    end
  end

  get "guide", to: "pages#guide"

  get "up" => "rails/health#show", as: :rails_health_check
end
