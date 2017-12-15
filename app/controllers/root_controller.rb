# encoding: utf-8
class RootController < ApplicationController
	require 'ostruct'
  require 'data_archive'
	require 'fileutils'


	FILE_CACHE_KEY_MAP_IMAGE =
		"event_[event_id]/data_set_[data_set_id]/map_images/shape_[parent_id]"

  # GET /
  # GET /.json
	def index

	  @elections = Event.public_official_elections(6, [51,52,53,55,56,57])
	  @voters_lists = Event.public_official_voters_lists(4)
	  @news = News.with_translations(I18n.locale).recent.limit(2) if @show_news
    gon.landing_page = true

    @summary_data = []

    @elections.each do |election|
      h = Hash.new
      h[:election] = election
      @summary_data << h

      dataset = DataSet.current_dataset(election.id, Datum::DATA_TYPE[:official])

      if dataset.present?
        summary_item = Datum.get_table_data_summary(election.id, dataset.first.id, 1,
          election.shape_id, 2, Datum::DATA_TYPE[:official])
      end

      if summary_item.present?
        h[:summary_item] = summary_item

        # get path to map images if exist
        key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', election.id.to_s)
                .gsub('[data_set_id]', dataset.first.id.to_s)
                .gsub('[parent_id]', election.shape_id.to_s)

        h[:parent_summary_img] = JsonCache.get_image_path(key, 'png')
        h[:parent_summary_img_json] = JsonCache.read_data(key)
        h[:parent_summary_img_json] = JSON.parse(h[:parent_summary_img_json]) if h[:parent_summary_img_json].present?
      end
    end

    @summary_lists = []

    @voters_lists.each do |list|
      h = Hash.new
      h[:list] = list
      @summary_lists << h

      dataset = DataSet.current_dataset(list.id, Datum::DATA_TYPE[:official])

      if dataset.present?
        summary_item = Datum.build_summary_voter_list_data_json(list.shape_id, 1, list.id, dataset.first.id)
      end

      if summary_item.present?
        h[:summary_item] = summary_item

        # get path to map images if exist
        key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', list.id.to_s)
                .gsub('[data_set_id]', dataset.first.id.to_s)
                .gsub('[parent_id]', list.shape_id.to_s)

        h[:parent_summary_img] = JsonCache.get_image_path(key, 'png')
        h[:parent_summary_img_json] = JsonCache.read_data(key)
        h[:parent_summary_img_json] = JSON.parse(h[:parent_summary_img_json]) if h[:parent_summary_img_json].present?
      end
    end

    # add live elections if exist
    @summary_live = []
    if @live_event_menu.present?
      gon.landing_live_election_ids = []
      gon.landing_live_dataset_ids = []
      @live_event_menu.each do |live|
        election = Event.find_by_id(live["id"])

        if election.present?
          h = Hash.new
          h[:election] = election
          @summary_live << h

          gon.landing_live_election = true
          gon.landing_live_election_data_type = Datum::DATA_TYPE[:live]
          gon.landing_live_election_ids << election.id

          # add live event info
          h[:data_available_at] = live['data_available_at']
          h[:data_available_at_est] = live['data_available_at'].in_time_zone('Eastern Time (US & Canada)')

          dataset = DataSet.current_dataset(election.id, Datum::DATA_TYPE[:live])

          if dataset.present?
            gon.landing_live_dataset_ids << dataset.first.id
            h[:precincts_completed] = dataset.first.precincts_completed
            h[:precincts_total] = dataset.first.precincts_total
            h[:precincts_percentage] = dataset.first.precincts_percentage
            h[:last_updated] = dataset.first.timestamp

            # if the election has the precincts reported indicator, get the data
						precincts_reporting = Datum.get_precincts_reported(election.shape_id, election.id, dataset.first.id)
						if precincts_reporting.present?
					    h[:precincts_completed] = precincts_reporting[:completed_number]
              h[:precincts_total] = precincts_reporting[:num_precincts]
              h[:precincts_percentage] = precincts_reporting[:completed_percent]
            end

            summary_item = Datum.get_table_data_summary(election.id, dataset.first.id, 1,
              election.shape_id, 2, Datum::DATA_TYPE[:official])
          else
            gon.landing_live_dataset_ids << 0
          end

          if summary_item.present?
            h[:summary_item] = summary_item

            # get path to map images if exist
            key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', election.id.to_s)
                    .gsub('[data_set_id]', dataset.first.id.to_s)
                    .gsub('[parent_id]', election.shape_id.to_s)

            h[:parent_summary_img] = JsonCache.get_image_path(key, 'png')
            h[:parent_summary_img_json] = JsonCache.read_data(key)
            h[:parent_summary_img_json] = JSON.parse(h[:parent_summary_img_json]) if h[:parent_summary_img_json].present?
          end
        end
      end
    end

    respond_to do |format|
      format.html
    end
  end




	def map
		# set flag indicating that a param is missing or data could not be found
		# which will cause user to go back to home page
		flag_redirect = false

		# get the event type id
    if params[:event_type_id].nil? && @event_types.empty?
logger.debug "////////////// event type id does not exist and no event types with public events exist"
# TODO - what to do?
    end
