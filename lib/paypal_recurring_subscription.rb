require 'rubygems'
require 'active_merchant'
require File.dirname(__FILE__) + '/active_merchant/billing/paypal_express_recurring_gateway'

module PaypalRecurringSubscription
  # Catch all errors from this module with
  #   rescue PaypalRecurringSubscription::Error => e
  # Errors from talking to the Paypal server (such as incorrect API credentials)
  # will either set errors on the model, or throw a 
  # PaypalRecurringSubscription::ServerError exception.
  class Error < StandardError; end
	class ServerError < Error; end
	class GatewayNotConfigured < Error; end
	
	def self.included(klass)
	  klass.extend(ClassMethods)
	  
    klass.serialize :info
    klass.send('attr_accessor', :token, :initial_amount, :start_date)
    
    klass.belongs_to(
      :pending_subscription,
      :class_name => klass.to_s,
      :foreign_key => 'pending_subscription_id'
    )
        
    klass.before_create :create_profile
    klass.after_create  :activate, :if => Proc.new{|p| p.state == State::ACTIVE}
    
    klass.before_destroy :ensure_deactivated
  end
	
  module ClassMethods  
    def get_authorisation_url(description, return_url, cancel_url)
      response = self.gateway.setup_agreement(
  			:description       => description,
  			:return_url        => return_url,
  			:cancel_return_url => cancel_url
  		)
  		if response.success?
  			return self.gateway.redirect_url_for(response.token)
  		else
  			raise PaypalRecurringSubscription::ServerError.new(response.message)
  		end
  	end
  	
  	def gateway=(gateway)
  	  @gateway = gateway
  	end
  	
  	def gateway
  	  if @gateway.nil?
  	    raise GatewayNotConfigured,
  	          "Please set #{self}.gateway to a configured instance of " +
  	          "ActiveMerchant::Billing::PaypalExpressRecurringGateway"
  	  end
  	  return @gateway
  	end
  	
  	def process_modifications
  	  for subscription in self.find(
  	                        :all, 
  	                        :conditions => [
  	                          'modify_on < ? AND (state = ? OR state = ?)', 
                	            Time.now, State::CANCELLED, State::CHANGED
                	          ])
  	    if subscription.state == State::CANCELLED
  	      subscription.state = State::INACTIVE
  	      subscription.deactivate
  	      subscription.save
  	    elsif subscription.state == State::CHANGED
  	      subscription.state = State::INACTIVE
  	      subscription.deactivate
  	      subscription.save
  	      
  	      subscription.pending_subscription.state = State::ACTIVE
  	      subscription.pending_subscription.activate
  	      subscription.pending_subscription.save
  	    end
  	  end
  	end
  end
  
  def initialize(*args)
    super(*args)
    self.state ||= State::ACTIVE
  end
  
  def gateway
    self.class.gateway
  end
  
  # Subscriptions can be in one of the following states:
  #   PaypalRecurringSubscription::ACTIVE - The Paypal profile is active and
  #   the user should be receiving services based on the current subscription.
  #   PaypalRecurringSubscription::CANCELLED - The Paypal profile has been 
  #   cancelled, but the user should still be receiving services based
  #   on the subscription.
  #   PaypalRecurringSubscription::INACTIVE - The Paypal profile is cancelled
  #   and the user should not be receiving the service.
  #   PaypalRecurringSubscription::CHANGED - The user has changed their
  #   subscription but it will not come in to effect until the current billing
  #   cycle is over. The current Paypal profile has been cancelled and a new
  #   one set up to begin charging at the beginning of the next billing cycle.
  #   The new subscription is stored with the state PENDING
  #   PaypalRecurringSubscription::PENDING - The user has changed subscription
  #   to this one, but it will not come into effect until the current billing
  #   cycle of the previous subscription is complete.
  module State
    ACTIVE    = 'active'
    CANCELLED = 'cancelled'
    INACTIVE  = 'inactive'
    CHANGED   = 'changed'
    PENDING   = 'pending'
  end

  # Returns true if the user should still be receiving the service. This
  # includes when the subscription is active, when it has been cancelled but
  # not yet deactivated and when it is waiting to be changed. This is the states
  # ACTIVE, CANCELLED, and CHANGED
  def active?
    [State::ACTIVE, State::CANCELLED, State::CHANGED].include?(self.state)
  end

  # Returns true if the subscription is cancelled and waiting to be terminated
  def cancelled?
    self.state == State::CANCELLED
  end
  
  def profile_options
    raise NotImplementedError, "please implement #profile_options to return a hash of options to configure the Paypal profile"
  end
  
  # Called when the service a subscription provides should become active for the
  # user. This is after the subscription is created, or after a subscription
  # is upgraded to a new one.
  def activate
  end
  
  # Called when the service provided by a subscription should be terminated. 
  # This is after a cancelled subscription runs out, or a new subscription is
  # activated.
  def deactivate
  end

  # Returns a hash with all the details stored by Paypal for the profile
  # corresponding to this subscription. This is not the prettiest set of 
  # information and it's content varies depending on the state of the
  # profile. Be careful if accessing it directly.
  def profile
    if @profile.blank?
      response = self.gateway.get_profile_details(self.paypal_profile_id)
      if response.success?
        @profile = response.params
      else
        raise Subscription::ServerError.new(response.message)
      end
    end
    return @profile
  end
  
  # Returns the next payment due date from the Paypal profile.
  # Note this does not exist if the profile is cancelled.
  def next_payment_due
    return nil if self.profile['next_billing_date'].blank?
    return Time.parse(self.profile['next_billing_date'])
  end
  
  module ProfileStatus
    ACTIVE    = 'ActiveProfile'
    PENDING   = 'PendingProfile'
    CANCELLED = 'CancelledProfile'
    SUSPENDED = 'SuspendedProfile'
    EXPIRED   = 'ExpiredProfile'
  end
  
  def profile_status
    self.profile['profile_status']
  end
  
  def modify(new_attributes = {})
    timeframe = new_attributes.delete(:timeframe) || :renewal
    
    if self.state == State::CHANGED
      # The subscription has already been updated. Cancel the existing pending
      # subscription since we are going to recreate a new one with the new
      # attributes.
      self.pending_subscription.cancel(:timeframe => :now)
    end
  
    if timeframe == :now
      modify_now(new_attributes)
    else
      modify_on_renewal(new_attributes)
    end
  end
  
  # Cancels a subscription. Takes the following optoins:
  #   :timeframe - :now or :renewal depending on whether the subscription
  #   should be deactivated immediately or when the next payment would be due.
  def cancel(options = {})
    timeframe = options[:timeframe] || :renewal
    
    # We do nothing for profiles which are already CANCELLED or INACTIVE.
    if [State::ACTIVE, State::CHANGED, State::PENDING].include?(self.state)
    
      if self.state == State::CHANGED
        # Subscription is due to be changed. This profile has already been
        # been cancelled so cancel the new subscription profile instead.
        return self.pending_subscription.cancel(options)
      end
      
      # This is no longer accessible once profile is cancelled
      cache_next_payment_due = self.next_payment_due
      
      # TODO: Issue refund for immediate cancellations (not for PENDING 
      # subscriptions though)
      # TODO: What about ProfileStatus::PENDING
      if [ProfileStatus::ACTIVE, ProfileStatus::SUSPENDED].include?(self.profile_status)
        response = self.gateway.cancel_profile(self.paypal_profile_id)
        if response.success?
          save_as_cancelled(timeframe, cache_next_payment_due)
        else
          self.errors.add_to_base(response.message)
          return false
        end
      else
        # Paypal profile is already cancelled for some reason
        save_as_cancelled(timeframe, cache_next_payment_due)
      end
    end
  end
  
