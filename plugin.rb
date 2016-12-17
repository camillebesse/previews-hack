# name: discourse-topic-previews
# about: A Discourse plugin that gives you a topic preview image in the topic list
# version: 0.2
# authors: Angus McLeod

register_asset 'stylesheets/previews_common.scss'
register_asset 'stylesheets/previews_mobile.scss'

module TopicListAddon
  def load_topics
    @topics = super

    # SQL only works with postgresql 9.4+
    # TODO: better to keep track of previewed posts' id so they can be loaded at once
    accepted_anwser_post_ids = @topics.map { |t| t.custom_fields["accepted_answer_post_id"]&.to_i }.compact
    posts = Post.all.joins("JOIN unnest('{#{accepted_anwser_post_ids.join(',')}}'::int[]) WITH ORDINALITY t(id, ord) USING (id)").order("t.ord")
    idx = 0
    @topics.each do |t|
      next unless t.custom_fields["accepted_answer_post_id"]
      t.previewed_post = posts[idx]
      idx += 1
    end
    normal_topic_ids = topics.delete_if { |t| t.custom_fields["accepted_answer_post_id"]&.to_i }.map(&:id)
    posts = Post.where("post_number = 1 AND topic_id IN (?)", normal_topic_ids).joins("JOIN unnest('{#{normal_topic_ids.join(',')}}'::int[]) WITH ORDINALITY t(topic_id, ord) USING (topic_id)").order("t.ord")
    idx = 0
    @topics.each do |t|
      next if t.custom_fields["accepted_answer_post_id"]
      t.previewed_post = posts[idx]
      idx += 1
    end

    if @current_user
      previewed_post_ids = @topics.map { |t| t.previewed_post.id }
      post_actions_map = {}
      PostAction.where("post_id IN (?) AND user_id = ?", previewed_post_ids, @current_user.id).each do |pa|
        (post_actions_map[pa.post_id] ||= []) << pa
      end
      @topics.each do |t|
        t.previewed_post_actions = post_actions_map[t.previewed_post.id]
      end
    end

    @topics
  end
end

