module Api
  class SandboxAliasesController < BaseController
    before_action :set_sandbox

    def index
      render json: @sandbox.aliases.order(:kind, :value).map { |a| alias_json(a) }
    end

    def create
      a = @sandbox.aliases.build(kind: params[:kind], value: params[:value])
      if a.save
        DnsManager.publish_best_effort(@sandbox.user)
        SandboxCertificateRefreshJob.perform_later(@sandbox.id) if defined?(SandboxCertificateRefreshJob)
        SandboxCaddyReloadJob.perform_later(@sandbox.id) if defined?(SandboxCaddyReloadJob)
        render json: alias_json(a), status: :created
      else
        render json: { error: a.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    end

    def destroy
      a = @sandbox.aliases.find(params[:id])
      a.destroy!
      DnsManager.publish_best_effort(@sandbox.user)
      SandboxCertificateRefreshJob.perform_later(@sandbox.id) if defined?(SandboxCertificateRefreshJob)
      SandboxCaddyReloadJob.perform_later(@sandbox.id) if defined?(SandboxCaddyReloadJob)
      render json: { status: "removed" }
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Alias not found" }, status: :not_found
    end

    private

    def set_sandbox
      @sandbox = current_user.sandboxes.active.find(params[:sandbox_id])
    end

    def alias_json(a)
      {
        id: a.id,
        sandbox_id: a.sandbox_id,
        kind: a.kind,
        value: a.value,
        fqdn: a.fqdn
      }
    end
  end
end