logger.debug "////////////// getting event type id"
		if params[:event_type_id].nil?
			set_default_event_params
			# if no default event exists, just resort to first event type in list
			params[:event_type_id] = @event_types.first.id.to_s if params[:event_type_id].nil?
		end

		# get the current event
logger.debug "////////////// getting current event for event type #{params[:event_type_id]}"
		event = get_current_event(params[:event_type_id], params[:data_type], params[:event_id])

		if event.nil? || event.shape_id.nil?
			# event could not be found or the selected event does not have a shape assigned to it
			logger.debug "+++++++++ event could not be found or the selected event does not have a shape assigned to it"

			# if this is a live event, mark flag to show user message that data does not exist yet and to come back
      live_event = @live_event_menu.select{|x| x["id"].to_s == params["event_id"].to_s}
			if params[:data_type] == Datum::DATA_TYPE[:live] && live_event.present?
			  logger.debug "+++++++++ this is live event but no data has been loaded yet"
        @live_event_with_no_data = true
        @live_event_name = live_event.first["name"]
        @live_event_date = live_event.first["date"]
        @live_event_data_available = live_event.first["data_available_at"]
        @live_event_data_available_est = live_event.first["data_available_at"].in_time_zone('Eastern Time (US & Canada)')
        @page_title = "#{@live_event_name} - #{l(@live_event_data_available, :format => :default_no_tz)}".html_safe
        gon.live_event_with_no_data = true
        gon.live_event_time_to_data = countdown_duration(Time.now, live_event.first["data_available_at"])
      else
			  flag_redirect = true
      end
		else
			# save the event name
			@event_name = event.name
			@event_description = event.description

      # is event a voters list
      @is_voters_list = event.is_voter_list?
      gon.is_voters_list = @is_voters_list

      # save event custom shape nav
      @event_custom_shape_nav = event.custom_shape_navigations

  		# get data set info
			dataset = DataSet.find_by_id(params[:data_set_id]) if params[:data_set_id].present?

			# get the most recent dataset for this event
      most_recent_dataset = DataSet.current_dataset(event.id, params[:data_type])
			@most_recent_dataset = most_recent_dataset.first if most_recent_dataset
      if @most_recent_dataset.present? && dataset.present? && @most_recent_dataset.id != dataset.id && params[:data_type] == Datum::DATA_TYPE[:official] && params[:preview_data_set] != 'true'
        # the passed in official data set is not the most recent,
        # redirect to the most recent data set
        redirect_to indicator_map_path(:event_id => params[:event_id], :event_type_id => params[:event_type_id]),
          :notice => I18n.t('app.msgs.newer_data')
        return
      elsif dataset.blank?
  			dataset = @most_recent_dataset
      end

      if dataset
        params[:data_set_id] = dataset.id.to_s
		    @live_event_precincts_percentage = dataset.precincts_percentage
		    @live_event_precincts_completed = dataset.precincts_completed
		    @live_event_precincts_total = dataset.precincts_total
		    @live_event_timestamp = dataset.timestamp

				# if the most_recent_datset > passed in dataset,
				# tell user that newer data is available
				@newer_data_available = @most_recent_dataset.id > dataset.id ? true : false if @most_recent_dataset
		  else
  			# dataset could not be found for event
  			logger.debug "+++++++++ an public data set could not be found for event"
  			flag_redirect = true
	    end

      if !flag_redirect
  			# get the shape
  logger.debug "////////////// getting shape"
  			params[:shape_id] = event.shape_id if params[:shape_id].nil?
  			logger.debug("+++++++++shape id = #{params[:shape_id]}")
  			@shape = Shape.get_shape_no_geometry(params[:shape_id])

  			if @shape.nil?
  				# parent shape could not be found
  				logger.debug "+++++++++ parent shape could not be found"
  				flag_redirect = true
  			else
  				# get the shape type id that was clicked
  				params[:shape_type_id] = @shape.shape_type_id if params[:shape_type_id].nil?

  				# now get the child shape type id
  logger.debug "////////////// getting parent shape type"
  				parent_shape_type = get_shape_type(params[:shape_type_id])
  logger.debug "////////////// parent shape type = #{parent_shape_type}"

  				@child_shape_type_id = nil

  				if parent_shape_type.nil?
  					logger.debug("+++++++++ parent shape type could not be found")
  					flag_redirect = true
  				else
  logger.debug "////////////// getting event custom view"
  					# if the event has a custom view for the parent shape type, use it
  					custom_view = event.event_custom_views.where(:shape_type_id => parent_shape_type.id).with_translations(I18n.locale)
  					@is_custom_view = false
  					@has_custom_view = false
  					if !custom_view.nil? && !custom_view.empty? && (params[:parent_shape_clickable].nil? || params[:parent_shape_clickable].to_s != "true")
  logger.debug "////////////// has custom view"
  						@has_custom_view = true
  						# set the param if not set yet
  						params[:custom_view] = custom_view.first.is_default_view.to_s if params[:custom_view].nil?

  						if params[:custom_view] == "true"
  							logger.debug("+++++++++ parent shape type has custom view of seeing shape_type #{custom_view.first.descendant_shape_type_id} ")
  							#found custom view, use it to get the child shape type
  							child_shape_type = custom_view.first.descendant_shape_type
  							custom_child_shape_type = get_child_shape_type(@shape)
  							# indicate custom view is being used
  							@is_custom_view = true
  							# save the note for this custom view
  							@custom_view_note = custom_view.first.note
  						else
  							logger.debug("+++++++++ parent shape type has custom view, but not using it")
  							child_shape_type = get_child_shape_type(@shape)
  							custom_child_shape_type = custom_view.first.descendant_shape_type
  						end
  					elsif parent_shape_type.is_root? && !params[:parent_shape_clickable].nil? && params[:parent_shape_clickable].to_s == "true"
  			      # if the parent shape is the root and the parent_shape_clickable is set to true,
  			      # make the parent shape also be the child shape
  logger.debug "////////////// child shape type = parent"
  						logger.debug("+++++++++ parent shape type is root and it should be clickable")
  						child_shape_type = parent_shape_type.clone
  					elsif parent_shape_type.has_children?
  logger.debug "////////////// getting child shape type"
  						logger.debug("+++++++++ parent shape type is not root or it should not be clickable")
  						# this is not the root, so reset parent shape clickable
              # - NOTE - had to change the following to false instead of nil so that the helper paths
              #          will be properly created due to changes in rails 3.2 from 3.1
  						params[:parent_shape_clickable] = "false"#nil
  #						child_shape_type = get_child_shape_type(params[:shape_type_id])
  						child_shape_type = get_child_shape_type(@shape)
  					else
  						logger.debug("+++++++++ parent shape type is not root and parent shape type does not have children")
  						flag_redirect = true
  					end

  					if !flag_redirect
  logger.debug "////////////// setting @ variables"
              @parent_shape_type = parent_shape_type.id
  						@parent_shape_type_name_singular = parent_shape_type.name_singular
  						@child_shape_type_id = child_shape_type.id
  						@child_shape_type_name_singular_possessive = child_shape_type.name_singular_possessive
  						@child_shape_type_name_plural = child_shape_type.name_plural
  						if @has_custom_view
  							@custom_child_shape_type_name_singular = custom_child_shape_type.name_singular
  							if I18n.locale == :ka
  								@custom_child_shape_type_name_plural = custom_child_shape_type.name_singular
  							else
  								@custom_child_shape_type_name_plural = custom_child_shape_type.name_plural
  							end
  						end
  						@map_title = nil
  						@data_table_ind_order_explanation = nil
  						# set the map title
  						if parent_shape_type.id == child_shape_type.id
  							@map_title = @parent_shape_type_name_singular + ": " + @shape.common_name
    						@data_table_ind_order_explanation = @parent_shape_type_name_singular + ": " + @shape.common_name
  						else
  							@map_title = @parent_shape_type_name_singular + ": " + @shape.common_name + " - " + @child_shape_type_name_plural
    						@data_table_ind_order_explanation = @parent_shape_type_name_singular + ": " + @shape.common_name
  						end
							# if this is live data, add the precincts reported numbers
							if params[:data_type] == Datum::DATA_TYPE[:live]
								precincts_reporting = Datum.get_precincts_reported(params[:shape_id], params[:event_id], params[:data_set_id])
								if precincts_reporting.present?
									if @show_precinct_percentages
										@map_title_precincts = I18n.t('app.common.live_event_status',
																		:completed => precincts_reporting[:completed_number],
			                              :total => precincts_reporting[:num_precincts],
			                              :percentage => precincts_reporting[:completed_percent])
									else
										@map_title_precincts = I18n.t('app.common.live_event_status_no_percent',
																		:completed => precincts_reporting[:completed_number])
									end
								end
							end
  logger.debug "////////////// done setting @ variables"
  					end

  				end

  				if @child_shape_type_id.nil? || flag_redirect
  					logger.debug("+++++++++ child shape type could not be found")
  					flag_redirect = true
  				else
  logger.debug "////////////// getting indicators"
  					# get the indicators for the children shape_type
