class Group < ActiveRecord::Base

  include Authority::Abilities
  self.authorizer_name = 'GroupAuthorizer'

  has_many :memberships, dependent: :destroy
  has_many :membership_requests, dependent: :destroy
  has_many :people, -> { order(:last_name, :first_name) }, through: :memberships
  has_many :admins, -> { where('memberships.admin IS true').order(:last_name, :first_name) }, through: :memberships, source: :person
  has_many :messages, -> { order(updated_at: :desc) }, dependent: :destroy
  has_many :notes, -> { order(created_at: :desc) }
  has_many :prayer_requests, -> { order(created_at: :desc) }
  has_many :attendance_records
  has_many :albums, as: :owner
  has_many :album_pictures, through: :albums, source: :pictures
  has_many :stream_items, -> { order('created_at desc') }, dependent: :destroy
  has_many :attachments, dependent: :delete_all
  has_many :group_times, dependent: :destroy
  has_many :checkin_times, through: :group_times
  belongs_to :creator, class_name: 'Person', foreign_key: 'creator_id'
  belongs_to :leader, class_name: 'Person', foreign_key: 'leader_id'
  belongs_to :parents_of_group, class_name: 'Group', foreign_key: 'parents_of'
  belongs_to :site

  scope :active, -> { where(hidden: false) }
  scope :hidden, -> { where(hidden: true) }
  scope :unapproved, -> { where(approved: false) }
  scope :approved, -> { where(approved: true) }
  scope :is_public, -> { where(private: false, hidden: false) } # cannot be 'public'
  scope :is_private, -> { where(private: true, hidden: false) } # cannot be 'private'
  scope :standard, -> { where("parents_of is null and (link_code is null or link_code = '')") }
  scope :linked, -> { where("link_code is not null and link_code != ''") }
  scope :parents_of, -> { where("parents_of is not null") }
  scope :checkin_destinations, -> { includes(:group_times).where('group_times.checkin_time_id is not null').order('group_times.ordering') }
  scope :recent, -> age { where("created_at >= ?", age.ago) }

  scope_by_site_id

  has_attached_file :photo, PAPERCLIP_PHOTO_OPTIONS

  validates_presence_of :name
  validates_presence_of :category
  validates_uniqueness_of :name, scope: :site_id
  validates_format_of :address, with: /\A[a-zA-Z0-9]+\z/, allow_nil: true
  validates_uniqueness_of :address, allow_nil: true, scope: :site_id
  validates_length_of :address, in: 2..30, allow_nil: true
  validates_uniqueness_of :cm_api_list_id, allow_nil: true, allow_blank: true, scope: :site_id
  validates_attachment_size :photo, less_than: PAPERCLIP_PHOTO_MAX_SIZE, message: I18n.t('photo.too_large', size: 10, :scope => 'activerecord.errors.models.group.attributes')
  validates_attachment_content_type :photo, content_type: PAPERCLIP_PHOTO_CONTENT_TYPES, message: I18n.t('photo.wrong_type', :scope => 'activerecord.errors.models.group.attributes')

  serialize :cached_parents

  validate :validate_self_referencing_parents_of

  def validate_self_referencing_parents_of
    begin
      errors.add('parents_of', :points_to_self) if not new_record? and parents_of == id
    rescue
      puts 'error checking for self-referencing parents_of (OK if you are migrating)'
    end
  end

  geocoded_by :location
  after_validation :geocode

  blank_to_nil :address

  def inspect
    "<#{name}>"
  end

  def admin?(person, exclude_global_admins=false)
    if person
      if exclude_global_admins
        admins.include? person
      else
        person.admin?(:manage_groups) or admins.include? person
      end
    end
  end

  def last_admin?(person)
    person and admin?(person, :exclude_global_admins) and admins.length == 1
  end

  def linked?
    link_code and link_code.any?
  end

  def mapable?
    latitude and longitude
  end

  def get_options_for(person)
    memberships.where(person_id: person.id).first
  end

  def set_options_for(person, options)
    memberships.where(person_id: person.id).first.update_attributes!(options)
  end

  after_save :update_memberships

  def update_memberships
    if parents_of
      parents = Group.find(parents_of).people.map { |p| p.parents }.flatten.uniq
      update_membership_associations(parents)
    elsif linked?
      q = []
      p = []
      link_code.downcase.split.each do |code|
        q << "lcase(classes) = ? or
              lcase(classes) like ? or lcase(classes) like ? or lcase(classes) like ? or
              lcase(classes) like ? or lcase(classes) like ?"
        p += [code,
              "#{code},%", "%,#{code}", "%,#{code},%",
              "#{code}[%", "%,#{code}[%"]
      end
      scope = Person.where(q.join(' or '), *p)
      update_membership_associations(scope.to_a)
    elsif Membership.column_names.include?('auto')
      memberships.where(auto: true).each { |m| m.destroy }
    end
    # have to expire the group fragments here since this is run in background nightly
    ActionController::Base.cache_store.delete_matched(%r{groups/#{id}})
  end

  def update_membership_associations(new_people)
    new_people.reject! { |p| !p || p.deleted? }
    people.reload
    # update existing
    memberships.where(person_id: (new_people & people).map(&:id)).includes(:person).each do |membership|
      membership.roles = get_roles_for(membership.person)
      membership.save!
    end
    # add new people
    (new_people - people).each do |person|
      memberships.create!(
        person: person,
        auto:   true,
        roles:  get_roles_for(person)
      )
    end
    # remove old people
    memberships.where(
      person_id: (people - new_people).map(&:id),
      auto: true
    ).delete_all
  end

  def get_roles_for(person)
    return [] unless link_code.present?
    classes = person.classes.to_s.split(/\s*,\s*/)
    if data = classes.detect { |c| c.downcase.index(link_code.downcase) == 0 } and data.match(/\[(.+)\]/)
      $1.gsub(/[^a-z0-9 \-_\(\)\|]+/i, '').split(/\s*\|\s*/)
    else
      []
    end
  end

  def can_send?(person)
    (email? and members_send? and person.member_of?(self) and person.messages_enabled?) or admin?(person)
  end
  alias_method 'can_post?', 'can_send?'

  def can_share?(person)
    person.member_of?(self) and \
      (
        (email? and can_post?(person)) or \
        blog? or \
        pictures? or \
        prayer?
      )
  end

  def full_address
    address.to_s.any? ? (address + '@' + Site.current.email_host) : nil
  end

  def get_people_attendance_records_for_date(date)
    records = {}
    people.each { |p| records[p.id] = [p, false] }
    date = Date.parse(date) if(date.is_a?(String))
    attendance_records.where('attended_at >= ? and attended_at <= ?', date.strftime('%Y-%m-%d 0:00'), date.strftime('%Y-%m-%d 23:59:59')).each do |record|
      records[record.person.id] = [record.person, record]
    end
    records.values.sort_by { |r| [r[0].last_name, r[0].first_name] }
  end

  def attendance_dates
    attendance_records.find_by_sql("select distinct attended_at from attendance_records where group_id = #{id} and site_id = #{Site.current.id} order by attended_at desc").map { |r| r.attended_at }
  end

  def gcal_url
    if gcal_private_link.to_s.any?
      if token = gcal_token
        "https://www.google.com/calendar/embed?pvttk=#{token}&amp;showTitle=0&amp;showCalendars=0&amp;showTz=1&amp;height=600&amp;wkst=1&amp;bgcolor=%23FFFFFF&amp;src=#{gcal_account}&amp;color=%23A32929&amp;ctz=#{Time.zone.tzinfo.name}"
      end
    end
  end

  def gcal_account
    gcal_private_link.to_s.match(/[a-z0-9\._]+(@|%40)[a-z\.]+/).to_s.sub(/@/, '%40')
  end

  def gcal_token
    gcal_private_link.to_s.match(/private\-([a-z0-9]+)/)[1] rescue ''
  end

  before_destroy :remove_parent_of_links

  def remove_parent_of_links
    Group.where(parents_of: id).each { |g| g.update_attribute(:parents_of, nil) }
  end

  def can_add_prayer_request?(person)
    person.can_create?(prayer_requests.new)
  end

  def can_add_album?(person)
    person.can_create?(albums.new)
  end

  class << self
    def update_memberships
      order(:parents_of).each(&:update_memberships)
    end

    def categories
      {}.tap do |cats|
        if Person.logged_in.admin?(:manage_groups)
          results = Group.find_by_sql("select category, count(*) as group_count from groups where category is not null and category != '' and category != 'Subscription' and site_id = #{Site.current.id} group by category").map { |g| [g.category, g.group_count] }
        else
          results = Group.find_by_sql(["select category, count(*) as group_count from groups where category is not null and category != '' and category != 'Subscription' and hidden = ? and approved = ? and site_id = #{Site.current.id} group by category", false, true]).map { |g| [g.category, g.group_count] }
        end
        results.each do |cat, count|
          cats[cat] = count.to_i
        end
      end
    end

    def category_names
      categories.keys.sort
    end

    def count_by_type
      {
        public: is_public.count,
        private: is_private.count
      }.reject { |k, v| v == 0 }
    end

    def count_by_linked
      {
        standard: standard.count,
        linked: linked.count,
        parents_of: parents_of.count
      }.reject { |k, v| v == 0 }
    end

    EXPORT_COLS = {
      group: %w(
        name
        description
        meets
        location
        directions
        other_notes
        creator_id
        address
        members_send
        private
        category
        leader_id
        updated_at
        hidden
        approved
        link_code
        parents_of
        blog
        email
        prayer
        attendance
        legacy_id
        gcal_private_link
        approval_required_to_join
        pictures
        cm_api_list_id
      ),
      member: %w(
        first_name
        last_name
        id
        legacy_id
      )
    }

    def to_csv
      CSV.generate do |csv|
        csv << EXPORT_COLS[:group]
        (1..(Group.count/50)).each do |page|
          Group.paginate(include: :people, per_page: 50, page: page).each do |group|
            csv << EXPORT_COLS[:group].map { |c| group.send(c) }
          end
        end
      end
    end

    def create_to_csv_job
      Job.add("GeneratedFile.create!(:job_id => JOB_ID, :person_id => #{Person.logged_in.id}, :file => FakeFile.new(Group.to_csv, 'groups.csv'))")
    end

    def to_xml
      builder = Builder::XmlMarkup.new
      builder.groups do |groups|
        (1..(Group.count/50)).each do |page|
          Group.paginate(include: :people, per_page: 100, page: page).each do |group|
            groups.group do |g|
              EXPORT_COLS[:group].each do |col|
                g.tag!(col, group.send(col))
              end
              g.people do |people|
                group.people.each do |person|
                  people.person do |p|
                    EXPORT_COLS[:member].each do |col|
                      p.tag!(col, person.send(col))
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def create_to_xml_job
      Job.add("GeneratedFile.create!(:job_id => JOB_ID, :person_id => #{Person.logged_in.id}, :file => FakeFile.new(Group.to_xml, 'groups.xml'))")
    end
  end
end
