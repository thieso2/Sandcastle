class OauthCallbacksController < ApplicationController
  allow_unauthenticated_access

  def create
    auth = request.env["omniauth.auth"]
    identity = OauthIdentity.find_by(provider: auth.provider, uid: auth.uid)

    if identity
      sign_in_oauth_user(identity.user)
    elsif (user = User.find_by(email_address: auth.info.email))
      user.oauth_identities.create!(provider: auth.provider, uid: auth.uid)
      sign_in_oauth_user(user)
    else
      user = create_oauth_user(auth)
      user.oauth_identities.create!(provider: auth.provider, uid: auth.uid)
      redirect_to new_session_path, notice: "Account created. An admin must approve your account before you can sign in."
    end
  end

  def failure
    redirect_to new_session_path, alert: "OAuth sign in failed: #{params[:message].to_s.humanize}."
  end

  private

  def sign_in_oauth_user(user)
    if user.suspended?
      redirect_to new_session_path, alert: "Your account has been suspended."
    elsif user.pending_approval?
      redirect_to new_session_path, alert: "Your account is pending admin approval."
    else
      start_new_session_for(user)
      redirect_to after_authentication_url
    end
  end

  def create_oauth_user(auth)
    name = derive_username(auth)
    User.create!(
      name: name,
      email_address: auth.info.email,
      password: SecureRandom.base64(32),
      status: "pending_approval"
    )
  end

  def derive_username(auth)
    base = if auth.info.nickname.present?
      auth.info.nickname
    else
      auth.info.email.split("@").first
    end

    base = base.downcase.gsub(/[^a-z0-9_-]/, "").gsub(/\A[^a-z]+/, "")
    base = "user" if base.length < 2
    base = base[0, 31]

    return base unless User.exists?(name: base)

    (2..99).each do |n|
      candidate = "#{base[0, 28]}#{n}"
      return candidate unless User.exists?(name: candidate)
    end

    "user#{SecureRandom.hex(4)}"
  end
end