#  					@indicator_types = IndicatorType.find_by_event_shape_type(params[:event_id], @child_shape_type_id)
  					@indicator_types = IndicatorType.with_summary_rank(params[:shape_id], @child_shape_type_id, params[:event_id], params[:data_set_id], @parent_shape_type)

  					if @indicator_types.blank?
  						# no indicators exist for this event and shape type
  						logger.debug "+++++++++ no indicators exist for this event and shape type"
  						flag_redirect = true
  					else
  						# if an indicator is not selected, select the first one in the list
  						# if the first indicator type has a summary, select the summary
  						if params[:indicator_id].nil? && params[:view_type].nil?
  logger.debug "////////////// selecting first indicator"
								x = get_current_indicator(event, @indicator_types)
								if x[:error]
  								logger.debug "+++++++++ cound not find an indicator to set as the value for params[:indicator_id]"
									flag_redirect = true
								elsif x[:view_type] == @summary_view_type_name
logger.debug "////////////// - default is summary"
									# first indicator is summary
									params[:view_type] = x[:view_type]
									params[:indicator_type_id] = x[:indicator_type_id]
								elsif x[:indicator_id]
logger.debug "////////////// - default is indicator, getting record"
									params[:indicator_type_id] = x[:indicator_type_id]
									params[:indicator_id] = x[:indicator_id]
								else
