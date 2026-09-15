Rails.application.routes.draw do
  resources :wakas
  resources :rengas, only: [:new, :create, :show] do        # ← この行を追加
    member do
      post :confirm
      patch :manual_tsugeku
    end
  end
  get "hyakuin/:id", to: "hyakuins#show", as: :hyakuin
  get "hyakuin/:id/vertical", to: "hyakuins#vertical", as: :vertical_hyakuin

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # Defines the root path route ("/")
  root "rengas#new"
end