after_initialize do
  Category.register_custom_field_type('topic_list_category_badge_move', :boolean)
  Topic.register_custom_field_type('thumbnails', :json)

  @nil_thumbs = TopicCustomField.where( name: 'thumbnails', value: nil )
  if @nil_thumbs.length
    @nil_thumbs.each do |thumb|
      hash = { :normal => '', :retina => ''}
      thumb.value = ::JSON.generate(hash)
      thumb.save!
    end
  end

  module ListHelper
    class << self
      def create_thumbnails(id, image, original_url)
        width = SiteSetting.topic_list_thumbnail_width
        height = SiteSetting.topic_list_thumbnail_height
        normal = image ? thumbnail_url(image, width, height, original_url) : original_url
        retina = image ? thumbnail_url(image, width*2, height*2, original_url) : original_url
        thumbnails = { normal: normal, retina: retina }
        save_thumbnails(id, thumbnails)
        return thumbnails
      end

      def thumbnail_url (image, w, h, original_url)
        image.create_thumbnail!(w, h) if !image.has_thumbnail?(w, h)
        image.has_thumbnail?(w, h) ? image.thumbnail(w, h).url : original_url
      end

      def save_thumbnails(id, thumbnails)
        return if !thumbnails
        topic = Topic.find(id)
        topic.custom_fields['thumbnails'] = thumbnails
        topic.save_custom_fields
      end
    end
  end

  class ::Topic
    attr_accessor :previewed_post
    attr_accessor :previewed_post_actions
  end

  require_dependency 'guardian/post_guardian'
  module ::PostGuardian
    def previewed_post_can_act?(post, topic, action_key, opts={})
      taken = opts[:taken_actions].try(:keys).to_a
      is_flag = PostActionType.is_flag?(action_key)
      already_taken_this_action = taken.any? && taken.include?(PostActionType.types[action_key])
      already_did_flagging      = taken.any? && (taken & PostActionType.flag_types.values).any?

      result = if authenticated? && post && !@user.anonymous?

        return false if action_key == :notify_moderators && !SiteSetting.enable_private_messages

        # we allow flagging for trust level 1 and higher
        # always allowed for private messages
        (is_flag && not(already_did_flagging) && (@user.has_trust_level?(TrustLevel[1]) || topic.private_message?)) ||

        # not a flagging action, and haven't done it already
        not(is_flag || already_taken_this_action) &&

        # nothing except flagging on archived topics
        not(topic.try(:archived?)) &&

        # nothing except flagging on deleted posts
        not(post.trashed?) &&

        # don't like your own stuff
        not(action_key == :like && is_my_own?(post)) &&

        # new users can't notify_user because they are not allowed to send private messages
        not(action_key == :notify_user && !@user.has_trust_level?(SiteSetting.min_trust_to_send_messages)) &&

        # non-staff can't send an official warning
        not(action_key == :notify_user && !is_staff? && opts[:is_warning].present? && opts[:is_warning] == 'true') &&

        # can't send private messages if they're disabled globally
        not(action_key == :notify_user && !SiteSetting.enable_private_messages) &&

        # no voting more than once on single vote topics
        not(action_key == :vote && opts[:voted_in_topic] && topic.has_meta_data_boolean?(:single_vote))
      end

      !!result
    end
  end

  TopicList.preloaded_custom_fields << "accepted_answer_post_id" if TopicList.respond_to? :preloaded_custom_fields
  TopicList.preloaded_custom_fields << "thumbnails" if TopicList.respond_to? :preloaded_custom_fields
  TopicList.class_eval do
    prepend TopicListAddon
  end

  require 'cooked_post_processor'
  class ::CookedPostProcessor

    def get_linked_image(url)
      max_size = SiteSetting.max_image_size_kb.kilobytes
      file = FileHelper.download(url, max_size, "discourse", true) rescue nil
      Rails.logger.info "Downloaded linked image: #{file}"
      image = file ? Upload.create_for(@post.user_id, file, file.path.split('/')[-1], File.size(file.path)) : nil
      image
    end

    def create_topic_thumbnails(url)
      local = UrlHelper.is_local(url)
      image = local ? Upload.find_by(sha1: url[/[a-z0-9]{40,}/i]) : get_linked_image(url)
      Rails.logger.info "Creating thumbnails with: #{image}"
      ListHelper.create_thumbnails(@post.topic.id, image, url)
    end

    def update_post_image
      img = extract_images_for_post.first
      if img["src"].present?
        url = img["src"][0...255]
        @post.update_column(:image_url, url) # post
        if @post.is_first_post?
          @post.topic.update_column(:image_url, url) # topic
          return if SiteSetting.topic_list_hotlink_thumbnails
          create_topic_thumbnails(url)
        end
      end
    end

  end

  require 'topic_list_item_serializer'
  class ::TopicListItemSerializer
    attributes :thumbnails,
               :topic_post_id,
               :topic_post_liked,
               :topic_post_like_count,
               :topic_post_can_like,
               :topic_post_can_unlike,
               :topic_post_bookmarked,
               :topic_post_is_current_users

    def include_topic_post_id?
      object.previewed_post.present?
    end

    def topic_post_id
      object.previewed_post.id
    end

    def excerpt
      cooked = object.previewed_post.cooked
      excerpt = PrettyText.excerpt(cooked, SiteSetting.topic_list_excerpt_length, keep_emoji_images: true)
      excerpt.gsub!(/(\[#{I18n.t 'excerpt_image'}\])/, "") if excerpt
      excerpt
    end

    def include_excerpt?
      object.excerpt.present?
    end

    def thumbnails
      return unless object.archetype == Archetype.default
      if SiteSetting.topic_list_hotlink_thumbnails
        thumbs = { normal: object.image_url, retina: object.image_url }
      else
        thumbs = get_thumbnails || get_thumbnails_from_image_url
      end
      thumbs
    end

    def include_thumbnails?
      thumbnails.present? && (thumbnails[:normal].present? || thumbnails['normal'].present?)
    end

    def get_thumbnails
      thumbnails = object.custom_fields['thumbnails']
      if thumbnails.is_a?(String)
        thumbnails = ::JSON.parse(thumbnails)
      end
      if thumbnails.is_a?(Array)
        thumbnails = thumbnails[0]
      end
      thumbnails.is_a?(Hash) ? thumbnails : false
    end

    def get_thumbnails_from_image_url
      image = Upload.get_from_url(object.image_url) rescue false
      return ListHelper.create_thumbnails(object.id, image, object.image_url)
    end

    def topic_post_actions
      object.previewed_post_actions || []
    end

    def topic_like_action
      topic_post_actions.select {|a| a.post_action_type_id == PostActionType.types[:like]}
    end

    def topic_post_bookmarked
      !!topic_post_actions.any?{|a| a.post_action_type_id == PostActionType.types[:bookmark]}
    end
    alias :include_topic_post_bookmarked? :topic_post_id

    def topic_post_liked
      topic_like_action.any?
    end
    alias :include_topic_post_liked? :topic_post_id

    def topic_post_like_count
      object.previewed_post.like_count
    end

    def include_topic_post_like_count?
      object.previewed_post&.id && topic_post_like_count > 0
    end

    def topic_post_can_like
      return false if !scope.current_user || topic_post_is_current_users
      scope.previewed_post_can_act?(object.previewed_post, object, PostActionType.types[:like], taken_actions: topic_post_actions)
    end
    alias :include_topic_post_can_like? :topic_post_id

    def topic_post_is_current_users
      return scope.current_user && (object.previewed_post.user_id == scope.current_user.id)
    end
    alias :include_topic_post_is_current_users? :topic_post_id

    def topic_post_can_unlike
      return false if !scope.current_user
      action = topic_like_action[0]
      !!(action && (action.user_id == scope.current_user.id) && (action.created_at > SiteSetting.post_undo_action_window_mins.minutes.ago))
    end
    alias :include_topic_post_can_unlike? :topic_post_id

  end

  add_to_serializer(:basic_category, :topic_list_excerpt) {object.custom_fields["topic_list_excerpt"]}
  add_to_serializer(:basic_category, :topic_list_thumbnail) {object.custom_fields["topic_list_thumbnail"]}
  add_to_serializer(:basic_category, :topic_list_action) {object.custom_fields["topic_list_action"]}
  add_to_serializer(:basic_category, :topic_list_category_badge_move) {object.custom_fields["topic_list_category_badge_move"]}
  add_to_serializer(:basic_category, :topic_list_default_thumbnail) {object.custom_fields["topic_list_default_thumbnail"]}
end