logger.debug "////////////// - no default found"
  								logger.debug "+++++++++ cound not find an indicator to set as the value for params[:indicator_id]"
									flag_redirect = true
								end

=begin
  							if @indicator_types[0].has_summary
  								params[:view_type] = @summary_view_type_name
  								params[:indicator_type_id] = @indicator_types[0].id
  							elsif @indicator_types[0].core_indicators.nil? || @indicator_types[0].core_indicators.empty? ||
  										@indicator_types[0].core_indicators[0].indicators.nil? ||
  										@indicator_types[0].core_indicators[0].indicators.empty?
  								# could not find an indicator
  								logger.debug "+++++++++ cound not find an indicator to set as the value for params[:indicator_id]"
  								flag_redirect = true
  							else
  								params[:indicator_id] = @indicator_types[0].core_indicators[0].indicators[0].id
  								params[:indicator_type_id] = @indicator_types[0].id
  							end
=end
  						end
  						# get the indicator
  						# if the shape type changed, update the indicator_id to be valid for the new shape_type
  						# only if this is not the summary view
  	          if params[:view_type] != @summary_view_type_name
  logger.debug "////////////// getting the current indicator"
  							if !params[:change_shape_type].nil? && params[:change_shape_type] == "true"
  logger.debug "////////////// this is shape change - getting indicator at new shape level"
  								# we know the old indicator id and the new shape type
  								# - use that to find the new indicator id
  								new_indicator = Indicator.find_new_id(params[:indicator_id], @child_shape_type_id)
  								if new_indicator.nil?
  logger.debug "////////////// - could not find new indicator, looking for default"
										# could not find matching indicator at new level
										# - so now use first indicator in list
										x = get_current_indicator(event, @indicator_types)
										if x[:error]
											logger.debug "+++++++++ cound not find matching indicator at new shape level and could not find default indicator"
											flag_redirect = true
										elsif x[:view_type] == @summary_view_type_name
  logger.debug "////////////// - default is summary"
											# first indicator is summary
											params[:view_type] = x[:view_type]
											params[:indicator_type_id] = x[:indicator_type_id]
											no_match_indicator_using_summary = true
										elsif x[:indicator_id]
  logger.debug "////////////// - default is indicator, getting record"
											params[:indicator_type_id] = x[:indicator_type_id]
											params[:indicator_id] = x[:indicator_id]
		  								@indicator = Indicator.find(params[:indicator_id])
										else
  logger.debug "////////////// - no default found"
											# could not find a match, reset the indicator id
											params[:indicator_id] = nil
										end
  								else
  logger.debug "////////////// - found new indicator, saving"
  									# save the new value
  									params[:indicator_id] = new_indicator.id.to_s
  									@indicator = new_indicator
  								end
  							else
  logger.debug "////////////// - getting indicator using id passed in"
  								# get the selected indicator
  								@indicator = Indicator.find_by_id(params[:indicator_id])
  logger.debug "////////////// -- indicator = #{@indicator.inspect}"
  							end
  							if @indicator.present?
    							# save the indicator type id so the indicator menu works
    							params[:indicator_type_id] = @indicator.core_indicator.indicator_type_id if params[:indicator_type_id].nil?
							  elsif !no_match_indicator_using_summary
  								# could not find an indicator
  								logger.debug "+++++++++ cound not find the desired indicator"
  								flag_redirect = true
						    end
  logger.debug "////////////// done getting current indicator"
  						end

  						# if have custom view, get indicator if user wants to switch between custom view and non-custom view
  						if !flag_redirect && @has_custom_view
  logger.debug "////////////// is custom view, getting indicator to switch between views"
  							@custom_indicator_id = nil

  							custom_indicator = Indicator.find_new_id(params[:indicator_id], custom_child_shape_type.id)
  							if !custom_indicator.nil?
  								@custom_indicator_id = custom_indicator.id.to_s
  							end
  						end
  					end
  				end
  			end

      end
		end

    # create the page title
    if @map_title && @event_name
      if params[:view_type] == @summary_view_type_name && @indicator_types && !@indicator_types.empty?
        @page_title = "#{@event_name} » #{@indicator_types[0].summary_name} » #{@map_title}".html_safe
      elsif @indicator
        @page_title = "#{@event_name} » #{@indicator.name_abbrv_w_parent} » #{@map_title}".html_safe
      end
    end

		# reset the parameter that indicates if the shape type changed
		params[:change_shape_type] = nil

    # get the summary data
    if !flag_redirect && !@live_event_with_no_data
      # if this is voters list and is showing the default ind id,
      # make sure the map image will be generated
      if @is_voters_list && event.default_core_indicator_id.present? && @indicator.present? &&
            event.default_core_indicator_id == @indicator.core_indicator_id

        gon.is_voters_list_using_default_core_ind_id = true
      end

      if @indicator_types.index{|x| x.has_summary}.present?
        # get the ind type id that has summary
        ind_type_id = @indicator_types.select{|x| x.has_summary}.first.id

        # get parent shape data
        @parent_summary_data = Datum.get_table_data_summary(params[:event_id], params[:data_set_id], @parent_shape_type,
          params[:shape_id], ind_type_id, params[:data_type])

        if @parent_summary_data.present?
          # if the event is live, get precincts reported
				  if params[:data_type] == Datum::DATA_TYPE[:live]
			      @parent_precincts_reporting = Datum.get_precincts_reported(params[:shape_id], params[:event_id], params[:data_set_id])
          end

          # get path to map images if exist
          key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', params[:event_id].to_s)
                  .gsub('[data_set_id]', params[:data_set_id].to_s)
                  .gsub('[parent_id]', params[:shape_id].to_s)

          @parent_summary_img = JsonCache.get_image_path(key, 'png')
          @parent_summary_img_json = JsonCache.read_data(key)
          @parent_summary_img_json = JSON.parse(@parent_summary_img_json) if @parent_summary_img_json.present?

          # if this is not the default event shape, get the default event shape data too
          if event.shape_id.to_s != params[:shape_id].to_s
            root_shape = Shape.select('shape_type_id').find_by_id(event.shape_id)
            if root_shape.present?
              @root_summary_data = Datum.get_table_data_summary(params[:event_id], params[:data_set_id], root_shape.shape_type_id,
                event.shape_id, ind_type_id, params[:data_type])
              if @root_summary_data.present?
                # if the event is live, get precincts reported
				        if params[:data_type] == Datum::DATA_TYPE[:live]
			            @root_precincts_reporting = Datum.get_precincts_reported(event.shape_id, params[:event_id], params[:data_set_id])
                end

                key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', params[:event_id].to_s)
                        .gsub('[data_set_id]', params[:data_set_id].to_s)
                        .gsub('[parent_id]', event.shape_id.to_s)

                @root_summary_img = JsonCache.get_image_path(key, 'png')
                @root_summary_img_json = JsonCache.read_data(key)
                @root_summary_img_json = JSON.parse(@root_summary_img_json) if @root_summary_img_json.present?
              end
            end
          end
        end
      elsif @is_voters_list
        # this is a voters list, so get voter list summary data
        # get parent shape data
        @parent_summary_data = Datum.build_summary_voter_list_data_json(params[:shape_id], @parent_shape_type,
          params[:event_id], params[:data_set_id])

        if @parent_summary_data.present?
          # get path to map images if exist
          key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', params[:event_id].to_s)
                  .gsub('[data_set_id]', params[:data_set_id].to_s)
                  .gsub('[parent_id]', params[:shape_id].to_s)

          @parent_summary_img = JsonCache.get_image_path(key, 'png')
          @parent_summary_img_json = JsonCache.read_data(key)
          @parent_summary_img_json = JSON.parse(@parent_summary_img_json) if @parent_summary_img_json.present?

          # if this is not the default event shape, get the default event shape data too
          if event.shape_id.to_s != params[:shape_id].to_s
            root_shape = Shape.select('shape_type_id').find_by_id(event.shape_id)
            if root_shape.present?
              @root_summary_data = Datum.build_summary_voter_list_data_json(event.shape_id, root_shape.shape_type_id,
                                    params[:event_id], params[:data_set_id])
              if @root_summary_data.present?
                key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', params[:event_id].to_s)
                        .gsub('[data_set_id]', params[:data_set_id].to_s)
                        .gsub('[parent_id]', event.shape_id.to_s)

                @root_summary_img = JsonCache.get_image_path(key, 'png')
                @root_summary_img_json = JsonCache.read_data(key)
                @root_summary_img_json = JSON.parse(@root_summary_img_json) if @root_summary_img_json.present?
              end
            end
          end
        end

      end
    end

		# set js variables
