class SettingsController < ApplicationController
  ALLOWED_TABS = %w[profile tokens sandboxes network files].freeze

  def show
    @user = Current.user
    @api_tokens = @user.api_tokens.active.order(created_at: :desc)
  end

  def update_profile
    @user = Current.user

    if @user.update(profile_params)
      redirect_to_tab(notice: "Profile updated successfully.")
    else
      render :show, status: :unprocessable_entity
    end
  end

  def update_password
    @user = Current.user

    unless @user.authenticate(params[:current_password])
      redirect_to_tab(alert: "Current password is incorrect.")
      return
    end

    if @user.update(password_params)
      redirect_to_tab(notice: "Password changed successfully.")
    else
      redirect_to_tab(alert: @user.errors.full_messages.join(", "))
    end
  end

  def update_smb_password
    @user = Current.user

    if @user.update(smb_password_params)
      SandboxManager.new.update_smb_password(user: @user)
      redirect_to_tab(notice: "SMB password updated.")
    else
      redirect_to_tab(alert: @user.errors.full_messages.join(", ").presence || "Failed to update SMB password.")
    end
  end

  def toggle_tailscale
    @user = Current.user

    if @user.update(tailscale_auto_connect: !@user.tailscale_auto_connect)
      status = @user.tailscale_auto_connect ? "enabled" : "disabled"
      redirect_to_tab(notice: "Tailscale auto-connect #{status}.")
    else
      redirect_to_tab(alert: "Failed to update Tailscale settings.")
    end
  end

  def update_custom_links
    @user = Current.user
    links = (params[:custom_links] || []).reject { |l| l[:name].blank? && l[:url].blank? }.map do |l|
      { "name" => l[:name].to_s.strip, "url" => l[:url].to_s.strip, "show_on" => l[:show_on].presence || "all" }
    end

    if @user.update(custom_links: links)
      redirect_to_tab(notice: "Custom links updated.")
    else
      redirect_to_tab(alert: @user.errors.full_messages.join(", "))
    end
  end

  def update_ssh_keys
    @user = Current.user
    keys = (params[:ssh_keys] || []).reject { |k| k[:key].blank? }.map do |k|
      { "name" => k[:name].to_s.strip.presence || "key-#{SecureRandom.hex(3)}", "key" => k[:key].to_s.strip }
    end

    if @user.update(ssh_keys: keys)
      redirect_to_tab(notice: "SSH keys updated.")
    else
      redirect_to_tab(alert: @user.errors.full_messages.join(", "))
    end
  end

  def update_persisted_paths
    @user = Current.user
    paths = (params[:persisted_paths] || []).map { |p| p[:path].to_s.strip.chomp("/") }.reject(&:blank?).uniq

    PersistedPath.transaction do
      @user.persisted_paths.where.not(path: paths).destroy_all
      paths.each { |p| @user.persisted_paths.find_or_create_by!(path: p) }
    end

    redirect_to_tab(notice: "Persisted directories updated.")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to_tab(alert: e.message)
  end

  def update_injected_files
    @user = Current.user
    rows = (params[:injected_files] || []).reject { |r| r[:path].blank? }

    InjectedFile.transaction do
      kept_paths = rows.map { |r| r[:path].to_s.strip }
      @user.injected_files.where.not(path: kept_paths).destroy_all

      rows.each do |row|
        path = row[:path].to_s.strip
        record = @user.injected_files.find_or_initialize_by(path: path)
        # Empty content on existing record = leave as-is (lets users edit path/mode without re-uploading content)
        record.content = row[:content] if row[:content].present? || record.new_record?
        # Mode is always octal in form input ("600" → 0o600 = 384 decimal)
        record.mode = row[:mode].to_s.to_i(8) if row[:mode].present?
        record.save!
      end
    end

    redirect_to_tab(notice: "Injected files updated.")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to_tab(alert: e.message)
  end

  def delete_injected_file
    @user = Current.user
    @user.injected_files.find(params[:id]).destroy!
    redirect_to_tab(notice: "Injected file removed.")
  end

  def generate_token
    @user = Current.user

    token_name = params[:name].presence || "Web UI Token"
    token, raw_token = ApiToken.generate_for(@user, name: token_name)

    flash[:api_token] = raw_token
    redirect_to_tab(notice: "API token '#{token_name}' generated. Make sure to copy it now - you won't be able to see it again!")
  end

  def revoke_token
    @user = Current.user
    token = @user.api_tokens.find(params[:id])
    token_name = token.name
    token.destroy!

    redirect_to_tab(notice: "API token '#{token_name}' revoked.")
  end

  private

  # Redirect back to /settings, preserving the active tab the user was on.
  # Tab names are allowlisted so no user-controlled fragment lands in the URL.
  def redirect_to_tab(notice: nil, alert: nil)
    tab = params[:tab].to_s
    anchor = ALLOWED_TABS.include?(tab) ? tab : nil
    redirect_to settings_path(anchor: anchor), notice: notice, alert: alert
  end

  def profile_params
    params.require(:user).permit(
      :email_address, :full_name, :github_username,
      :sandbox_archive_retention_days, :terminal_emulator,
      :default_vnc_enabled, :default_mount_home, :default_docker_enabled, :default_data_path
    )
  end

  def password_params
    params.require(:user).permit(:password, :password_confirmation)
  end

  def smb_password_params
    params.require(:user).permit(:smb_password)
  end
end
