Rails.application.routes.draw do
  root "dashboard#index"

  # Mount Action Cable for WebSocket connections
  mount ActionCable.server => "/cable"

  resource :session
  resources :passwords, param: :token

  get  "invites/:token",        to: "registrations#new",    as: :new_registration
  post "invites/:token/accept", to: "registrations#create", as: :accept_registration

  get  "auth/:provider/callback", to: "oauth_callbacks#create"
  post "auth/:provider/callback", to: "oauth_callbacks#create"
  get  "auth/failure",            to: "oauth_callbacks#failure"
  resource :change_password, only: [ :show, :update ]

  resource :settings, only: :show do
    patch :update_profile
    patch :update_password
    patch :toggle_tailscale
    patch :update_smb_password
    patch :update_custom_links
    patch :update_ssh_keys
    patch :update_persisted_paths
    patch :update_injected_files
    delete "injected_files/:id", action: :delete_injected_file, as: :delete_injected_file
    post :generate_token
    delete "revoke_token/:id", action: :revoke_token, as: :revoke_token
  end

  get  "auth/device",              to: "device_auth#show",     as: :auth_device
  post "auth/device/verify",       to: "device_auth#verify",   as: :auth_device_verify
  get  "auth/device/approve/:id",  to: "device_auth#confirm",  as: :auth_device_confirm
  post "auth/device/approve",      to: "device_auth#approve",  as: :auth_device_approve

  resources :sandboxes, only: [ :new, :create, :show, :destroy, :update ] do
    collection do
      delete :purge_all
    end
    member do
      post :start
      post :stop
      post :rebuild
      post :retry
      post :archive_restore
      delete :purge
      get :logs
      get :stats, controller: "dashboard", action: "stats"
      get :metrics
      get :card, controller: "dashboard", action: "card"
      post :terminal, controller: "terminal", action: "open"
      delete :terminal, controller: "terminal", action: "close"
      post :vnc, controller: "vnc", action: "open"
      delete :vnc, controller: "vnc", action: "close"
      post :snapshot, controller: "snapshots", action: "create_for_sandbox"
      get :discover_files
      post :promote_file
    end
    resources :routes, only: [ :create, :destroy ]
  end
  resources :projects, only: [ :new, :create, :edit, :update, :destroy ]

  resources :snapshots, only: [ :index, :destroy ], param: :name do
    member do
      post :clone
    end
  end

  get "terminals/:id/:type", to: "terminal#show", as: :terminal_show, constraints: { type: /tmux|shell/ }
  get "terminal/auth", to: "terminal#auth"
  get "vnc/auth", to: "vnc#auth"

  resource :tailscale, only: [], controller: "tailscale" do
    get :show
    post :login
    get :login_status
    get :connected
    patch :update_settings
    delete :disable
  end

  namespace :admin do
    get "/", to: "dashboard#index", as: :dashboard
    get "system_status", to: "dashboard#system_status"
    get "update_status", to: "dashboard#update_status"
    resource :update, only: [], controller: "update" do
      get  :check
      post :pull
      get  :status
      post :restart
      get  :progress
    end
    resource :settings, only: [ :edit, :update ]
    resources :users
    resources :invites, only: [ :index, :create, :destroy ]
    resources :sandboxes, only: :destroy do
      member do
        post :start
        post :stop
        post :rebuild
        get :stats
        post :archive_restore
        delete :purge
      end
    end

    resources :docker, only: :index, controller: "docker" do
      get :logs, on: :member
    end

    # Job monitoring dashboard
    mount MissionControl::Jobs::Engine, at: "/jobs"

    # Error tracking dashboard
    mount SolidErrors::Engine, at: "/errors"
  end

  namespace :api do
    get "archived_sandboxes", to: "sandboxes#archived_index"
    resources :projects, only: [ :index, :show, :create, :destroy ]
    resources :sandboxes do
      member do
        post :start
        post :stop
        post :rebuild
        get :logs
        post :connect
        post :snapshot
        post :restore
        post :archive_restore
        delete :purge
        post :tailscale_connect
        delete :tailscale_disconnect
        post "services/:service/start", action: :service_start, as: :service_start
        post "services/:service/stop", action: :service_stop, as: :service_stop
      end
      resources :routes, only: [ :index, :create, :destroy ]
    end
    resources :snapshots, only: [ :index, :create, :show, :destroy ], param: :name
    resources :users
    resource :status, only: :show, controller: "status"
    resource :info, only: :show
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
    resource :smb, only: [], controller: "smb" do
      patch :set_password
    end
  end

  get "guide", to: "pages#guide"

  get "up" => "rails/health#show", as: :rails_health_check
end