logger.debug "////////////// setting gon variables"
    set_gon_variables if !flag_redirect && !@live_event_with_no_data



logger.debug "//////////////////////////////////////////////////////// done with index action"

    if flag_redirect
			# either data could not be found or param is missing and page could not be loaded
			logger.debug "+++++++++ either data could not be found or param is missing and page could not be loaded, redirecting to home page"
			if (params[:event_id].present? && params[:event_type_id].present?)
  			redirect_to indicator_map_path(:event_id => params[:event_id], :event_type_id => params[:event_type_id])
			else
			  redirect_to root_path
			end
    else
      respond_to do |format|
        format.html
      end
		end
	end

  # get the detailed and summary (if needed) table data
  def data_table
    params[:custom_view] = params[:custom_view].blank? ? false : params[:custom_view]

		# if data type is live, the dataset must also be provided
		params_ok = true
		if params[:data_type] == Datum::DATA_TYPE[:live] && params[:data_set_id].blank?
			params_ok = false
		end

		if params_ok
		  # get summary data
			@summary_data = nil
      if params[:indicator_type_id].present?
        @summary_data = Datum.get_table_data_summary(params[:event_id],
          params[:data_set_id],
          params[:child_shape_type_id],
          params[:shape_id],
          params[:indicator_type_id],
          params[:data_type])
      end

			# get the detailed data
		  get_data = Datum.get_table_data(params[:event_id], params[:data_set_id], params[:child_shape_type_id], params[:shape_id], params[:shape_type_id])

			if get_data.present? && get_data['data'].present? && get_data['indicator_types'].present?
        cols_skip = 3
        cols_static = 1

        @default_cols_show = 5
        @table_data = get_data['data']
        @indicator_types = get_data['indicator_types']
        @table_selected_id = ''
        # the data contains the election name, common name, common id in first 3 cols
        # and we don't need - so skip
				@table_data.each_with_index do |val, i|
				  @table_data[i] = @table_data[i][cols_skip..- 1]
				end

				# selected indicator id
				if params[:indicator_id].blank? || params[:indicator_id] == 'null'
				  if params[:view_type] == params[:summary_view_type_name]
				    @table_selected_id = params[:indicator_type_id].present? ? "ind_type_#{params[:indicator_type_id]}" : 'winner_ind'
				  end
				else
				  @table_selected_id = params[:indicator_id].to_s
				end
      end
    end

    render :layout => 'ajax_data_table'
  end


  # POST /export
	# generate the svg file
  def export
		# create the file name: map title - indicator - event
		filename = params[:hidden_form_map_title].clone()
		filename << "-"
		filename << params[:hidden_form_indicator_name_abbrv]
		filename << "-"
		filename << params[:hidden_form_event_name]
		filename << "-#{l Time.now, :format => :file}"

		headers['Content-Type'] = "image/svg+xml; charset=utf-8"
    headers['Content-Disposition'] = "attachment; filename=#{clean_filename(filename)}.svg"
  end

  # GET /download
  # GET /download.json
  def download
    sent_data = false
		if params[:event_id].present? && params[:data_set_id].present? && params[:shape_type_id].present? &&
		      params[:child_shape_type_id].present? && params[:shape_id].present?

      #get the data
		  get_data = Datum.get_table_data(params[:event_id], params[:data_set_id], params[:child_shape_type_id], params[:shape_id], params[:shape_type_id])

			if get_data.present? && get_data['data'].present?
				# create file name using event name and map title that were passed in
		    filename = params[:map_title]
				filename << "-"
				filename << params[:event_name]
				filename << "-#{l Time.now, :format => :file}"

		    # send the file
				respond_to do |format|
				  format.csv {
logger.debug ">>>>>>>>>>>>>>>> format = csv"
   					spreadsheet = DataArchive.create_csv_formatted_string(get_data['data'])
            send_data spreadsheet,
				      :type => 'text/csv; header=present',
				      :disposition => "attachment; filename=#{clean_filename(filename)}.csv"

					  sent_data = true
					}

				  format.xls{
logger.debug ">>>>>>>>>>>>>>>> format = xls"
						spreadsheet = DataArchive.create_excel_formatted_string(get_data['data'])
						send_data spreadsheet,
				    :disposition => "attachment; filename=#{clean_filename(filename)}.xls"
					  sent_data = true
					}
				end
			end
		end

		# if get here, then an error occurred
		if request.env["HTTP_REFERER"] && !sent_data
			redirect_to :back, :notice => t("app.msgs.no_data_download")
		elsif !sent_data
			redirect_to root_path, :notice => t("app.msgs.no_data_download")
		end

  end

	# any mis-match routing errors are directed here
	def routing_error
		render_not_found(nil)
	end

  # save the png images rendered from the map svg
  def save_map_images
    if request.xhr? && params[:img].present? && params[:event_id].present? && params[:data_set_id].present? && params[:parent_shape_id].present?

      key = FILE_CACHE_KEY_MAP_IMAGE.gsub('[event_id]', params[:event_id])
              .gsub('[data_set_id]', params[:data_set_id])
              .gsub('[parent_id]', params[:parent_shape_id])

      JsonCache.write_image(key, 'png'){
        params[:img]
      }

      # create json file that contains properties for width, height and left positioning
      file_path_json = "#{key.gsub('[type]', 'json')}"
      JsonCache.write_data(file_path_json) {
        h = Hash.new
        h[:width] = params[:img_width]
        h[:height] = params[:img_height]
        h.to_json
      }

    end
    render nothing: true
  end


