ElectionMap::Application.routes.draw do

  devise_for :users

  root :to => "root#index"

  match '/export', :to => 'root#export', :as => :export, :via => :post, :defaults => {:format => 'svg'}
  match '/routing_error', :to => 'root#routing_error'
  match "/:locale" => "root#index", via: :get, :as => :root
  match '/:locale/admin', :to => 'root#admin', :as => :admin, :via => :get
  match '/:locale/shape/:id', :to => 'root#shape', :as => :shape, :via => :get, :defaults => {:format => 'json'}
  match '/:locale/children_shapes/:parent_id', :to => 'root#children_shapes', :as => :children_shapes, :via => :get, :defaults => {:format => 'json'}

  scope "/:locale" do
    resources :locales
  end

  scope "/:locale" do
    resources :data do
			collection do
        get :upload
        post :upload
        get :export
			end
		end
  end

  scope "/:locale" do
    resources :indicator_scales do
  		collection do
        get :upload
        post :upload
        get :export
  		end
    end
  end
  
  scope "/:locale" do
    resources :indicators do
			collection do
        get :upload
        post :upload
        get :export
			end
		end
  end
  
  scope "/:locale" do
    resources :events
  end
  
  scope "/:locale" do
    resources :event_types
  end
  
  scope "/:locale" do
    resources :shapes do
			collection do
        get :upload
        post :upload
        get :export
			end
		end
  end
  
  scope "/:locale" do
    resources :shape_types
  end

	# Catch unroutable paths and send to the routing error handler
	match '*a', :to => 'root#routing_error'

end
