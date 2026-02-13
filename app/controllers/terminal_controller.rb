class TerminalController < ApplicationController
  allow_unauthenticated_access only: :auth
  skip_before_action :require_password_change, only: :auth

  def open
    sandbox = if Current.user.admin?
      Sandbox.active.find(params[:id])
    else
      Current.user.sandboxes.active.find(params[:id])
    end

    url = TerminalManager.new.open(sandbox: sandbox)
    redirect_to url, allow_other_host: false, status: :see_other
  rescue TerminalManager::Error => e
    redirect_to root_path, alert: e.message
  end

  def close
    sandbox = if Current.user.admin?
      Sandbox.active.find(params[:id])
    else
      Current.user.sandboxes.active.find(params[:id])
    end

    TerminalManager.new.close(sandbox: sandbox)
    redirect_to root_path, notice: "Terminal closed"
  rescue TerminalManager::Error => e
    redirect_to root_path, alert: e.message
  end

  # Called by Traefik forwardAuth — returns status code only, no body/redirect
  def auth
    forwarded_uri = request.headers["X-Forwarded-Uri"] || ""
    match = forwarded_uri.match(%r{/terminal/(\d+)/wetty})
    head(:unauthorized) and return unless match

    session_record = find_session_by_cookie
    head(:unauthorized) and return unless session_record

    user = session_record.user
    sandbox = Sandbox.active.find_by(id: match[1].to_i)
    head(:unauthorized) and return unless sandbox && (sandbox.user_id == user.id || user.admin?)

    head :ok
  end
end