#########################################################
#########################################################
#########################################################
#########################################################
private
	# get the default event to show when the site loads
	def set_default_event_params
		events = @event_types.map{|x| x.events.select{|y| y.is_default_view?}}.flatten
		params[:data_type] = Datum::DATA_TYPE[:official] # default value
		if events && !events.empty?
			params[:event_type_id] = events.first.event_type_id.to_s
			params[:event_id] = events.first.id.to_s
			# if have live data and not official -> set to live
			# else -> set to official
			if !events.first.has_official_data? && events.first.has_live_data?
				params[:data_type] = Datum::DATA_TYPE[:live]
			end
		end
	end

	# get the the current event
	def get_current_event(event_type_id, data_type, event_id=nil)
	  if event_type_id && data_type
	    event_type = @event_types.select{|x| x.id.to_s == event_type_id.to_s}
	    if event_type.present? && event_type.first.events.present?
	      if event_id
          # find the event that matches the passed in id
	        event = event_type.first.events.select{|x| x.id.to_s == event_id.to_s}
	        if event.present?
            logger.debug "////////////// get_current_event - found event: #{event}"
	          # check if have correct data type
	          return event.first if (event.first.has_official_data && data_type == Datum::DATA_TYPE[:official]) ||
	                                (event.first.has_live_data && data_type == Datum::DATA_TYPE[:live]) ||
                                  params[:preview_data_set] == 'true'
          end
        else
          # no id provided, so get first one with correct data type
          event_type.first.events.each do |event|
            if event.shape_id && (event.has_official_data && data_type == Datum::DATA_TYPE[:official]) ||
	                                (event.has_live_data && data_type == Datum::DATA_TYPE[:live])
            	# - save event_id
              params[:event_id] = event.id
              return event
            end
          end
        end
      else
        logger.debug "////////////// get_current_event - event type not found or not have events"
      end
    end
		# if get to here then no matching event was found