private
  
  def create_profile
    profile_options = self.profile_options.dup
    profile_options[:start_date] = self.start_date.nil? ? Time.now : self.start_date
    profile_options[:initial_amount] = self.initial_amount unless self.initial_amount.nil?
      
    response = self.gateway.create_profile(
      self.token,
      profile_options
    )
    if response.success?
      self.paypal_profile_id = response.params['profile_id']
      return true
    else
      self.errors.add_to_base(response.message)
      return false
    end
  end
  
  def save_as_cancelled(timeframe, cache_next_payment_due)
    if timeframe == :now
      self.state = State::INACTIVE
      self.deactivate
    else
      self.state = State::CANCELLED
      self.modify_on = cache_next_payment_due
    end
    return self.save
  end
  
  def modify_now(new_attributes = {})
    next_payment_date = self.next_payment_due
    
    # Deactivate this subscription and activate the new one.
    response = self.gateway.cancel_profile(self.paypal_profile_id)
    if response.success?
      
      new_subscription = self.class.new(
        user_attributes.merge(new_attributes).merge({
          :start_date => next_payment_date
        })
      )

      seconds_left = (next_payment_date - Time.now).to_i
      seconds_left = 0 unless seconds_left > 0
      
      # We round to get the number of days left. This seems fairest for
      # everyone
      days_left = (seconds_left / 60.0 / 60.0 / 24.0).round
      
      current_subscription_length = self.profile_options[:frequency].months.to_i / 60.0 / 60.0 / 24.0
      refund_due = ((days_left / current_subscription_length.to_f) * self.profile_options[:amount]).to_i
      
      new_subscription_length = new_subscription.profile_options[:frequency].months.to_i / 60.0 / 60.0 / 24.0
      extra_due = ((days_left / new_subscription_length.to_f) * new_subscription.profile_options[:amount]).to_i
      
      difference = extra_due - refund_due
      if difference >= 0
        new_subscription.initial_amount = difference
      else
        raise NotImplementedError, "can't issue refunds"
      end
      
      self.deactivate
      self.state = State::INACTIVE
      
      self.save and new_subscription.save
    else
      raise Subscription::ServerError.new(response.message)
    end
  end
  
  def modify_on_renewal(new_attributes = {})
    # Create new subscription to start on renewal
    new_subscription = self.class.new(
      user_attributes.merge(new_attributes).merge({
        :start_date => self.next_payment_due,
        :state      => State::PENDING
      })
    )
    new_subscription.save
    
    # Set this subscription to expire on renewal and pass onto the new 
    # subcription
    response = self.gateway.cancel_profile(self.paypal_profile_id)
    if response.success?
      self.state = State::CHANGED
      self.pending_subscription = new_subscription
      self.modify_on = self.next_payment_due
      self.save
    else
      raise Subscription::ServerError.new(response.message)
    end
  end
  
  # Returns all attributes which are set by the user. Used to copy user state of
  # subscription.
  def user_attributes
    filtered_attributes = self.attributes.dup
    filtered_attributes.delete('paypal_profile_id')
    filtered_attributes.delete('state')
    filtered_attributes.delete('modify_on')
    filtered_attributes.delete('pending_subscription_id')
    filtered_attributes.delete('id')
    filtered_attributes.delete('created_at')
    filtered_attributes.delete('updated_at')
    return filtered_attributes
  end
  
  def ensure_deactivated
    unless self.state == State::INACTIVE
      self.state = State::INACTIVE
      self.deactivate
    end
  end
end
