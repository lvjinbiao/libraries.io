class Project < ApplicationRecord
  include ProjectSearch
  include SourceRank
  include Status
  include Releases

  include GithubProject
  include GitlabProject
  include BitbucketProject

  HAS_DEPENDENCIES = false
  STATUSES = ['Active', 'Deprecated', 'Unmaintained', 'Help Wanted', 'Removed']
  API_FIELDS = [:name, :platform, :description, :language, :homepage,
                :repository_url, :normalized_licenses, :rank, :status,
                :latest_release_number, :latest_release_published_at,
                :latest_stable_release_number, :latest_stable_release_published_at,
                :dependents_count, :dependent_repos_count, :latest_download_url]

  validates_presence_of :name, :platform
  validates_uniqueness_of :name, scope: :platform, case_sensitive: true

  belongs_to :repository
  has_many :versions
  has_many :dependencies, -> { group 'project_name' }, through: :versions
  has_many :contributions, through: :repository
  has_many :contributors, through: :contributions, source: :repository_user
  has_many :tags, through: :repository
  has_many :published_tags, -> { where('published_at IS NOT NULL') }, through: :repository, class_name: 'Tag'
  has_many :dependents, class_name: 'Dependency'
  has_many :dependent_versions, through: :dependents, source: :version, class_name: 'Version'
  has_many :dependent_projects, -> { group('projects.id').order('projects.rank DESC NULLS LAST') }, through: :dependent_versions, source: :project, class_name: 'Project'
  has_many :repository_dependencies
  has_many :dependent_repositories, -> { group('repositories.id').order('repositories.rank DESC NULLS LAST, repositories.stargazers_count DESC') }, through: :repository_dependencies, source: :repository
  has_many :subscriptions
  has_many :project_suggestions, dependent: :delete_all
  has_many :registry_permissions, dependent: :delete_all
  has_many :registry_users, through: :registry_permissions
  has_one :readme, through: :repository

  scope :platform, ->(platform) { where(platform: PackageManager::Base.format_name(platform)) }
  scope :lower_platform, ->(platform) { where('lower(projects.platform) = ?', platform.try(:downcase)) }
  scope :lower_name, ->(name) { where('lower(projects.name) = ?', name.try(:downcase)) }

  scope :with_homepage, -> { where("homepage <> ''") }
  scope :with_repository_url, -> { where("repository_url <> ''") }
  scope :without_repository_url, -> { where("repository_url IS ? OR repository_url = ''", nil) }
  scope :with_repo, -> { joins(:repository).where('repositories.id IS NOT NULL') }
  scope :without_repo, -> { where(repository_id: nil) }
  scope :with_description, -> { where("projects.description <> ''") }

  scope :with_license, -> { where("licenses <> ''") }
  scope :without_license, -> { where("licenses IS ? OR licenses = ''", nil) }
  scope :unlicensed, -> { maintained.without_license.with_repo.where("repositories.license IS ? OR repositories.license = ''", nil) }

  scope :with_versions, -> { where('versions_count > 0') }
  scope :without_versions, -> { where('versions_count < 1') }
  scope :few_versions, -> { where('versions_count < 2') }
  scope :many_versions, -> { where('versions_count > 2') }

  scope :with_dependents, -> { where('dependents_count > 0') }
  scope :with_dependent_repos, -> { where('dependent_repos_count > 0') }

  scope :with_github_url, -> { where('repository_url ILIKE ?', '%github.com%') }
  scope :with_gitlab_url, -> { where('repository_url ILIKE ?', '%gitlab.com%') }
  scope :with_bitbucket_url, -> { where('repository_url ILIKE ?', '%bitbucket.org%') }
  scope :with_launchpad_url, -> { where('repository_url ILIKE ?', '%launchpad.net%') }
  scope :with_sourceforge_url, -> { where('repository_url ILIKE ?', '%sourceforge.net%') }

  scope :most_watched, -> { joins(:subscriptions).group('projects.id').order("COUNT(subscriptions.id) DESC") }
  scope :most_dependents, -> { with_dependents.order('dependents_count DESC') }
  scope :most_dependent_repos, -> { with_dependent_repos.order('dependent_repos_count DESC') }

  scope :visible, -> { where('projects."status" != ? OR projects."status" IS NULL', "Hidden")}
  scope :maintained, -> { where('projects."status" not in (?) OR projects."status" IS NULL', ["Deprecated", "Removed", "Unmaintained", "Hidden"])}
  scope :deprecated, -> { where('projects."status" = ?', "Deprecated")}
  scope :not_removed, -> { where('projects."status" not in (?) OR projects."status" IS NULL', ["Removed", "Hidden"])}
  scope :removed, -> { where('projects."status" = ?', "Removed")}
  scope :unmaintained, -> { where('projects."status" = ?', "Unmaintained")}
  scope :hidden, -> { where('projects."status" = ?', "Hidden")}

  scope :indexable, -> { not_removed.includes(:repository) }

  scope :unsung_heroes, -> { maintained
                             .with_repo
                             .where('repositories.stargazers_count < 100')
                             .where('projects.dependent_repos_count > 1000') }

  scope :digital_infrastructure, -> { not_removed
                             .with_repo
                             .where('projects.dependent_repos_count > ?', 10000)}

  scope :bus_factor, -> { maintained
                          .joins(:repository)
                          .where('repositories.contributions_count < 6')
                          .where('repositories.contributions_count > 0')
                          .where('repositories.stargazers_count > 0')}

  scope :hacker_news, -> { with_repo.where('repositories.stargazers_count > 0').order("((repositories.stargazers_count-1)/POW((EXTRACT(EPOCH FROM current_timestamp-repositories.created_at)/3600)+2,1.8)) DESC") }
  scope :recently_created, -> { with_repo.where('repositories.created_at > ?', 2.weeks.ago)}

  after_commit :update_repository_async, on: :create
  after_commit :set_dependents_count, on: [:create, :update]
  after_commit :update_source_rank_async, on: [:create, :update]
  before_save  :update_details
  before_destroy :destroy_versions

  def self.total
    Rails.cache.fetch 'projects:total', :expires_in => 1.day, race_condition_ttl: 2.minutes do
      self.all.count
    end
  end

  def to_param
    { name: name, platform: platform.downcase }
  end

  def to_s
    name
  end

  def manual_sync
    async_sync
    update_repository_async
    self.last_synced_at = Time.zone.now
    forced_save
  end

  def forced_save
    self.updated_at = Time.zone.now
    save
  end

  def sync
    check_status
    if status == 'Removed'
      set_last_synced_at
      return
    end

    result = platform_class.update(name)
    set_last_synced_at unless result
  rescue
    set_last_synced_at
  end

  def set_last_synced_at
    update_attribute(:last_synced_at, Time.zone.now)
  end

  def async_sync
    PackageManagerDownloadWorker.perform_async(platform, name)
  end

  def recently_synced?
    last_synced_at && last_synced_at > 1.day.ago
  end

  def contributions_count
    repository.try(:contributions_count) || 0
  end

  def meta_tags
    {
      title: "#{name} on #{platform}",
      description: description,
    }
  end

  def update_details
    normalize_licenses
    set_latest_release_published_at
    set_latest_release_number
    set_latest_stable_release_info
    set_runtime_dependencies_count
    set_language
  end

  def keywords
    (Array(keywords_array) + Array(repository.try(:keywords) || [])).compact.uniq(&:downcase)
  end

  def package_manager_url(version = nil)
    platform_class.package_link(self, version)
  end

  def download_url(version = nil)
    platform_class.download_url(name, version) if version
  end

  def latest_download_url
    download_url(latest_release_number)
  end

  def documentation_url(version = nil)
    platform_class.documentation_url(name, version)
  end

  def install_instructions(version = nil)
    platform_class.install_instructions(self, version)
  end

  def owner
    return nil unless repository && repository.host_type == 'GitHub'
    RepositoryUser.host('GitHub').visible.login(repository.owner_name).first
  end

  def platform_class
    "PackageManager::#{platform}".constantize
  end

  def platform_name
    platform_class.formatted_name
  end

  def color
    Linguist::Language[language].try(:color) || platform_class.try(:color)
  end

  def mlt
    begin
      Project.where(id: mlt_ids).limit(5)
    rescue
      []
    end
  end

  def mlt_ids
    Rails.cache.fetch "projects:#{self.id}:mlt_ids", :expires_in => 1.week do
      results = Project.__elasticsearch__.client.mlt(id: self.id, index: 'projects', type: 'project', mlt_fields: 'keywords_array,platform,description,repository_url', min_term_freq: 1, min_doc_freq: 2)
      results['hits']['hits'].map{|h| h['_id']}
    end
  end

  def destroy_versions
    versions.find_each(&:destroy)
  end

  def stars
    repository.try(:stargazers_count) || 0
  end

  def forks
    repository.try(:forks_count) || 0
  end

  def watchers
    repository.try(:subscribers_count) || 0
  end

  def set_language
    return unless repository
    self.language = repository.try(:language)
  end

  def repo_name
    repository.try(:full_name)
  end

  def description
    if platform == 'Go'
      repository.try(:description).presence || read_attribute(:description)
    else
      read_attribute(:description).presence || repository.try(:description)
    end
  end

  def homepage
    read_attribute(:homepage).presence || repository.try(:homepage)
  end

  def set_dependents_count
    return if destroyed?
    new_dependents_count = dependents.joins(:version).pluck('DISTINCT versions.project_id').count

    # Most of the time we truncate this count if it is larger than 1,000 anyways, so only do slow version if less
    # Just as an example, rubygems/rake takes 500 ms for counting from the view, but 10 minutes if we do the
    # actual query on a database with no other load.
    if dependent_repos_count < 1000
      new_dependent_repos_count = dependent_repositories.open_source.count.length
    else
      new_dependent_repos_count = dependent_repos_fast_count
    end
    updates = {}
    updates[:dependents_count] = new_dependents_count if read_attribute(:dependents_count) != new_dependents_count
    updates[:dependent_repos_count] = new_dependent_repos_count if read_attribute(:dependent_repos_count) != new_dependent_repos_count
    self.update_columns(updates) if updates.present?
  end

  def needs_suggestions?
    repository_url.blank? || normalized_licenses.blank?
  end

  def self.undownloaded_repos
    with_github_url.or(with_gitlab_url).or(with_bitbucket_url).without_repo
  end

  def self.license(license)
    where("projects.normalized_licenses @> ?", Array(license).to_postgres_array(true))
  end

  def self.keyword(keyword)
    where("projects.keywords_array @> ?", Array(keyword).to_postgres_array(true))
  end

  def self.keywords(keywords)
    where("projects.keywords_array && ?", Array(keywords).to_postgres_array(true))
  end

  def self.language(language)
    where('lower(projects.language) = ?', language.try(:downcase))
  end

  def self.all_languages
    @all_languages ||= Linguist::Language.all.map{|l| l.name.downcase}
  end

  def self.popular_languages(options = {})
    facets(options)[:languages].language.buckets
  end

  def self.popular_platforms(options = {})
    facets(options)[:platforms].platform.buckets.reject{ |t| ['biicode', 'jam'].include?(t['key'].downcase) }
  end

  def self.keywords_badlist
    ['bsd3', 'library']
  end

  def self.popular_keywords(options = {})
    facets(options)[:keywords].keywords_array.buckets.reject{ |t| all_languages.include?(t['key'].downcase) }.reject{|t| keywords_badlist.include?(t['key'].downcase) }
  end

  def self.popular_licenses(options = {})
    facets(options)[:licenses].normalized_licenses.buckets.reject{ |t| t['key'].downcase == 'other' }
  end

  def self.popular(options = {})
    results = search('*', options.merge(sort: 'rank', order: 'desc'))
    results.records.includes(:repository).reject{|p| p.repository.nil? }
  end

  def normalized_licenses
    read_attribute(:normalized_licenses).presence || [Project.format_license(repository.try(:license))].compact
  end

  def self.format_license(license)
    return nil if license.blank?
    return 'Other' if license.downcase == 'other'
    Spdx.find(license).try(:id) || license
  end

  def normalize_licenses
    if licenses.blank?
      normalized = []
    elsif licenses.length > 150
      normalized = ['Other']
    else
      downcased = licenses.downcase
      # chomp off leading/trailing () to make Spdx.find happier
      if downcased.start_with?('(')
        downcased[0] = ''
      end
      if downcased.start_with?(')')
        downcased[-1] = ''
      end
      # splits are OR, AND, COMMA (,), and SLASH (/)
      # technically OR and AND are different in meaning
      # but our model doesn't allow the distinction
      if downcased.include?("or")
        split = downcased.split(/or/)
      elsif downcased.include?("and")
        split = downcased.split(/and/)
      else
        split = licenses.split(/[,\/]/)
      end
      normalized = split.map do |license|
        Spdx.find(license).try(:id)
      end.compact
      normalized = ['Other'] if normalized.empty?
    end
    self.normalized_licenses = normalized
  end

  def update_repository_async
    RepositoryProjectWorker.perform_async(self.id) if known_repository_host_name.present?
  end

  def known_repository_host_name
    github_name_with_owner || bitbucket_name_with_owner || gitlab_name_with_owner
  end

  def known_repository_host
    return 'GitHub' if github_name_with_owner.present?
    return 'Bitbucket' if bitbucket_name_with_owner
    return 'GitLab' if gitlab_name_with_owner
  end

  def can_have_dependencies?
    return false if platform_class == Project
    platform_class::HAS_DEPENDENCIES
  end

  def can_have_versions?
    return false if platform_class == Project
    platform_class::HAS_VERSIONS
  end

  def release_or_tag
    can_have_versions? ? 'releases' : 'tags'
  end

  def update_repository
    return false unless known_repository_host_name.present?
    r = Repository.create_from_host(known_repository_host, known_repository_host_name)
    return if r.nil?
    unless self.new_record?
      self.repository_id = r.id
      self.forced_save
    end
  end

  def subscribed_repos(user)
    subscriptions.with_repository_subscription.where('repository_subscriptions.user_id = ?', user.id).map(&:repository).uniq
  end

  def dependent_repos_view_query(limit, offset=0)
    Repository.find_by_sql(["select * from repositories where id in (select repository_id from project_dependent_repositories where project_id = ? order by rank desc nulls last, stargazers_count desc limit ? offset ?);", id, limit, offset])
  end

  def dependent_repos_top_ten
    dependent_repos_view_query(10)
  end

  def dependent_repos_fast_count
    ProjectDependentRepository.where(project_id: id).count
  end

  def check_status(removed = false)
    url = platform_class.check_status_url(self)
    return if url.blank?
    response = Typhoeus.head(url)
    if platform.downcase == 'packagist' && response.response_code == 302
      update_attribute(:status, 'Removed')
    elsif platform.downcase != 'packagist' && [400, 404].include?(response.response_code)
      update_attribute(:status, 'Removed')
    elsif removed
      update_attribute(:status, nil)
    end
  end

  def unique_repo_requirement_ranges
    repository_dependencies.select('repository_dependencies.requirements').distinct.pluck(:requirements)
  end

  def unique_project_requirement_ranges
    dependents.select('dependencies.requirements').distinct.pluck(:requirements)
  end

  def unique_requirement_ranges
    (unique_repo_requirement_ranges + unique_project_requirement_ranges).uniq
  end

  def potentially_outdated?
    current_version = SemanticRange.clean(latest_release_number)
    unique_requirement_ranges.compact.sort.any? do |range|
      begin
        !(SemanticRange.gtr(current_version, range, false, platform) ||
        SemanticRange.satisfies(current_version, range, false, platform))
      rescue
        false
      end
    end
  end

  def download_registry_users
    # download owner data
    owner_json = platform_class.download_registry_users(name)
    owners = []

    return unless owner_json.present?

    # find or create registry users
    owner_json.each do |user|
      r = RegistryUser.find_or_create_by(platform: platform, uuid: user[:uuid])
      r.email = user[:email]
      r.login = user[:login]
      r.name = user[:name]
      r.url = user[:url]
      r.save if r.changed?
      owners << r
    end

    # update registry permissions
    existing_permissions = registry_permissions.includes(:registry_user).all
    existing_owners = existing_permissions.map(&:registry_user)

    # add new owners
    new_owners = owners - existing_owners
    new_owners.each do |owner|
      registry_permissions.create(registry_user: owner)
    end

    # remove missing users
    removed_owners = existing_owners - owners
    removed_owners.each do |owner|
      registry_permissions.find{|rp| rp.registry_user == owner}.destroy
    end
  end

  def self.find_with_includes!(platform, name, includes)
    # this clunkiness is because .includes() doesn't allow zero args and we want
    # to allow that.
    query = self.visible.platform(platform).where(name: name)
    query = query.includes(*includes) unless includes.empty?
    project = query.first
    if project.nil?
      query = self.visible.lower_platform(platform).lower_name(name)
      query = query.includes(*includes) unless includes.empty?
      project = query.first
    end
    raise ActiveRecord::RecordNotFound if project.nil?
    raise ActiveRecord::RecordNotFound if project.status == 'Hidden'
    project
  end

  def find_version!(version_name)
    version = if version_name == 'latest'
                versions.sort.first
              else
                versions.find_by_number(version_name)
              end

    raise ActiveRecord::RecordNotFound if version.nil?

    version
  end

end