logger.debug " - no matching event found!"
		return nil
	end

	# get the shape type
	def get_shape_type(shape_type_id)
		if @shape_types.blank? || shape_type_id.blank?
      return nil
    else
			@shape_types.each do |type|
				if type.id.to_s == shape_type_id.to_s
					# found match, return child
				  return type
				end
			end
		end
		logger.debug " - no matching shape type found!"
		return nil
	end

	# get the child shape type of the current shape
	def get_child_shape_type(shape)
		if shape.nil?
      return nil
    else
      if shape.has_children?
        # shape has children, get the shape type of children
        return shape.children.first.shape_type
      else
        return nil
      end
		end
	end

	# get current indicator
	# returns:
	# {error, indicator_id, indicator_type_id, view_type}
	def get_current_indicator(event, indicator_types)
		hash = Hash.new()
		hash[:error] = false
		hash[:indicator_id] = nil
		hash[:indicator_type_id] = nil
		hash[:view_type] = nil

    if event.default_core_indicator_id.present?
      ind = indicator_types.map{|x| x.core_indicators.select{|y| y.id == event.default_core_indicator_id}}
      if ind.present? && ind.flatten!.present?
				hash[:indicator_id] = ind.first.indicators[0].id
				hash[:indicator_type_id] = ind.first.indicator_type_id
      end
		elsif indicator_types && !indicator_types.empty?
			if indicator_types[0].has_summary
				hash[:view_type] = @summary_view_type_name
				hash[:indicator_type_id] = indicator_types[0].id
			elsif indicator_types[0].core_indicators.nil? || indicator_types[0].core_indicators.empty? ||
						indicator_types[0].core_indicators[0].indicators.nil? ||
						indicator_types[0].core_indicators[0].indicators.empty?
				# could not find an indicator
				logger.debug "+++++++++ cound not find an indicator to set as the value for params[:indicator_id]"
				hash[:error] = true
			else
				hash[:indicator_id] = indicator_types[0].core_indicators[0].indicators[0].id
				hash[:indicator_type_id] = indicator_types[0].id
			end
		end
		return hash
	end

  def set_gon_variables
    # shape json paths
		# - only children shape path needs the indicator id since that is the only layer that is clickable
		if !params[:shape_id].nil?
			gon.shape_path = json_shape_path(:id => params[:shape_id], :shape_type_id => @parent_shape_type)
			if params[:view_type] == @summary_view_type_name && @is_custom_view
  			gon.children_shapes_path = json_custom_children_shapes_path(:parent_id => params[:shape_id],
				  :shape_type_id => @child_shape_type_id)
				gon.data_path = json_summary_custom_children_data_path(:parent_id => params[:shape_id],
  			  :event_id => params[:event_id], :indicator_type_id => params[:indicator_type_id],
  			  :shape_type_id => @child_shape_type_id, :custom_view => @is_custom_view.to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
			elsif params[:view_type] == @summary_view_type_name
  			gon.children_shapes_path = json_children_shapes_path(:parent_id => params[:shape_id],
  			  :shape_type_id => @child_shape_type_id,
  			  :event_id => params[:event_id],
  			  :parent_shape_clickable => params[:parent_shape_clickable].to_s)
				gon.data_path = json_summary_children_data_path(:parent_id => params[:shape_id],
  			  :event_id => params[:event_id], :indicator_type_id => params[:indicator_type_id],
  			  :shape_type_id => @child_shape_type_id,
  			  :parent_shape_clickable => params[:parent_shape_clickable].to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
      elsif @is_custom_view
				gon.children_shapes_path = json_custom_children_shapes_path(:parent_id => params[:shape_id],
				  :shape_type_id => @child_shape_type_id)
				gon.data_path = json_custom_children_data_path(:parent_id => params[:shape_id],
				  :indicator_id => params[:indicator_id], :shape_type_id => @child_shape_type_id,
				  :event_id => params[:event_id], :custom_view => @is_custom_view.to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
  		else
  			gon.children_shapes_path = json_children_shapes_path(:parent_id => params[:shape_id],
  			  :shape_type_id => @child_shape_type_id,
  			  :event_id => params[:event_id],
  			  :parent_shape_clickable => params[:parent_shape_clickable].to_s)
				gon.data_path = json_children_data_path(:parent_id => params[:shape_id],
  			  :indicator_id => params[:indicator_id], :shape_type_id => @child_shape_type_id,
  			  :event_id => params[:event_id],
  			  :parent_shape_clickable => params[:parent_shape_clickable].to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
      end


      # set json paths for indicator menu ajax calls
			# - 'xxx' are placeholders that will be replaced with the id from the link the user clicks on
      if @is_custom_view
				gon.indicator_menu_data_path_summary = json_summary_custom_children_data_path(:parent_id => params[:shape_id],
  			  :event_id => params[:event_id], :indicator_type_id => 'xxx',
  			  :shape_type_id => @child_shape_type_id, :custom_view => @is_custom_view.to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
				gon.indicator_menu_data_path = json_custom_children_data_path(:parent_id => params[:shape_id],
				  :indicator_id => 'xxx', :shape_type_id => @child_shape_type_id,
				  :event_id => params[:event_id], :custom_view => @is_custom_view.to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
      else
				gon.indicator_menu_data_path_summary = json_summary_children_data_path(:parent_id => params[:shape_id],
  			  :event_id => params[:event_id], :indicator_type_id => 'xxx',
  			  :shape_type_id => @child_shape_type_id,
  			  :parent_shape_clickable => params[:parent_shape_clickable].to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
				gon.indicator_menu_data_path = json_children_data_path(:parent_id => params[:shape_id],
  			  :indicator_id => 'xxx', :shape_type_id => @child_shape_type_id,
  			  :event_id => params[:event_id],
  			  :parent_shape_clickable => params[:parent_shape_clickable].to_s,
					:data_type => params[:data_type], :data_set_id => params[:data_set_id])
      end
		end

		# view type
#		gon.view_type = params[:view_type]
		gon.summary_view_type_name = @summary_view_type_name
=begin
		# indicator name
		if !@indicator.nil?
			gon.indicator_name = @indicator.name
			gon.indicator_name_abbrv = @indicator.name_abbrv_w_parent
			gon.indicator_description = @indicator.description_w_parent
			gon.indicator_number_format = @indicator.number_format.nil? ? "" : @indicator.number_format
			gon.indicator_scale_colors = IndicatorScale.get_colors(@indicator.id)
		end
=end
		# if summary view type, set indicator_description for legend title
		if params[:view_type] == @summary_view_type_name
			gon.indicator_description = I18n.t("app.msgs.map_summary_legend_title", :shape_type => @child_shape_type_name_singular_possessive)
		end
=begin
		# indicator scales
		if !params[:indicator_id].nil? && params[:view_type] != @summary_view_type_name
			build_indicator_scale_array
		end
=end
    # save the map title for export
		if !params[:event_id].nil?
		  gon.event_id = params[:event_id]
		  gon.event_name = @event_name
		  gon.map_title = @map_title
		  gon.parent_shape_id = params[:shape_id]

			# data type
			gon.data_type = params[:data_type]
			gon.data_type_live = Datum::DATA_TYPE[:live]

			# data set id
			gon.data_set_id = params[:data_set_id]
			gon.data_set_id_most_recent = @most_recent_dataset.id if @most_recent_dataset

      # save the initial values for the jquery history state
  		if params[:view_type] == @summary_view_type_name
        gon.history_url = summary_map_url(
          :event_type_id => params[:event_type_id],
          :event_id => params[:event_id],
          :shape_type_id => params[:shape_type_id],
          :shape_id => params[:shape_id],
          :indicator_type_id => params[:indicator_type_id],
          :view_type => @summary_view_type_name,
          :custom_view => params[:custom_view]
        )
        gon.history_id = params[:indicator_type_id]
      else
        gon.history_url = indicator_map_url(
          :event_type_id => params[:event_type_id],
          :event_id => params[:event_id],
          :shape_type_id => params[:shape_type_id],
          :shape_id => params[:shape_id],
          :indicator_id => params[:indicator_id],
          :custom_view => params[:custom_view]
        )
        gon.history_id = params[:indicator_id]
      end
	  end

		# data table
    iid = (params[:indicator_id].nil? ? 'null' : params[:indicator_id])
    vt = (params[:view_type].nil? ? 'null' : params[:view_type])
    itid= (params[:indicator_type_id].nil? && params[:view_type] != @summary_view_type_name ? 'null' : params[:indicator_type_id])
		gon.data_table_path = data_table_path(:event_type_id => params[:event_type_id],
			:event_id => params[:event_id], :shape_id => params[:shape_id],
			:shape_type_id => params[:shape_type_id], :indicator_id => iid,
			:custom_view => params[:custom_view], :child_shape_type_id => @child_shape_type_id,
			:view_type => vt, :summary_view_type_name => @summary_view_type_name,
			:data_type => params[:data_type], :data_set_id => params[:data_set_id],
			:indicator_type_id => itid, :ind_order_explanation => @data_table_ind_order_explanation
		)

		gon.dt_highlight_shape = (params[:highlight_shape].nil? ? false : params[:highlight_shape])

		# indicate indicator menu/scale block should be loaded
		gon.indicator_menu_scale = true

		# load openlayers js
		gon.openlayers = true

  end

  # build an array of indicator scales that will be used in js
  def build_indicator_scale_array
    if !params[:indicator_id].nil?
      # get the scales
      scales = IndicatorScale.find_by_indicator_id(params[:indicator_id])
      if !scales.nil? && scales.length > 0
        gon.indicator_scales = scales
      end
    end
  end



end
