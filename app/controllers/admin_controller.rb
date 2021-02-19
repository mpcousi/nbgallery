require 'rubygems/package'

# Controller for admin pages
class AdminController < ApplicationController
  before_action :verify_admin

  # GET /admin
  def index
    # Links to other admin pages
    @total_authors = Notebook.includes(:creator).group(:creator).count.count
  end

  # GET /admin/recommender_summary
  def recommender_summary
    @total_notebooks = Notebook.count
    @total_users = User.count
    @total_recommendations = SuggestedNotebook.count
    @notebooks_recommended = SuggestedNotebook.pluck('COUNT(DISTINCT(notebook_id))').first
    @users_with_recommendations = SuggestedNotebook.pluck('COUNT(DISTINCT(user_id))').first

    @reasons = SuggestedNotebook
      .select(reason_select)
      .group(:reason)
      .order('count DESC')

    @most_suggested_notebooks = SuggestedNotebook
      .group(:notebook)
      .order('count_all DESC')
      .limit(50)
      .count

    @users_with_most_suggestions = SuggestedNotebook
      .group(:user)
      .order('count_all DESC')
      .limit(50)
      .count

    @most_suggested_groups = SuggestedGroup
      .group(:group)
      .order('count_all DESC')
      .limit(25)
      .count

    @most_suggested_tags = SuggestedTag.top(:tag, 25)

    @scores = SuggestedNotebook
      .group('notebook_id, user_id')
      .pluck('notebook_id, user_id, TRUNCATE(SUM(score), 1) as rounded_score')
      .group_by(&:last)
      .map {|score, arr| [score, arr.count]}
      .sort_by(&:first)

    @user_notebook_scores = SuggestedNotebook
      .includes(:notebook, :user)
      .select([
        'notebook_id',
        'user_id',
        SuggestedNotebook.reasons_sql,
        SuggestedNotebook.score_sql
      ].join(', '))
      .group('notebook_id, user_id')
      .order('score DESC')
      .limit(25)
  end

  # GET /admin/recommender
  def recommender
    @reason = params[:reason]

    @notebooks = SuggestedNotebook
      .where(reason: @reason)
      .group(:notebook)
      .order('count_all DESC')
      .limit(25)
      .count
    @notebook_count = SuggestedNotebook
      .where(reason: @reason)
      .select(:notebook_id)
      .distinct
      .count

    @users = SuggestedNotebook
      .where(reason: @reason)
      .group(:user)
      .order('count_all DESC')
      .limit(25)
      .count
    @user_count = SuggestedNotebook
      .where(reason: @reason)
      .select(:user_id)
      .distinct
      .count

    # Scores grouped into 0.05-sized bins
    @scores = SuggestedNotebook
      .where(reason: @reason)
      .select('FLOOR(score*20)/20 as rounded_score, count(*) as count')
      .group('rounded_score')
      .map {|result| [result.rounded_score, result.count]}
    @scores = GalleryLib.chart_prep(@scores, keys: (0..20).map {|i| i / 20.0})

    @distribution = SuggestedNotebook
      .where(reason: @reason)
      .select(reason_select)
      .first
  end

  # GET /admin/trendiness
  def trendiness
    @total_notebooks = Notebook.count
    @nonzero_trendiness = NotebookSummary.where('trendiness > 0.0').count

    @scores = NotebookSummary
      .where('trendiness > 0.0')
      .select('FLOOR(trendiness*20)/20 AS rounded_score, COUNT(*) AS count')
      .group('rounded_score')
      .map {|result| [result.rounded_score, result.count]}
    @scores = GalleryLib.chart_prep(@scores, keys: (0..20).map {|i| i / 20.0})

    @notebooks = NotebookSummary
      .includes(:notebook)
      .order(trendiness: :desc)
      .take(25)
      .map(&:notebook)
  end

  # GET /admin/health
  def health
    @execs = exec_helper(nil, false)
    @execs_last30 = exec_helper(nil, true)
    @execs_pass = exec_helper(true, false)
    @execs_pass_last30 = exec_helper(true, true)
    @execs_fail = exec_helper(false, false)
    @execs_fail_last30 = exec_helper(false, true)

    @total_code_cells = CodeCell.count
    @cell_execs = cell_exec_helper(nil, false)
    @cell_execs_fail = @cell_execs - cell_exec_helper(true, false)
    @cell_execs_last30 = cell_exec_helper(nil, true)
    @cell_execs_fail_last30 = @cell_execs_last30 - cell_exec_helper(true, true)

    @total_notebooks = Notebook.count
    @notebook_execs = notebook_exec_helper(nil, false)
    @notebook_execs_fail = @notebook_execs - notebook_exec_helper(true, false)
    @notebook_execs_last30 = notebook_exec_helper(nil, true)
    @notebook_execs_fail_last30 = @notebook_execs_last30 - notebook_exec_helper(true, true)

    @lang_by_day = Execution
      .languages_by_day
      .map {|lang, entries| { name: lang, data: entries }}
    @lang_by_day = GalleryLib.chart_prep(@lang_by_day)

    @users_by_day = Execution.users_by_day

    @success_by_cell_number = execution_success_chart(
      Execution,
      'code_cells.cell_number',
      :cell_number
    )

    @recently_executed = Notebook.recently_executed.limit(20)
    @recently_failed = Notebook.recently_failed.limit(20)

    # Graph with x = fail rate, y = cells with fail rate >= x
    @cumulative_fail_rates = CodeCell.cumulative_fail_rates

    @scores = notebook_health_distribution
  end

  # GET /admin/user_similarity
  def user_similarity
    @scores = similarity_helper(UserSimilarity)
  end

  # GET /admin/user_summary
  def user_summary
    @top_users = UserSummary.includes(:user).order(user_rep_raw: :desc).take(50)
    @top_authors = UserSummary.includes(:user).order(author_rep_raw: :desc).take(50)
  end

  # GET /admin/notebook_similarity
  def notebook_similarity
    @more_like_this = similarity_helper(NotebookSimilarity)
    @users_also_view = similarity_helper(UsersAlsoView)
  end

  # GET /admin/packages
  def packages
    @packages = Notebook.package_summary
  end

  # GET /admin/exception
  def exception
    blah = nil
    render json: blah.stuff
  end

  # GET /admin/notebooks
  def notebooks
    notebooks_info =  Notebook.includes(:creator).group(:creator).count
    total_notebooks = 0
    notebooks_info.each_value do |value|
      total_notebooks += value
    end
    @total_notebooks = total_notebooks
    @total_authors = notebooks_info.count
    @public_count = Notebook.where('public=true').count
    @private_count = Notebook.where('public=false').count
    @notebooks_info = notebooks_info.sort_by {|_user, num| -num}
  end

  # GET /admin/import
  def import
  end

  # POST /admin/import_upload
  def import_upload
    uncompressed = Gem::Package::TarReader.new(Zlib::GzipReader.open(uploaded_archive))
    @errors = []
    @successes = []
    text = uncompressed.detect do |f|
      f.full_name == "metadata.json"
    end.read
    if text.empty?
      raise JupyterNotebook::BadFormat, 'metadata.json file is missing'
    end
    @metadata = JSON.parse(text, symbolize_names: true)
    uncompressed.rewind
    uncompressed.each do |file|
      next if file.full_name == "metadata.json"
      key = file.full_name.gsub('.ipynb','').to_sym
      @metadata.rehash
      if @metadata[key].nil?
        @errors[@errors.length]='Metadata missing for ' + key + '-' + file.full_name
        next
      end
      if @metadata[key][:owner_type] == "User"
        owner = User.find_by(:user_name => @metadata[key][:owner])
      elsif @metadata[key][:owner_type] == "Group"
        owner = Group.find_by(:name => @metadata[key][:owner])
      else
        @errors[@errors.length]='Owner type missing for ' + file.full_name
        next
      end

      if owner.nil?
        @errors[@errors.length]='Owner missing for  ' + file.full_name
        next
      end
      creator = User.find_by(:user_name => @metadata[key][:creator])
      updater = User.find_by(:user_name => @metadata[key][:updater])

      jn = JupyterNotebook.new(file.read)
      jn.strip_output!
      jn.strip_gallery_meta!
      staging_id = SecureRandom.uuid
      stage = Stage.new(uuid: staging_id, user: @user)
      stage.content = jn.pretty_json
      if !stage.save
        @errors[@errors.length]='Unable to stage notebook ' + file.full_name
      end
      # Check existence: (owner, title) must be unique
      notebook = Notebook.find_or_initialize_by(
        owner: owner,
        title: Notebook.groom(@metadata[key][:title])
      )
      new_record=notebook.new_record?
      old_content = notebook.content
      if !new_record
        if @metadata[key][:uuid].nil?
          @errors[@errors.length]='A notebook with that title for that owner already exists and the UUID was not specified in the metadata.  Will not overwrite. ' + file.full_name
          next
        elsif @metadata[key][:uuid] != notebook.uuid
          @errors[@errors.length]='A notebook with that title for that owner already exists and the UUID specified in the metadata did not match the UUID of the notebook. Will not overwrite. ' + file.full_name
          next
        elsif @metadata[key][:updated].to_date < notebook.updated_at.to_date
          @errors[@errors.length]='The notebook in the gallery was updated more recently than the uploaded notebook and will not be updated ' + file.full_name
          next
        end
      else
        notebook.uuid = @metadata[key][:uuid].nil? ? stage.uuid : @metadata[key][:uuid]
        notebook.title = @metadata[key][:title]
        notebook.public = !@metadata[key][:public].nil? ? @metadata[key][:public] : params[:visibility]
        notebook.creator = creator
        notebook.owner = owner
      end
      notebook.lang, notebook.lang_version = jn.language
      if !@metadata[key][:tags].nil?
        #Todo add tags
        #notebook.tags = @metadata[key][:tags]
      end
      notebook.description = @metadata[key][:description] if @metadata[key][:description].present?
      notebook.updater = updater if !updater.nil?
      if !@metadata[key][:updated].nil?
        notebook.updated_at = @metadata[key][:updated].to_date
      end
      if !@metadata[key][:created].nil?
        notebook.created_at = @metadata[key][:created].to_date
      end
      notebook.content = stage.content # saves to cache

      # Check validity of the notebook content.
      # This is not done at stage time because validations may depend on
      # user/notebook metadata or request parameters.
      raise Notebook::BadUpload.new('bad content', jn.errors) if jn.invalid?(notebook, owner, params)

      # Check validity - we want to be as sure as possible that the DB records
      # will save before we start storing the content anywhere.
      raise Notebook::BadUpload.new('invalid parameters'  + "-"  + params[:visibility], notebook.errors) if notebook.invalid?

      notebook.commit_id = stage.uuid
      commit_message = "Notebook Imported by Admininistrator"
      # Save to the db and to local cache

      if notebook.save
        stage.destroy
        if new_record
          real_commit_id = Revision.notebook_create(notebook, updater, commit_message)
          revision = Revision.where(notebook_id: notebook.id).last
          if !@metadata[key][:updated].nil?
            revision.updated_at = @metadata[key][:updated].to_date
            revision.created_at = @metadata[key][:updated].to_date
          end
          revision.save!
          @successes[@successes.length] = { title: notebook.title, url: notebook_path(notebook), method: "created"}
          if !updater.nil?
            UsersAlsoView.initial_upload(notebook, updater)
            notebook.thread.subscribe(updater)
          end
        else
          method = (notebook.content == old_content ? :notebook_metadata : :notebook_update)
          real_commit_id = Revision.send(method, notebook, updater, commit_message)
          if !updater.nil?
            UsersAlsoView.initial_upload(notebook, updater)
            notebook.thread.subscribe(updater)
          end
          revision = Revision.where(notebook_id: notebook.id).last
          revision.commit_message = commit_message
          if !@metadata[key][:updated].nil?
            revision.updated_at = @metadata[key][:updated].to_date
            revision.created_at = @metadata[key][:updated].to_date
          end
          revision.save!
          @successes[@successes.length] = { title: notebook.title, url: notebook_path(notebook), method: "updated"}
        end
      else
        # We checked validity before saving, so we don't expect to land here, but
        # if we do, we need to rollback the content storage.
        @errors[@errors.length] = "Failed to save " + file.full_name + " : " + notebook.errors
        notebook.remove_content
        stage.destroy
      end
    end
  end

  # GET /admin/download_export
  def download_export
    @notebooks = Notebook.where('public=true')
    if @notebooks.count > 0
      export_filename = "/tmp/" + SecureRandom.uuid + ".tar.gz"
      metadata = {}
      File.open(export_filename,"wb") do |archive|
        Zlib::GzipWriter.wrap(archive) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            @notebooks.each do |notebook|
              @metadata[notebook.uuid] = {:updated => notebook.updated_at, :created => notebook.created_at, :title => notebook.title, :description => notebook.description, :uuid => notebook.uuid, :public => notebook.public}
              if notebook.creator
                @metadata[notebook.uuid][:creator] = notebook.creator.user_name
              end
              if notebook.updater
                @metadata[notebook.uuid][:updater] = notebook.updater.user_name
              end
              if notebook.owner
                if notebook.owner.is_a?(User)
                  @metadata[notebook.uuid][:owner] = notebook.owner.user_name
                  @metadata[notebook.uuid][:owner_type] = "User"
                else
                  @metadata[notebook.uuid][:owner] = notebook.owner.description
                  @metadata[notebook.uuid][:owner_type] = "Group"
                end
              end
              if notebook.tags.length > 0
                @metadata[notebook.uuid][:tags] = []
                notebook.tags.each do |tag_obj|
                  @metadata[notebook.uuid][:tags][@metadata[notebook.uuid][:tags].length] = tag_obj.tag
                end
              end
              content = notebook.content
              tar.add_file_simple(notebook.uuid + ".ipynb", 0644, content.bytesize) do |io|
                io.write(content)
              end #end tar add_file_simple
            end #End notebooks.each
            tar.add_file_simple("metadata.json", 0644, metadata.to_json.bytesize) do |io|
              io.write(metadata.to_json)
            end #end tar add_file_simple
          end #End TarWriter
        end #End GzipWriter
      end #End File.open
      File.open(export_filename, "rb") do |archive|
        send_data(archive.read, filename: "notebook_export.tar.gz", type: "application/gzip")
      end
      File.unlink(export_filename)
    else
      raise ActiveRecord::RecordNotFound, "No Notebooks Found"
    end
  end

  private

  def reason_select
    [
      'count(1) as count',
      'avg(score) as mean',
      'stddev(score) as stddev',
      'min(score) as min',
      'max(score) as max',
      'reason'
    ].join(', ')
  end

  def exec_helper(success, last30)
    relation = Execution
    relation = relation.where(success: success) unless success.nil?
    relation = relation.where('updated_at > ?', 30.days.ago) if last30
    relation.count
  end

  def cell_exec_helper(success, last30)
    relation = Execution
    relation = relation.where(success: success) unless success.nil?
    relation = relation.where('executions.updated_at > ?', 30.days.ago) if last30
    relation.select(:code_cell_id).distinct.count
  end

  def notebook_exec_helper(success, last30)
    relation = Execution.joins(:code_cell)
    relation = relation.where(success: success) unless success.nil?
    relation = relation.where('executions.updated_at > ?', 30.days.ago) if last30
    relation.select(:notebook_id).distinct.count
  end

  def similarity_helper(table)
    similarity = table
      .select('ROUND(score*50)/50 AS rounded_score, COUNT(*) AS count')
      .group('rounded_score')
      .map {|result| [result.rounded_score, result.count]}
    GalleryLib.chart_prep(similarity, keys: (0..50).map {|i| i / 50.0})
  end

  def notebook_health_distribution
    # Hash of {:healthy => number of healthy notebooks, etc}
    counts = NotebookSummary
      .where.not(health: nil)
      .pluck(:health)
      .group_by {|x| Notebook.health_symbol(x)}
      .map {|sym, vals| [sym, vals.size]}
      .to_h
    # Histogram of scores in 0.05-sized bins
    scores = NotebookSummary
      .where.not(health: nil)
      .select('FLOOR(health*40)/40 AS rounded_score, COUNT(*) AS count')
      .group('rounded_score')
      .map {|result| [result.rounded_score, result.count]}
      .group_by {|score, _count| Notebook.health_symbol(score + 0.01)}
      .map {|sym, data| { name: "#{sym} (#{counts[sym]})", data: data }}
    GalleryLib.chart_prep(scores, keys: (0..40).map {|i| i / 40.0})
  end
  def uploaded_archive
    if params[:file].nil?
      [request.body.read, nil]
    else
      unless params[:file].respond_to?(:tempfile) && params[:file].respond_to?(:original_filename)
        raise JupyterNotebook::BadFormat, 'Expected a file object.'
      end
      unless params[:file].original_filename.end_with?('.tar.gz')
        raise JupyterNotebook::BadFormat, 'File extension must be .tar.gz'
      end
      params[:file].tempfile
    end
  end
end
